"""Synthetic isolated receipts and actual route dispatch; no network/model/user data."""
import io
import json
import os
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from unittest.mock import patch
from http.server import ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from app_events import AppEvents, day_bounds, iso
from cove import Application
from runtime import CodexRuntime
from storage import APIError, Store


class AppEventTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.time = datetime(2026, 9, 21, 15, 55, tzinfo=timezone.utc)
        self.events = AppEvents(self.temp.name, True, lambda: self.time)

    def tearDown(self):
        self.events.close()
        self.temp.cleanup()

    def add(self, identifier, minute, action='open', app='示例 App'):
        self.time = datetime(2026, 9, 21, 15, 55, tzinfo=timezone.utc) + timedelta(minutes=minute)
        return self.events.ingest({'id': identifier, 'app': app, 'action': action, 'timestamp': iso(self.time)})

    def summary(self, day='2026-09-21', zone='Asia/Shanghai'):
        return self.events.summary(day, zone)

    def test_independent_empty_summary_not_configured_and_private_file(self):
        self.assertEqual(self.summary()['source'], 'cove-shortcuts')
        self.assertEqual(self.summary()['apps'], [])
        self.assertEqual(self.summary()['totalSeconds'], 0)
        self.assertFalse(self.summary()['incomplete'])
        self.assertEqual((__import__('pathlib').Path(self.temp.name) / 'app-events.sqlite3').stat().st_mode & 0o777, 0o600)
        self.events.close()
        self.events = AppEvents(self.temp.name, False, lambda: self.time)
        self.assertFalse(self.summary()['configured'])
        with self.assertRaises(APIError) as caught: self.add('disabled', 1)
        self.assertEqual(caught.exception.status, 503)

    def test_completed_cross_midnight_pairs_are_clipped(self):
        self.add('open', 0)
        self.add('close', 15, 'close')
        first, second = self.summary(), self.summary('2026-09-22')
        self.assertEqual((first['totalSeconds'], second['totalSeconds']), (300, 600))
        self.assertEqual((first['eventCount'], second['eventCount']), (1, 1))
        self.assertFalse(first['incomplete'])
        self.assertEqual(second['apps'], [{'name': '示例 App', 'seconds': 600}])

    def test_missing_events_never_project_duration_to_now(self):
        self.add('open', 1)
        self.time += timedelta(hours=1)
        result = self.summary()
        self.assertEqual(result['totalSeconds'], 0)
        self.assertTrue(result['incomplete'])
        self.add('orphan-close', 3, 'close', '另一个 App')
        self.assertEqual(self.summary()['totalSeconds'], 0)

    def test_repeated_open_marks_gap_and_pairs_latest_only(self):
        self.add('o1', 0)
        self.add('o2', 2)
        self.add('c', 4, 'close')
        self.assertEqual(self.summary()['totalSeconds'], 120)
        self.assertTrue(self.summary()['incomplete'])

    def test_out_of_order_receipts_reconstruct_by_event_time(self):
        self.add('c', 4, 'close')
        stamp = self.time - timedelta(minutes=3)
        self.events.ingest({'id': 'o', 'app': '示例 App', 'action': 'open', 'timestamp': iso(stamp)})
        self.assertEqual(self.summary()['totalSeconds'], 180)
        self.assertFalse(self.summary()['incomplete'])

    def test_idempotence_conflicts_and_restart(self):
        self.add('o', 1)
        body = {'id': 'o', 'app': '示例 App', 'action': 'open', 'timestamp': iso(self.time)}
        self.time += timedelta(days=1)
        self.assertTrue(self.events.ingest(body)['duplicate'])
        for key, value in (('app', '别的 App'), ('action', 'close'), ('timestamp', iso(self.time))):
            with self.subTest(key=key), self.assertRaises(APIError) as caught:
                self.events.ingest(dict(body, **{key: value}))
            self.assertEqual(caught.exception.status, 409)
        started = self.events.started_at
        self.events.close()
        self.events = AppEvents(self.temp.name, True, lambda: self.time)
        self.assertEqual(self.events.started_at, started)
        self.assertTrue(self.events.ingest(body)['duplicate'])
        self.assertEqual(self.summary()['eventCount'], 1)

    def test_concurrent_retries_have_one_commit(self):
        body = {'id': 'retry', 'app': '示例 App', 'action': 'open', 'timestamp': iso(self.time)}
        with ThreadPoolExecutor(max_workers=8) as executor:
            values = list(executor.map(lambda _: self.events.ingest(body), range(16)))
        self.assertEqual(sum(not value['duplicate'] for value in values), 1)
        self.assertEqual(self.summary()['eventCount'], 1)

    def test_strict_fields_types_and_timestamps(self):
        body = {'id': 'event', 'app': '示例 App', 'action': 'open', 'timestamp': iso(self.time)}
        for key, bad in [('id', ''), ('id', 'x'*129), ('id', '../x'), ('id', True),
                         ('app', ''), ('app', ' x'), ('app', 'x\n'), ('app', 'x\u202e'), ('app', 'x'*81),
                         ('action', 'launch'), ('action', []), ('timestamp', '2026-09-21T15:55:00'),
                         ('timestamp', '2026-09-21'), ('timestamp', '2026-09-21T15:55:00+99:00'),
                         ('timestamp', 123), ('timestamp', '2026-02-30T15:55:00Z')]:
            with self.subTest(key=key, bad=bad), self.assertRaises(APIError) as caught:
                self.events.ingest(dict(body, **{key: bad}))
            self.assertEqual(caught.exception.status, 400)
        for invalid in (dict(body, owner='another assistant'), {k: v for k, v in body.items() if k != 'id'}, []):
            with self.assertRaises(APIError): self.events.ingest(invalid)
        self.assertEqual(self.summary()['eventCount'], 0)

    def test_pre_setup_stale_and_future_events_rejected(self):
        with self.assertRaises(APIError):
            self.events.ingest({'id': 'before-setup', 'app': 'App', 'action': 'open',
                                'timestamp': iso(self.time-timedelta(seconds=1))})
        self.time += timedelta(hours=1)
        for stamp in (self.time-timedelta(hours=2), self.time-timedelta(minutes=11), self.time+timedelta(seconds=61)):
            with self.assertRaises(APIError):
                self.events.ingest({'id': 'bad', 'app': 'App', 'action': 'open', 'timestamp': iso(stamp)})
        self.assertEqual(self.summary()['eventCount'], 0)

    def test_duration_over_24h_rejected_as_incomplete(self):
        self.add('o', 0)
        self.add('c', 24*60+1, 'close')
        self.assertEqual(self.summary()['totalSeconds'], 0)
        self.assertTrue(self.summary()['incomplete'])

    def test_time_zone_validation_dst_and_empty_day(self):
        start, end = day_bounds('2026-03-08', 'America/New_York')
        self.assertEqual(end-start, 23*3600)
        start, end = day_bounds('2026-11-01', 'America/New_York')
        self.assertEqual(end-start, 25*3600)
        for day, zone in [('2026-9-21', 'UTC'), ('2026-02-30', 'UTC'), ('9999-12-31', 'UTC'),
                          ('2026-09-21', '../UTC'), ('2026-09-21', '/etc/passwd'), ('2026-09-21', 'No/Such')]:
            with self.assertRaises(APIError): day_bounds(day, zone)
        self.add('o', 0); self.add('c', 1, 'close')
        self.assertEqual(self.summary('2026-09-23')['apps'], [])

    def test_bounded_store_does_not_delete_records(self):
        self.add('o', 0)
        with patch('app_events.MAX_EVENTS', 1), self.assertRaises(APIError) as caught:
            self.add('c', 1, 'close')
        self.assertEqual(caught.exception.status, 507)
        self.assertEqual(self.summary()['eventCount'], 1)


class AppEventRouteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(self.temp.name)
        self.owner = 'synthetic-cove-owner-credential-00000'
        self.shortcut = 'synthetic-shortcut-credential-0000000'
        self.app = Application(self.store, self.owner, shortcuts_token=self.shortcut)

    def tearDown(self):
        self.app.close(); self.store.close(); self.temp.cleanup()

    def call(self, method, path, token=None, body=None):
        # Invoke the actual HTTP route/body methods without opening a socket.
        handler = self.app.handler().__new__(self.app.handler())
        handler.command, handler.path = method, path
        data = json.dumps(body).encode() if body is not None else b''
        handler.headers = {'Content-Length': str(len(data)), 'Authorization': 'Bearer ' + (token or '')}
        handler.rfile = io.BytesIO(data)
        try:
            return 200, handler.route()
        except APIError as exc:
            return exc.status, {'error': exc.message}

    def test_shortcut_has_ingest_only_no_owner_data_access(self):
        body = {'id': 'synthetic-event', 'app': '示例 App', 'action': 'open', 'timestamp': iso(datetime.now(timezone.utc))}
        before = self.store.db.total_changes
        self.assertEqual(self.call('POST', '/v1/app-events', self.owner, body)[0], 401)
        self.assertEqual(self.call('POST', '/v1/app-events', None, body)[0], 401)
        self.assertEqual(self.call('POST', '/v1/app-events', self.shortcut, body)[0], 200)
        for method, path in [('GET', '/v1/app-events?day=2026-09-22&timeZone=Asia/Shanghai'),
                             ('GET', '/v1/messages'), ('GET', '/v1/health'), ('GET', '/v1/conversations'),
                             ('POST', '/v1/messages'), ('POST', '/v1/health'), ('DELETE', '/v1/health'),
                             ('POST', '/v1/app-events/'), ('POST', '/v1/app-events/anything')]:
            self.assertEqual(self.call(method, path, self.shortcut, body)[0], 401, path)
        self.assertEqual(self.store.db.total_changes, before)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0], 0)
        self.assertFalse(self.app.wake.is_set())

    def test_owner_summary_strict_query_and_body_limits(self):
        code, result = self.call('GET', '/v1/app-events?day=2026-09-22&timeZone=Asia/Shanghai', self.owner)
        self.assertEqual(code, 200)
        self.assertTrue(result['configured'])
        for query in ('', '?day=2026-09-22', '?day=2026-09-22&timeZone=UTC&day=2026-09-23',
                      '?day=2026-09-22&timeZone=UTC&token=bad', '?day=2026-09-22&timeZone=No/Such'):
            self.assertEqual(self.call('GET', '/v1/app-events'+query, self.owner)[0], 400)
        self.assertEqual(self.call('POST', '/v1/app-events?q=1', self.shortcut, {})[0], 400)
        self.assertEqual(self.call('POST', '/v1/app-events', self.shortcut, {'large': 'x'*2048})[0], 413)

    def test_disabled_and_invalid_configuration_fail_closed(self):
        self.app.close()
        self.app = Application(self.store, self.owner)
        code, result = self.call('GET', '/v1/app-events?day=2026-09-22&timeZone=UTC', self.owner)
        self.assertEqual(code, 200)
        self.assertFalse(result['configured'])
        self.assertEqual(self.call('POST', '/v1/app-events', self.shortcut, {})[0], 401)
        for token in (self.owner, 'short', 'x'*257, 'x'*32+'\n', '中'*32):
            with self.assertRaises(ValueError): Application(self.store, self.owner, shortcuts_token=token)

    def test_non_main_runtime_never_inherits_shortcut_secret(self):
        runtime = CodexRuntime(self.store, self.temp.name)
        try:
            with patch.dict(os.environ, {'COVE_TOKEN': self.owner, 'COVE_SHORTCUTS_TOKEN': self.shortcut}), \
                    patch('runtime.subprocess.Popen', side_effect=RuntimeError('synthetic stop before spawn')) as spawn:
                with self.assertRaisesRegex(RuntimeError, 'synthetic stop'):
                    runtime.ensure_started()
                environment = spawn.call_args.kwargs['env']
                self.assertNotIn('COVE_TOKEN', environment)
                self.assertNotIn('COVE_SHORTCUTS_TOKEN', environment)
        finally:
            runtime.close()


class AppEventHTTPTests(AppEventRouteTests):
    """Repeat owner/shortcut scope tests over a real isolated loopback server."""
    def setUp(self):
        super().setUp()
        try:
            self.server = ThreadingHTTPServer(('127.0.0.1', 0), self.app.handler())
        except Exception:
            super().tearDown()
            raise
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join()
        super().tearDown()

    def call(self, method, path, token=None, body=None):
        headers = {'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        data = json.dumps(body).encode() if body is not None else None
        request = Request('http://127.0.0.1:' + str(self.server.server_port) + path,
                          data=data, method=method, headers=headers)
        try:
            with urlopen(request, timeout=5) as response:
                return response.status, json.loads(response.read())
        except HTTPError as exc:
            return exc.code, json.loads(exc.read())

    def test_disabled_and_invalid_configuration_fail_closed(self):
        # The server's handler retains the original Application; disabling its
        # already-initialized ingress exercises the same absent-token branch.
        self.app.shortcuts_token = ''
        self.app.app_events.configured = False
        code, result = self.call('GET', '/v1/app-events?day=2026-09-22&timeZone=UTC', self.owner)
        self.assertEqual(code, 200)
        self.assertFalse(result['configured'])
        self.assertEqual(self.call('POST', '/v1/app-events', self.shortcut, {})[0], 401)


if __name__ == '__main__':
    unittest.main()
