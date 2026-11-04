"""Cove-only shortcut receipts. No Seen import, model tools, or chat writes."""
import re
import sqlite3
import threading
import unicodedata
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from storage import APIError

MAX_BODY = 2048
MAX_DELAY_SECONDS = 600
MAX_QUEUED_DELAY_SECONDS = 7 * 24 * 60 * 60
QUEUED_APPS = ("微信", "抖音", "淘宝", "ChatGPT", "Cove", "CCC", "Safari", "小红书")
APP_ALIASES = {"WeChat": "微信", "rednote": "小红书"}
UUID_ID = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}")
MAX_SESSION_SECONDS = 86400
MAX_EVENTS = 250_000
ID = re.compile(r'[A-Za-z0-9_.-]{1,128}')
STAMP = re.compile(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})', re.ASCII)


def utc_now():
    return datetime.now(timezone.utc)


def iso(value):
    return value.astimezone(timezone.utc).isoformat(timespec='microseconds').replace('+00:00', 'Z')


def normalize(body):
    if not isinstance(body, dict) or set(body) != {'id', 'app', 'action', 'timestamp'}:
        raise APIError(400, '只接受 id、app、action、timestamp')
    identifier, name, action, stamp = (body[key] for key in ('id', 'app', 'action', 'timestamp'))
    if not isinstance(identifier, str) or not ID.fullmatch(identifier):
        raise APIError(400, '事件 ID 无效')
    if (not isinstance(name, str) or not name.strip() or len(name) > 80
            or name != name.strip() or any(unicodedata.category(c).startswith('C') for c in name)):
        raise APIError(400, 'App 名称无效')
    if not isinstance(action, str) or action not in ('open', 'close'):
        raise APIError(400, 'action 必须是 open 或 close')
    if not isinstance(stamp, str) or not STAMP.fullmatch(stamp):
        raise APIError(400, 'timestamp 必须是带时区的 ISO8601')
    try:
        parsed = datetime.fromisoformat(stamp.replace('Z', '+00:00')).astimezone(timezone.utc)
    except (ValueError, OverflowError):
        raise APIError(400, 'timestamp 无效') from None
    return {'id': identifier, 'app': unicodedata.normalize('NFC', name), 'action': action,
            'timestamp': iso(parsed)}, parsed.timestamp()


def day_bounds(day, time_zone):
    if not isinstance(day, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', day, re.ASCII):
        raise APIError(400, 'day 必须是 YYYY-MM-DD')
    if (not isinstance(time_zone, str) or not time_zone or len(time_zone) > 100
            or time_zone.startswith('/') or '..' in time_zone or '\\' in time_zone):
        raise APIError(400, 'timeZone 必须是有效 IANA 时区')
    try:
        zone = ZoneInfo(time_zone)
        local_day = date.fromisoformat(day)
        start = datetime.combine(local_day, datetime.min.time(), tzinfo=zone)
        end = datetime.combine(local_day + timedelta(days=1), datetime.min.time(), tzinfo=zone)
        return start.timestamp(), end.timestamp()
    except (ValueError, OverflowError, ZoneInfoNotFoundError):
        raise APIError(400, '日期或时区无效') from None


class AppEvents:
    def __init__(self, directory, configured=False, clock=utc_now):
        self.clock, self.configured = clock, configured
        self.lock = threading.RLock()
        path = Path(directory) / 'app-events.sqlite3'
        self.db = sqlite3.connect(path, check_same_thread=False)
        path.chmod(0o600)
        self.db.row_factory = sqlite3.Row
        self.db.executescript('''
            PRAGMA journal_mode=DELETE;
            PRAGMA synchronous=FULL;
            PRAGMA secure_delete=ON;
            CREATE TABLE IF NOT EXISTS setup(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS events(
                id TEXT PRIMARY KEY, app TEXT NOT NULL, action TEXT NOT NULL,
                timestamp TEXT NOT NULL, stamp REAL NOT NULL, received TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS event_time ON events(stamp);
        ''')
        with self.db:
            if configured:
                self.db.execute("INSERT OR IGNORE INTO setup VALUES('startedAt',?)", (iso(clock()),))
        row = self.db.execute("SELECT value FROM setup WHERE key='startedAt'").fetchone()
        self.started_at = row[0] if row else None

    def close(self):
        with self.lock:
            self.db.close()

    def ingest(self, body, *, queued=False):
        if not self.configured:
            raise APIError(503, 'Cove 独立快捷指令尚未配置')
        event, stamp = normalize(body)
        original = event.copy()
        if queued:
            if not UUID_ID.fullmatch(event['id']):
                raise APIError(400, '队列事件 ID 必须是 UUID')
            event['app'] = APP_ALIASES.get(event['app'], event['app'])
            if event['app'] not in QUEUED_APPS:
                raise APIError(400, '队列只接收已配置的八个 App')
        current = self.clock()
        with self.lock, self.db:
            old = self.db.execute('SELECT * FROM events WHERE id=?', (event['id'],)).fetchone()
            if old:
                # A pre-existing legacy alias keeps its exact stored identity.
                if (any(old[key] != event[key] for key in event)
                        and any(old[key] != original[key] for key in original)):
                    raise APIError(409, '事件 ID 已用于不同内容')
                return {'ok': True, 'id': event['id'], 'duplicate': True}
            started = datetime.fromisoformat(self.started_at.replace('Z', '+00:00')).timestamp()
            maximum = MAX_QUEUED_DELAY_SECONDS if queued else MAX_DELAY_SECONDS
            if stamp < started or not -60 <= current.timestamp() - stamp <= maximum:
                if queued:
                    raise APIError(400, "仅接受配置后且七天以内的新事件；未来时间最多容差一分钟")
                raise APIError(400, '仅接受配置后且十分钟以内的新事件；未来时间最多容差一分钟')
            if self.db.execute('SELECT count(*) FROM events').fetchone()[0] >= MAX_EVENTS:
                raise APIError(507, 'Cove App 事件存储已满；未删除旧记录')
            utc_day = int((stamp if queued else current.timestamp()) // 86400) * 86400
            count = self.db.execute('SELECT count(*) FROM events WHERE stamp>=? AND stamp<?',
                                    (utc_day, utc_day + 86400)).fetchone()[0]
            if count >= 10000:
                raise APIError(429, '今日 App 事件过多')
            self.db.execute('INSERT INTO events VALUES(?,?,?,?,?,?)',
                            (event['id'], event['app'], event['action'], event['timestamp'], stamp, iso(current)))
        return {'ok': True, 'id': event['id'], 'duplicate': False}

    def summary(self, day, time_zone):
        start, end = day_bounds(day, time_zone)
        # A bounded surrounding window permits proven cross-midnight pairs.
        with self.lock:
            rows = self.db.execute('SELECT app,action,stamp FROM events WHERE stamp>=? AND stamp<? '
                                   "ORDER BY stamp, CASE action WHEN 'open' THEN 0 ELSE 1 END,id",
                                   (start - MAX_SESSION_SECONDS, end + MAX_SESSION_SECONDS)).fetchall()
        opened, seconds, incomplete = {}, {}, False
        event_count = 0

        def overlaps(left, right):
            return left < end and right > start

        for row in rows:
            app, action, stamp = row['app'], row['action'], row['stamp']
            if start <= stamp < end:
                event_count += 1
                seconds.setdefault(app, 0.0)
            if action == 'open':
                previous = opened.get(app)
                if previous is not None and overlaps(previous, min(stamp, previous + MAX_SESSION_SECONDS)):
                    incomplete = True
                opened[app] = stamp
                continue
            previous = opened.pop(app, None)
            if previous is None:
                incomplete |= start <= stamp < end
            elif stamp - previous > MAX_SESSION_SECONDS:
                incomplete |= overlaps(previous, stamp)
            else:
                duration = max(0.0, min(stamp, end) - max(previous, start))
                if duration:
                    seconds[app] = seconds.get(app, 0.0) + duration
        for app, stamp in opened.items():
            if overlaps(stamp, stamp + MAX_SESSION_SECONDS):
                incomplete = True
                seconds.setdefault(app, 0.0)
        apps = [{'name': name, 'seconds': round(value, 3)} for name, value in seconds.items()]
        apps.sort(key=lambda item: (-item['seconds'], item['name']))
        return {'day': day, 'timeZone': time_zone, 'source': 'cove-shortcuts',
                'totalSeconds': round(sum(item['seconds'] for item in apps), 3), 'apps': apps,
                'eventCount': event_count, 'incomplete': bool(incomplete),
                'configured': self.configured, 'startedAt': self.started_at}
