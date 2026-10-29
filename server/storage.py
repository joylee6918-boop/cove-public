"""Private Cove records; every externally acknowledged write is committed."""
import json
import fcntl
import os
import sqlite3
import threading
import uuid
from datetime import date as calendar_date, datetime, timezone, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


def now():
    return datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=False)


class APIError(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message
        super().__init__(message)


from health_requests import HealthRequestStore
from collar import CollarStore
from continuity import ContinuityStore
from data_access import DataAccessStore
from toy_control import ToyControlStore
from memory_outbox import MemoryOutboxStore
from device_actions import DeviceActionStore
from auto_rollover import AutoRolloverStore
from personal_ledger import PersonalLedgerStore


class Store(PersonalLedgerStore, HealthRequestStore, CollarStore, ContinuityStore, DataAccessStore, ToyControlStore, MemoryOutboxStore, DeviceActionStore, AutoRolloverStore):
    def __init__(self, directory):
        self.directory = Path(directory).expanduser().resolve()
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self.directory, 0o700)
        self.process_lock = open(self.directory / 'server.lock', 'a')
        os.chmod(self.directory / 'server.lock', 0o600)
        try:
            fcntl.flock(self.process_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.process_lock.close()
            raise RuntimeError('Another Cove server already owns this data directory')
        self.lock = threading.RLock()
        self.db = sqlite3.connect(self.directory / 'cove.sqlite3', check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.executescript('''
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        PRAGMA foreign_keys=ON;
        PRAGMA secure_delete=ON;
        CREATE TABLE IF NOT EXISTS conversations(id TEXT PRIMARY KEY, title TEXT NOT NULL, created TEXT NOT NULL, thread TEXT UNIQUE);
        CREATE TABLE IF NOT EXISTS messages(id TEXT PRIMARY KEY, conversation TEXT NOT NULL REFERENCES conversations(id), body TEXT NOT NULL, fingerprint TEXT, revision INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS message_cursor ON messages(conversation,revision);
        CREATE TABLE IF NOT EXISTS revisions(id INTEGER PRIMARY KEY AUTOINCREMENT);
        CREATE TABLE IF NOT EXISTS jobs(message TEXT PRIMARY KEY REFERENCES messages(id), state TEXT NOT NULL, turn TEXT, assistant TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS state(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS attachments(id TEXT PRIMARY KEY, filename TEXT NOT NULL, mime TEXT NOT NULL, data BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS devices(token TEXT PRIMARY KEY, registered TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS health_requests(id TEXT PRIMARY KEY, conversation TEXT NOT NULL REFERENCES conversations(id), body TEXT NOT NULL, response TEXT);
        CREATE TABLE IF NOT EXISTS health_tool_results(call TEXT PRIMARY KEY, result TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS health_history(day TEXT PRIMARY KEY, snapshot TEXT NOT NULL, synced TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS file_tool_results(call TEXT PRIMARY KEY, attachment TEXT NOT NULL REFERENCES attachments(id));
        CREATE TABLE IF NOT EXISTS stickers(id TEXT PRIMARY KEY, owner TEXT NOT NULL CHECK(owner IN ('user','assistant')), label TEXT NOT NULL, created TEXT NOT NULL, attachment TEXT NOT NULL REFERENCES attachments(id), UNIQUE(owner,attachment));
        CREATE TABLE IF NOT EXISTS sticker_tool_results(call TEXT PRIMARY KEY, result TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS pulse_notes(message TEXT PRIMARY KEY REFERENCES messages(id), turn TEXT NOT NULL, thought_summary TEXT NOT NULL, intent TEXT NOT NULL, created TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS pulse_note_tool_results(call TEXT PRIMARY KEY, message TEXT NOT NULL REFERENCES messages(id), result TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS terminal_events(id INTEGER PRIMARY KEY AUTOINCREMENT, conversation TEXT NOT NULL REFERENCES conversations(id), body TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS terminal_cursor ON terminal_events(conversation,id);
        CREATE TABLE IF NOT EXISTS terminal_inputs(id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, result TEXT NOT NULL);
        ''')
        self.db.commit()
        self.init_collar()
        self.init_continuity()
        self.init_memory_outbox()
        self.init_auto_rollover()
        self.init_data_access()
        self.init_personal_ledger()
        self.init_toy_control()
        self.init_device_actions()
        if 'preview_mode' not in {r[1] for r in self.db.execute('PRAGMA table_info(devices)')}:
            self.db.execute("ALTER TABLE devices ADD COLUMN preview_mode TEXT NOT NULL DEFAULT 'generic'")
            self.db.commit()
        for p in self.directory.glob('cove.sqlite3*'):
            os.chmod(p, 0o600)
        # Uncertain dispatches are never replayed; queued work has not reached runtime.
        with self.lock, self.db:
            for row in self.db.execute("SELECT * FROM jobs WHERE state='running'").fetchall():
                message = self._message(row['message'])
                error = '健康续答在服务重启时中断；为避免重复回复，未自动重发。' if message.get('healthRequestID') else '服务在回复途中重启；未自动重发，请确认后发一条新消息。'
                self._finish(row['message'], 'failed', error)

    def _revision(self):
        return self.db.execute('INSERT INTO revisions DEFAULT VALUES').lastrowid

    def _put(self, message, fingerprint=None):
        revision = self._revision()
        message['revision'] = revision
        self.db.execute('INSERT INTO messages VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET body=excluded.body,revision=excluded.revision',
                        (message['id'], message['conversationID'], encode(message), fingerprint, revision))

    def _message(self, id):
        row = self.db.execute('SELECT body,revision FROM messages WHERE id=?', (id,)).fetchone()
        return dict(self._decode_message(row[0]), revision=row[1]) if row else None

    def _decode_message(self, body):
        message = json.loads(body)
        message.setdefault('readAt', None)
        message.setdefault('isLiked', False)
        if 'attachments' not in message:
            url = message.get('attachmentURL') or ''
            attachment = self._file_metadata(url.rsplit('/', 1)[-1]) if url.startswith('/v1/attachments/') else None
            message['attachments'] = [attachment] if attachment else []
        return message

    @staticmethod
    def attachment_ids(body):
        from files import MAX_ATTACHMENTS
        ids = body.get('attachmentIDs')
        legacy = body.get('attachmentID')
        if ids is None:
            ids = [legacy] if legacy else []
        if not isinstance(ids, list) or len(ids) > MAX_ATTACHMENTS or any(not isinstance(id, str) or not id for id in ids) or len(set(ids)) != len(ids):
            raise APIError(400, 'attachmentIDs 最多 10 个且不能重复')
        if legacy and ids != [legacy] and (not ids or ids[0] != legacy):
            raise APIError(400, 'attachmentID 与 attachmentIDs 不一致')
        return ids

    @classmethod
    def _identity(cls, body):
        result = {k: body.get(k) for k in ('id', 'conversationID', 'text', 'replyTo')}
        result['attachmentIDs'] = cls.attachment_ids(body)
        # Omit absent sticker identity so all existing durable retries remain valid.
        if body.get('stickerID') is not None:
            result['stickerID'] = body['stickerID']
        if body.get('travelSceneID') is not None:
            from travel_bridge import bounded_id
            result['travelSceneID'] = bounded_id(body['travelSceneID'])
        return result

    def conversation(self, id):
        row = self.db.execute('SELECT * FROM conversations WHERE id=?', (id,)).fetchone()
        if not row:
            raise APIError(404, '会话不存在')
        return dict(row)

    def create_conversation(self, id=None):
        id = id or str(uuid.uuid4())
        with self.lock, self.db:
            self.db.execute('INSERT OR IGNORE INTO conversations VALUES(?,?,?,NULL)', (id, '新对话', now()))
            self.db.execute("INSERT INTO state VALUES('active',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (encode(id),))
            c = self.conversation(id)
            return {'id': id, 'title': c['title'], 'createdAt': c['created']}

    def mark_window_reset(self, conversation):
        with self.lock, self.db:
            current = self.conversation(conversation)
            if not current['thread']:
                raise APIError(409, '当前会话没有可重开的 Codex 窗口')
            busy = self.db.execute("SELECT 1 FROM jobs JOIN messages ON jobs.message=messages.id WHERE messages.conversation=? AND jobs.state IN ('queued','running') LIMIT 1", (conversation,)).fetchone()
            if busy:
                raise APIError(409, '当前会话仍有待处理回复')
            self.db.execute('INSERT INTO state VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
                            ('window-reset:'+conversation, encode({'previousThread': current['thread']})))
            self.db.execute('UPDATE conversations SET thread=NULL WHERE id=?', (conversation,))
            return current['thread']

    def consume_window_reset(self, conversation):
        with self.lock, self.db:
            key = 'window-reset:'+conversation
            marked = self.db.execute('SELECT value FROM state WHERE key=?', (key,)).fetchone()
            if marked:
                self.db.execute('DELETE FROM state WHERE key=?', (key,))
            return json.loads(marked[0]) if marked else None

    def conversations(self):
        with self.lock:
            rows = self.db.execute("SELECT * FROM conversations WHERE id NOT IN (SELECT target FROM handoffs WHERE json_extract(body,'$.status')!='complete') ORDER BY created").fetchall()
            active = self.db.execute("SELECT value FROM state WHERE key='active'").fetchone()
            return {'conversations': [{'id': r['id'], 'title': r['title'], 'createdAt': r['created']} for r in rows],
                    'activeConversationID': json.loads(active[0]) if active else None}

    @staticmethod
    def _search_query(query, allow_empty=False):
        if not isinstance(query, str) or len(query.strip()) > 200 or '\x00' in query or (not allow_empty and not query.strip()):
            raise APIError(400, '搜索关键词需为 1 至 200 个字符')
        return query.strip()

    @staticmethod
    def _search_zone(value):
        if not isinstance(value, str) or not value or len(value) > 100 or '\x00' in value:
            raise APIError(400, '时区无效')
        try:
            return ZoneInfo(value)
        except (ZoneInfoNotFoundError, ValueError):
            raise APIError(400, '时区无效')

    @classmethod
    def _search_day_bounds(cls, value, time_zone):
        if not isinstance(value, str):
            raise APIError(400, '日期无效')
        try:
            day = calendar_date.fromisoformat(value)
        except ValueError:
            raise APIError(400, '日期无效')
        if day.isoformat() != value:
            raise APIError(400, '日期无效')
        zone = cls._search_zone(time_zone)
        stamp = lambda value: value.astimezone(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
        try:
            start = datetime.combine(day, datetime.min.time(), zone)
            end = datetime.combine(day + timedelta(days=1), datetime.min.time(), zone)
            return zone, stamp(start), stamp(end)
        except (OverflowError, ValueError):
            raise APIError(400, '日期无效')

    def search_messages(self, query, before=None, limit=20, date=None, time_zone=None):
        """Owner-only literal body search over the same visible chat projection."""
        if (date is None) != (time_zone is None):
            raise APIError(400, '日期与时区须同时提供')
        query = self._search_query(query, allow_empty=date is not None)
        start = end = None
        if date is not None:
            _, start, end = self._search_day_bounds(date, time_zone)
        def positive(value, maximum, label):
            if isinstance(value, str):
                if not value.isascii() or not value.isdigit() or len(value) > 19:
                    raise APIError(400, label+'无效')
                value = int(value)
            if type(value) is not int or not 1 <= value <= maximum:
                raise APIError(400, label+'无效')
            return value
        limit = positive(limit, 50, '搜索页大小')
        before = positive(before, 2**63-1, '搜索游标') if before is not None else 2**63-1
        sql = """SELECT m.rowid AS position,m.id,m.conversation,m.body,c.title
                 FROM messages m JOIN conversations c ON c.id=m.conversation
                 WHERE m.rowid<? AND json_extract(m.body,'$.role') IN ('user','assistant')
                   AND COALESCE(json_extract(m.body,'$.hidden'),0)=0
                   AND NOT EXISTS (SELECT 1 FROM handoffs h WHERE h.target=c.id
                     AND COALESCE(json_extract(h.body,'$.status'),'')!='complete')
                   AND (?='' OR instr(lower(COALESCE(json_extract(m.body,'$.text'),'')),lower(?))>0)
                   AND (? IS NULL OR (julianday(json_extract(m.body,'$.createdAt'))>=julianday(?)
                     AND julianday(json_extract(m.body,'$.createdAt'))<julianday(?)))
                 ORDER BY m.rowid DESC LIMIT ?"""
        with self.lock:
            rows = self.db.execute(sql, (before, query, query, start, start, end, limit+1)).fetchall()
        folded = str.maketrans('ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')
        results = []
        for row in rows[:limit]:
            message = json.loads(row['body']); text = message.get('text') or ''
            position = text.translate(folded).find(query.translate(folded)) if query else 0
            start = max(0, position-60); end = min(len(text), start+318)
            snippet = ('…' if start else '') + text[start:end] + ('…' if end<len(text) else '')
            if not snippet and (message.get('attachments') or message.get('attachmentURL')):
                snippet = '[附件]'
            from weather_tools import weather_preview
            snippet = weather_preview(message) or snippet
            results.append({'conversationID':row['conversation'],'conversationTitle':row['title'],
                            'messageID':row['id'],'role':message['role'],'snippet':snippet,'createdAt':message['createdAt']})
        result = {'query':query,'results':results,'nextCursor':str(rows[limit-1]['position']) if len(rows)>limit else None}
        if date is not None:
            result.update(date=date, timeZone=time_zone)
        return result

    def message_calendar(self, month, time_zone, query=''):
        if not isinstance(month, str) or len(month) != 7 or month[4] != '-':
            raise APIError(400, '月份无效')
        try:
            first = calendar_date(int(month[:4]), int(month[5:]), 1)
        except (ValueError, TypeError):
            raise APIError(400, '月份无效')
        if first.strftime('%Y-%m') != month:
            raise APIError(400, '月份无效')
        zone = self._search_zone(time_zone)
        query = self._search_query(query, allow_empty=True)
        sql = """SELECT json_extract(m.body,'$.createdAt') AS created_at
                 FROM messages m JOIN conversations c ON c.id=m.conversation
                 WHERE json_extract(m.body,'$.role') IN ('user','assistant')
                   AND COALESCE(json_extract(m.body,'$.hidden'),0)=0
                   AND NOT EXISTS (SELECT 1 FROM handoffs h WHERE h.target=c.id
                     AND COALESCE(json_extract(h.body,'$.status'),'')!='complete')
                   AND (?='' OR instr(lower(COALESCE(json_extract(m.body,'$.text'),'')),lower(?))>0)"""
        with self.lock:
            rows = self.db.execute(sql, (query, query)).fetchall()
        counts = {}; first_month = last_month = None
        for row in rows:
            value = row['created_at']
            try:
                instant = datetime.fromisoformat(value.replace('Z', '+00:00'))
                if instant.tzinfo is None:
                    continue
                local_day = instant.astimezone(zone).date()
            except (AttributeError, TypeError, ValueError, OverflowError):
                continue
            local_month = local_day.strftime('%Y-%m')
            first_month = local_month if first_month is None or local_month < first_month else first_month
            last_month = local_month if last_month is None or local_month > last_month else last_month
            if local_month == month:
                key = local_day.isoformat(); counts[key] = counts.get(key, 0) + 1
        return {'month':month, 'timeZone':time_zone, 'query':query,
                'firstMonth':first_month, 'lastMonth':last_month,
                'days':[{'date':key, 'count':counts[key]} for key in sorted(counts)]}

    def accept(self, body):
        identity = self._identity(body)
        if body['id'].startswith('pulse-cove-'):
            raise APIError(400, '此消息 ID 前缀仅用于内部心跳事件')
        fingerprint = encode(identity)
        with self.lock, self.db:
            if self.db.execute('SELECT 1 FROM terminal_inputs WHERE id=?', (body['id'],)).fetchone():
                raise APIError(409, '消息 ID 已用于控制指令')
            row = self.db.execute('SELECT fingerprint FROM messages WHERE id=?', (body['id'],)).fetchone()
            if row:
                if row[0] is None or self._identity(json.loads(row[0])) != identity:
                    raise APIError(409, '消息 ID 已用于不同内容')
                return self._message(body['id'])
            self.conversation(body['conversationID'])
            if self._handoff_busy(body['conversationID']):
                raise APIError(409, '正在安全换窗，请等待完成后再发送')
            attachments = [self._file_metadata(id) for id in identity['attachmentIDs']]
            if any(attachment is None for attachment in attachments):
                raise APIError(404, '附件不存在')
            if body.get('stickerID') is not None:
                sticker = self.sticker(body['stickerID'])
                if identity['attachmentIDs'] != [sticker['attachment']['id']]:
                    raise APIError(400, '表情包与附件不一致')
            if body.get('replyTo'):
                quoted = self._message(body['replyTo'])
                if not quoted or quoted['conversationID'] != body['conversationID']:
                    raise APIError(400, '引用消息不属于此会话')
            message = {'id': body['id'], 'conversationID': body['conversationID'], 'role': 'user', 'text': body['text'],
                       'createdAt': now(), 'status': 'sent', 'replyTo': body.get('replyTo'),
                       'attachmentURL': attachments[0]['url'] if attachments else None, 'attachments': attachments, 'error': None,
                       'readAt': None, 'isLiked': False}
            if body.get('stickerID') is not None:
                message['stickerID'] = body['stickerID']
            if identity.get('travelSceneID') is not None:
                message['travelSceneID'] = identity['travelSceneID']
            self._put(message, fingerprint)
            self.db.execute('INSERT INTO jobs VALUES(?,?,NULL,?)', (message['id'], 'queued', 'assistant-' + str(uuid.uuid4())))
            self._terminal_event(message['conversationID'], 'input', message['text'])
            self.db.execute("UPDATE conversations SET title=? WHERE id=? AND title='新对话'", (message['text'][:36] or '附件', message['conversationID']))
            return message

    def poll(self, conversation, after, limit=200):
        with self.lock:
            self.conversation(conversation)
            rows = self.db.execute('SELECT body,revision FROM messages WHERE conversation=? AND revision>? ORDER BY revision LIMIT ?', (conversation, after, limit)).fetchall()
            busy = self.db.execute("""SELECT 1 FROM jobs JOIN messages ON jobs.message=messages.id
                WHERE messages.conversation=? AND jobs.state IN ('queued','running')
                AND json_extract(messages.body,'$.autoRolloverID') IS NULL LIMIT 1""", (conversation,)).fetchone()
            return {'messages': [dict(self._decode_message(r[0]), revision=r[1]) for r in rows if json.loads(r[0]).get('role') != 'system' and not json.loads(r[0]).get('hidden')], 'cursor': rows[-1][1] if rows else after, 'busy': bool(busy)}

    def claim(self):
        with self.lock, self.db:
            while True:
                row = self.db.execute("""SELECT jobs.* FROM jobs JOIN messages ON messages.id=jobs.message
                    WHERE state='queued' ORDER BY CASE WHEN json_extract(messages.body,'$.autoRolloverID') IS NOT NULL THEN 0 ELSE 1 END,
                    messages.rowid LIMIT 1""").fetchone()
                if not row:
                    return None
                event = self._message(row['message'])
                if event.get('deviceActionID'):
                    if self.db.execute("SELECT 1 FROM jobs WHERE state='running' LIMIT 1").fetchone():
                        return None
                    device_state = self.device_action_continuation_state(event['conversationID'], event['deviceActionID'], row['message'])
                    if device_state == 'wait':
                        return None
                    if device_state != 'ready':
                        self.db.execute('UPDATE jobs SET state=? WHERE message=?', (device_state, row['message']))
                        continue
                if event.get('healthRequestID'):
                    # One worker in production; also enforce this on direct
                    # claims so consent never overlaps an already-active turn.
                    if self.db.execute("SELECT 1 FROM jobs WHERE state='running' LIMIT 1").fetchone():
                        return None
                    health = self.db.execute('SELECT body FROM health_requests WHERE id=? AND conversation=?', (event['healthRequestID'], event['conversationID'])).fetchone()
                    health = json.loads(health[0]) if health else None
                    reader = self.db.execute('SELECT state FROM jobs WHERE message=?', ((health or {}).get('readByMessageID', ''),)).fetchone()
                    if health and health.get('readAt') and reader and reader[0] in ('failed', 'interrupted'):
                        self._finish(row['message'], 'failed', '上一个回合已读取健康，但回复是否送达无法确认；为避免重复，未自动续答。')
                        continue
                    already_answered = health and health.get('readAt') and reader and reader[0] == 'complete'
                    if not health or health['status'] != 'allowed' or already_answered:
                        self.db.execute("UPDATE jobs SET state=? WHERE message=?", ('skipped' if already_answered else 'interrupted', row['message']))
                        continue
                break
            self.db.execute("UPDATE jobs SET state='running' WHERE message=?", (row['message'],))
            self.auto_rollover_claimed(row['message'])
            user = self._message(row['message'])
            assistant = {'id': row['assistant'], 'conversationID': user['conversationID'], 'role': 'assistant', 'text': '',
                         'createdAt': now(), 'status': 'streaming', 'replyTo': user['id'] if user['role'] == 'user' else None, 'attachmentURL': None, 'attachments': [], 'error': None}
            if (row['message'].startswith('pulse-cove-') or user.get('handoffID')
                    or user.get('aisayEventID') or user.get('autoRolloverID')):
                assistant['hidden'] = True
            if user.get('handoffID'):
                assistant['handoffID'] = user['handoffID']
            if user.get('autoRolloverID'):
                assistant['autoRolloverID'] = user['autoRolloverID']
            self._put(assistant)
            job = dict(row)
            job.update(user=user, conversation=self.conversation(user['conversationID']))
            return job

    def bind_thread(self, conversation, thread):
        with self.lock, self.db:
            self.db.execute('UPDATE conversations SET thread=? WHERE id=?', (thread, conversation))

    def adopt_native_turn(self, conversation, thread, turn, text):
        """Record an observed owner terminal turn, NEVER enqueue or resend it.

        The caller verifies the native rollout and user-message provenance. This
        transaction is idempotent by native turn, with exact content comparison;
        a restarted/finished turn cannot become runnable again.
        """
        if (not isinstance(turn, str) or not turn or len(turn) > 200 or
                not isinstance(text, str) or not text.strip() or
                len(text.encode('utf-8')) > 256 * 1024):
            raise APIError(400, '原生终端回合内容无效或过大')
        with self.lock, self.db:
            record = self.conversation(conversation)
            if not thread or record['thread'] != thread:
                raise APIError(409, '原生终端线程与当前聊天不一致')
            old = self.db.execute('SELECT * FROM jobs WHERE turn=?', (turn,)).fetchone()
            if old:
                user = self._message(old['message'])
                if (user.get('source') != 'native-terminal' or
                        user['conversationID'] != conversation or user['text'] != text):
                    raise APIError(409, '原生回合已绑定其他消息')
                return dict(old, user=user, conversation=record, duplicate=True)
            if self._handoff_busy(conversation):
                raise APIError(409, '安全换窗期间不能接管新的终端回合')
            if self.db.execute("SELECT 1 FROM jobs WHERE state='running' LIMIT 1").fetchone():
                raise APIError(409, '已有活跃任务，不能交错接管终端回合')
            message = 'native-terminal-' + str(uuid.uuid4())
            assistant_id = 'assistant-' + str(uuid.uuid4())
            timestamp = now()
            user = {'id': message, 'conversationID': conversation, 'role': 'user',
                    'text': text, 'createdAt': timestamp, 'status': 'sent',
                    'replyTo': None, 'attachmentURL': None, 'attachments': [],
                    'error': None, 'readAt': timestamp, 'isLiked': False,
                    'source': 'native-terminal'}
            assistant = {'id': assistant_id, 'conversationID': conversation,
                         'role': 'assistant', 'text': '', 'createdAt': timestamp,
                         'status': 'streaming', 'replyTo': message,
                         'attachmentURL': None, 'attachments': [], 'error': None}
            self._put(user)
            self._put(assistant)
            self.db.execute('INSERT INTO jobs VALUES(?,?,?,?)',
                            (message, 'running', turn, assistant_id))
            self._terminal_event(conversation, 'input', text)
            self.db.execute("UPDATE conversations SET title=? WHERE id=? AND title='新对话'",
                            (text[:36], conversation))
            return {'message': message, 'state': 'running', 'turn': turn,
                    'assistant': assistant_id, 'user': user,
                    'conversation': record, 'duplicate': False}

    def bind_turn(self, message, turn, thread=None):
        with self.lock, self.db:
            row = self.db.execute("SELECT jobs.turn,conversations.thread FROM jobs JOIN messages ON messages.id=jobs.message JOIN conversations ON conversations.id=messages.conversation WHERE jobs.message=? AND jobs.state='running'", (message,)).fetchone()
            if not row or not isinstance(turn, str) or not turn or (row['turn'] and row['turn'] != turn) or (thread is not None and row['thread'] != thread):
                return False
            if self.db.execute('SELECT 1 FROM jobs WHERE turn=? AND message!=? LIMIT 1', (turn, message)).fetchone():
                return False
            self.db.execute('UPDATE jobs SET turn=? WHERE message=?', (turn, message))
            user = self._message(message)
            if user and user['role'] == 'user' and user['readAt'] is None:
                user['readAt'] = now()
                self._put(user)
            return True

    def set_reaction(self, conversation, message, liked):
        if not isinstance(liked, bool):
            raise APIError(400, 'isLiked 必须是布尔值')
        with self.lock, self.db:
            self.conversation(conversation)
            current = self._message(message)
            if not current:
                raise APIError(404, '消息不存在')
            if current['conversationID'] != conversation:
                raise APIError(400, '消息不属于此会话')
            if current['isLiked'] != liked:
                current['isLiked'] = liked
                self._put(current)
            return current

    def complete_reply(self, message, turn, text, little_thoughts):
        from little_thoughts import MAX_THOUGHT_CHARS
        if not isinstance(text, str) or (little_thoughts is not None and
                (not isinstance(little_thoughts, str) or len(little_thoughts) > MAX_THOUGHT_CHARS)):
            return False
        with self.lock, self.db:
            row = self.db.execute("SELECT assistant FROM jobs WHERE message=? AND turn=? AND state='running'", (message, turn)).fetchone()
            if not row:
                return False
            m = self._message(row[0])
            if not m or m.get('role') != 'assistant':
                return False
            value = (little_thoughts.strip() or None) if little_thoughts else None
            if m.get('text') != text or m.get('littleThoughts') != value:
                m['text'] = text
                m['littleThoughts'] = value
                if text.strip() and not m.get('handoffID') and not m.get('autoRolloverID'):
                    m.pop('hidden', None)
                self._put(m)
            return True

    def set_thinking_summary(self, message, turn, text):
        from thinking_summary import MAX_SUMMARY_CHARS
        if not isinstance(text, str) or len(text) > MAX_SUMMARY_CHARS:
            return False
        with self.lock, self.db:
            row = self.db.execute("SELECT assistant FROM jobs WHERE message=? AND turn=? AND state='running'", (message, turn)).fetchone()
            if not row:
                return False
            m = self._message(row[0])
            if not m or m.get('role') != 'assistant':
                return False
            value = text.strip() or None
            if m.get('thinkingSummary') != value:
                m['thinkingSummary'] = value
                self._put(m)
            return True

    def stream(self, message, text):
        with self.lock, self.db:
            row = self.db.execute("SELECT assistant FROM jobs WHERE message=? AND state='running'", (message,)).fetchone()
            if row:
                m = self._message(row[0]); m['text'] = text
                if isinstance(text, str) and text.strip() and not m.get('handoffID') and not m.get('autoRolloverID'):
                    m.pop('hidden', None)
                self._put(m)

    def _finish(self, message, status, error=None):
        row = self.db.execute('SELECT assistant FROM jobs WHERE message=?', (message,)).fetchone()
        if not row:
            return
        m = self._message(row[0])
        if not m:
            user = self._message(message)
            m = {'id': row[0], 'conversationID': user['conversationID'], 'role': 'assistant', 'text': '', 'createdAt': now(), 'replyTo': message, 'attachmentURL': None}
        m.update(status=status, error=error)
        # A scheduled Pulse wake may intentionally only update its public note.
        # Keep its durable result for the dashboard, but never create a blank
        # chat bubble. Ordinary turns, including empty failed ones, are unchanged.
        user = self._message(message)
        if user.get('aisayEventID'):
            m['hidden'] = True
        if user.get('handoffID'):
            m['hidden'] = True; m['handoffID'] = user['handoffID']
        if user.get('autoRolloverID'):
            m['hidden'] = True; m['autoRolloverID'] = user['autoRolloverID']
        quiet_pulse = (status == 'complete' and message.startswith('pulse-cove-')
                       and not str(m.get('text') or '').strip()
                       and not m.get('attachments') and not m.get('attachmentURL'))
        if quiet_pulse:
            # Codex may complete a deliberately silent wake with newline-only
            # agent-message deltas. Canonicalize those to an actually empty body
            # so they cannot escape the hidden Pulse path or reach push/chat UI.
            m['text'] = ''
            m['hidden'] = True
        elif status != 'complete' and message.startswith('pulse-cove-'):
            # Errors and interruption remain visible; only a successful quiet
            # wake is suppressed from chat and push delivery.
            m.pop('hidden', None)
        self._put(m)
        self.db.execute('UPDATE jobs SET state=? WHERE message=?', (status, message))
        self._finish_handoff(message, status, error)
        self.auto_rollover_finished(message, status, error)
        if user.get('handoffPhase') == 'restoring':
            handoff = self.db.execute('SELECT body FROM handoffs WHERE id=?', (user['handoffID'],)).fetchone()
            if handoff and json.loads(handoff[0])['status'] == 'complete':
                m.pop('hidden', None); self._put(m)
        if error or status == 'interrupted':
            self._terminal_event(m['conversationID'], 'error' if error else 'turn', error or '回合已停止')

    def finish(self, message, status, error=None):
        with self.lock, self.db:
            self._finish(message, status, error)

    def record_pulse_note(self, message, turn, call, arguments):
        if set(arguments) != {'thoughtSummary', 'intent'}:
            raise APIError(400, 'Pulse note 参数无效')
        thought, intent = arguments['thoughtSummary'], arguments['intent']
        if (not isinstance(thought, str) or not thought.strip() or len(thought) > 500 or
                not isinstance(intent, str) or not intent.strip() or len(intent) > 240):
            raise APIError(400, 'Pulse note 过长或为空')
        with self.lock, self.db:
            job = self.db.execute("SELECT state,turn FROM jobs WHERE message=?", (message,)).fetchone()
            origin = self._message(message)
            if not message.startswith('pulse-cove-') or not origin or origin.get('role') != 'system' or not job or job['state'] != 'running' or job['turn'] != turn:
                raise APIError(403, '仅当前 Pulse 唤醒回合可记录')
            key = encode([message, turn, call])
            old = self.db.execute('SELECT result FROM pulse_note_tool_results WHERE call=?', (key,)).fetchone()
            existing = self.db.execute('SELECT thought_summary,intent,created FROM pulse_notes WHERE message=?', (message,)).fetchone()
            if existing:
                if existing['thought_summary'] != thought.strip() or existing['intent'] != intent.strip():
                    raise APIError(409, '该唤醒已记录不同 note')
                created = existing['created']
                if old:
                    return json.loads(old[0])
            else:
                created = now()
                self.db.execute('INSERT INTO pulse_notes VALUES(?,?,?,?,?)', (message, turn, thought.strip(), intent.strip(), created))
            result = {'ok': True, 'createdAt': created}
            self.db.execute('INSERT INTO pulse_note_tool_results VALUES(?,?,?)', (key, message, encode(result)))
            return result

    def cancel_queued(self, conversation):
        with self.lock, self.db:
            self.conversation(conversation)
            rows = self.db.execute("SELECT jobs.message FROM jobs JOIN messages ON messages.id=jobs.message WHERE conversation=? AND state='queued'", (conversation,)).fetchall()
            for r in rows:
                self._finish(r[0], 'interrupted')

    def _terminal_event(self, conversation, kind, text, thread=None, turn=None, item=None):
        from terminal import redact
        body = {'kind': kind, 'text': redact(text), 'createdAt': now(), 'threadID': thread, 'turnID': turn, 'itemID': item}
        return self.db.execute('INSERT INTO terminal_events(conversation,body) VALUES(?,?)', (conversation, encode(body))).lastrowid

    def terminal_event(self, conversation, kind, text, thread=None, turn=None, item=None):
        with self.lock, self.db:
            self.conversation(conversation)
            return self._terminal_event(conversation, kind, text, thread, turn, item)

    def terminal_settings(self, conversation, model=None, effort=None):
        with self.lock:
            self.conversation(conversation)
            row = self.db.execute('SELECT value FROM state WHERE key=?', ('terminal-model:'+conversation,)).fetchone()
            return json.loads(row[0]) if row else {'model': model, 'effort': effort}

    def set_terminal_model(self, conversation, model, effort):
        with self.lock, self.db:
            self.conversation(conversation)
            self.db.execute('INSERT INTO state VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
                            ('terminal-model:'+conversation, encode({'model': model, 'effort': effort})))
            self._terminal_event(conversation, 'model', '下一回合：'+model+' · '+effort)

    def terminal_poll(self, conversation, after, tail=False):
        with self.lock:
            c = self.conversation(conversation)
            if tail:
                rows = list(reversed(self.db.execute('SELECT id,body FROM terminal_events WHERE conversation=? ORDER BY id DESC LIMIT 200', (conversation,)).fetchall()))
            else:
                rows = self.db.execute('SELECT id,body FROM terminal_events WHERE conversation=? AND id>? ORDER BY id LIMIT 200', (conversation, after)).fetchall()
            busy = self.db.execute("SELECT 1 FROM jobs JOIN messages ON jobs.message=messages.id WHERE messages.conversation=? AND jobs.state IN ('queued','running') LIMIT 1", (conversation,)).fetchone()
            return {'conversationID': conversation, 'events': [dict(json.loads(r['body']), id=r['id']) for r in rows],
                    'cursor': rows[-1]['id'] if rows else after, 'busy': bool(busy), 'threadID': c['thread']}

    def terminal_control(self, body, result=None, model=None, effort=None):
        identity = encode({k: body[k] for k in ('id', 'conversationID', 'text')})
        with self.lock, self.db:
            self.conversation(body['conversationID'])
            old = self.db.execute('SELECT fingerprint,result FROM terminal_inputs WHERE id=?', (body['id'],)).fetchone()
            if old:
                if old['fingerprint'] != identity:
                    raise APIError(409, '控制指令 ID 已用于不同内容')
                return json.loads(old['result']), False
            if result is None:
                return None, False
            if self.db.execute('SELECT 1 FROM messages WHERE id=?', (body['id'],)).fetchone():
                raise APIError(409, '控制指令 ID 已用于消息')
            if model:
                self.db.execute('INSERT INTO state VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
                                ('terminal-model:'+body['conversationID'], encode({'model': model, 'effort': effort})))
                self._terminal_event(body['conversationID'], 'model', '下一回合：'+model+' · '+effort)
            self._terminal_event(body['conversationID'], result['kind'], body['text'])
            self.db.execute('INSERT INTO terminal_inputs VALUES(?,?,?)', (body['id'], identity, encode(result)))
            return result, True

    def health(self):
        with self.lock:
            row = self.db.execute("SELECT value FROM state WHERE key='health'").fetchone()
            result = json.loads(row[0]) if row else {'snapshot': None, 'syncedAt': None, 'readAt': None}
            return result

    def health_for_tool(self):
        with self.lock:
            version = self.db.execute("SELECT value FROM state WHERE key='healthVersion'").fetchone()
            return self.health(), version[0] if version else None

    def mark_health_read(self, delivered, version):
        """Mark only the snapshot whose dynamic-tool response was written successfully."""
        if delivered['snapshot'] is None:
            return
        with self.lock, self.db:
            row = self.db.execute("SELECT value FROM state WHERE key='health'").fetchone()
            current = json.loads(row[0]) if row else None
            current_version = self.db.execute("SELECT value FROM state WHERE key='healthVersion'").fetchone()
            current_version = current_version[0] if current_version else None
            if current and current_version == version and current['syncedAt'] == delivered['syncedAt'] and current['snapshot'] == delivered['snapshot']:
                current['readAt'] = now()
                self.db.execute("UPDATE state SET value=? WHERE key='health'", (encode(current),))

    def upload_health(self, snapshot, standing=False):
        result = {'snapshot': snapshot, 'syncedAt': now(), 'readAt': None}
        capture_day = datetime.fromisoformat(snapshot['capturedAt'].replace('Z', '+00:00')).astimezone(timezone.utc).date().isoformat()
        with self.lock, self.db:
            if standing:
                self._require_data_access()
            old = self.db.execute('SELECT snapshot,synced FROM health_uploads WHERE captured=?', (snapshot['capturedAt'],)).fetchone()
            if old:
                if json.loads(old['snapshot']) != snapshot:
                    raise APIError(409, '同一采集时间已有不同健康快照')
                return old['synced']
            self.db.execute('INSERT INTO health_uploads VALUES(?,?,?)', (snapshot['capturedAt'], encode(snapshot), result['syncedAt']))
            current = self.health()['snapshot']
            if current is None or datetime.fromisoformat(current['capturedAt'].replace('Z', '+00:00')) <= datetime.fromisoformat(snapshot['capturedAt'].replace('Z', '+00:00')):
                self.db.execute("INSERT INTO state VALUES('health',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (encode(result),))
                self.db.execute("INSERT INTO state VALUES('healthVersion',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (str(uuid.uuid4()),))
            self.db.execute('''INSERT INTO health_history VALUES(?,?,?) ON CONFLICT(day) DO UPDATE SET snapshot=excluded.snapshot,synced=excluded.synced
                               WHERE julianday(json_extract(excluded.snapshot,'$.capturedAt')) >= julianday(json_extract(health_history.snapshot,'$.capturedAt'))''',
                            (capture_day, encode(snapshot), result['syncedAt']))
        return result['syncedAt']

    def health_upload(self, captured_at):
        """Read one durably acknowledged phone upload by canonical capture time."""
        from health_requests import timestamp
        captured = timestamp(captured_at).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
        with self.lock:
            row = self.db.execute('SELECT snapshot,synced FROM health_uploads WHERE captured=?', (captured,)).fetchone()
            if not row:
                raise APIError(404, '健康上传记录不存在')
            return {'snapshot': json.loads(row['snapshot']), 'syncedAt': row['synced']}

    def health_history(self, days=7):
        today = datetime.now(timezone.utc).date()
        since = (today - timedelta(days=days-1)).isoformat()
        with self.lock:
            rows = self.db.execute('SELECT snapshot,synced FROM health_history WHERE day>=? AND day<=? ORDER BY day', (since, today.isoformat())).fetchall()
            return {'snapshots': [json.loads(r[0]) for r in rows], 'updatedAt': max((r[1] for r in rows), default=None)}

    def delete_health(self):
        with self.lock, self.db:
            self.db.execute("DELETE FROM state WHERE key IN ('health','healthVersion')")
            self.db.execute('DELETE FROM health_history')
            self.db.execute('DELETE FROM health_uploads')
            self.db.execute('DELETE FROM data_tool_results')
            self.set_data_access({'enabled': False})
            self.db.execute("UPDATE jobs SET state='interrupted' WHERE state='queued' AND message IN (SELECT id FROM messages WHERE json_extract(body,'$.healthRequestID') IS NOT NULL)")
            self.db.execute('DELETE FROM health_requests')
            self.db.execute('DELETE FROM health_tool_results')
            self.db.execute('DELETE FROM collar_calls')
            self.db.execute('DELETE FROM collar_grants')
            self.db.execute("DELETE FROM state WHERE key='collarAccess'")

    def add_attachment(self, filename, mime, data):
        from files import validate_file
        filename, mime, data = validate_file(filename, mime, data)
        id = str(uuid.uuid4())
        with self.lock, self.db:
            self.db.execute('INSERT INTO attachments VALUES(?,?,?,?)', (id, filename, mime, data))
            return self._file_metadata(id)

    def _file_metadata(self, id):
        row = self.db.execute('SELECT id,filename,mime,length(data) AS size FROM attachments WHERE id=?', (id,)).fetchone()
        if not row:
            return None
        result = dict(row); result['url'] = '/v1/attachments/' + id
        return result

    def attachment(self, id):
        with self.lock:
            row = self.db.execute('SELECT * FROM attachments WHERE id=?', (id,)).fetchone()
            if not row:
                raise APIError(404, '附件不存在')
            return dict(row)

    def attachment_for_message(self, id):
        attachments = self.attachments_for_message(id)
        return attachments[0] if attachments else None

    def attachments_for_message(self, id):
        with self.lock:
            row = self.db.execute('SELECT fingerprint FROM messages WHERE id=?', (id,)).fetchone()
            return [self.attachment(aid) for aid in self.attachment_ids(json.loads(row[0]))]

    def create_assistant_file(self, message, turn, call, filename, mime, data):
        from files import MAX_ATTACHMENTS, validate_file
        filename, mime, data = validate_file(filename, mime, data)
        with self.lock, self.db:
            job = self.db.execute("SELECT assistant FROM jobs WHERE message=? AND turn=? AND state='running'", (message, turn)).fetchone()
            if not job:
                raise APIError(409, '文件请求不属于正在运行的 Cove 回合')
            call = encode([message, turn, call])
            previous = self.db.execute('SELECT attachment FROM file_tool_results WHERE call=?', (call,)).fetchone()
            if previous:
                return self._file_metadata(previous[0])
            assistant = self._message(job[0])
            if len(assistant.get('attachments', [])) >= MAX_ATTACHMENTS:
                raise APIError(413, '每条回复最多 10 个文件')
            id = str(uuid.uuid4())
            self.db.execute('INSERT INTO attachments VALUES(?,?,?,?)', (id, filename, mime, data))
            attachment = self._file_metadata(id)
            assistant.setdefault('attachments', []).append(attachment)
            assistant.pop('hidden', None)
            assistant['attachmentURL'] = assistant['attachments'][0]['url']
            assistant.pop('stickerID', None)
            self._put(assistant)
            self.db.execute('INSERT INTO file_tool_results VALUES(?,?)', (call, id))
            return attachment

    def _sticker(self, row):
        return {'id': row['id'], 'owner': row['owner'], 'label': row['label'],
                'createdAt': row['created'], 'attachment': self._file_metadata(row['attachment'])}

    def sticker(self, id):
        if not isinstance(id, str) or not id or len(id) > 128:
            raise APIError(400, '表情包 ID 无效')
        with self.lock:
            row = self.db.execute('SELECT * FROM stickers WHERE id=?', (id,)).fetchone()
            if not row:
                raise APIError(404, '表情包不存在')
            return self._sticker(row)

    def stickers(self, owner=None):
        with self.lock:
            rows = self.db.execute('SELECT * FROM stickers WHERE (? IS NULL OR owner=?) ORDER BY created,id', (owner, owner)).fetchall()
            return {'stickers': [self._sticker(row) for row in rows]}

    def _save_sticker(self, attachment_id, label, owner):
        from files import vision_image
        if not isinstance(attachment_id, str) or not attachment_id or len(attachment_id) > 128:
            raise APIError(400, '附件 ID 无效')
        if not isinstance(label, str) or not label.strip() or len(label) > 120 or any(ord(c) < 32 or ord(c) == 127 for c in label):
            raise APIError(400, '表情包名称需为 1–120 字且不能含控制字符')
        attachment = self.attachment(attachment_id)
        if not vision_image(attachment):
            raise APIError(400, '表情包仅支持格式匹配的 PNG、JPEG、GIF 或 WebP 图片')
        previous = self.db.execute('SELECT * FROM stickers WHERE owner=? AND attachment=?', (owner, attachment_id)).fetchone()
        if previous:
            return self._sticker(previous)
        if self.db.execute('SELECT count(*) FROM stickers WHERE owner=?', (owner,)).fetchone()[0] >= 500:
            raise APIError(413, '每人的表情包库最多 500 个')
        id = str(uuid.uuid4())
        self.db.execute('INSERT INTO stickers VALUES(?,?,?,?,?)', (id, owner, label.strip(), now(), attachment_id))
        return self.sticker(id)

    def save_user_sticker(self, attachment_id, label):
        with self.lock, self.db:
            return self._save_sticker(attachment_id, label, 'user')

    def assistant_sticker_tool(self, message, turn, call, tool, arguments):
        """Current-turn transaction; no global-token or path access for the model."""
        from files import MAX_ATTACHMENTS
        with self.lock, self.db:
            job = self.db.execute("SELECT assistant FROM jobs WHERE message=? AND turn=? AND state='running'", (message, turn)).fetchone()
            if not job:
                raise APIError(409, '表情包请求不属于正在运行的 Cove 回合')
            key = encode([message, turn, call])
            previous = self.db.execute('SELECT result FROM sticker_tool_results WHERE call=?', (key,)).fetchone()
            if previous:
                return json.loads(previous[0])
            if tool == 'cove_list_stickers':
                if arguments:
                    raise APIError(400, '列出表情包不接受参数')
                result = self.stickers('assistant')
            elif tool == 'cove_save_sticker':
                if set(arguments) != {'attachmentID', 'label'} or not isinstance(arguments['attachmentID'], str):
                    raise APIError(400, '保存表情包需 attachmentID 和 label')
                user = self._message(message)
                # The assistant can save only an image actually sent by the user in
                # this conversation, never an unshared upload or another chat's file.
                source = self.db.execute('''SELECT 1 FROM messages m
                    WHERE conversation=? AND json_extract(body,'$.role')='user'
                    AND (json_extract(body,'$.attachmentURL')=? OR EXISTS
                        (SELECT 1 FROM json_each(m.body,'$.attachments') a WHERE json_extract(a.value,'$.id')=?)) LIMIT 1''',
                    (user['conversationID'], '/v1/attachments/'+arguments['attachmentID'], arguments['attachmentID'])).fetchone()
                if not source:
                    raise APIError(403, '只能保存本会话中用户已发送的图片')
                result = {'sticker': self._save_sticker(arguments['attachmentID'], arguments['label'], 'assistant')}
            elif tool == 'cove_send_sticker':
                if set(arguments) != {'stickerID'}:
                    raise APIError(400, '发送表情包需 stickerID')
                sticker = self.sticker(arguments['stickerID'])
                if sticker['owner'] != 'assistant':
                    raise APIError(403, '只能发送自己已保存的表情包')
                assistant = self._message(job[0])
                if len(assistant.get('attachments', [])) >= MAX_ATTACHMENTS:
                    raise APIError(413, '每条回复最多 10 个文件')
                attachment = sticker['attachment']
                assistant.setdefault('attachments', []).append(attachment)
                assistant.pop('hidden', None)
                assistant['attachmentURL'] = assistant['attachments'][0]['url']
                # A single-sticker reply has the same rendering marker as user sends.
                # Mixed/multiple files retain ordinary attachment presentation.
                if len(assistant['attachments']) == 1:
                    assistant['stickerID'] = sticker['id']
                else:
                    assistant.pop('stickerID', None)
                self._put(assistant)
                result = {'sticker': sticker, 'attachment': attachment}
            else:
                raise APIError(400, '未知表情包工具')
            self.db.execute('INSERT INTO sticker_tool_results VALUES(?,?)', (key, encode(result)))
            return result

    def register_device(self, token, preview_mode='generic'):
        if preview_mode not in ('generic', 'content'):
            raise APIError(400, '通知预览设置无效')
        with self.lock, self.db:
            self.db.execute('INSERT INTO devices(token,registered,preview_mode) VALUES(?,?,?) ON CONFLICT(token) DO UPDATE SET registered=excluded.registered,preview_mode=excluded.preview_mode', (token, now(), preview_mode))

    def notification_devices(self):
        with self.lock:
            return [{'token': r['token'], 'previewMode': r['preview_mode']} for r in self.db.execute('SELECT token,preview_mode FROM devices')]

    def unregister_device(self, token):
        with self.lock, self.db:
            self.db.execute('DELETE FROM devices WHERE token=?', (token,))

    def device_tokens(self):
        with self.lock:
            return [r[0] for r in self.db.execute('SELECT token FROM devices')]

    def close(self):
        with self.lock:
            self.db.close()
            self.process_lock.close()
