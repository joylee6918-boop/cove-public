"""Assistant-only Collar tools. Standing passive reads; separate active measurement grant."""
import hashlib
import json
import math
import os
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone, timedelta
from urllib.parse import urlsplit
from urllib.error import HTTPError
from urllib.request import Request, build_opener, HTTPRedirectHandler, ProxyHandler

METRICS = {'sleep': ('睡眠', '小时'), 'restingHeartRate': ('静息心率', '次/分'),
           'heartRate': ('心率', '次/分'), 'steps': ('步数', '步'), 'hrv': ('HRV', '毫秒')}
COLLAR_TOOLS = [
    {'name': 'cove_collar_summary', 'description': 'Read an existing requested past <=48h Apple Watch summary under 用户’s persistent Collar or standing-data permission without asking again in each conversation. Only standing-data permission extends passive reads to an existing authorized Pulse wake. This does not start a measurement; no polling or diagnoses. Preserve sampling timestamps; heart rate is an existing sample, not live.',
     'inputSchema': {'type': 'object', 'properties': {'metrics': {'type': 'array', 'items': {'type': 'string', 'enum': list(METRICS)}, 'minItems': 1, 'maxItems': 5}, 'startAt': {'type': 'string'}, 'endAt': {'type': 'string'}}, 'required': ['metrics', 'startAt', 'endAt'], 'additionalProperties': False}},
    {'name': 'cove_collar_measure', 'description': 'Request ONE 30-second Collar heart-rate measurement only after the owner’s persistent Assistant measurement permission is enabled. The grant survives conversation changes, but measurements remain ordinary user-turn actions and are never started by Pulse/system wakes. Returns queued/pending, never immediate measurement success. Do not repeat if status unknown or pending; use the returned id to check later.',
     'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': False}},
    {'name': 'cove_collar_measurement', 'description': 'Check only a Collar measurement previously requested in this Cove conversation. Read-only, no new measurement or push. Pending/seen/unknown is not measured; do not poll in a loop.',
     'inputSchema': {'type': 'object', 'properties': {'id': {'type': 'string'}}, 'required': ['id'], 'additionalProperties': False}}
]


def _error(status, text):
    from storage import APIError
    return APIError(status, text)


def _date(value):
    try:
        if not isinstance(value, str) or len(value) > 64:
            raise ValueError()
        result = datetime.fromisoformat(value.replace('Z', '+00:00'))
        if result.tzinfo is None:
            raise ValueError()
        return result.astimezone(timezone.utc)
    except (TypeError, ValueError, OverflowError):
        raise _error(400, 'Collar 日期必须带时区')


def validate_summary_args(args):
    if not isinstance(args, dict) or set(args) != {'metrics', 'startAt', 'endAt'}:
        raise _error(400, 'Collar 摘要参数无效')
    metrics = args['metrics']
    if not isinstance(metrics, list) or not 1 <= len(metrics) <= 5 or any(not isinstance(x, str) or x not in METRICS for x in metrics) or len(set(metrics)) != len(metrics):
        raise _error(400, 'Collar 只接受不重复的五项健康指标')
    start, end = _date(args['startAt']), _date(args['endAt'])
    clock = datetime.now(timezone.utc)
    if not timedelta(0) < end-start <= timedelta(hours=48) or end > clock+timedelta(seconds=60) or start < clock-timedelta(hours=48, seconds=60):
        raise _error(400, 'Collar 摘要范围为过去最多 48 小时')
    return args


def _number(value):
    return isinstance(value, (float, int)) and not isinstance(value, bool) and math.isfinite(value) and 0 <= value <= 1e8


def project_summary(result, args):
    """Do not allow upstream prose, extra metrics or rows into model context."""
    try:
        if result.get('source') != 'collar':
            raise ValueError()
        snapshot = result['snapshot']
        captured = _date(snapshot['capturedAt'])
        if abs((captured-datetime.now(timezone.utc)).total_seconds()) > 300:
            raise ValueError()
        rows = snapshot['metrics']
        if not isinstance(rows, list) or len(rows) > len(args['metrics']):
            raise ValueError()
        metrics, seen = [], set()
        for row in rows:
            id = row['id']
            if id not in args['metrics'] or id in seen or not _number(row['value']):
                raise ValueError()
            title, unit = METRICS[id]
            if row.get('source') != 'Collar · Apple Watch' or row['unit'] != unit or not _date(args['startAt']) <= _date(row['sampledAt']) <= _date(args['endAt']):
                raise ValueError()
            seen.add(id)
            metrics.append({'id': id, 'title': title, 'value': row['value'], 'unit': unit,
                            'sampledAt': row['sampledAt'], 'source': 'Collar · Apple Watch'})
        return {'source': 'collar', 'startAt': args['startAt'], 'endAt': args['endAt'],
                'snapshot': {'capturedAt': snapshot['capturedAt'], 'metrics': metrics},
                'missingMetricIDs': [x for x in args['metrics'] if x not in seen]}
    except Exception:
        raise _error(502, 'Collar 摘要响应无效；未交付数据')


def project_measurement(result, id):
    try:
        value = result['measurement']
        if value['id'] != id or value['status'] not in ('pending', 'seen', 'done', 'expired', 'unknown') or value['durationSeconds'] != 30:
            raise ValueError()
        requested = _date(value['requestedAt'])
        if requested > datetime.now(timezone.utc)+timedelta(seconds=60):
            raise ValueError()
        completed = value.get('completedAt')
        if completed is not None:
            if not requested <= _date(completed) <= datetime.now(timezone.utc)+timedelta(seconds=60):
                raise ValueError()
        if value['status'] == 'done' and completed is None:
            raise ValueError()
        measured = None
        if value['status'] == 'done' and value.get('result') is not None:
            raw = value['result']
            if any(not _number(raw[k]) or raw[k] <= 0 for k in ('average', 'minimum', 'maximum')) or not isinstance(raw['sampleCount'], int) or isinstance(raw['sampleCount'], bool) or raw['sampleCount'] < 1:
                raise ValueError()
            if not raw['minimum'] <= raw['average'] <= raw['maximum'] or completed is None:
                raise ValueError()
            if raw['sampleCount'] > 100000 or not requested <= _date(raw['measuredAt']) <= _date(completed):
                raise ValueError()
            measured = {k: raw[k] for k in ('average', 'minimum', 'maximum', 'sampleCount', 'measuredAt')}
        return {'measurement': {'id': id, 'status': value['status'], 'requestedAt': value['requestedAt'],
                                'completedAt': completed, 'durationSeconds': 30, 'result': measured}}
    except Exception:
        raise _error(502, 'Collar 测量响应无效；不能确认测量成功')


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class CollarClient:
    def __init__(self, url=None, token=None):
        self.url = (os.getenv('COVE_COLLAR_URL', '') if url is None else url).rstrip('/')
        self.token = os.getenv('COVE_COLLAR_TOKEN', '') if token is None else token
        try:
            parsed = urlsplit(self.url)
            parsed.port  # Validate malformed deployment settings without crashing chat.
        except ValueError:
            self.configured = False
            self.opener = build_opener(ProxyHandler({}), NoRedirect())
            return
        local = parsed.scheme == 'http' and parsed.hostname in ('127.0.0.1', '::1', 'localhost')
        self.configured = bool(self.url and len(self.token) >= 32 and (parsed.scheme == 'https' or local)
                               and parsed.hostname and not parsed.username and not parsed.password
                               and not parsed.query and not parsed.fragment
                               and not any(ord(c) < 32 for c in self.token+self.url))
        self.opener = build_opener(ProxyHandler({}), NoRedirect())

    def call(self, path, body=None):
        if not self.configured:
            raise _error(503, 'Assistant 的 Collar 独立连接尚未配置')
        from storage import encode
        request = Request(self.url+path, data=None if body is None else encode(body).encode(),
                          headers={'Authorization': 'Bearer '+self.token, 'Content-Type': 'application/json'})
        try:
            with self.opener.open(request, timeout=8) as response:
                data = response.read(65537)
                if len(data) > 65536:
                    raise ValueError()
                result = json.loads(data)
                if not isinstance(result, dict):
                    raise ValueError()
                return result
        except HTTPError as error:
            error.close()
            messages = {400: 'Collar 拒绝了无效请求', 401: 'Collar 独立凭证不匹配',
                        403: 'Collar 接口未授权', 409: '已有测量待处理，未创建新测量',
                        429: '测量请求过于频繁，未创建新测量'}
            if error.code in messages:
                raise _error(error.code, messages[error.code])
            raise _error(502, 'Collar 连接失败；动作状态可能未知，请勿重复发起测量')
        except Exception:
            # Never propagate private URLs, credentials, response bodies or health data.
            raise _error(502, 'Collar 连接失败；动作状态可能未知，请勿重复发起测量')


class CollarStore:
    def init_collar(self):
        self.db.executescript('''
        CREATE TABLE IF NOT EXISTS collar_grants(conversation TEXT PRIMARY KEY REFERENCES conversations(id), body TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS collar_calls(id TEXT PRIMARY KEY, conversation TEXT NOT NULL REFERENCES conversations(id), action TEXT NOT NULL, status TEXT NOT NULL, created TEXT NOT NULL, fingerprint TEXT NOT NULL, result TEXT, measurement TEXT);
        ''')
        self.db.commit()

    def _global_collar_permissions(self):
        """Owner-controlled Collar grant that survives conversation changes."""
        row = self.db.execute("SELECT value FROM state WHERE key='collarAccess'").fetchone()
        value = json.loads(row[0]) if row else {}
        return {
            'readSummary': value.get('readSummary') is True,
            'requestMeasurement': value.get('requestMeasurement') is True,
            'updatedAt': value.get('updatedAt'),
        }

    def collar_permissions(self, conversation, configured=False):
        with self.lock:
            self.conversation(conversation)
            value = dict(self._global_collar_permissions(), conversationID=conversation)
            recent = self.db.execute('SELECT id,action,status,created FROM collar_calls WHERE conversation=? ORDER BY rowid DESC LIMIT 20', (conversation,)).fetchall()
            return dict(value, configured=bool(configured), recentActions=[{'id': r[0], 'action': r[1], 'status': r[2], 'createdAt': r[3]} for r in recent])

    def set_collar_permissions(self, conversation, body, configured=False):
        from storage import encode, now
        if not isinstance(body, dict) or set(body) != {'readSummary', 'requestMeasurement'} or any(type(x) is not bool for x in body.values()):
            raise _error(400, '需明确设置两项 Collar 权限')
        with self.lock, self.db:
            old = self.collar_permissions(conversation, configured)
            if not configured and any(body[k] and not old[k] for k in body):
                raise _error(503, 'Collar 连接尚未配置；不能新增授权')
            if all(old[k] == body[k] for k in body):
                return old
            value = dict(body, updatedAt=now())
            self.db.execute("INSERT INTO state VALUES('collarAccess',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (encode(value),))
            if not body['readSummary']:
                self.db.execute("UPDATE collar_calls SET result=NULL WHERE action='read_summary'")
            if not body['requestMeasurement']:
                self.db.execute("UPDATE collar_calls SET result=NULL WHERE action IN ('request_measurement','read_measurement')")
            self.db.execute('INSERT INTO collar_calls VALUES(?,?,?,?,?,?,NULL,NULL)', (str(uuid.uuid4()), conversation, 'permission_update', 'complete', now(), ''))
            return self.collar_permissions(conversation, configured)

    def assistant_collar_tool(self, message, turn, call, tool, arguments, conversation, client):
        from storage import encode, now
        action = {'cove_collar_summary': 'read_summary', 'cove_collar_measure': 'request_measurement', 'cove_collar_measurement': 'read_measurement'}.get(tool)
        if not action:
            raise _error(400, '未知 Collar 工具')
        # Runtime holds the actual current-turn permit; store validates again.
        with self.lock:
            event = self._message(message)
            running = self.db.execute("SELECT 1 FROM jobs WHERE message=? AND turn=? AND state='running'", (message, turn)).fetchone()
            global_permissions = self._global_collar_permissions()
            standing_read = action == 'read_summary' and self.data_access()['enabled']
            if not running or not event or event['conversationID'] != conversation or event.get('handoffID') or (not standing_read and (event.get('role') != 'user' or event.get('hidden'))):
                raise _error(403, 'Collar 只用于当前普通对话，不允许后台或系统唤醒访问')
            permission = 'readSummary' if action == 'read_summary' else 'requestMeasurement'
            if not standing_read and not global_permissions[permission]:
                raise _error(403, '请先在 Cove 健康页给 Assistant 开启跨对话的对应 Collar 权限')
            if not client.configured:
                raise _error(503, 'Assistant 的 Collar 独立连接尚未配置')
            if action == 'read_summary':
                validate_summary_args(arguments)
            elif action == 'request_measurement':
                if arguments != {}:
                    raise _error(400, '测量时长固定 30 秒，无额外参数')
            else:
                if set(arguments) != {'id'} or not isinstance(arguments['id'], str):
                    raise _error(400, '测量 ID 无效')
                try:
                    uuid.UUID(arguments['id'])
                except ValueError:
                    raise _error(400, '测量 ID 无效')
                if not self.db.execute("SELECT 1 FROM collar_calls WHERE conversation=? AND action='request_measurement' AND measurement=?", (conversation, arguments['id'])).fetchone():
                    raise _error(404, '找不到本对话发起的 Collar 测量')
            key = encode([message, turn, call])
            fingerprint = hashlib.sha256(encode([tool, arguments]).encode()).hexdigest()
            old = self.db.execute('SELECT * FROM collar_calls WHERE id=?', (key,)).fetchone()
            if old:
                if old['fingerprint'] != fingerprint:
                    raise _error(409, 'Collar 工具重试参数不一致')
                if old['result']:
                    return json.loads(old['result'])
                raise _error(409, '此动作结果未知或已撤销；不会自动重复执行')
            measurement = str(uuid.uuid4()) if action == 'request_measurement' else arguments.get('id')
            with self.db:
                self.db.execute('INSERT INTO collar_calls VALUES(?,?,?,?,?,?,NULL,?)', (key, conversation, action, 'unknown', now(), fingerprint, measurement))
            try:
                if action == 'read_summary':
                    result = project_summary(client.call('/summary', arguments), arguments)
                    status = 'ready'  # Actual MCP callback flush records delivery below.
                else:
                    raw = client.call('/measurements', {'requestID': measurement}) if action == 'request_measurement' else client.call('/measurements/'+measurement)
                    result = project_measurement(raw, measurement)
                    status = result['measurement']['status']
            except Exception as error:
                from storage import APIError
                if isinstance(error, APIError) and error.status in (400, 401, 403, 409, 429):
                    with self.db:
                        self.db.execute("UPDATE collar_calls SET status='failed' WHERE id=?", (key,))
                    raise
                if action == 'request_measurement':
                    # Intent ID survives a lost ACK; subsequent status checks never reissue.
                    result = {'measurement': {'id': measurement, 'status': 'unknown', 'requestedAt': now(), 'completedAt': None, 'durationSeconds': 30, 'result': None}}
                    status = 'unknown'
                else:
                    with self.db:
                        self.db.execute("UPDATE collar_calls SET status='failed' WHERE id=?", (key,))
                    raise _error(502, 'Collar 查询失败；未确认数据交付')
            with self.db:
                self.db.execute('UPDATE collar_calls SET status=?,result=? WHERE id=?', (status, encode(result), key))
            return result


@contextmanager
def delivery_guard(runtime, conversation, tool, arguments, result):
    """Revoke ACK is ordered after any already-in-flight result flush, never before."""
    from storage import encode
    with runtime.state_lock, runtime.store.lock:
        active = runtime.active
        if not active or active['conversation'] != conversation or active['cancel'].is_set():
            raise _error(409, 'Collar 回合已结束；不再交付数据')
        event = runtime.store._message(active['message'])
        global_permissions = runtime.store._global_collar_permissions()
        standing_read = tool == 'cove_collar_summary' and runtime.store.data_access()['enabled']
        if not event or event.get('handoffID') or (not standing_read and (event.get('role') != 'user' or event.get('hidden'))):
            raise _error(403, 'Collar 不允许系统唤醒访问')
        if not runtime.store.db.execute("SELECT 1 FROM jobs WHERE message=? AND turn=? AND state='running'", (active['message'], active['turn'])).fetchone():
            raise _error(409, 'Collar 回合已结束')
        permission = 'readSummary' if tool == 'cove_collar_summary' else 'requestMeasurement'
        if not standing_read and not global_permissions[permission]:
            raise _error(403, 'Collar 权限已撤销；未交付数据')
        keys = [encode([active['message'], active['turn'], p['call']]) for p in runtime.file_permits
                if p['conversation'] == conversation and p['turn'] == active['turn'] and p['tool'] == tool and p['arguments'] == arguments and p['used']]
        encoded = encode(result)
        matching = [key for key in keys if runtime.store.db.execute('SELECT 1 FROM collar_calls WHERE id=? AND result=?', (key, encoded)).fetchone()]
        if not matching:
            raise _error(403, 'Collar 结果已撤销或不属于当前工具调用')
        yield
        if tool == 'cove_collar_summary':
            with runtime.store.db:
                for key in matching:
                    runtime.store.db.execute("UPDATE collar_calls SET status='complete' WHERE id=?", (key,))
