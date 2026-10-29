"""Apple WeatherKit REST, fixed Beijing; no geolocation, fallback or auto retry.

Local candidate: credentials/account setup and iOS attribution are release gates.
See docs/WEATHERKIT.md. Never log credentials, JWTs or upstream error bodies.
"""
import base64
import copy
import json
import math
import os
import re
import stat
import threading
import time
from datetime import datetime, timedelta, timezone
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler, ProxyHandler

BEIJING = timezone(timedelta(hours=8))
HOST = 'https://weatherkit.apple.com'
LANGUAGE = 'zh-Hans'
ATTRIBUTION_URL = HOST + '/attribution/' + LANGUAGE
TOKEN_SECONDS = 300
TTL_SECONDS = 900
ERROR_COOLDOWN = 60
MAX_RESPONSE = 262144
ENV_NAMES = ('COVE_WEATHERKIT_TEAM_ID', 'COVE_WEATHERKIT_KEY_ID',
             'COVE_WEATHERKIT_SERVICE_ID', 'COVE_WEATHERKIT_PRIVATE_KEY_PATH')



class WeatherError(Exception):
    """Only fixed safe codes cross the MCP boundary."""


def iso(value):
    return value.astimezone(BEIJING).isoformat(timespec='seconds')


def timestamp(value):
    if not isinstance(value, str) or len(value) > 64:
        raise ValueError('invalid timestamp')
    result = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if result.tzinfo is None:
        raise ValueError('timezone missing')
    return result.astimezone(BEIJING)


def number(value, low=None, high=None):
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError('invalid number')
    if low is not None and value < low or high is not None and value > high:
        raise ValueError('number out of range')
    return value


def short_text(value):
    if not isinstance(value, str) or not value.strip() or len(value) > 150 or any(ord(c) < 32 for c in value):
        raise ValueError('invalid text')
    return value


def apple_url(value, relative=False):
    if not isinstance(value, str) or len(value) > 2048 or any(c.isspace() for c in value):
        raise ValueError('invalid attribution URL')
    if relative and value.startswith('/') and not value.startswith('//'):
        value = HOST + value
    parsed = urlsplit(value)
    if (parsed.scheme != 'https' or parsed.hostname != 'weatherkit.apple.com'
            or parsed.username or parsed.password or parsed.port not in (None, 443)
            or not parsed.path or '\\' in value):
        raise ValueError('unexpected attribution URL')
    return value


def legal_url(value):
    # The real Apple response uses this developer.apple.com page. Artwork and
    # legal URLs are different allowlists; no arbitrary Apple-host navigation.
    if value in ('https://developer.apple.com/weatherkit/data-source-attribution/',
                 'https://weatherkit.apple.com/legal-attribution.html'):
        return value
    raise ValueError('unexpected legal attribution URL')


def attribution(payload):
    # No substitute Apple logo, text-only brand imitation, or invented legal URL.
    def mark(kind):
        for scale in (2, 3, 1):
            value = payload.get('logo' + kind + '@' + str(scale) + 'x')
            if value:
                return apple_url(value, relative=True)
        raise ValueError('missing official mark')
    return {'required': True, 'serviceName': short_text(payload['serviceName']),
            'markLightURL': mark('Light'), 'markDarkURL': mark('Dark'),
            'legalURLs': []}


def configuration(env):
    values = tuple(env.get(name, '').strip() for name in ENV_NAMES)
    if not any(values):
        raise WeatherError('weatherkit_unconfigured')
    team, key, service, path = values
    if (not all(values) or not re.fullmatch(r'[A-Z0-9]{10}', team)
            or not re.fullmatch(r'[A-Z0-9]{10}', key)
            or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]{1,253}', service)
            or not os.path.isabs(path)):
        raise WeatherError('weatherkit_configuration_invalid')
    return team, key, service, path


def make_token(config, now):
    """Read exactly the explicit key, safely; private key is never returned."""
    team, key_id, service, path = config
    try:
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import ec, utils
        # O_NOFOLLOW rejects a symlink leaf; fstat validates the opened inode.
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(stream.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600
                    or info.st_uid != os.geteuid() or info.st_size > 16384):
                raise ValueError('unsafe key')
            pem = stream.read(16385)
        private = serialization.load_pem_private_key(pem, password=None)
        if not isinstance(private, ec.EllipticCurvePrivateKey) or not isinstance(private.curve, ec.SECP256R1):
            raise ValueError('wrong key type')
        def b64(value):
            return base64.urlsafe_b64encode(value).rstrip(b'=').decode('ascii')
        def encoded(value):
            return b64(json.dumps(value, separators=(',', ':'), sort_keys=True).encode())
        issued = int(now.timestamp())
        # Exact Apple header/claims, no extra audience/typ/jti claim.
        unsigned = encoded({'alg': 'ES256', 'kid': key_id, 'id': team + '.' + service}) + '.' + encoded({
            'iss': team, 'iat': issued, 'exp': issued + TOKEN_SECONDS, 'sub': service})
        r, s = utils.decode_dss_signature(private.sign(unsigned.encode(), ec.ECDSA(hashes.SHA256())))
        return unsigned + '.' + b64(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))
    except Exception:
        raise WeatherError('weatherkit_key_unavailable') from None


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise WeatherError('weatherkit_redirect_refused')


def weather_url(now):
    # Default Apple daily horizon avoids interpreting dailyEnd boundary semantics.
    # normalize selects exactly local today + the next two days from that horizon.
    return HOST + '/api/v1/weather/' + LANGUAGE + '/39.9042/116.4074?' + urlencode({
        'dataSets': 'currentWeather,forecastDaily', 'timezone': 'Asia/Shanghai'})


def fetch_json(url, token):
    # All callers use compile-time Apple URLs. Never forward the bearer token.
    if url != ATTRIBUTION_URL and not url.startswith(HOST + '/api/v1/weather/' + LANGUAGE + '/39.9042/116.4074?'):
        raise WeatherError('weatherkit_url_refused')
    request = Request(url, headers={'Accept': 'application/json',
        'Authorization': 'Bearer ' + token, 'User-Agent': 'Cove-WeatherKit/1.0'})
    try:
        with build_opener(ProxyHandler({}), NoRedirect()).open(request, timeout=12) as response:
            if response.status != 200:
                raise WeatherError('weatherkit_upstream_unavailable')
            raw = response.read(MAX_RESPONSE + 1)
            if len(raw) > MAX_RESPONSE:
                raise WeatherError('weatherkit_invalid_response')
            return json.loads(raw)
    except HTTPError as exc:
        code = ('weatherkit_authentication_failed' if exc.code in (401, 403) else
                'weatherkit_rate_limited' if exc.code == 429 else 'weatherkit_upstream_unavailable')
        raise WeatherError(code) from None


def metadata(value, now):
    lat, lon = number(value['latitude']), number(value['longitude'])
    if lat is None or lon is None or abs(lat - 39.9042) > 0.1 or abs(lon - 116.4074) > 0.1:
        raise ValueError('wrong location')
    if value.get('units', 'm') != 'm' or value.get('temporarilyUnavailable', False) is not False:
        raise ValueError('data unavailable or units wrong')
    read, expiry = timestamp(value['readTime']), timestamp(value['expireTime'])
    if not read <= now + timedelta(minutes=5) or not now < expiry or read >= expiry:
        raise ValueError('expired or invalid source time')
    result = {'readTime': iso(read), 'expireTime': iso(expiry),
              'reportedTime': iso(timestamp(value['reportedTime'])) if value.get('reportedTime') else None,
              'attributionURL': legal_url(value['attributionURL']),
              'providerName': short_text(value['providerName']) if value.get('providerName') else None,
              'sourceType': short_text(value['sourceType']) if value.get('sourceType') else None}
    # Data provider logos are not substituted for the required Apple Weather mark.
    return result, expiry


def normalize(payload, marks, now):
    current, daily = payload['currentWeather'], payload['forecastDaily']
    current_meta, expiry_current = metadata(current['metadata'], now)
    daily_meta, expiry_daily = metadata(daily['metadata'], now)
    source_time = timestamp(current['asOf'])
    if not now - timedelta(hours=2) <= source_time <= now + timedelta(minutes=20):
        raise ValueError('current time stale or future')
    values = {'conditionCode': short_text(current['conditionCode'])}
    bounds = {'temperature': (-100, 70), 'temperatureApparent': (-120, 100),
              'humidity': (0, 1), 'precipitationIntensity': (0, None),
              'windSpeed': (0, None), 'windGust': (0, None), 'windDirection': (0, 360), 'uvIndex': (0, None)}
    for key, (low, high) in bounds.items():
        values[key] = number(current.get(key), low, high)
    if values['temperature'] is None:
        raise ValueError('current temperature missing')
    days = daily['days']
    if not isinstance(days, list) or not 3 <= len(days) <= 11:
        raise ValueError('forecast shape')
    forecast = []
    for index, day in enumerate(days[:3]):
        start, end = timestamp(day['forecastStart']), timestamp(day['forecastEnd'])
        if (start.date() != now.astimezone(BEIJING).date() + timedelta(days=index)
                or start.hour != 0 or start.minute != 0 or start.second != 0
                or not timedelta(hours=23) <= end - start <= timedelta(hours=25)):
            raise ValueError('forecast date or timezone mismatch')
        row = {'date': start.date().isoformat(), 'forecastStart': iso(start), 'forecastEnd': iso(end),
               'conditionCode': short_text(day['conditionCode'])}
        for key, low, high in [('temperatureMin', -100, 70), ('temperatureMax', -100, 70),
                               ('precipitationChance', 0, 1), ('precipitationAmount', 0, None),
                               ('maxUvIndex', 0, None)]:
            row[key] = number(day.get(key), low, high)
        if (row['temperatureMin'] is not None and row['temperatureMax'] is not None
                and row['temperatureMin'] > row['temperatureMax']):
            raise ValueError('forecast range')
        forecast.append(row)
    expiry = min(now + timedelta(seconds=TTL_SECONDS), expiry_current, expiry_daily)
    brand = copy.deepcopy(marks)
    brand['legalURLs'] = list(dict.fromkeys((current_meta['attributionURL'], daily_meta['attributionURL'])))
    return {'available': True, 'configured': True, 'location': {'name': '北京', 'latitude': 39.9042,
            'longitude': 116.4074, 'scope': '城市代表点，不是手机当前位置'}, 'timezone': 'Asia/Shanghai',
            'source': {'name': 'Apple Weather', 'service': 'WeatherKit REST', 'kind': 'current-conditions-and-forecast',
                       'url': 'https://weatherkit.apple.com/'},
            'sourceValidAt': iso(source_time), 'sourceMetadata': {'currentWeather': current_meta, 'forecastDaily': daily_meta},
            'fetchedAt': iso(now), 'expiresAt': iso(expiry), 'ttlSeconds': int((expiry - now).total_seconds()),
            'cached': False, 'stale': False, 'current': values, 'forecast': forecast, 'attribution': brand,
            'units': {'temperature': '°C', 'temperatureApparent': '°C', 'temperatureMin': '°C', 'temperatureMax': '°C',
                      'humidity': 'fraction 0..1', 'precipitationChance': 'fraction 0..1', 'precipitationIntensity': 'mm/h',
                      'precipitationAmount': 'mm', 'windSpeed': 'km/h', 'windGust': 'km/h', 'windDirection': 'degrees'},
            'note': 'sourceValidAt 是当前天气有效时间，readTime 是上游读取时间，reportedTime 未提供时保持空值；不是手机现场实时测量。预报会变，缺项不补零。展示须同时保留官方 Apple Weather 标记与法律归属链接。'}


class BeijingWeatherKit:
    def __init__(self, fetcher=fetch_json, env=None, clock=None, monotonic=time.monotonic, signer=make_token):
        self.fetcher, self.env, self.signer = fetcher, os.environ if env is None else env, signer
        self.clock = clock or (lambda: datetime.now(BEIJING))
        self.monotonic = monotonic
        self.lock = threading.Lock()
        self.cache = self.marks = None
        self.cache_until = self.marks_until = self.failure_until = 0
        self.last_error = None
        self.config = None

    def unavailable(self, code, now):
        return {'available': False, 'configured': code not in ('weatherkit_unconfigured', 'weatherkit_configuration_invalid', 'weatherkit_key_unavailable'),
                'code': code, 'source': {'name': 'Apple Weather', 'service': 'WeatherKit REST'},
                'timezone': 'Asia/Shanghai', 'checkedAt': iso(now), 'current': None, 'forecast': [],
                'note': 'Apple WeatherKit 当前未取得可用数据；不能声称已查到天气，不回退其他天气源。失败不自动重试。'}

    def read(self, arguments):
        if not isinstance(arguments, dict) or arguments:
            raise ValueError('cove_read_weather accepts no arguments')
        with self.lock:
            now, tick = self.clock().astimezone(BEIJING), self.monotonic()
            try:
                config = configuration(self.env)
            except WeatherError as exc:
                return self.unavailable(str(exc), now)
            if config != self.config:
                self.config = config
                self.cache = self.marks = None
                self.cache_until = self.marks_until = self.failure_until = 0
            if (self.cache and tick < self.cache_until and now < timestamp(self.cache['expiresAt'])
                    and self.cache['forecast'][0]['date'] == now.date().isoformat()):
                result = copy.deepcopy(self.cache)
                result['cached'] = True
                return result
            if tick < self.failure_until:
                return self.unavailable(self.last_error, now)
            try:
                token = self.signer(config, now)
                if self.marks is None or tick >= self.marks_until:
                    self.marks = attribution(self.fetcher(ATTRIBUTION_URL, token))
                    self.marks_until = tick + 86400
                payload = self.fetcher(weather_url(now), token)
                fetched = self.clock().astimezone(BEIJING)
                result = normalize(payload, self.marks, fetched)
                self.cache, self.cache_until = copy.deepcopy(result), self.monotonic() + result['ttlSeconds']
                self.failure_until, self.last_error = 0, None
                return result
            except WeatherError as exc:
                code = str(exc)
            except (ValueError, TypeError, KeyError, IndexError):
                code = 'weatherkit_invalid_response'
            except Exception:
                code = 'weatherkit_upstream_unavailable'
            self.last_error, self.failure_until = code, tick + ERROR_COOLDOWN
            return self.unavailable(code, now)


