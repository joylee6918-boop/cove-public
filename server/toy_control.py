"""Durable, owner-granted Cove -> iPhone -> SOSEXY command bridge.

The server never speaks Bluetooth and never accepts arbitrary GATT bytes.  A
phone-created foreground session is required before a model tool can enqueue a
high-level command.  Tool calls wait for the phone's execution ACK so
the model cannot confuse "queued" with "written to the device".
"""
import json
import threading
import time
import uuid
from datetime import datetime, timezone, timedelta

from storage import APIError, encode, now


TOY_CONTROL_TOOL = {
    'name': 'cove_bobobei_control',
    'description': (
        'Control 用户’s nearby 啵啵贝 only while she has explicitly opened a foreground '
        '“交给助手” session in Cove. Sets the three captured SOSEXY output channels '
        '(motion, vibration, rotation) from 0–100. The selected state stays active until '
        'the next control command, an explicit stop, revocation, or a real disconnect. '
        'There is no command-count or duration limit. Success means Cove confirmed the '
        'GATT writes, not that any subjective effect is known. Never claim success when '
        'the returned status is unavailable, failed or unknown.'),
    'inputSchema': {
        'type': 'object',
        'properties': {
            'motion': {'type': 'integer', 'minimum': 0, 'maximum': 100},
            'vibration': {'type': 'integer', 'minimum': 0, 'maximum': 100},
            'rotation': {'type': 'integer', 'minimum': 0, 'maximum': 100},
        },
        'required': ['motion', 'vibration', 'rotation'],
        'additionalProperties': False,
    },
}

TOY_STOP_TOOL = {
    'name': 'cove_bobobei_stop',
    'description': (
        'Send an immediate all-channel stop to 啵啵贝 through the currently owner-granted '
        'foreground Cove session. Success is reported only after the phone confirms all '
        'three stop writes. This does not create or extend control permission.'),
    'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': False},
}

FENXIN_CONTROL_TOOL = {
    'name': 'cove_fenxin_control',
    'description': (
        'Control 用户’s nearby 分欣 toy only while she has explicitly opened a '
        '“交给助手” session for the SL278 device in Cove. Sets the captured suction '
        'channel from 0–100. Success means the iPhone accepted the BLE write; never '
        'claim success for unavailable, failed, expired, or unknown results.'),
    'inputSchema': {
        'type': 'object',
        'properties': {'level': {'type': 'integer', 'minimum': 0, 'maximum': 100}},
        'required': ['level'],
        'additionalProperties': False,
    },
}

FENXIN_STOP_TOOL = {
    'name': 'cove_fenxin_stop',
    'description': (
        'Send the captured all-stop sequence to 分欣 through its current owner-granted '
        'Cove session. This does not create or extend control permission.'),
    'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': False},
}

TOY_TOOLS = [TOY_CONTROL_TOOL, TOY_STOP_TOOL, FENXIN_CONTROL_TOOL, FENXIN_STOP_TOOL]
TOY_TOOL_WAIT_SECONDS = 10
TOY_COMMAND_MAX_AGE_SECONDS = 12


def _iso(value):
    return value.astimezone(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')


def _parse(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


class ToyControlStore:
    def init_toy_control(self):
        self.db.executescript('''
        CREATE TABLE IF NOT EXISTS toy_sessions(
          id TEXT PRIMARY KEY,
          status TEXT NOT NULL CHECK(status IN ('active','revoked','expired','restarted')),
          created TEXT NOT NULL,
          expires TEXT NOT NULL,
          last_phone TEXT,
          device TEXT NOT NULL DEFAULT 'bobobei'
        );
        CREATE TABLE IF NOT EXISTS toy_commands(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          request_id TEXT UNIQUE NOT NULL,
          session TEXT NOT NULL REFERENCES toy_sessions(id),
          body TEXT NOT NULL,
          status TEXT NOT NULL CHECK(status IN ('queued','delivered','completed','failed','canceled')),
          created TEXT NOT NULL,
          completed TEXT,
          result TEXT
        );
        CREATE INDEX IF NOT EXISTS toy_command_session_cursor ON toy_commands(session,id);
        ''')
        columns = {row['name'] for row in self.db.execute('PRAGMA table_info(toy_sessions)')}
        if 'device' not in columns:
            self.db.execute("ALTER TABLE toy_sessions ADD COLUMN device TEXT NOT NULL DEFAULT 'bobobei'")
        # A server restart invalidates the capability.  The phone will stop on
        # its first failed/inactive poll and the owner must grant a fresh session.
        self.db.execute("UPDATE toy_sessions SET status='restarted' WHERE status='active'")
        self.db.execute("UPDATE toy_commands SET status='canceled',completed=?,result=? WHERE status IN ('queued','delivered')",
                        (now(), encode({'status': 'canceled', 'reason': 'server-restarted'})))
        self.db.commit()
        self.toy_condition = threading.Condition(self.lock)

    def _active_toy_session_locked(self):
        row = self.db.execute("SELECT * FROM toy_sessions WHERE status='active' ORDER BY created DESC LIMIT 1").fetchone()
        if not row:
            return None
        if _parse(row['expires']) <= datetime.now(timezone.utc):
            self.db.execute("UPDATE toy_sessions SET status='expired' WHERE id=?", (row['id'],))
            self.db.execute("UPDATE toy_commands SET status='canceled',completed=?,result=? WHERE session=? AND status='queued'",
                            (now(), encode({'status': 'canceled', 'reason': 'session-expired'}), row['id']))
            self.db.commit()
            self.toy_condition.notify_all()
            return None
        return row

    @staticmethod
    def _session_value(row):
        if not row:
            return None
        return {'id': row['id'], 'status': row['status'], 'createdAt': row['created'],
                'expiresAt': row['expires'], 'lastPhoneAt': row['last_phone'],
                'device': row['device'] if 'device' in row.keys() else 'bobobei'}

    def toy_status(self):
        with self.toy_condition:
            row = self._active_toy_session_locked()
            return {'active': bool(row), 'session': self._session_value(row)}

    def grant_toy_session(self, body):
        if not isinstance(body, dict) or set(body) - {'mode', 'device'} or body.get('mode') != 'untilRevoked':
            raise APIError(400, '玩具授权模式无效')
        device = body.get('device', 'bobobei')
        if device not in ('bobobei', 'fenxin'):
            raise APIError(400, '玩具类型无效')
        created = datetime.now(timezone.utc)
        session = str(uuid.uuid4())
        with self.toy_condition, self.db:
            self.db.execute("UPDATE toy_sessions SET status='revoked' WHERE status='active'")
            self.db.execute("UPDATE toy_commands SET status='canceled',completed=?,result=? WHERE status IN ('queued','delivered')",
                            (now(), encode({'status': 'canceled', 'reason': 'session-replaced'})))
            self.db.execute('INSERT INTO toy_sessions(id,status,created,expires,last_phone,device) VALUES(?,?,?,?,NULL,?)',
                            (session, 'active', _iso(created), '9999-12-31T23:59:59.000Z', device))
            row = self.db.execute('SELECT * FROM toy_sessions WHERE id=?', (session,)).fetchone()
            self.toy_condition.notify_all()
            return {'active': True, 'session': self._session_value(row)}

    def poll_toy_commands(self, session, after):
        if type(after) is not int or not 0 <= after <= 2**63 - 1:
            raise APIError(400, '玩具指令游标无效')
        with self.toy_condition, self.db:
            active = self._active_toy_session_locked()
            if not active or active['id'] != session:
                return {'active': False, 'session': None, 'cursor': after, 'commands': []}
            stamp = now()
            self.db.execute('UPDATE toy_sessions SET last_phone=? WHERE id=?', (stamp, session))
            cutoff = _iso(datetime.now(timezone.utc) - timedelta(seconds=TOY_COMMAND_MAX_AGE_SECONDS))
            self.db.execute(
                "UPDATE toy_commands SET status='canceled',completed=?,result=? "
                "WHERE session=? AND status IN ('queued','delivered') AND created<?",
                (stamp, encode({'status': 'expired', 'reason': 'command-expired'}), session, cutoff))
            rows = self.db.execute(
                "SELECT * FROM toy_commands WHERE session=? AND id>? AND status IN ('queued','delivered') ORDER BY id LIMIT 20",
                (session, after)).fetchall()
            for row in rows:
                if row['status'] == 'queued':
                    self.db.execute("UPDATE toy_commands SET status='delivered' WHERE id=? AND status='queued'", (row['id'],))
            commands = []
            for row in rows:
                body = json.loads(row['body'])
                commands.append(dict(body, id=str(row['id']), createdAt=row['created'],
                                     expiresAt=_iso(_parse(row['created']) + timedelta(
                                         seconds=TOY_COMMAND_MAX_AGE_SECONDS))))
            return {'active': True, 'session': self._session_value(
                        self.db.execute('SELECT * FROM toy_sessions WHERE id=?', (session,)).fetchone()),
                    'cursor': int(rows[-1]['id']) if rows else after, 'commands': commands}

    def acknowledge_toy_command(self, session, command, body):
        if not isinstance(body, dict) or set(body)-{'status', 'error', 'startedAt', 'stopAt'}:
            raise APIError(400, '玩具指令回执无效')
        status = body.get('status')
        if status not in ('started', 'stopped', 'failed'):
            raise APIError(400, '玩具指令状态无效')
        if any(value is not None and (not isinstance(value, str) or len(value) > 500)
               for value in (body.get('error'), body.get('startedAt'), body.get('stopAt'))):
            raise APIError(400, '玩具指令回执过长')
        try:
            command_id = int(command)
        except (TypeError, ValueError):
            raise APIError(400, '玩具指令 ID 无效')
        with self.toy_condition, self.db:
            row = self.db.execute('SELECT * FROM toy_commands WHERE id=? AND session=?', (command_id, session)).fetchone()
            if not row:
                raise APIError(404, '玩具指令不存在')
            if row['status'] in ('completed', 'failed'):
                return {'ok': True, 'commandID': str(command_id), 'status': row['status']}
            if row['status'] == 'canceled':
                raise APIError(409, '玩具指令已经取消')
            final = 'failed' if status == 'failed' else 'completed'
            result = {'status': status}
            for key in ('error', 'startedAt', 'stopAt'):
                if body.get(key) is not None:
                    result[key] = body[key]
            self.db.execute('UPDATE toy_commands SET status=?,completed=?,result=? WHERE id=?',
                            (final, now(), encode(result), command_id))
            self.toy_condition.notify_all()
            return {'ok': True, 'commandID': str(command_id), 'status': final}

    def revoke_toy_session(self, session):
        with self.toy_condition, self.db:
            row = self.db.execute('SELECT * FROM toy_sessions WHERE id=?', (session,)).fetchone()
            if not row:
                raise APIError(404, '玩具授权不存在')
            if row['status'] == 'active':
                self.db.execute("UPDATE toy_sessions SET status='revoked' WHERE id=?", (session,))
                self.db.execute("UPDATE toy_commands SET status='canceled',completed=?,result=? WHERE session=? AND status IN ('queued','delivered')",
                                (now(), encode({'status': 'canceled', 'reason': 'owner-revoked'}), session))
            self.toy_condition.notify_all()
            return {'ok': True, 'active': False}

    @staticmethod
    def _validated_toy_action(tool, arguments):
        if not isinstance(arguments, dict):
            raise APIError(400, '玩具参数无效')
        if tool == 'cove_bobobei_stop':
            if arguments:
                raise APIError(400, '停止指令不接受参数')
            return 'bobobei', {'device': 'bobobei', 'kind': 'stop', 'motion': 0, 'vibration': 0, 'rotation': 0}
        if tool == 'cove_bobobei_control':
            if set(arguments) != {'motion', 'vibration', 'rotation'}:
                raise APIError(400, '啵啵贝控制参数无效')
            for key in ('motion', 'vibration', 'rotation'):
                if type(arguments[key]) is not int or not 0 <= arguments[key] <= 100:
                    raise APIError(400, key + ' 必须为 0 至 100 的整数')
            return 'bobobei', dict(device='bobobei', kind='control', **arguments)
        if tool == 'cove_fenxin_stop':
            if arguments:
                raise APIError(400, '停止指令不接受参数')
            return 'fenxin', {'device': 'fenxin', 'kind': 'stop', 'level': 0}
        if tool == 'cove_fenxin_control':
            if set(arguments) != {'level'} or type(arguments['level']) is not int or not 0 <= arguments['level'] <= 100:
                raise APIError(400, '分欣强度必须为 0 至 100 的整数')
            return 'fenxin', {'device': 'fenxin', 'kind': 'control', 'level': arguments['level']}
        raise APIError(400, '未知玩具控制指令')

    def assistant_toy_tool(self, message, turn, call, tool, arguments, conversation):
        device, action = self._validated_toy_action(tool, arguments)
        request_id = encode([message, turn, call])
        deadline = time.monotonic() + TOY_TOOL_WAIT_SECONDS
        with self.toy_condition:
            active = self._active_toy_session_locked()
            if not active:
                return {'status': 'unavailable', 'executed': False,
                        'message': '用户尚未在前台 Cove 中把啵啵贝交给你，未发送任何动作。'}
            if active['device'] != device:
                return {'status': 'unavailable', 'executed': False,
                        'message': '当前交给你的不是这台玩具，未发送任何动作。'}
            existing = self.db.execute('SELECT * FROM toy_commands WHERE request_id=?', (request_id,)).fetchone()
            if existing:
                command_id = existing['id']
            else:
                reason = 'superseded-by-stop' if tool.endswith('_stop') else 'superseded-by-newer-command'
                self.db.execute(
                    "UPDATE toy_commands SET status='canceled',completed=?,result=? "
                    "WHERE session=? AND status IN ('queued','delivered')",
                    (now(), encode({'status': 'canceled', 'reason': reason}), active['id']))
                command_id = self.db.execute(
                    'INSERT INTO toy_commands(request_id,session,body,status,created) VALUES(?,?,?,?,?)',
                    (request_id, active['id'], encode(action), 'queued', now())).lastrowid
                self.db.commit()
                self.toy_condition.notify_all()
            while True:
                row = self.db.execute('SELECT * FROM toy_commands WHERE id=?', (command_id,)).fetchone()
                if row['status'] in ('completed', 'failed', 'canceled'):
                    result = json.loads(row['result']) if row['result'] else {'status': row['status']}
                    return {'commandID': str(command_id), 'executed': row['status'] == 'completed', **result}
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    self.db.execute(
                        "UPDATE toy_commands SET status='canceled',completed=?,result=? "
                        "WHERE id=? AND status IN ('queued','delivered')",
                        (now(), encode({'status': 'expired', 'reason': 'ack-timeout'}), command_id))
                    self.db.commit()
                    self.toy_condition.notify_all()
                    return {'commandID': str(command_id), 'status': 'expired', 'executed': False,
                            'message': '指令在确认前已过期并作废，不会在蓝牙重连后补执行。'}
                self.toy_condition.wait(min(remaining, .5))
