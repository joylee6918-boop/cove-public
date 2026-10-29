"""Owner-controlled standing read access, independent of conversation lifetime."""
import json
from contextlib import contextmanager
from datetime import datetime, timezone, timedelta

from health_requests import METRICS, summary, timestamp

DATA_TOOLS = [
    {'name': 'cove_read_health',
     'description': 'Directly read available Cove health snapshots under 用户’s standing permission, including synced phone archives and previously allowed request summaries across conversations. No new consent card. Dates and source remain attached; missing data is unknown, not zero or live measurement. Paginate with nextOffset to inspect older available records; no time horizon restriction. Read naturally when useful, including an already-authorized Pulse wake; do not turn every reply into a report.',
     'inputSchema': {'type': 'object', 'properties': {'limit': {'type': 'integer', 'minimum': 1, 'maximum': 100}, 'offset': {'type': 'integer', 'minimum': 0}}, 'additionalProperties': False}},
    {'name': 'cove_read_app_activity',
     'description': 'Read Cove’s own App open/close activity for a local day under 用户’s standing permission, without asking again. Not another assistant/Seen records. Missing/incomplete events do not mean she did not use her phone.',
     'inputSchema': {'type': 'object', 'properties': {'day': {'type': 'string'}, 'timeZone': {'type': 'string'}}, 'required': ['day', 'timeZone'], 'additionalProperties': False}}
]


def upload_snapshot(snapshot):
    """Canonical bounded HealthKit payload; historical archives are welcome."""
    from storage import APIError
    if not isinstance(snapshot, dict):
        raise APIError(400, '健康快照无效')
    captured = timestamp(snapshot.get('capturedAt'))
    beginning = datetime(1900, 1, 1, tzinfo=timezone.utc)
    if not beginning <= captured <= datetime.now(timezone.utc)+timedelta(minutes=1):
        raise APIError(400, '健康快照时间无效')
    request = {'createdAt': captured.isoformat(), 'startAt': beginning.isoformat(),
               'endAt': (captured+timedelta(minutes=1)).isoformat(), 'metrics': list(METRICS)}
    result = summary(snapshot, request, allow_detail=True)
    result['capturedAt'] = captured.isoformat(timespec='milliseconds').replace('+00:00', 'Z')
    return result


class DataAccessStore:
    def init_data_access(self):
        self.db.executescript('''
        CREATE TABLE IF NOT EXISTS health_uploads(captured TEXT PRIMARY KEY, snapshot TEXT NOT NULL, synced TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS data_tool_results(call TEXT PRIMARY KEY, result TEXT NOT NULL);
        ''')

    def data_access(self):
        with self.lock:
            row = self.db.execute("SELECT value FROM state WHERE key='dataAccess'").fetchone()
            return json.loads(row[0]) if row else {'enabled': False, 'grantedAt': None, 'updatedAt': None, 'revokedAt': None}

    def set_data_access(self, body):
        from storage import APIError, encode, now
        if not isinstance(body, dict) or set(body) != {'enabled'} or type(body['enabled']) is not bool:
            raise APIError(400, '请提供 enabled 布尔值')
        with self.lock, self.db:
            state = self.data_access()
            if state['enabled'] == body['enabled'] and state['updatedAt']:
                return state
            clock = now()
            state.update(enabled=body['enabled'], updatedAt=clock)
            state['grantedAt' if body['enabled'] else 'revokedAt'] = clock
            self.db.execute("INSERT INTO state VALUES('dataAccess',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (encode(state),))
            # Prevent an in-flight result from surviving revoke/regrant.
            self.db.execute('DELETE FROM data_tool_results')
            self.db.execute('DELETE FROM personal_ledger_results')
            import uuid
            self.db.execute("INSERT INTO state VALUES('personalLedgerAccessVersion',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (str(uuid.uuid4()),))
            self.db.execute("UPDATE collar_calls SET result=NULL WHERE action='read_summary'")
            return state

    def _require_data_access(self):
        from storage import APIError
        if not self.data_access()['enabled']:
            raise APIError(403, '持续读取已关闭；未读取数据')

    def standing_health(self, arguments):
        from storage import APIError, encode
        if set(arguments)-{'limit', 'offset'}:
            raise APIError(400, '健康读取参数无效')
        limit, offset = arguments.get('limit', 20), arguments.get('offset', 0)
        if type(limit) is not int or not 1 <= limit <= 100 or type(offset) is not int or not 0 <= offset <= 2**31-1:
            raise APIError(400, '健康分页参数无效')
        # SQL pagination includes every retained source, not just today or this thread.
        # Identical snapshots from daily history/upload/current state deduplicate.
        rows = self.db.execute('''
            SELECT snapshot, MAX(synced) AS synced, source, request FROM (
              SELECT snapshot,synced,'phone-sync' AS source,NULL AS request FROM health_uploads
              UNION ALL SELECT snapshot,synced,'phone-sync',NULL FROM health_history
              UNION ALL SELECT json_extract(value,'$.snapshot'),json_extract(value,'$.syncedAt'),'phone-sync',NULL FROM state
                WHERE key='health' AND json_type(value,'$.snapshot')='object'
              UNION ALL SELECT json_extract(response,'$.snapshot'),json_extract(body,'$.respondedAt'),'allowed-request',
                json_object('id',id,'startAt',json_extract(body,'$.startAt'),'endAt',json_extract(body,'$.endAt'),
                            'metrics',json_extract(body,'$.metrics')) FROM health_requests
                WHERE json_extract(body,'$.status')='allowed' AND json_extract(response,'$.decision')='allow'
            ) GROUP BY snapshot,source,request
            ORDER BY julianday(json_extract(snapshot,'$.capturedAt')) DESC,snapshot,source,request
            LIMIT ? OFFSET ?''', (limit+1, offset)).fetchall()
        entries, size = [], 0
        for row in rows[:limit]:
            snapshot = json.loads(row['snapshot'])
            request = json.loads(row['request']) if row['request'] else None
            entry = {'snapshot': snapshot, 'syncedAt': row['synced'], 'source': row['source'], 'request': request,
                     'aggregationRange': {'startAt': request['startAt'], 'endAt': request['endAt']} if request else None,
                     'missingMetricIDs': [key for key in (request['metrics'] if request else METRICS) if key not in {m['id'] for m in snapshot['metrics']}]}
            length = len(encode(entry).encode())
            if entries and size+length > 2*1024*1024:
                break
            entries.append(entry); size += length
        return {'source': 'cove-health', 'entries': entries,
                'nextOffset': offset+len(entries) if len(rows)>len(entries) else None,
                'available': bool(entries), 'liveMeasurement': False,
                'timeContext': 'capturedAt is collection time, not an aggregation range. For allowed-request totals use aggregationRange; phone-sync intervals are in each metric detail. Missing range is unknown, never assume today.'}

    def assistant_data_tool(self, message, turn, call, tool, arguments, conversation, app_events=None):
        from storage import APIError, encode
        with self.lock, self.db:
            self._require_data_access()
            event = self._message(message)
            if not event or event['conversationID'] != conversation or event.get('handoffID') or not self.db.execute(
                    "SELECT 1 FROM jobs WHERE message=? AND turn=? AND state='running'", (message, turn)).fetchone():
                raise APIError(409, '数据读取不属于当前活跃回合')
            key = encode([message, turn, call])
            old = self.db.execute('SELECT result FROM data_tool_results WHERE call=?', (key,)).fetchone()
            if old:
                return json.loads(old[0])
            if tool == 'cove_read_health':
                result = self.standing_health(arguments)
            elif tool == 'cove_read_app_activity':
                if set(arguments) != {'day', 'timeZone'}:
                    raise APIError(400, 'App 读取需要 day 和 timeZone')
                if app_events is None:
                    raise APIError(503, 'Cove App 记录连接尚不可用')
                result = app_events.summary(arguments['day'], arguments['timeZone'])
            else:
                raise APIError(400, '未知数据读取工具')
            self.db.execute('INSERT INTO data_tool_results VALUES(?,?)', (key, encode(result)))
            return result


@contextmanager
def delivery_guard(runtime, conversation, tool, arguments, result):
    """Serialize revoke ACK after an already-started result flush; no stale-turn leaks."""
    from storage import APIError, encode
    with runtime.state_lock, runtime.store.lock:
        runtime.store._require_data_access()
        active = runtime.active
        if not active or active['conversation'] != conversation or active['cancel'].is_set():
            raise APIError(409, '数据读取回合已结束')
        if not runtime.store.db.execute("SELECT 1 FROM jobs WHERE message=? AND turn=? AND state='running'", (active['message'], active['turn'])).fetchone():
            raise APIError(409, '数据读取回合已结束')
        keys = [encode([active['message'], active['turn'], p['call']]) for p in runtime.file_permits
                if p['conversation'] == conversation and p['turn'] == active['turn'] and p['tool'] == tool and p['arguments'] == arguments and p['used']]
        if not any(runtime.store.db.execute('SELECT 1 FROM data_tool_results WHERE call=? AND result=?', (key, encode(result))).fetchone() for key in keys):
            raise APIError(403, '数据结果已撤销或不属于当前回合')
        yield
        if tool == 'cove_read_health':
            current, version = runtime.store.health_for_tool()
            if current['snapshot'] is not None and any(entry['snapshot'] == current['snapshot'] for entry in result['entries']):
                runtime.store.mark_health_read(current, version)
