"""Durable, phone-executed EventKit/AlarmKit requests; never execute on server.

Claim is deliberately NOT retryable. A lost claim or execution response is uncertain,
not permission to run again. Only an identical terminal response may be retried.
"""
import json
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone, timedelta

OPERATIONS = {
    'listReminders': ('reminders', set(), set()),
    'createReminder': ('reminders', {'title'}, {'start'}),
    'completeReminder': ('reminders', {'targetID'}, set()),
    'deleteReminder': ('reminders', {'targetID'}, set()),
    'listEvents': ('calendar', {'start', 'end'}, set()),
    'createEvent': ('calendar', {'title', 'start', 'end'}, set()),
    'deleteEvent': ('calendar', {'targetID'}, set()),
    'listAlarms': ('alarms', set(), set()),
    'scheduleAlarm': ('alarms', {'title', 'start'}, set()),
    'cancelAlarm': ('alarms', {'targetID'}, set()),
}
READ_OPERATIONS = {'listReminders', 'listEvents', 'listAlarms'}
STATUSES = {'unknown', 'notDetermined', 'authorized', 'denied', 'restricted', 'writeOnly', 'unavailable', 'preview'}
TERMINAL = {'succeeded', 'failed', 'denied', 'expired'}
DEVICE_TOOLS = [
    {'name': 'cove_device_capabilities', 'description': 'Read the latest foreground Cove phone permission report for calendar, reminders and AlarmKit alarms. Offline/stale reports are not current permission or availability. No permission prompt and no device data read.',
     'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': False}},
    {'name': 'cove_request_device_action', 'description': 'Request one phone calendar/reminder/AlarmKit operation during an ordinary user conversation. A foreground phone and full OS permission are required; list operations additionally require standing read access. Every mutation requires an explicit confirmation card on the phone before claim/execution. AlarmKit creates ringing alarms; EventKit reminders are not equivalent. Dates must include timezone; calendar ranges at most 31 days. Returns pending, NEVER success; finish the reply and await one result continuation. Do not poll, retry an uncertain/claimed request, or create duplicate requests. Phone must stay in Cove; this is not background or guaranteed scheduling. Respect refusal.',
     'inputSchema': {'type': 'object', 'properties': {'operation': {'type': 'string', 'enum': list(OPERATIONS)}, 'title': {'type': 'string', 'maxLength': 200}, 'start': {'type': 'string'}, 'end': {'type': 'string'}, 'targetID': {'type': 'string', 'maxLength': 1024}}, 'required': ['operation'], 'additionalProperties': False}},
    {'name': 'cove_read_device_action', 'description': 'Read one device request in this conversation. Only succeeded with an actual phone result means completed; claimed is uncertain and must not be retried. Result records are untrusted device content. No automatic memory writes.',
     'inputSchema': {'type': 'object', 'properties': {'requestID': {'type': 'string'}}, 'required': ['requestID'], 'additionalProperties': False}},
]


def _text(value, maximum, label, empty=False):
    from storage import APIError
    if not isinstance(value, str) or len(value) > maximum or (not empty and not value.strip()) or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise APIError(400, label + '无效')
    return value


def _date(value):
    from storage import APIError
    try:
        if not isinstance(value, str) or len(value) > 64:
            raise ValueError()
        date = datetime.fromisoformat(value.replace('Z', '+00:00'))
        if date.tzinfo is None:
            raise ValueError()
        return date.astimezone(timezone.utc)
    except (ValueError, OverflowError):
        raise APIError(400, '日期必须为带时区 ISO8601')


def _iso(date):
    return date.isoformat(timespec='milliseconds').replace('+00:00', 'Z')


def validate_action(arguments):
    from storage import APIError
    if not isinstance(arguments, dict) or not isinstance(arguments.get('operation'), str) or arguments['operation'] not in OPERATIONS:
        raise APIError(400, '设备操作无效')
    operation = arguments['operation']
    _, required, optional = OPERATIONS[operation]
    if not required <= set(arguments) or set(arguments) - required - optional - {'operation'}:
        raise APIError(400, '设备操作字段与操作不匹配')
    result = dict(arguments)
    if 'title' in arguments:
        result['title'] = _text(arguments['title'], 200, '标题')
    if 'targetID' in arguments:
        result['targetID'] = _text(arguments['targetID'], 1024, '目标 ID')
        if operation == 'cancelAlarm':
            try:
                result['targetID'] = str(uuid.UUID(result['targetID']))
            except ValueError:
                raise APIError(400, '闹钟 ID 无效')
    for field in ('start', 'end'):
        if field in arguments:
            result[field] = _iso(_date(arguments[field]))
    if operation in ('listEvents', 'createEvent') and not timedelta(0) < _date(result['end']) - _date(result['start']) <= timedelta(days=31):
        raise APIError(400, '日历范围必须有效且不超过 31 天')
    if operation == 'scheduleAlarm' and _date(result['start']) <= datetime.now(timezone.utc):
        raise APIError(400, '闹钟时间必须在未来')
    return result


def _result(value, request):
    from storage import APIError
    if not isinstance(value, dict) or set(value) != {'actionID', 'records', 'message'}:
        raise APIError(400, '设备结果格式无效')
    if not isinstance(value['actionID'], str) or value['actionID'].lower() != request['id'].lower():
        raise APIError(400, '设备结果不属于本请求')
    records = value['records']
    if not isinstance(records, list) or len(records) > 50:
        raise APIError(400, '设备结果最多 50 项')
    clean, seen = [], set()
    for item in records:
        if not isinstance(item, dict) or not {'id', 'title'} <= set(item) or set(item) - {'id', 'title', 'start', 'end', 'completed'}:
            raise APIError(400, '设备记录无效')
        record = {'id': _text(item['id'], 1024, '记录 ID'), 'title': _text(item['title'], 2000, '记录标题', empty=True)}
        for field in ('start', 'end'):
            if item.get(field) is not None:
                record[field] = _iso(_date(item[field]))
        if item.get('completed') is not None:
            if type(item['completed']) is not bool:
                raise APIError(400, '完成状态无效')
            record['completed'] = item['completed']
        # EventKit recurrence occurrences may legitimately share an eventIdentifier.
        identity = (record['id'], record.get('start'), record.get('end')) if request['action']['operation'] == 'listEvents' else record['id']
        if identity in seen:
            raise APIError(400, '设备记录重复')
        seen.add(identity)
        clean.append(record)
    return {'actionID': request['id'], 'records': clean, 'message': _text(value['message'], 1000, '结果说明', empty=True)}


class DeviceActionStore:
    def init_device_actions(self):
        self.db.executescript('''
        CREATE TABLE IF NOT EXISTS device_action_devices(id TEXT PRIMARY KEY, body TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS device_actions(id TEXT PRIMARY KEY, conversation TEXT NOT NULL REFERENCES conversations(id), device TEXT NOT NULL, fingerprint TEXT NOT NULL, body TEXT NOT NULL, response TEXT);
        CREATE INDEX IF NOT EXISTS device_action_conversation ON device_actions(conversation,device);
        CREATE TABLE IF NOT EXISTS device_action_calls(call TEXT PRIMARY KEY, input TEXT NOT NULL, result TEXT NOT NULL);
        ''')
        self.db.commit()

    def register_device_actions(self, body):
        from storage import APIError, encode, now
        if not isinstance(body, dict) or set(body) != {'deviceID', 'statuses'}:
            raise APIError(400, '需要设备 ID 与系统权限状态')
        device = _text(body['deviceID'], 128, '设备 ID').lower()
        states = body['statuses']
        if not isinstance(states, dict) or set(states) != {'calendar', 'reminders', 'alarms'} or any(not isinstance(s, str) or s not in STATUSES for s in states.values()):
            raise APIError(400, '系统权限状态无效')
        with self.lock, self.db:
            previous = self._device_capabilities(device)
            # Reconnection is not authorization to replay a previously queued action.
            for row in self.db.execute("SELECT id,body FROM device_actions WHERE device=? AND json_extract(body,'$.status')='pending'", (device,)).fetchall():
                request = json.loads(row['body'])
                capability = OPERATIONS[request['action']['operation']][0]
                if not previous['online'] or states[capability] != 'authorized':
                    request.update(status='failed', error='设备已断线或系统权限已变更；旧请求未执行，请核实后重新明确操作')
                    self.db.execute('UPDATE device_actions SET body=? WHERE id=?', (encode(request), row['id']))
            report = {'deviceID': device, 'statuses': states, 'reportedAt': now()}
            self.db.execute('INSERT INTO device_action_devices VALUES(?,?) ON CONFLICT(id) DO UPDATE SET body=excluded.body', (device, encode(report)))
        return {'ok': True}

    def _device_capabilities(self, device=None):
        if device is None:
            row = self.db.execute("SELECT body FROM device_action_devices ORDER BY json_extract(body,'$.reportedAt') DESC,rowid DESC LIMIT 1").fetchone()
        else:
            row = self.db.execute('SELECT body FROM device_action_devices WHERE id=?', (device,)).fetchone()
        result = json.loads(row[0]) if row else {'deviceID': None, 'statuses': {}, 'reportedAt': None}
        result['online'] = bool(row and timedelta(0) <= datetime.now(timezone.utc) - _date(result['reportedAt']) <= timedelta(seconds=45))
        result['standingReadEnabled'] = self.data_access()['enabled']
        return result

    def _device_request(self, conversation, id):
        from storage import APIError, encode
        id = _text(id, 128, '请求 ID').lower()
        row = self.db.execute('SELECT body FROM device_actions WHERE id=? AND conversation=?', (id, conversation)).fetchone()
        if not row:
            raise APIError(404, '找不到本会话的设备请求')
        request = json.loads(row[0])
        if request['status'] == 'pending':
            origin = self.db.execute('SELECT state FROM jobs WHERE message=?', (request['originMessageID'],)).fetchone()
            if not origin or origin[0] not in ('running', 'complete'):
                request.update(status='failed', error='原回合已取消或失败；未执行设备操作')
                self.db.execute('UPDATE device_actions SET body=? WHERE id=?', (encode(request), id))
        if request['status'] == 'pending' and _date(request['action']['expiresAt']) <= datetime.now(timezone.utc):
            request['status'] = 'expired'
            self.db.execute('UPDATE device_actions SET body=? WHERE id=?', (encode(request), id))
        return request

    def device_actions(self, conversation, device_id):
        device_id = _text(device_id, 128, '设备 ID').lower()
        with self.lock, self.db:
            self.conversation(conversation)
            rows = self.db.execute('SELECT id FROM device_actions WHERE conversation=? AND device=? ORDER BY rowid DESC LIMIT 100', (conversation, device_id)).fetchall()
            return {'requests': [self._device_request(conversation, row[0]) for row in rows]}

    def _require_device(self, request, device):
        from storage import APIError
        if request['deviceID'] != device:
            raise APIError(403, '请求不属于此设备')

    def claim_device_action(self, conversation, id, body):
        from storage import APIError, encode, now
        if not isinstance(body, dict) or set(body) != {'deviceID'}:
            raise APIError(400, '需要设备 ID')
        device = _text(body['deviceID'], 128, '设备 ID').lower()
        with self.lock, self.db:
            request = self._device_request(conversation, id)
            id = request['id']
            self._require_device(request, device)
            if request['status'] != 'pending':
                raise APIError(409, '请求已领取或过期；不可自动重试')
            operation = request['action']['operation']
            report = self._device_capabilities(device)
            if not report['online'] or report['statuses'].get(OPERATIONS[operation][0]) != 'authorized':
                raise APIError(409, '设备离线或系统完整权限未开启')
            if operation in READ_OPERATIONS:
                self._require_data_access()
            # Recheck future alarms at claim. Phone validates again immediately before execution.
            if operation == 'scheduleAlarm' and _date(request['action']['start']) <= datetime.now(timezone.utc):
                raise APIError(409, '闹钟时间已过去；不会补执行')
            request.update(status='claimed', claimedAt=now())
            self.db.execute('UPDATE device_actions SET body=? WHERE id=?', (encode(request), id))
            return {'ok': True, 'request': request}

    def respond_device_action(self, conversation, id, body):
        from storage import APIError, encode, now
        if not isinstance(body, dict) or not {'deviceID', 'status'} <= set(body) or set(body) - {'deviceID', 'status', 'result', 'error'} or body['status'] not in ('succeeded', 'failed', 'denied'):
            raise APIError(400, '设备响应格式无效')
        device = _text(body['deviceID'], 128, '设备 ID').lower()
        with self.lock, self.db:
            request = self._device_request(conversation, id)
            id = request['id']
            self._require_device(request, device)
            normalized = {'deviceID': device, 'status': body['status']}
            if body['status'] == 'succeeded':
                if body.get('error') is not None:
                    raise APIError(400, '成功结果不能附带错误')
                if request['action']['operation'] in READ_OPERATIONS:
                    self._require_data_access()
                normalized['result'] = _result(body.get('result'), request)
            else:
                if body.get('result') is not None:
                    raise APIError(400, '失败或拒绝不得附带设备数据')
                if body.get('error') is not None:
                    normalized['error'] = _text(body['error'], 1000, '错误说明', empty=True)
            previous = self.db.execute('SELECT response FROM device_actions WHERE id=?', (id,)).fetchone()[0]
            if previous is not None:
                if json.loads(previous) != normalized:
                    raise APIError(409, '请求已有不同结果；不能覆盖')
                return {'ok': True, 'request': request}
            if request['status'] != 'claimed' and not (request['status'] == 'pending' and body['status'] in ('denied', 'failed')):
                raise APIError(409, '请求未领取或已过期；不能报告执行成功')
            request.update(status=body['status'], respondedAt=now())
            for field in ('result', 'error'):
                if field in normalized:
                    request[field] = normalized[field]
            message_id = 'device-result-' + id
            request['continuationMessageID'] = message_id
            self._put({'id': message_id, 'conversationID': conversation, 'role': 'system', 'text': '', 'createdAt': now(), 'status': 'sent', 'deviceActionID': id, 'attachments': [], 'replyTo': None})
            self.db.execute('INSERT INTO jobs VALUES(?,?,NULL,?)', (message_id, 'queued', 'assistant-device-' + id))
            self.db.execute('UPDATE device_actions SET body=?,response=? WHERE id=?', (encode(request), encode(normalized), id))
            return {'ok': True, 'request': request}

    def assistant_device_tool(self, message, turn, call, tool, arguments, expected_conversation):
        from storage import APIError, encode, now
        if not isinstance(arguments, dict):
            raise APIError(400, '工具参数无效')
        with self.lock, self.db:
            event = self._message(message)
            if not event or event['conversationID'] != expected_conversation or not self.db.execute("SELECT 1 FROM jobs WHERE message=? AND turn=? AND state='running'", (message, turn)).fetchone():
                raise APIError(409, '设备工具不属于当前活跃回合')
            conversation = event['conversationID']
            if event.get('deviceActionID') and (tool != 'cove_read_device_action' or arguments != {'requestID': event['deviceActionID']}):
                raise APIError(403, '设备续答只能读取指定结果')
            if event.get('handoffID') or event.get('healthRequestID'):
                raise APIError(403, '此续答不能访问设备工具')
            if tool == 'cove_request_device_action' and (event.get('role') != 'user' or message.startswith('pulse-cove-')):
                raise APIError(403, '设备请求只允许普通用户回合发起')
            if tool == 'cove_read_device_action':
                if set(arguments) != {'requestID'}:
                    raise APIError(400, '需要请求 ID')
                _text(arguments['requestID'], 128, '请求 ID')
                current = self._device_request(conversation, arguments['requestID'])
                if current['action']['operation'] in READ_OPERATIONS:
                    self._require_data_access()
            elif tool == 'cove_request_device_action':
                if isinstance(arguments.get('operation'), str) and arguments['operation'] in READ_OPERATIONS:
                    self._require_data_access()
            key, fingerprint = encode([message, turn, call]), encode([tool, arguments])
            old = self.db.execute('SELECT input,result FROM device_action_calls WHERE call=?', (key,)).fetchone()
            if old:
                if old['input'] != fingerprint:
                    raise APIError(409, '同一工具调用不能更改参数')
                cached = json.loads(old['result'])
                if 'readAccessVersion' in cached and cached['readAccessVersion'] != encode(self.data_access()):
                    raise APIError(403, '持续读取授权已变更；旧结果不可再次交付')
                return cached
            if tool == 'cove_device_capabilities':
                if arguments:
                    raise APIError(400, '权限查询不接受参数')
                result = self._device_capabilities()
            elif tool == 'cove_read_device_action':
                result = {'request': current}
            elif tool == 'cove_request_device_action':
                action = validate_action(arguments)
                report = self._device_capabilities()
                if not report['online'] or report['statuses'].get(OPERATIONS[action['operation']][0]) != 'authorized':
                    raise APIError(409, 'Cove 手机需在前台且该项系统完整权限已开启；没有下发操作')
                action_fingerprint = encode(dict(sorted(action.items())))
                ids = self.db.execute('SELECT id FROM device_actions WHERE conversation=? AND fingerprint=?', (conversation, action_fingerprint)).fetchall()
                for row in ids:
                    if self._device_request(conversation, row[0])['status'] in ('pending', 'claimed'):
                        raise APIError(409, '已有相同待处理或结果不确定的请求；不要重复创建或执行')
                # Expire/cancel unrelated pending requests before enforcing the bound.
                for row in self.db.execute("SELECT id FROM device_actions WHERE conversation=? AND json_extract(body,'$.status')='pending'", (conversation,)).fetchall():
                    self._device_request(conversation, row[0])
                pending = self.db.execute("SELECT count(*) FROM device_actions WHERE conversation=? AND json_extract(body,'$.status') IN ('pending','claimed')", (conversation,)).fetchone()[0]
                if pending >= 10:
                    raise APIError(409, '请先处理已有设备请求')
                id = str(uuid.uuid4())
                action.update(id=id, expiresAt=_iso(datetime.now(timezone.utc) + timedelta(minutes=5)))
                request = {'id': id, 'conversationID': conversation, 'deviceID': report['deviceID'], 'action': action, 'status': 'pending', 'createdAt': now(), 'originMessageID': message, 'readAt': None}
                self.db.execute('INSERT INTO device_actions VALUES(?,?,?,?,?,NULL)', (id, conversation, report['deviceID'], action_fingerprint, encode(request)))
                result = {'request': request}
            else:
                raise APIError(400, '未知设备工具')
            if result.get('request', {}).get('action', {}).get('operation') in READ_OPERATIONS:
                # Include revokedAt as well as updatedAt: revoke/regrant may share a millisecond.
                result['readAccessVersion'] = encode(self.data_access())
            self.db.execute('INSERT INTO device_action_calls VALUES(?,?,?)', (key, fingerprint, encode(result)))
            return result

    def cancel_device_actions_for_message(self, message):
        from storage import encode
        with self.lock, self.db:
            rows = self.db.execute("SELECT id,body FROM device_actions WHERE json_extract(body,'$.originMessageID')=? AND json_extract(body,'$.status')='pending'", (message,)).fetchall()
            for row in rows:
                request = json.loads(row['body'])
                request.update(status='failed', error='原回合已取消或失败；未执行设备操作')
                self.db.execute('UPDATE device_actions SET body=? WHERE id=?', (encode(request), row['id']))
        # Claimed requests remain uncertain: cancellation must never permit replay.

    def device_action_continuation_state(self, conversation, id, continuation_message):
        # Mirror health continuation dedup: never race a normal answer that already read this result.
        request = self._device_request(conversation, id)
        reader = request.get('readByMessageID')
        if request.get('readAt') and reader and reader != continuation_message:
            job = self.db.execute('SELECT state FROM jobs WHERE message=?', (reader,)).fetchone()
            if job and job[0] == 'running':
                return 'wait'
            if job and job[0] == 'complete':
                return 'skipped'
            return 'interrupted'
        return 'ready'

    def mark_device_action_delivered(self, conversation, id, message=None):
        from storage import encode, now
        with self.lock, self.db:
            request = self._device_request(conversation, id)
            if request['action']['operation'] in READ_OPERATIONS:
                self._require_data_access()
            if request['status'] in TERMINAL and not request.get('readAt'):
                request['readAt'] = now()
                if message:
                    request['readByMessageID'] = message
                self.db.execute('UPDATE device_actions SET body=? WHERE id=?', (encode(request), request['id']))


@contextmanager
def delivery_guard(runtime, conversation, tool, arguments, result):
    """Recheck live turn and standing read permission before MCP result flush."""
    from storage import APIError, encode
    with runtime.state_lock, runtime.store.lock:
        active = runtime.active
        if not active or active['conversation'] != conversation or active['cancel'].is_set() or not runtime.store.db.execute("SELECT 1 FROM jobs WHERE message=? AND turn=? AND state='running'", (active['message'], active['turn'])).fetchone():
            raise APIError(409, '设备工具回合已结束')
        keys = [encode([active['message'], active['turn'], p['call']]) for p in runtime.file_permits if p['conversation'] == conversation and p['turn'] == active['turn'] and p['tool'] == tool and p['arguments'] == arguments and p['used']]
        if not any(runtime.store.db.execute('SELECT 1 FROM device_action_calls WHERE call=? AND input=? AND result=?', (key, encode([tool, arguments]), encode(result))).fetchone() for key in keys):
            raise APIError(403, '设备结果不属于当前工具调用')
        request = result.get('request', {})
        if request.get('action', {}).get('operation') in READ_OPERATIONS:
            runtime.store._require_data_access()
            if result.get('readAccessVersion') != encode(runtime.store.data_access()):
                raise APIError(403, '持续读取授权已变更；旧结果不可交付')
        yield
        if tool == 'cove_read_device_action':
            runtime.store.mark_device_action_delivered(conversation, arguments['requestID'], active['message'])
