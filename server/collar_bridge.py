"""Restricted, independent Cove adapter for Collar (stdlib, loopback only).

This service deliberately never calls health_store.create_command: that function
also sends an alert and can overwrite another owner's pending measurement. The
legacy command slot has no compare-and-swap: independent writers can still race.
A post-write mismatch is reported as unknown, not as an isolated queue guarantee.
No remote service, health read or measurement is performed on import.
"""
from __future__ import annotations

import contextlib
from datetime import datetime, timedelta, timezone
import fcntl
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib
import ipaddress
import json
import math
import os
from pathlib import Path
import sqlite3
import sys
import threading
import uuid

UTC = timezone.utc
MAX_ROWS = 100_000
MAX_BODY = 4096
METRICS = {
    'sleep': ('sleep_analysis', '睡眠', '小时', None),
    'restingHeartRate': ('resting_heart_rate', '静息心率', '次/分', 'count/min'),
    'heartRate': ('heart_rate', '最近一次心率', '次/分', 'count/min'),
    'steps': ('step_count', '步数', '步', 'count'),
    'hrv': ('heart_rate_variability', 'HRV', '毫秒', 'ms'),
}
ASLEEP = {'asleep', 'core', 'deep', 'rem'}


class BridgeError(Exception):
    def __init__(self, status, code):
        self.status, self.code = status, code
        super().__init__(code)


def iso(value):
    return value.astimezone(UTC).isoformat().replace('+00:00', 'Z')


def date(value):
    if not isinstance(value, str) or len(value) > 64:
        raise ValueError('invalid date')
    parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if parsed.tzinfo is None:
        raise ValueError('timezone required')
    return parsed.astimezone(UTC)


def number(value):
    return (isinstance(value, (int, float)) and not isinstance(value, bool)
            and math.isfinite(value) and 0 <= value <= 100_000_000)


def request_id(value):
    try:
        if not isinstance(value, str) or str(uuid.UUID(value)) != value.lower():
            raise ValueError()
        return str(uuid.UUID(value))
    except (ValueError, AttributeError):
        raise BridgeError(400, 'invalid_request_id') from None


class CollarBridge:
    def __init__(self, health_store, token, data_dir, clock=None, push=None):
        if not isinstance(token, str) or len(token) < 32 or token.strip() != token:
            raise ValueError('COLLAR_COVE_TOKEN must be a dedicated token of at least 32 characters')
        self.hs, self.token = health_store, token
        self.push = push
        self.clock = clock or (lambda: datetime.now(UTC))
        directory = Path(data_dir)
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        if directory.is_symlink() or not directory.is_dir():
            raise ValueError('invalid private data directory')
        directory.chmod(0o700)
        self.db_path, self.lock_path = directory / 'measurements.sqlite3', directory / 'measurements.lock'
        for path in (self.db_path, self.lock_path):
            fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
            os.fchmod(fd, 0o600)
            os.close(fd)
        self.lock = threading.RLock()
        with self._connection() as db:
            db.execute('CREATE TABLE IF NOT EXISTS measurements '
                       '(id TEXT PRIMARY KEY, command_id TEXT UNIQUE NOT NULL, '
                       'requested_at TEXT NOT NULL, intent TEXT NOT NULL)')
            columns = {row['name'] for row in db.execute('PRAGMA table_info(measurements)')}
            if 'notification_intent' not in columns:
                # Existing measurements predate push and must never alert retroactively.
                db.execute("ALTER TABLE measurements ADD COLUMN notification_intent TEXT NOT NULL DEFAULT 'legacy'")
            if 'notification_receipt' not in columns:
                db.execute('ALTER TABLE measurements ADD COLUMN notification_receipt TEXT')

    def authorized(self, header):
        return isinstance(header, str) and hmac.compare_digest(
            header.encode('utf-8'), ('Bearer ' + self.token).encode('utf-8'))

    @contextlib.contextmanager
    def _connection(self):
        db = sqlite3.connect(self.db_path, timeout=10)
        db.row_factory = sqlite3.Row
        try:
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    @contextlib.contextmanager
    def _serialized(self):
        with self.lock:
            fd = os.open(self.lock_path, os.O_RDWR | os.O_NOFOLLOW)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX)
                yield
            finally:
                fcntl.flock(fd, fcntl.LOCK_UN)
                os.close(fd)

    def summary(self, body):
        if not isinstance(body, dict) or set(body) != {'metrics', 'startAt', 'endAt'}:
            raise BridgeError(400, 'invalid_summary_request')
        metrics = body['metrics']
        if (not isinstance(metrics, list) or not 1 <= len(metrics) <= 5
                or any(not isinstance(m, str) or m not in METRICS for m in metrics)
                or len(set(metrics)) != len(metrics)):
            raise BridgeError(400, 'invalid_metrics')
        try:
            start, end, now = date(body['startAt']), date(body['endAt']), self.clock()
        except (ValueError, OverflowError):
            raise BridgeError(400, 'invalid_time_range') from None
        if (not start < end or end - start > timedelta(hours=48)
                or start < now - timedelta(hours=48, seconds=60)
                or end > now + timedelta(seconds=60)):
            raise BridgeError(400, 'invalid_time_range')
        types = {METRICS[m][0] for m in metrics}
        # The legacy helper itself materializes rows. MAX_ROWS bounds projection,
        # not that helper's memory use; production ingest needs its own limits.
        raw = self.hs._samples_between(start, end, types=types,
                                       exclude_sources=self.hs._STATUS_EXCLUDED_SOURCES)
        rows = []
        for index, row in enumerate(raw):
            if index >= MAX_ROWS:
                raise BridgeError(503, 'summary_unavailable')
            if not isinstance(row, dict) or row.get('source') != 'watch' or row.get('type') not in types:
                continue
            try:
                at = date(row.get('at'))
            except (ValueError, OverflowError):
                continue
            if start <= at <= end:
                rows.append((at, row))
        result = []
        for metric in metrics:
            kind, title, unit, raw_unit = METRICS[metric]
            selected = [(at, row) for at, row in rows if row['type'] == kind]
            if metric == 'sleep':
                projected = self._sleep(selected, start, end)
            else:
                # Deterministic deduplication for retransmitted samples. Conflicting
                # same-time values are unavailable instead of arbitrarily counted.
                groups = {}
                for at, row in selected:
                    if row.get('unit') == raw_unit and number(row.get('value')):
                        groups.setdefault(at, set()).add(row['value'])
                samples = [(at, next(iter(values))) for at, values in groups.items() if len(values) == 1]
                if not samples:
                    projected = None
                elif metric == 'steps':
                    projected = sum(value for _, value in samples), max(at for at, _ in samples)
                else:
                    at, value = max(samples)
                    projected = value, at
            if projected is not None and number(projected[0]):
                result.append(dict(id=metric, title=title, value=projected[0], unit=unit,
                                   sampledAt=iso(projected[1]), source='Collar · Apple Watch'))
        present = {m['id'] for m in result}
        return {'snapshot': {'capturedAt': iso(now), 'metrics': result},
                'missingMetricIDs': [m for m in metrics if m not in present],
                'source': 'collar', 'startAt': iso(start), 'endAt': iso(end)}

    @staticmethod
    def _sleep(rows, start, end):
        intervals, sessions = [], {}
        segment_evidence = False
        for at, row in rows:
            extra = row.get('extra')
            if not isinstance(extra, dict):
                continue
            segments = extra.get('segments')
            if isinstance(segments, list) and segments:
                segment_evidence = True
                for segment in segments:
                    if not isinstance(segment, dict) or segment.get('stage') not in ASLEEP:
                        continue
                    try:
                        lo, hi = max(start, date(segment.get('start'))), min(end, date(segment.get('end')))
                    except (ValueError, OverflowError):
                        continue
                    if lo < hi:
                        intervals.append((lo, hi))
                continue
            try:
                lo, hi, hours = date(extra.get('sleepStart')), date(extra.get('sleepEnd')), extra.get('totalSleep')
            except (ValueError, OverflowError):
                continue
            if start <= lo < hi <= end and number(hours) and hours > 0 and hours <= (hi-lo).total_seconds()/3600:
                sessions.setdefault((lo, hi), set()).add(hours)
        if segment_evidence:
            # Do not mix aggregate totals with segment windows: overlap cannot be
            # safely apportioned without the missing underlying stage intervals.
            if not intervals:
                return None
            intervals.sort()
            merged = []
            for lo, hi in intervals:
                if merged and lo <= merged[-1][1]:
                    merged[-1] = merged[-1][0], max(merged[-1][1], hi)
                else:
                    merged.append((lo, hi))
            return sum((hi-lo).total_seconds() for lo, hi in merged)/3600, merged[-1][1]
        ordered = sorted(sessions.items())
        if not ordered or any(len(values) != 1 for _, values in ordered):
            return None
        if any(ordered[i][0][0] < ordered[i-1][0][1] for i in range(1, len(ordered))):
            return None
        return sum(next(iter(values)) for _, values in ordered), ordered[-1][0][1]

    def _state(self):
        state = self.hs.get_command_state()
        return state if isinstance(state, dict) else {}

    def measurement(self, identifier):
        identifier = request_id(identifier)
        with self._serialized(), self._connection() as db:
            row = db.execute('SELECT * FROM measurements WHERE id=?', (identifier,)).fetchone()
            if row is None:
                raise BridgeError(404, 'measurement_not_found')
            return self._project_measurement(row, self._state())

    def _notify_claimed(self, db, row, state):
        if (not self.push or row['notification_intent'] != 'available'
                or state.get('command_id') != row['command_id']
                or state.get('command') != 'measure_heart_rate'
                or state.get('status') not in {'pending', 'seen'}):
            return
        changed = db.execute("UPDATE measurements SET notification_intent='claimed' "
                             "WHERE id=? AND notification_intent='available'", (row['id'],)).rowcount
        db.commit()  # Durable at-most-once claim before any request reaches APNs.
        if not changed:
            return
        receipt = self.push.send_measurement(row['id'])
        safe = json.dumps(receipt, ensure_ascii=True, allow_nan=False, separators=(',', ':'))
        db.execute('UPDATE measurements SET notification_receipt=? WHERE id=?', (safe[:1024], row['id']))

    def create_measurement(self, body):
        if not isinstance(body, dict) or set(body) != {'requestID'}:
            raise BridgeError(400, 'invalid_measurement_request')
        identifier = request_id(body['requestID'])
        with self._serialized(), self._connection() as db:
            prior = db.execute('SELECT * FROM measurements WHERE id=?', (identifier,)).fetchone()
            if prior is not None:
                # The command is never replayed. A crash between command write and
                # notification claim may be reconciled once; claimed sends never retry.
                state = self._state()
                self._notify_claimed(db, prior, state)
                return self._project_measurement(prior, state)
            now = self.clock()
            latest = db.execute('SELECT requested_at FROM measurements ORDER BY requested_at DESC LIMIT 1').fetchone()
            if latest and now - date(latest['requested_at']) < timedelta(seconds=60):
                raise BridgeError(429, 'measurement_cooldown')
            state = self._state()
            if state.get('status') in {'pending', 'seen'}:
                raise BridgeError(409, 'measurement_busy')
            command_id = 'cove_' + uuid.UUID(identifier).hex
            requested_at = iso(now)
            db.execute('INSERT INTO measurements '
                       '(id,command_id,requested_at,intent,notification_intent) VALUES (?,?,?,?,?)',
                       (identifier, command_id, requested_at, 'prepared', 'available'))
            db.commit()  # Durable write intent BEFORE touching the legacy slot.
            row = db.execute('SELECT * FROM measurements WHERE id=?', (identifier,)).fetchone()
            try:
                # Recheck after commit; legacy writers do not hold our lock.
                if self._state().get('status') in {'pending', 'seen'}:
                    return self._project_measurement(row, {})
                self.hs._write_command({'command_id': command_id, 'command': 'measure_heart_rate',
                                        'status': 'pending', 'requested_at': requested_at,
                                        'duration_seconds': 30, 'result': None})
                state = self._state()
                self._notify_claimed(db, row, state)
            except Exception:
                # Never include upstream paths, values or credentials in errors.
                return self._project_measurement(row, {})
            return self._project_measurement(row, state)

    @staticmethod
    def _project_measurement(row, state):
        result = {'id': row['id'], 'status': 'unknown', 'requestedAt': row['requested_at'],
                  'completedAt': None, 'durationSeconds': 30, 'result': None}
        if state.get('command_id') != row['command_id'] or state.get('command') != 'measure_heart_rate':
            return {'measurement': result}
        status = state.get('status')
        if status in {'pending', 'seen', 'expired'}:
            result['status'] = status
        elif status == 'done':
            raw = state.get('result')
            if isinstance(raw, dict):
                average, minimum, maximum = (raw.get('heart_rate_' + key) for key in ('average', 'minimum', 'maximum'))
                count = raw.get('sample_count')
                try:
                    completed = date(state.get('completed_at'))
                    valid_time = completed >= date(row['requested_at'])
                except (ValueError, OverflowError):
                    valid_time = False
                if type(count) is int and count == 0 and valid_time:
                    # Completed transport receipt is not a successful reading.
                    result.update(status='done', completedAt=iso(completed))
                elif (all(number(x) and x > 0 for x in (average, minimum, maximum))
                        and minimum <= average <= maximum and type(count) is int and 0 < count <= 100_000
                        and valid_time):
                    result.update(status='done', completedAt=iso(completed),
                                  result={'average': average, 'minimum': minimum, 'maximum': maximum,
                                          'sampleCount': count, 'measuredAt': iso(completed)})
        return {'measurement': result}


def make_server(bridge, host='127.0.0.1', port=8798):
    # A hostname is deliberately not resolved: DNS must not change the bind scope.
    try:
        if not ipaddress.ip_address(host).is_loopback:
            raise ValueError()
    except ValueError:
        raise ValueError('bridge may bind only a literal loopback address') from None
    if ':' in host:
        raise ValueError('use IPv4 loopback for this server')

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass  # No request bodies, IDs, bearer values or upstream errors in logs.

        def setup(self):
            super().setup()
            self.connection.settimeout(10)

        def _reply(self, status, payload):
            encoded = json.dumps(payload, ensure_ascii=False, allow_nan=False).encode('utf-8')
            self.send_response(status)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(encoded)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(encoded)
            self.close_connection = True

        def _run(self):
            try:
                if len(self.headers.get_all('Authorization', [])) != 1 or not bridge.authorized(self.headers.get('Authorization')):
                    raise BridgeError(401, 'unauthorized')
                if self.command == 'GET' and self.path == '/health':
                    payload = {'ok': True, 'service': 'collar-cove', 'protocol': 1}
                elif self.command == 'GET' and self.path == '/push/status':
                    payload = bridge.push.status() if bridge.push else {'configured': False}
                elif self.command == 'GET' and self.path.startswith('/measurements/'):
                    payload = bridge.measurement(self.path[len('/measurements/'):])
                elif self.command == 'POST' and self.path in {'/summary', '/measurements'}:
                    if self.headers.get('Transfer-Encoding') or len(self.headers.get_all('Content-Length', [])) != 1:
                        raise BridgeError(400, 'invalid_body')
                    try:
                        size = int(self.headers.get('Content-Length', ''))
                    except ValueError:
                        raise BridgeError(400, 'invalid_body') from None
                    if not 0 < size <= MAX_BODY:
                        raise BridgeError(413, 'body_too_large')
                    try:
                        def unique(pairs):
                            result = {}
                            for key, value in pairs:
                                if key in result:
                                    raise ValueError()
                                result[key] = value
                            return result
                        body = json.loads(self.rfile.read(size), object_pairs_hook=unique)
                    except (ValueError, UnicodeError):
                        raise BridgeError(400, 'invalid_body') from None
                    payload = bridge.summary(body) if self.path == '/summary' else bridge.create_measurement(body)
                else:
                    raise BridgeError(404, 'not_found')
                self._reply(200, payload)
            except BridgeError as exc:
                self._reply(exc.status, {'error': exc.code})
            except Exception:
                self._reply(503, {'error': 'collar_unavailable'})

        do_GET = do_POST = _run

    return ThreadingHTTPServer((host, port), Handler)


def main():
    token = os.environ.get('COLLAR_COVE_TOKEN', '')
    if len(token) < 32 or token.strip() != token:
        raise SystemExit('A dedicated COLLAR_COVE_TOKEN of at least 32 characters is required')
    health_dir = os.environ.get('HEALTH_DATA_DIR', '')
    if not health_dir or not Path(health_dir).is_absolute():
        raise SystemExit('HEALTH_DATA_DIR must explicitly identify the existing Collar data directory')
    root = Path(os.environ.get('COLLAR_STORE_ROOT', '/srv/collar'))
    sys.path.insert(0, str(root / 'server'))
    sys.path.insert(0, str(root / 'vendor'))
    hs = importlib.import_module('health_store')
    from collar_push import WatchPush
    bridge = CollarBridge(hs, token, os.environ.get('COLLAR_COVE_DATA_DIR', '/var/lib/collar-cove'),
                          push=WatchPush())
    server = make_server(bridge, os.environ.get('COLLAR_COVE_HOST', '127.0.0.1'),
                         int(os.environ.get('COLLAR_COVE_PORT', '8798')))
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
