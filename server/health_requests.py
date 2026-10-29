"""Per-request consent. Never reads legacy global health uploads."""
import json
import math
import uuid
from datetime import datetime, timezone, timedelta

METRICS = {
    'sleep': ('睡眠', '小时'), 'sleepAwake': ('清醒', '小时'),
    'sleepCore': ('核心睡眠', '小时'), 'sleepDeep': ('深度睡眠', '小时'),
    'sleepREM': ('快速眼动睡眠', '小时'), 'sleepUnspecified': ('未分类睡眠', '小时'),
    'restingHeartRate': ('静息心率', '次/分'), 'heartRate': ('最近一次心率', '次/分'),
    'walkingHeartRate': ('步行平均心率', '次/分'), 'heartRateRecovery': ('心率恢复', '次/分'),
    'hrv': ('HRV', '毫秒'), 'oxygenSaturation': ('血氧饱和度', '%'),
    'respiratoryRate': ('呼吸频率', '次/分'), 'vo2Max': ('最大摄氧量', '毫升/千克/分钟'),
    'bodyMass': ('体重', '千克'), 'height': ('身高', '厘米'), 'bodyMassIndex': ('BMI', ''),
    'bodyFatPercentage': ('体脂率', '%'), 'bloodPressureSystolic': ('收缩压', '毫米汞柱'),
    'bloodPressureDiastolic': ('舒张压', '毫米汞柱'), 'bloodGlucose': ('血糖', '毫摩尔/升'),
    'bodyTemperature': ('体温', '摄氏度'), 'sleepingWristTemperature': ('睡眠腕温', '摄氏度'),
    'dietaryWater': ('饮水量', '升'), 'steps': ('步数', '步'),
    'activeEnergy': ('活动能量', '千卡'), 'basalEnergy': ('静息能量', '千卡'),
    'exerciseTime': ('锻炼时间', '分钟'), 'standTime': ('站立时间', '分钟'),
    'walkingRunningDistance': ('步行与跑步距离', '公里'), 'cyclingDistance': ('骑行距离', '公里'),
    'flightsClimbed': ('已爬楼层', '层'), 'workoutCount': ('健身次数', '次'),
    'workoutDuration': ('健身时长', '分钟')
}
HEALTH_TOOLS = [
    {'name': 'cove_request_health', 'description': 'Request a bounded phone health refresh in this conversation. With standing access enabled, first use cove_read_health; if relevant metrics are missing, incomplete or too old for the current question, proactively request only those needed metrics and their relevant time range. The connected Cove app may fulfill it automatically under the owner’s persistent grant, so do not ask her to re-authorize each conversation. If standing access is off, this remains an explicit one-time sharing card. If existing records suffice, do not request again. Use only relevant metrics and a past range <=7 days; request expires after 10 minutes. Returns pending request, not data or a live measurement. Finish this reply; a successful phone response queues one automatic continuation in this same conversation. Never poll in a loop, duplicate a pending request, or repeatedly ask after denial/expiry. Respect an explicit pause or refusal.',
     'inputSchema': {'type': 'object', 'properties': {'metrics': {'type': 'array', 'items': {'type': 'string', 'enum': list(METRICS)}, 'minItems': 1, 'maxItems': len(METRICS)}, 'startAt': {'type': 'string'}, 'endAt': {'type': 'string'}, 'reason': {'type': 'string'}}, 'required': ['metrics', 'startAt', 'endAt', 'reason'], 'additionalProperties': False}},
    {'name': 'cove_read_health_request', 'description': 'Read the outcome of one health request in this conversation. Only a user-allowed request returns its minimal summary; missing metrics mean unavailable, not a diagnosis or a known permission decision. Heart rate is the latest existing sample, never live measurement. No automatic memory writes.',
     'inputSchema': {'type': 'object', 'properties': {'requestID': {'type': 'string'}}, 'required': ['requestID'], 'additionalProperties': False}}
]


def timestamp(value):
    from storage import APIError
    try:
        if not isinstance(value, str) or len(value) > 64:
            raise ValueError()
        parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
        if parsed.tzinfo is None:
            raise ValueError()
        return parsed.astimezone(timezone.utc)
    except (ValueError, OverflowError):
        raise APIError(400, '健康日期必须为带时区 ISO8601')


def summary(snapshot, request, allow_detail=False):
    from storage import APIError
    if not isinstance(snapshot, dict) or set(snapshot)-{'capturedAt', 'metrics', 'sleepSegments', 'workouts'} or not {'capturedAt', 'metrics'} <= set(snapshot):
        raise APIError(400, '只接受本次健康摘要')
    captured = timestamp(snapshot['capturedAt'])
    if not timestamp(request['createdAt'])-timedelta(minutes=1) <= captured <= datetime.now(timezone.utc)+timedelta(minutes=1):
        raise APIError(400, '请重新读取本次健康摘要')
    values = snapshot['metrics']
    if not isinstance(values, list) or len(values) > len(request['metrics']):
        raise APIError(400, '健康指标超出请求范围')
    result, seen = [], set()
    start, end = timestamp(request['startAt']), timestamp(request['endAt'])
    for metric in values:
        if not isinstance(metric, dict) or set(metric)-{'id','title','value','unit','sampledAt','detail','source'}:
            raise APIError(400, '健康指标格式无效')
        id = metric.get('id')
        if not isinstance(id, str) or id not in request['metrics'] or id in seen:
            raise APIError(400, '健康指标超出请求范围或重复')
        seen.add(id)
        value = metric.get('value')
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not 0 <= value <= 1e8:
            raise APIError(400, '健康数值无效')
        if not start <= timestamp(metric.get('sampledAt')) <= end:
            raise APIError(400, '健康样本时间超出请求范围')
        # No arbitrary details/history; canonical display metadata, single aggregate per metric.
        detail = metric.get('detail')
        if allow_detail and detail is not None and (not isinstance(detail, str) or len(detail) > 4000):
            raise APIError(400, '健康详情无效')
        if not allow_detail and detail not in (None, ''):
            raise APIError(400, '本次摘要不接受健康明细')
        source = metric.get('source')
        if source is not None and (not isinstance(source, str) or len(source) > 120 or any(ord(c)<32 for c in source)):
            raise APIError(400, '健康来源无效')
        title, unit = METRICS[id]
        if metric.get('unit') != unit:
            raise APIError(400, '健康单位无效')
        result.append({'id': id, 'title': title, 'unit': unit, 'value': value, 'sampledAt': metric['sampledAt'], 'detail': detail if allow_detail else None, 'source': source})
    result.sort(key=lambda m: m['id'])
    normalized = {'capturedAt': snapshot['capturedAt'], 'metrics': result}
    sleep_ids = {'sleepAwake', 'sleepCore', 'sleepDeep', 'sleepREM', 'sleepUnspecified'}
    segments = snapshot.get('sleepSegments')
    if segments is not None:
        if not isinstance(segments, list) or len(segments) > 5000:
            raise APIError(400, '睡眠阶段记录过多或格式无效')
        clean, seen_segments = [], set()
        for segment in segments:
            if not isinstance(segment, dict) or set(segment)-{'stageID','startAt','endAt','source'} or not {'stageID','startAt','endAt'} <= set(segment):
                raise APIError(400, '睡眠阶段格式无效')
            stage = segment['stageID']
            if not isinstance(stage, str) or stage not in sleep_ids or ('sleep' not in request['metrics'] and stage not in request['metrics']):
                raise APIError(400, '睡眠阶段超出请求范围')
            segment_start, segment_end = timestamp(segment['startAt']), timestamp(segment['endAt'])
            if not start <= segment_start < segment_end <= end:
                raise APIError(400, '睡眠阶段时间超出请求范围')
            source = bounded_source(segment.get('source'))
            key = (stage, segment['startAt'], segment['endAt'], source)
            if key in seen_segments:
                continue
            seen_segments.add(key)
            clean.append({'stageID': stage, 'startAt': segment['startAt'], 'endAt': segment['endAt'], 'source': source})
        normalized['sleepSegments'] = clean
    workouts = snapshot.get('workouts')
    if workouts is not None:
        if not ({'workoutCount', 'workoutDuration'} & set(request['metrics'])):
            raise APIError(400, '健身记录超出请求范围')
        if not isinstance(workouts, list) or len(workouts) > 200:
            raise APIError(400, '健身记录过多或格式无效')
        clean, seen_workouts = [], set()
        for workout in workouts:
            required = {'id','type','startAt','endAt','durationSeconds'}
            if not isinstance(workout, dict) or set(workout)-required-{'energyKcal','distanceMeters','source'} or not required <= set(workout):
                raise APIError(400, '健身记录格式无效')
            identifier, kind = workout['id'], workout['type']
            if not isinstance(identifier, str) or not 1 <= len(identifier) <= 128 or identifier in seen_workouts:
                raise APIError(400, '健身记录 ID 无效或重复')
            if not isinstance(kind, str) or not 1 <= len(kind) <= 80 or any(ord(c)<32 for c in kind):
                raise APIError(400, '健身类型无效')
            workout_start, workout_end = timestamp(workout['startAt']), timestamp(workout['endAt'])
            if not start <= workout_start < workout_end <= end:
                raise APIError(400, '健身记录时间超出请求范围')
            duration = finite_nonnegative(workout['durationSeconds'], 7*86400, '健身时长无效')
            if duration > (workout_end-workout_start).total_seconds()+1:
                raise APIError(400, '健身时长超过起止时间范围')
            clean_workout = {'id': identifier, 'type': kind, 'startAt': workout['startAt'], 'endAt': workout['endAt'],
                             'durationSeconds': duration, 'source': bounded_source(workout.get('source'))}
            for key, maximum in (('energyKcal', 1e6), ('distanceMeters', 1e8)):
                if key in workout and workout[key] is not None:
                    clean_workout[key] = finite_nonnegative(workout[key], maximum, '健身数值无效')
            seen_workouts.add(identifier); clean.append(clean_workout)
        normalized['workouts'] = clean
    return normalized


def bounded_source(source):
    from storage import APIError
    if source is not None and (not isinstance(source, str) or len(source) > 120 or any(ord(c)<32 for c in source)):
        raise APIError(400, '健康来源无效')
    return source


def finite_nonnegative(value, maximum, message):
    from storage import APIError
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not 0 <= value <= maximum:
        raise APIError(400, message)
    return value


class HealthRequestStore:
    def _health_request(self, conversation, id):
        from storage import APIError, encode, now
        row = self.db.execute('SELECT body FROM health_requests WHERE id=? AND conversation=?', (id, conversation)).fetchone()
        if not row:
            raise APIError(404, '找不到本会话的健康请求')
        request = json.loads(row[0])
        if request['status'] == 'pending' and timestamp(request['expiresAt']) <= datetime.now(timezone.utc):
            request['status'] = 'expired'
            self.db.execute('UPDATE health_requests SET body=? WHERE id=?', (encode(request), id))
        if request.get('continuationMessageID'):
            job = self.db.execute('SELECT state FROM jobs WHERE message=?', (request['continuationMessageID'],)).fetchone()
            request['continuationStatus'] = job[0] if job else 'failed'
        return request

    def health_requests(self, conversation):
        with self.lock, self.db:
            self.conversation(conversation)
            ids = self.db.execute('SELECT id FROM health_requests WHERE conversation=? ORDER BY rowid DESC LIMIT 100', (conversation,)).fetchall()
            return {'requests': [self._health_request(conversation, row[0]) for row in ids]}

    def respond_health_request(self, conversation, id, body):
        from storage import APIError, encode, now
        if not isinstance(body, dict) or body.get('decision') not in ('allow', 'deny') or set(body)-{'decision','snapshot'}:
            raise APIError(400, '健康请求需明确允许或拒绝')
        with self.lock, self.db:
            request = self._health_request(conversation, id)
            if body['decision'] == 'deny':
                if 'snapshot' in body:
                    raise APIError(400, '拒绝时不得上传健康数据')
                normalized = {'decision': 'deny'}
            else:
                normalized = {'decision': 'allow', 'snapshot': summary(body.get('snapshot'), request)}
            previous = self.db.execute('SELECT response FROM health_requests WHERE id=?', (id,)).fetchone()[0]
            if previous is not None:
                if json.loads(previous) != normalized:
                    raise APIError(409, '健康请求已处理，不能改变结果')
                return {'ok': True, 'request': request}
            if request['status'] != 'pending':
                raise APIError(409, '健康请求已过期')
            request.update(status='allowed' if body['decision'] == 'allow' else 'denied', respondedAt=now())
            if body['decision'] == 'allow':
                # Consent + durable dispatch intent are committed together. No
                # user-visible message or raw health values are synthesized.
                message_id = 'health-consent-' + id
                request['continuationMessageID'] = message_id
                request['continuationStatus'] = 'queued'
                event = {'id': message_id, 'conversationID': conversation, 'role': 'system',
                         'text': '', 'createdAt': now(), 'status': 'sent',
                         'healthRequestID': id, 'attachments': [], 'replyTo': None}
                self._put(event)
                self.db.execute('INSERT INTO jobs VALUES(?,?,NULL,?)',
                                (message_id, 'queued', 'assistant-health-' + id))
            self.db.execute('UPDATE health_requests SET body=?,response=? WHERE id=?', (encode(request), encode(normalized), id))
            return {'ok': True, 'request': request}

    def assistant_health_tool(self, message, turn, call, tool, arguments, expected_conversation):
        from storage import APIError, encode, now
        with self.lock, self.db:
            if not self.db.execute("SELECT 1 FROM jobs WHERE message=? AND turn=? AND state='running'", (message, turn)).fetchone():
                raise APIError(409, '健康工具不属于活跃回合')
            event = self._message(message)
            conversation = event['conversationID']
            if event.get('healthRequestID') and (tool != 'cove_read_health_request' or arguments != {'requestID': event['healthRequestID']}):
                raise APIError(403, '本次授权续答只能读取指定健康请求')
            if conversation != expected_conversation:
                raise APIError(409, '健康请求不属于当前会话')
            key = encode([message, turn, call])
            old = self.db.execute('SELECT result FROM health_tool_results WHERE call=?', (key,)).fetchone()
            if old:
                return json.loads(old[0])
            if tool == 'cove_request_health':
                # A standing grant permits stored reads, but does not imply the
                # phone has uploaded every needed metric. Supplemental cards
                # still require an explicit device response before any new read.
                if set(arguments) != {'metrics','startAt','endAt','reason'}:
                    raise APIError(400, '健康请求参数无效')
                metrics = arguments['metrics']
                if not isinstance(metrics, list) or not 1 <= len(metrics) <= len(METRICS) or any(not isinstance(m,str) or m not in METRICS for m in metrics) or len(set(metrics)) != len(metrics):
                    raise APIError(400, '健康指标必须来自允许范围且不重复')
                start, end = timestamp(arguments['startAt']), timestamp(arguments['endAt'])
                clock = datetime.now(timezone.utc)
                if not timedelta(0) < end-start <= timedelta(days=7) or end > clock+timedelta(minutes=1):
                    raise APIError(400, '健康时间范围必须为过去最多七天')
                reason = arguments['reason']
                if not isinstance(reason, str) or not reason.strip() or len(reason) > 240 or any(ord(c)<32 for c in reason):
                    raise APIError(400, '健康请求原因无效')
                if sum(r['status']=='pending' for r in self.health_requests(conversation)['requests']) >= 3:
                    raise APIError(409, '请先等待已有健康请求处理')
                request = dict(id=str(uuid.uuid4()), conversationID=conversation, metrics=metrics, startAt=arguments['startAt'], endAt=arguments['endAt'], reason=reason.strip(), createdAt=now(), expiresAt=(clock+timedelta(minutes=10)).isoformat(), status='pending', respondedAt=None, readAt=None, originMessageID=message)
                self.db.execute('INSERT INTO health_requests VALUES(?,?,?,NULL)', (request['id'], conversation, encode(request)))
                result = {'request': request}
            elif tool == 'cove_read_health_request':
                if set(arguments) != {'requestID'} or not isinstance(arguments['requestID'], str):
                    raise APIError(400, '需提供健康请求 ID')
                request = self._health_request(conversation, arguments['requestID'])
                result = {'request': request, 'snapshot': None}
                if request['status'] == 'allowed':
                    request['readByMessageID'] = message
                    self.db.execute('UPDATE health_requests SET body=? WHERE id=?', (encode(request), request['id']))
                    response = json.loads(self.db.execute('SELECT response FROM health_requests WHERE id=?', (request['id'],)).fetchone()[0])
                    result['snapshot'] = response['snapshot']
                    result['missingMetricIDs'] = [m for m in request['metrics'] if m not in {v['id'] for v in result['snapshot']['metrics']}]
            else:
                raise APIError(400, '未知健康工具')
            self.db.execute('INSERT INTO health_tool_results VALUES(?,?)', (key, encode(result)))
            return result

    def mark_health_request_delivered(self, conversation, id):
        from storage import encode, now
        with self.lock, self.db:
            request = self._health_request(conversation, id)
            if request['status'] in ('allowed', 'denied', 'expired') and not request['readAt']:
                request['readAt'] = now()
                self.db.execute('UPDATE health_requests SET body=? WHERE id=?', (encode(request), id))
