"""Cove WeatherKit: existing exact-turn MCP permission + durable attribution.

No owner-token shortcut, phone location, autonomous polling, or fallback provider.
One immutable snapshot per message/turn. Uncertain outcomes never auto-replay.
"""
import base64
import json
import struct
import threading
import zlib
from urllib.request import Request, build_opener, ProxyHandler

from weatherkit import BeijingWeatherKit, NoRedirect, apple_url, legal_url, short_text, timestamp

WEATHER_TOOL = {
    'name': 'cove_read_weather',
    'description': '读取 Apple WeatherKit 的北京城市代表点当前天气与今天起 3 天预报。不是手机位置或现场实测。仅当前普通聊天回合，空参数；一次回合一个快照，失败不循环重试。先看 available/sourceValidAt/fetchedAt/expiresAt/sourceMetadata；缺值不是零。成功后系统自动将官方 Apple Weather 标记及法律来源链接保存到当前回复。',
    'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': False},
}

# Included verbatim in the deployed new/resumed/realtime developer instructions.
WEATHER_GUIDANCE = '''
[Cove Apple WeatherKit]
Use cove_read_weather({}) for relevant Beijing weather in an ordinary current chat
turn; never invent a result or read the iPhone Weather app. Fixed coordinates
39.9042,116.4074 and Asia/Shanghai are a city representative point, not phone GPS.
Check available first, then sourceValidAt, fetchedAt, expiresAt and sourceMetadata.
Current conditions are not phone measurements; forecasts may change and missing
values are not zero. Temperature is Celsius, wind km/h, precipitation mm, humidity
and precipitationChance fractions 0..1 (multiply by 100 for percent). No arbitrary
location, hourly data, alerts, AQI or severe-weather inference is supplied here.
Only one immutable weather snapshot is allowed per turn; do not loop, retry an
unknown call, or claim stale/expired data are current. Unconfigured or unavailable
means Apple WeatherKit did not return usable data; do not silently use other
providers. The application, not your prose, attaches the official Apple Weather
mark and legal links to this reply. Never fabricate that metadata or credentials.
Full operation and deployment guide: docs/DEVELOPER_FEATURES.md.
'''

MAX_MARK = 256 * 1024
WEATHER_PREVIEW = '北京天气消息，打开查看'


def png_mark(data):
    """Bound a genuine PNG container before any native image decoder sees it."""
    if not isinstance(data, bytes) or not 33 <= len(data) <= MAX_MARK:
        raise ValueError('invalid mark bytes')
    if data[:8] != b'\x89PNG\r\n\x1a\n' or data[8:16] != b'\0\0\0\rIHDR':
        raise ValueError('invalid PNG mark')
    width, height = struct.unpack('>II', data[16:24])
    if not 1 <= width <= 2048 or not 1 <= height <= 1024:
        raise ValueError('oversize mark')
    offset, has_pixels = 8, False
    while offset + 12 <= len(data):
        length = struct.unpack('>I', data[offset:offset + 4])[0]
        end = offset + 12 + length
        if end > len(data):
            raise ValueError('truncated PNG mark')
        kind = data[offset + 4:offset + 8]
        crc = struct.unpack('>I', data[end - 4:end])[0]
        if zlib.crc32(data[offset + 4:end - 4]) & 0xffffffff != crc:
            raise ValueError('corrupt PNG mark')
        has_pixels |= kind == b'IDAT' and length > 0
        if kind == b'IEND':
            if length != 0 or end != len(data) or not has_pixels:
                raise ValueError('invalid PNG end')
            return base64.b64encode(data).decode('ascii')
        offset = end
    raise ValueError('incomplete PNG mark')


def fetch_mark(url):
    # Static official artwork needs no JWT or user authentication. Refuse redirects
    # and ambient proxy credentials, and never borrow Cove's owner-token session.
    request = Request(apple_url(url), headers={'Accept': 'image/png'})
    opener = build_opener(ProxyHandler({}), NoRedirect())
    with opener.open(request, timeout=8) as response:
        if response.status != 200 or response.headers.get_content_type() != 'image/png':
            raise ValueError('invalid mark response')
        return response.read(MAX_MARK + 1)


class CoveWeatherClient:
    def __init__(self, provider=None, mark_fetcher=fetch_mark):
        self.provider = provider or BeijingWeatherKit()
        self.mark_fetcher = mark_fetcher
        self.lock = threading.Lock()
        self.marks = {}

    def read(self):
        with self.lock:
            result = self.provider.read({})
            if result.get('available') is not True:
                return result, None
            brand = reply_attribution(result)
            try:
                urls = [brand['markLightURL'], brand['markDarkURL']]
                marks = {url: self.marks.get(url) or png_mark(self.mark_fetcher(url)) for url in urls}
                self.marks = marks  # At most the current official pair, not an unbounded URL cache.
                brand['markLightData'] = marks[urls[0]]
                brand['markDarkData'] = marks[urls[1]]
            except Exception:
                return {'available': False, 'code': 'weatherkit_attribution_unavailable',
                        'source': {'name': 'Apple Weather', 'service': 'WeatherKit REST'},
                        'current': None, 'forecast': [],
                        'note': '未完整取得官方 Apple Weather 标记，未交付天气数据；不自动重试或换源。'}, None
            # Raw mark bytes go only to application metadata, never model context.
            return result, brand


def reply_attribution(result):
    if result.get('source', {}).get('name') != 'Apple Weather' or result.get('timezone') != 'Asia/Shanghai':
        raise ValueError('unexpected weather source')
    raw = result['attribution']
    if raw.get('required') is not True or not isinstance(raw.get('legalURLs'), list) or not 1 <= len(raw['legalURLs']) <= 4:
        raise ValueError('missing attribution')
    output = {'required': True, 'serviceName': short_text(raw['serviceName']),
              'markLightURL': apple_url(raw['markLightURL']), 'markDarkURL': apple_url(raw['markDarkURL']),
              'legalURLs': list(dict.fromkeys(legal_url(url) for url in raw['legalURLs'])), 'timezone': 'Asia/Shanghai'}
    for key in ('sourceValidAt', 'fetchedAt', 'expiresAt'):
        timestamp(result[key])
        output[key] = result[key]
    return output


def weather_preview(message):
    """No raw weather in compact surfaces that cannot show the Apple mark.

    Only verified-shaped assistant metadata qualifies. Never guess from prose,
    and do not require a historical snapshot to still be current.
    """
    if not isinstance(message, dict) or message.get('role') != 'assistant':
        return None
    raw = message.get('weatherAttribution')
    if not isinstance(raw, dict):
        return None
    try:
        reply_attribution({'source': {'name': 'Apple Weather'}, 'timezone': raw.get('timezone'),
                           'attribution': raw, **{key: raw.get(key) for key in ('sourceValidAt', 'fetchedAt', 'expiresAt')}})
        for key in ('markLightData', 'markDarkData'):
            value = raw.get(key)
            if not isinstance(value, str) or len(value) > 350000:
                return None
            png_mark(base64.b64decode(value, validate=True))
    except (ValueError, TypeError, KeyError):
        return None
    return WEATHER_PREVIEW


def _scope(runtime, conversation, message, turn):
    from storage import APIError
    active, store = runtime.active, runtime.store
    if (not active or active['conversation'] != conversation or active['message'] != message
            or active['turn'] != turn or active['cancel'].is_set()):
        raise APIError(409, '天气读取不属于当前 Cove 回合')
    origin = store._message(message)
    if (not origin or origin.get('role') != 'user' or origin.get('handoffID')
            or origin.get('healthRequestID') or origin.get('deviceActionID')):
        raise APIError(403, '天气工具仅限当前普通聊天，不在内部换窗或回执续答中额外调用')
    job = store.db.execute("SELECT assistant FROM jobs WHERE message=? AND turn=? AND state='running'", (message, turn)).fetchone()
    if not job or origin.get('conversationID') != conversation:
        raise APIError(409, '天气读取的聊天回合已结束')
    return job['assistant']


def execute_weather(runtime, conversation, message, turn, call, arguments):
    """Caller already authenticated a real tool event; never call from an HTTP shortcut."""
    from storage import APIError, encode
    if not isinstance(arguments, dict) or arguments:
        raise APIError(400, 'cove_read_weather 只接受空参数 {}')
    store = runtime.store
    key = encode([message, turn])
    with runtime.state_lock, store.lock, store.db:
        assistant = _scope(runtime, conversation, message, turn)
        store.db.execute('''CREATE TABLE IF NOT EXISTS weather_tool_results(
          scope TEXT PRIMARY KEY, conversation TEXT NOT NULL, assistant TEXT NOT NULL,
          first_call TEXT NOT NULL, state TEXT NOT NULL, result TEXT)''')
        row = store.db.execute('SELECT * FROM weather_tool_results WHERE scope=?', (key,)).fetchone()
        if row:
            if row['conversation'] != conversation or row['assistant'] != assistant or row['state'] != 'done':
                raise APIError(409, '这次天气读取正在进行或结果不确定，不自动重试')
            result = json.loads(row['result'])
            if result.get('available') and runtime.weather_client.provider.clock() >= timestamp(result['expiresAt']):
                return {'available': False, 'code': 'weather_snapshot_expired', 'stale': True,
                        'sourceValidAt': result['sourceValidAt'], 'expiresAt': result['expiresAt'],
                        'current': None, 'forecast': [], 'note': '本轮天气快照已过期，不能当作当前天气；不在同一回合重复调用。'}
            return result
        store.db.execute('INSERT INTO weather_tool_results VALUES(?,?,?,?,?,NULL)',
                         (key, conversation, assistant, call, 'running'))
    # Quota-bearing network and key access are outside both application locks.
    try:
        result, attribution = runtime.weather_client.read()
        serialized = encode(result)
    except Exception:
        with store.lock, store.db:
            store.db.execute("UPDATE weather_tool_results SET state='unknown' WHERE scope=?", (key,))
        raise APIError(503, '天气读取结果不确定，未自动重试') from None
    with runtime.state_lock, store.lock, store.db:
        try:
            if _scope(runtime, conversation, message, turn) != assistant:
                raise APIError(409, '天气回合已改变')
        except APIError:
            store.db.execute("UPDATE weather_tool_results SET state='orphaned' WHERE scope=?", (key,))
            # Commit the terminal receipt even though delivery is rejected.
            store.db.commit()
            raise APIError(409, '天气已取回但原回合已结束，未转交到其他消息') from None
        if attribution:
            reply = store._message(assistant)
            reply['weatherAttribution'] = attribution
            store._put(reply)
        store.db.execute("UPDATE weather_tool_results SET state='done',result=? WHERE scope=?", (serialized, key))
    return result
