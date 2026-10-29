"""Synthetic Apple schema, ephemeral test keys only; no weather API requests."""
import base64
import copy
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.parse import parse_qs, urlsplit

import weatherkit as w

try:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec, utils
    CRYPTO = True
except ImportError:
    CRYPTO = False

ENV = dict(zip(w.ENV_NAMES, ('ABCDEFGHIJ', '1234567890', 'uk.example.cove.weather', '/explicit/test-key.p8')))
MARKS = {'serviceName': 'Apple Weather', 'logoLight@2x': '/assets/light.png', 'logoDark@2x': '/assets/dark.png'}


def fixture(now):
    metadata = {'readTime': w.iso(now - timedelta(minutes=2)), 'expireTime': w.iso(now + timedelta(minutes=30)),
                'latitude': 39.9042, 'longitude': 116.4074, 'units': 'm', 'version': 1,
                'attributionURL': 'https://weatherkit.apple.com/legal-attribution.html'}
    current = dict(metadata=copy.deepcopy(metadata), asOf=w.iso(now), conditionCode='Clear', temperature=18,
                   temperatureApparent=17, humidity=.4, precipitationIntensity=0, windSpeed=8, uvIndex=0)
    start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    days = [dict(forecastStart=w.iso(start + timedelta(days=i)), forecastEnd=w.iso(start + timedelta(days=i + 1)),
                 conditionCode='Clear', temperatureMin=10, temperatureMax=20,
                 precipitationChance=.1, precipitationAmount=0, maxUvIndex=4) for i in range(3)]
    return {'currentWeather': current, 'forecastDaily': {'metadata': metadata, 'days': days}}


class WeatherKitTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 10, 14, 21, 0, tzinfo=w.BEIJING)
        self.tick = 100
        self.calls = []
        self.payload = fixture(self.now)
        self.marks = copy.deepcopy(MARKS)
        def fetch(url, token):
            self.calls.append(url)
            self.assertEqual(token, 'test-only-token')
            return copy.deepcopy(self.marks if url == w.ATTRIBUTION_URL else self.payload)
        self.weather = w.BeijingWeatherKit(fetch, env=ENV.copy(), clock=lambda: self.now,
                                           monotonic=lambda: self.tick, signer=lambda *_: 'test-only-token')

    def test_unconfigured_no_key_read_no_network(self):
        weather = w.BeijingWeatherKit(env={}, fetcher=lambda *_: self.fail('network'), signer=lambda *_: self.fail('key'))
        self.assertEqual(weather.read({})['code'], 'weatherkit_unconfigured')

    def test_partial_or_bad_config_no_network(self):
        for env in ({w.ENV_NAMES[0]: 'ABCDEFGHIJ'}, {**ENV, w.ENV_NAMES[3]: 'relative'}, {**ENV, w.ENV_NAMES[0]: 'abc'}):
            self.weather.env = env
            self.assertEqual(self.weather.read({})['code'], 'weatherkit_configuration_invalid')
        self.assertEqual(self.calls, [])

    def test_fixed_city_endpoint_timezone_dates(self):
        result = self.weather.read({})
        self.assertTrue(result['available'])
        parsed = urlsplit(self.calls[-1]); args = parse_qs(parsed.query)
        self.assertEqual(parsed.hostname, 'weatherkit.apple.com')
        self.assertEqual(parsed.path, '/api/v1/weather/zh-Hans/39.9042/116.4074')
        self.assertEqual(args['timezone'], ['Asia/Shanghai'])
        self.assertEqual(args['dataSets'], ['currentWeather,forecastDaily'])
        self.assertNotIn('dailyStart', args)
        self.assertNotIn('dailyEnd', args)
        with self.assertRaises(ValueError): self.weather.read({'latitude': 2})

    def test_normalized_units_attribution_and_timestamps(self):
        out = self.weather.read({})
        self.assertEqual(out['source']['name'], 'Apple Weather')
        self.assertEqual(out['attribution']['markDarkURL'], w.HOST + '/assets/dark.png')
        self.assertEqual(len(out['attribution']['legalURLs']), 1)
        self.assertTrue(out['attribution']['required'])
        self.assertEqual(out['units']['windSpeed'], 'km/h')
        self.assertEqual(out['units']['humidity'], 'fraction 0..1')
        self.assertEqual(out['ttlSeconds'], 900)
        self.assertEqual(out['sourceValidAt'], w.iso(self.now))
        self.assertIsNone(out['sourceMetadata']['currentWeather']['reportedTime'])
        self.assertIsNone(out['current']['windGust'])

    def test_cache_copy_and_provider_expiry_bound(self):
        self.payload['currentWeather']['metadata']['expireTime'] = w.iso(self.now + timedelta(seconds=120))
        out = self.weather.read({}); out['current']['temperature'] = 999
        self.assertEqual(out['ttlSeconds'], 120)
        self.tick += 119; self.now += timedelta(seconds=119)
        out = self.weather.read({})
        self.assertTrue(out['cached']); self.assertEqual(out['current']['temperature'], 18)
        self.assertEqual(len(self.calls), 2)
        self.tick += 2; self.now += timedelta(seconds=2)
        self.assertFalse(self.weather.read({})['available'])
        self.assertEqual(len(self.calls), 3)  # official marks separately cached

    def test_midnight_never_claims_yesterdays_forecast(self):
        self.now = self.now.replace(hour=23, minute=59); self.payload = fixture(self.now)
        self.weather.read({})
        self.now += timedelta(minutes=2); self.tick += 120
        self.assertFalse(self.weather.read({})['available'])

    def test_no_stale_fallback_or_exception_secret(self):
        self.weather.read({}); self.now += timedelta(minutes=16); self.tick += 960
        def fail(*_): raise OSError('private JWT secret path')
        self.weather.fetcher = fail
        out = self.weather.read({})
        self.assertFalse(out['available']); self.assertIsNone(out['current'])
        self.assertNotIn('secret', json.dumps(out)); self.assertNotIn('Open-Meteo', json.dumps(out))

    def test_failures_cooldown_no_retry_loop(self):
        self.marks = {}
        self.weather.read({}); self.weather.read({})
        self.assertEqual(len(self.calls), 1)
        self.tick += 60; self.weather.read({}); self.assertEqual(len(self.calls), 2)

    def test_wrong_city_units_expired_future_missing_mark_and_legal_fail_closed(self):
        changes = [lambda p: p['currentWeather']['metadata'].update(latitude=40.1),
                   lambda p: p['currentWeather']['metadata'].update(units='fahrenheit'),
                   lambda p: p['forecastDaily']['metadata'].update(expireTime=w.iso(self.now)),
                   lambda p: p['currentWeather']['metadata'].update(temporarilyUnavailable=True),
                   lambda p: p['currentWeather'].update(asOf=w.iso(self.now + timedelta(hours=1))),
                   lambda p: p['currentWeather'].update(temperature=float('nan')),
                   lambda p: p['currentWeather'].update(humidity=40),
                   lambda p: p['currentWeather']['metadata'].pop('attributionURL'),
                   lambda p: p['forecastDaily']['days'][0].update(forecastStart='2026-10-14T00:00:00Z')]
        for change in changes:
            payload = fixture(self.now); change(payload)
            with self.subTest(change=change), self.assertRaises((ValueError, KeyError)):
                w.normalize(payload, w.attribution(MARKS), self.now)
        with self.assertRaises(ValueError): w.attribution({'serviceName': 'Apple Weather'})

    def test_reject_off_origin_logo_and_legal_urls(self):
        for url in ('http://weatherkit.apple.com/a', 'https://evil.invalid/a', '//evil.invalid/x',
                    'https://x@weatherkit.apple.com/a', 'https://weatherkit.apple.com:444/a'):
            with self.subTest(url=url), self.assertRaises(ValueError): w.apple_url(url, relative=True)

    def test_fetch_has_auth_timeout_cap_no_proxy_redirect_or_retry(self):
        class Response:
            status = 200
            def __enter__(self): return self
            def __exit__(self, *_): pass
            def read(self, n): self.n = n; return b'{"ok":true}'
        response = Response()
        with patch.object(w, 'build_opener') as build:
            build.return_value.open.return_value = response
            self.assertEqual(w.fetch_json(w.ATTRIBUTION_URL, 'test-token'), {'ok': True})
            req = build.return_value.open.call_args.args[0]
            self.assertEqual(req.get_header('Authorization'), 'Bearer test-token')
            self.assertEqual(response.n, w.MAX_RESPONSE + 1)
            self.assertEqual(build.return_value.open.call_args.kwargs['timeout'], 12)
            self.assertEqual(build.call_args.args[0].proxies, {})
            self.assertIsInstance(build.call_args.args[1], w.NoRedirect)
        with self.assertRaises(w.WeatherError):
            w.NoRedirect().redirect_request(None, None, 302, None, None, 'https://evil.invalid')

    def test_http_errors_do_not_expose_body_or_auth(self):
        for status, code in [(401, 'authentication_failed'), (403, 'authentication_failed'), (429, 'rate_limited'), (503, 'upstream_unavailable')]:
            with patch.object(w, 'build_opener') as build:
                build.return_value.open.side_effect = HTTPError('x', status, 'private token', {}, io.BytesIO(b'secret'))
                with self.assertRaisesRegex(w.WeatherError, code): w.fetch_json(w.ATTRIBUTION_URL, 'test-token')
                self.assertEqual(build.return_value.open.call_count, 1)



@unittest.skipUnless(CRYPTO, 'cryptography is needed for real ES256 verification')
class SigningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / 'ephemeral-test.p8'
        self.private = ec.generate_private_key(ec.SECP256R1())
        self.path.write_bytes(self.private.private_bytes(serialization.Encoding.PEM,
                              serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        self.path.chmod(0o600)
        self.env = {**ENV, w.ENV_NAMES[3]: str(self.path)}
        self.now = datetime(2026, 10, 14, 21, tzinfo=w.BEIJING)

    def tearDown(self): self.temp.cleanup()

    def test_real_es256_signature_and_exact_apple_claims(self):
        token = w.make_token(w.configuration(self.env), self.now)
        parts = token.split('.')
        decoded = [base64.urlsafe_b64decode(p + '=' * (-len(p) % 4)) for p in parts]
        self.assertEqual(json.loads(decoded[0]), {'alg': 'ES256', 'kid': ENV[w.ENV_NAMES[1]],
                                                 'id': ENV[w.ENV_NAMES[0]] + '.' + ENV[w.ENV_NAMES[2]]})
        claims = json.loads(decoded[1]); self.assertEqual(set(claims), {'iss', 'iat', 'exp', 'sub'})
        self.assertEqual(claims['exp'] - claims['iat'], 300)
        self.assertEqual(len(decoded[2]), 64)
        r, s = int.from_bytes(decoded[2][:32], 'big'), int.from_bytes(decoded[2][32:], 'big')
        self.private.public_key().verify(utils.encode_dss_signature(r, s), '.'.join(parts[:2]).encode(), ec.ECDSA(hashes.SHA256()))

    def test_bad_permissions_symlink_hardlink_key_type_missing_refused(self):
        self.path.chmod(0o644)
        with self.assertRaises(w.WeatherError): w.make_token(w.configuration(self.env), self.now)
        self.path.chmod(0o600)
        link = self.path.with_name('linked.p8'); link.symlink_to(self.path)
        for path in (link, self.path.with_name('missing.p8')):
            with self.assertRaises(w.WeatherError): w.make_token(w.configuration({**self.env, w.ENV_NAMES[3]: str(path)}), self.now)
        hard = self.path.with_name('hard.p8'); os.link(self.path, hard)
        with self.assertRaises(w.WeatherError): w.make_token(w.configuration(self.env), self.now)
        hard.unlink()
        self.path.write_bytes(ec.generate_private_key(ec.SECP384R1()).private_bytes(serialization.Encoding.PEM,
                             serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        with self.assertRaises(w.WeatherError): w.make_token(w.configuration(self.env), self.now)


if __name__ == '__main__': unittest.main()
