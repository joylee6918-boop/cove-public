"""Isolated fake network/process tests. No real key, weather request, or chat write."""
import ast
import base64
import copy
import io
import json
import os
from pathlib import Path
import shlex
import sys
import tempfile
import threading
import unittest
from datetime import datetime, timedelta
from types import SimpleNamespace
from unittest.mock import patch

from runtime import CodexRuntime
from storage import Store, APIError
import weather_tools as wt
import weatherkit as wk
from test_weatherkit import fixture, MARKS

PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=')


class FixtureProvider:
    def __init__(self):
        self.now = datetime(2026, 10, 14, 21, tzinfo=wk.BEIJING)
        self.calls = 0
        self.result = wk.normalize(fixture(self.now), wk.attribution(MARKS), self.now)
    def clock(self): return self.now
    def read(self, arguments):
        assert arguments == {}
        self.calls += 1
        return copy.deepcopy(self.result)


class MarkTests(unittest.TestCase):
    def test_marks_are_ordinary_no_auth_no_proxy_no_redirect_bounded_requests(self):
        class Response:
            status = 200
            headers = SimpleNamespace(get_content_type=lambda: 'image/png')
            def __enter__(self): return self
            def __exit__(self, *_): pass
            def read(self, size): self.size = size; return PNG
        response = Response()
        with patch.object(wt, 'build_opener') as build:
            build.return_value.open.return_value = response
            self.assertEqual(wt.fetch_mark('https://weatherkit.apple.com/assets/branding/mark.png'), PNG)
            request = build.return_value.open.call_args.args[0]
            self.assertIsNone(request.get_header('Authorization'))
            self.assertEqual(response.size, wt.MAX_MARK + 1)
            self.assertEqual(build.call_args.args[0].proxies, {})
            self.assertIsInstance(build.call_args.args[1], wk.NoRedirect)

    def test_exact_png_bytes_persisted_and_reused_without_model_payload(self):
        calls = []; provider = FixtureProvider()
        client = wt.CoveWeatherClient(provider, lambda url: (calls.append(url) or PNG))
        result, brand = client.read(); client.read()
        self.assertEqual(len(calls), 2)
        self.assertEqual(base64.b64decode(brand['markLightData']), PNG)
        self.assertNotIn('markLightData', json.dumps(result))
        self.assertEqual(brand['legalURLs'], [wk.HOST + '/legal-attribution.html'])

    def test_missing_malformed_oversize_off_origin_marks_fail_closed(self):
        for data in (b'not an image', PNG * 5000, PNG[:-4], PNG + b'extra',
                     b'\x89PNG\r\n\x1a\n' + b'x' * 100):
            with self.subTest(data=len(data)):
                result, brand = wt.CoveWeatherClient(FixtureProvider(), lambda _: data).read()
                self.assertFalse(result['available']); self.assertIsNone(brand)
                self.assertIsNone(result['current'])
        with self.assertRaises(ValueError): wt.fetch_mark('https://evil.invalid/logo.png')

    def test_real_legal_url_allowed_but_not_arbitrary_developer_pages(self):
        legal = 'https://developer.apple.com/weatherkit/data-source-attribution/'
        self.assertEqual(wk.legal_url(legal), legal)
        for url in ('https://developer.apple.com/login', legal + '?next=evil', legal.replace('https:', 'http:'),
                    'https://weatherkit.apple.com/api/v1/weather'):
            with self.assertRaises(ValueError): wk.legal_url(url)
        with self.assertRaises(ValueError): wk.apple_url(legal)


class WeatherPreviewTests(unittest.TestCase):
    def message(self):
        _, brand = wt.CoveWeatherClient(FixtureProvider(), lambda _: PNG).read()
        return dict(id='weather', conversationID='a', role='assistant',
                    text='北京气温 23°C，降水概率 37%。', createdAt='2026-10-14T12:35:00Z',
                    status='complete', weatherAttribution=brand)

    def test_only_valid_assistant_metadata_selects_compact_preview_including_history(self):
        message = self.message()
        # An old snapshot still requires attribution when displayed as history.
        message['weatherAttribution']['expiresAt'] = '2020-01-01T00:00:00Z'
        self.assertEqual(wt.weather_preview(message), wt.WEATHER_PREVIEW)
        for field, invalid in [('required', False), ('timezone', 'UTC'), ('serviceName', ''),
                               ('legalURLs', ['https://evil.invalid/']), ('sourceValidAt', 'bad'),
                               ('markLightURL', 'https://evil.invalid/a.png'),
                               ('markLightData', 'bad base64'), ('markDarkData', base64.b64encode(PNG[:-4]).decode())]:
            broken = copy.deepcopy(message); broken['weatherAttribution'][field] = invalid
            with self.subTest(field=field): self.assertIsNone(wt.weather_preview(broken))
        for ordinary in (None, {}, dict(message, role='user'), dict(message, weatherAttribution=None),
                         {'role': 'assistant', 'text': 'Apple Weather 北京天气 23°C'}):
            self.assertIsNone(wt.weather_preview(ordinary))

    def test_content_push_redacts_weather_without_changing_privacy_modes_or_ordinary_text(self):
        from notifications import GENERIC_BODY, notification_payload
        message = self.message(); original = copy.deepcopy(message)
        payload = notification_payload('a', message, 'content')
        self.assertEqual(payload['aps']['alert']['body'], wt.WEATHER_PREVIEW)
        self.assertEqual((payload['conversationID'], payload['messageID']), ('a', 'weather'))
        self.assertNotIn('23', json.dumps(payload)); self.assertNotIn('markLightData', json.dumps(payload))
        for mode in ('generic', 'unknown', None):
            self.assertEqual(notification_payload('a', message, mode)['aps']['alert']['body'], GENERIC_BODY)
        ordinary = dict(message, weatherAttribution=None)
        self.assertEqual(notification_payload('a', ordinary, 'content')['aps']['alert']['body'], ordinary['text'])
        self.assertEqual(message, original)

    def test_search_keeps_literal_match_ids_paging_and_body_but_not_unbranded_weather_snippets(self):
        with tempfile.TemporaryDirectory() as temp:
            store = Store(temp); store.create_conversation('a')
            try:
                message = self.message()
                ordinary = dict(message, id='ordinary', weatherAttribution=None)
                with store.lock, store.db:
                    store._put(message); store._put(ordinary)
                before = store.db.total_changes
                page = store.search_messages('23°C', limit=1)
                self.assertEqual(page['results'][0]['messageID'], 'ordinary')
                self.assertEqual(page['results'][0]['snippet'], ordinary['text'])
                second = store.search_messages('23°C', before=page['nextCursor'], limit=1)
                self.assertEqual(second['results'][0]['messageID'], 'weather')
                self.assertEqual(second['results'][0]['snippet'], wt.WEATHER_PREVIEW)
                self.assertIsNone(second['nextCursor'])
                self.assertEqual(store.db.total_changes, before)
                self.assertEqual(store._message('weather')['text'], message['text'])
                self.assertNotIn('weatherAttribution', second['results'][0])
            finally: store.close()

    def test_native_compact_surfaces_use_helper_without_replacing_full_body(self):
        source = (Path(__file__).parents[1] / 'ios/Cove/Views.swift').read_text()
        self.assertIn('last.previewText(emptyFallback: "一个附件")', source)
        self.assertIn('message.previewText()', source)
        self.assertIn('quote.previewText()', source)
        self.assertIn('CoveWeatherAttributionView(', source)
        self.assertTrue('MarkdownMessageView(text: message.text,' in source)


class WeatherRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.store = Store(self.temp.name)
        self.store.create_conversation('a'); self.store.create_conversation('b')
        self.store.accept({'id': 'weather-user', 'conversationID': 'a', 'text': '北京天气'})
        self.job = self.store.claim(); self.store.bind_turn('weather-user', 'turn')
        self.runtime = CodexRuntime(self.store, self.temp.name)
        self.runtime.active = {'conversation': 'a', 'thread': 'thread', 'turn': 'turn', 'message': 'weather-user', 'cancel': threading.Event()}
        self.provider = FixtureProvider()
        self.runtime.weather_client = wt.CoveWeatherClient(self.provider, lambda _: PNG)

    def tearDown(self):
        self.runtime.close(); self.store.close(); self.temp.cleanup()

    def permit(self, call='weather-call', args=None, turn='turn'):
        self.runtime.file_permits.append({'conversation': 'a', 'turn': turn, 'call': call, 'tool': 'cove_read_weather', 'arguments': args or {}, 'used': False})

    def read(self): return self.runtime.mcp_file_call('a', 'cove_read_weather', {})

    def test_exact_turn_snapshot_attribution_and_different_call_ids_no_respend(self):
        self.permit(); result = self.read(); self.assertTrue(result['available'])
        self.permit('another-id'); self.assertEqual(self.read(), result)
        self.assertEqual(self.provider.calls, 1)
        reply = self.store._message(self.job['assistant'])
        self.assertEqual(reply['weatherAttribution']['markLightData'], base64.b64encode(PNG).decode())
        self.store.stream('weather-user', '今天北京的天气。'); self.store.finish('weather-user', 'complete')
        self.assertEqual(self.store._message(self.job['assistant'])['weatherAttribution'], reply['weatherAttribution'])
        self.assertNotIn('weatherAttribution', self.store._message('weather-user'))

    def test_unconfigured_no_attribution_no_invented_current(self):
        self.runtime.weather_client = wt.CoveWeatherClient(wk.BeijingWeatherKit(env={}), lambda _: self.fail('network'))
        self.permit(); result = self.read()
        self.assertFalse(result['available']); self.assertEqual(result['code'], 'weatherkit_unconfigured')
        self.assertNotIn('weatherAttribution', self.store._message(self.job['assistant']))

    def test_no_permit_stale_or_wrong_conversation_no_requests(self):
        self.permit(turn='old')
        with patch('runtime.MCP_EVENT_WAIT', .001):
            with self.assertRaises(APIError): self.read()
        with self.assertRaises(APIError): self.runtime.mcp_file_call('b', 'cove_read_weather', {})
        self.assertEqual(self.provider.calls, 0)

    def test_bad_arguments_and_internal_turns_rejected_before_network(self):
        self.permit(args={'city': 'Shanghai'})
        with self.assertRaises(APIError): self.runtime.mcp_file_call('a', 'cove_read_weather', {'city': 'Shanghai'})
        self.permit()
        for key in ('handoffID', 'healthRequestID', 'deviceActionID'):
            with self.store.lock, self.store.db:
                message = self.store._message('weather-user'); message[key] = 'internal'; self.store._put(message)
            with self.assertRaises(APIError): self.read()
            with self.store.lock, self.store.db:
                message.pop(key); self.store._put(message)
        self.assertEqual(self.provider.calls, 0)

    def test_cancel_during_network_no_runtime_lock_no_cross_turn_attachment(self):
        self.permit(); started = threading.Event(); release = threading.Event(); errors = []
        original = self.provider.read
        def slow(arguments): started.set(); release.wait(3); return original(arguments)
        self.provider.read = slow
        def invoke():
            try: self.read()
            except Exception as error: errors.append(error)
        thread = threading.Thread(target=invoke); thread.start(); self.assertTrue(started.wait(1))
        self.assertTrue(self.runtime.state_lock.acquire(timeout=1))
        self.runtime.active['cancel'].set(); self.runtime.state_lock.release()
        release.set(); thread.join(3)
        self.assertEqual(len(errors), 1); self.assertIsInstance(errors[0], APIError)
        self.assertNotIn('weatherAttribution', self.store._message(self.job['assistant']))
        self.assertEqual(self.store.db.execute('SELECT state FROM weather_tool_results').fetchone()[0], 'orphaned')

    def test_unknown_and_reserved_calls_do_not_replay(self):
        self.permit()
        def fail(): raise OSError('sensitive path or token')
        self.runtime.weather_client.read = fail
        with self.assertRaises(APIError) as error: self.read()
        self.assertNotIn('sensitive', str(error.exception))
        with self.assertRaises(APIError): self.read()
        self.assertEqual(self.store.db.execute('SELECT state FROM weather_tool_results').fetchone()[0], 'unknown')

    def test_expired_durable_snapshot_is_not_current_and_not_requeried(self):
        self.permit(); self.read(); self.provider.now += timedelta(minutes=16)
        result = self.read()
        self.assertFalse(result['available']); self.assertEqual(result['code'], 'weather_snapshot_expired')
        self.assertEqual(self.provider.calls, 1)

    def test_attribution_survives_store_restart_no_chat_replay(self):
        self.permit(); self.read(); expected = self.store._message(self.job['assistant'])['weatherAttribution']
        self.runtime.close(); self.store.close(); self.store = Store(self.temp.name)
        self.assertEqual(self.store._message(self.job['assistant'])['weatherAttribution'], expected)
        self.assertIsNone(self.store.claim())


class WeatherGuideAndMCPTests(unittest.TestCase):
    def test_real_stdio_from_new_and_original_resumed_threads_strips_credentials(self):
        command = shlex.quote(sys.executable) + ' ' + shlex.quote(str(Path(__file__).with_name('fake_app_server.py')))
        with tempfile.TemporaryDirectory() as temp:
            store = Store(temp); store.create_conversation('new'); store.create_conversation('old')
            store.bind_thread('old', 'same-original-thread')
            test_env = {name: 'synthetic-not-for-child' for name in wk.ENV_NAMES}
            test_env.update(NO_PROXY='127.0.0.1,localhost', no_proxy='127.0.0.1,localhost')
            with patch.dict(os.environ, test_env):
                runtime = CodexRuntime(store, temp, command, timeout=8)
                runtime.weather_client = wt.CoveWeatherClient(FixtureProvider(), lambda _: PNG)
                try:
                    for conversation in ('new', 'old'):
                        store.accept({'id': 'weather-'+conversation, 'conversationID': conversation, 'text': 'COVE_TEST_WEATHER'})
                        job = store.claim(); status, error = runtime.run(job, threading.Event())
                        store.finish(job['message'], status, error)
                        self.assertEqual(status, 'complete', error)
                        reply = store._message(job['assistant'])
                        self.assertIn('synthetic weather', reply['text'])
                        self.assertEqual(reply['weatherAttribution']['markLightData'], base64.b64encode(PNG).decode())
                    self.assertEqual(store.conversation('old')['thread'], 'same-original-thread')
                finally:
                    runtime.close(); store.close()

    def test_weather_contract_is_routed_only_by_relevant_turn_text(self):
        from runtime import guidance_topics
        self.assertTrue(guidance_topics('北京今天会下雨吗')['weather'])
        self.assertTrue(guidance_topics('weather forecast please')['weather'])
        self.assertFalse(guidance_topics('今天想抱着你')['weather'])
        self.assertIn('cove_read_weather({})', wt.WEATHER_GUIDANCE)

    def test_real_stdio_listing_and_error_semantics(self):
        import files_mcp
        commands = [{'id': 1, 'method': 'tools/list'}, {'id': 2, 'method': 'tools/call', 'params': {'name': 'cove_read_weather', 'arguments': {}}}]
        class Response:
            def __enter__(self): return self
            def __exit__(self, *_): pass
            def read(self): return b'{"available":false,"code":"weatherkit_unconfigured"}'
        output = io.StringIO()
        with patch.object(files_mcp, 'callback_credentials', return_value=('http://127.0.0.1:1/call', 'synthetic')), \
             patch.object(files_mcp.sys, 'stdin', io.StringIO(''.join(json.dumps(x)+'\n' for x in commands))), \
             patch.object(files_mcp.sys, 'stdout', output), patch.object(files_mcp, 'urlopen', return_value=Response()):
            files_mcp.main()
        rows = [json.loads(x) for x in output.getvalue().splitlines()]
        tool = next(t for t in rows[0]['result']['tools'] if t['name'] == 'cove_read_weather')
        self.assertTrue(tool['annotations']['readOnlyHint']); self.assertTrue(tool['annotations']['openWorldHint'])
        self.assertTrue(rows[1]['result']['isError'])


if __name__ == '__main__': unittest.main()
