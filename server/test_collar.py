"""Synthetic local tests only. No user health, remote service, model or push."""
import json
import os
import subprocess
import shlex
import sys
from pathlib import Path
import tempfile
import threading
import unittest
from datetime import datetime, timezone, timedelta
from http.server import ThreadingHTTPServer
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from unittest.mock import patch

from collar import CollarClient, project_summary, project_measurement, validate_summary_args, delivery_guard
from cove import Application
from runtime import CodexRuntime
from storage import Store, APIError, now, encode
from test_server import TOKEN


class SyntheticCollar:
    configured = True

    def __init__(self):
        self.calls = []
        self.fail = False

    def call(self, path, body=None):
        self.calls.append((path, body))
        if self.fail:
            raise RuntimeError('private-secret-never-display')
        if path == '/summary':
            return {'source': 'collar', 'snapshot': {'capturedAt': now(), 'metrics': [{'id': 'steps', 'value': 42, 'unit': '步', 'sampledAt': body['endAt'], 'source': 'Collar · Apple Watch', 'privateExtra': 'never-output'}]}, 'private': 'never-output'}
        id = body['requestID'] if body else path.rsplit('/', 1)[1]
        return {'measurement': {'id': id, 'status': 'pending', 'requestedAt': now(), 'completedAt': None, 'durationSeconds': 30, 'result': None}}


class CollarTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(self.temp.name)
        for id in ('a', 'b'):
            self.store.create_conversation(id)
        self.store.accept({'id': 'incoming', 'conversationID': 'a', 'text': 'synthetic fixture'})
        self.store.claim(); self.store.bind_turn('incoming', 'turn')
        self.runtime = CodexRuntime(self.store, self.temp.name)
        self.client = SyntheticCollar(); self.runtime.collar_client = self.client
        self.runtime.active = {'conversation': 'a', 'thread': 'thread', 'turn': 'turn', 'message': 'incoming', 'cancel': threading.Event()}
        self.app = Application(self.store, TOKEN, self.runtime, '')
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), self.app.handler())
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True); self.thread.start()
        self.base = 'http://127.0.0.1:'+str(self.server.server_port)
        clock = datetime.now(timezone.utc)
        self.args = {'metrics': ['steps', 'hrv'], 'startAt': (clock-timedelta(hours=24)).isoformat(), 'endAt': clock.isoformat()}
        self.count = 0

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.app.close()
        self.runtime.close(); self.store.close(); self.temp.cleanup()

    def http(self, body=None, conversation='a', auth=True):
        request = Request(self.base+'/v1/conversations/'+conversation+'/collar', data=None if body is None else encode(body).encode(), headers={'Authorization': 'Bearer '+(TOKEN if auth else 'wrong'), 'Content-Type': 'application/json'})
        try:
            with urlopen(request, timeout=3) as response:
                return response.status, json.loads(response.read())
        except HTTPError as error:
            return error.code, json.loads(error.read())

    def tool(self, name='cove_collar_summary', args=None, call=None):
        self.count += 1
        args = self.args if args is None else args
        self.runtime.file_permits.append({'conversation': 'a', 'turn': 'turn', 'call': call or str(self.count), 'tool': name, 'arguments': args, 'used': False})
        return self.runtime.mcp_file_call('a', name, args)

    def allow(self, read=True, measure=False):
        code, body = self.http({'readSummary': read, 'requestMeasurement': measure})
        self.assertEqual(code, 200, body)
        return body

    def test_defaults_owner_auth_strict_global_grants_and_no_side_effect(self):
        code, permissions = self.http()
        self.assertEqual(code, 200)
        self.assertFalse(permissions['readSummary']); self.assertFalse(permissions['requestMeasurement'])
        self.assertEqual(self.http(auth=False)[0], 401)
        self.assertEqual(self.http(conversation='missing')[0], 404)
        for body in ({'readSummary': 1, 'requestMeasurement': False}, {'readSummary': True}, {'readSummary': True, 'requestMeasurement': False, 'token': 'bad'}):
            self.assertEqual(self.http(body)[0], 400)
        with self.assertRaises(APIError): self.tool()
        self.allow()
        self.assertTrue(self.http(conversation='b')[1]['readSummary'])
        self.assertFalse(self.http(conversation='b')[1]['requestMeasurement'])
        self.assertEqual(self.client.calls, [])
        self.client.configured = False
        self.assertEqual(self.http({'readSummary': True, 'requestMeasurement': True})[0], 503)
        self.allow(False, False)

    def test_projection_scope_audit_and_revoked_cached_call(self):
        self.allow()
        result = self.tool(call='one')
        self.assertEqual(result['snapshot']['metrics'][0]['value'], 42)
        self.assertEqual(result['missingMetricIDs'], ['hrv'])
        self.assertNotIn('never-output', encode(result))
        self.assertEqual(self.tool(call='one'), result)
        self.assertEqual(len(self.client.calls), 1)
        audit = self.http()[1]['recentActions']
        self.assertEqual(audit[0]['action'], 'read_summary')
        self.assertNotIn('snapshot', encode(audit)); self.assertNotIn('value', encode(audit))
        self.allow(False)
        with self.assertRaises(APIError): self.tool(call='one')
        self.allow(True)
        with self.assertRaises(APIError): self.tool(call='one')
        self.assertEqual(len(self.client.calls), 1)

    def test_measurement_separate_grant_idempotence_ownership_and_unknown(self):
        self.allow()
        with self.assertRaises(APIError): self.tool('cove_collar_measure', {})
        self.allow(False, True)
        with self.assertRaises(APIError): self.tool()
        result = self.tool('cove_collar_measure', {}, call='measure')
        self.assertEqual(result['measurement']['status'], 'pending')
        self.assertEqual(self.tool('cove_collar_measure', {}, call='measure'), result)
        self.assertEqual(len(self.client.calls), 1)
        id = result['measurement']['id']
        self.assertEqual(self.tool('cove_collar_measurement', {'id': id})['measurement']['id'], id)
        with self.assertRaises(APIError): self.tool('cove_collar_measurement', {'id': '00000000-0000-4000-8000-000000000000'})
        self.client.fail = True
        lost = self.tool('cove_collar_measure', {}, call='lost')
        self.assertEqual(lost['measurement']['status'], 'unknown')
        self.assertNotIn('private-secret', encode(lost))
        before = len(self.client.calls)
        self.assertEqual(self.tool('cove_collar_measure', {}, call='lost'), lost)
        self.assertEqual(len(self.client.calls), before)

    def test_no_background_no_stale_permit_no_cross_conversation(self):
        self.allow(True, True)
        with patch('runtime.MCP_EVENT_WAIT', .01), self.assertRaises(APIError):
            self.runtime.mcp_file_call('a', 'cove_collar_summary', self.args)
        original = self.store._message('incoming')
        with self.store.lock, self.store.db: self.store._put(dict(original, role='system'))
        with self.assertRaises(APIError): self.tool()
        with self.store.lock, self.store.db: self.store._put(original)
        with self.assertRaises(APIError): self.store.assistant_collar_tool('incoming', 'turn', 'x', 'cove_collar_summary', self.args, 'b', self.client)
        self.runtime.active['cancel'].set()
        with self.assertRaises(APIError): self.tool()
        self.assertEqual(self.client.calls, [])

    def test_bounds_invalid_response_failure_no_secret(self):
        self.allow()
        for args in (dict(self.args, metrics=['steps', 'steps']), dict(self.args, metrics=['temperature']), dict(self.args, startAt='2000-01-01T00:00:00Z'), dict(self.args, endAt='2099-01-01T00:00:00Z'), dict(self.args, metrics=[{}])):
            with self.assertRaises(APIError): self.tool(args=args)
        self.assertEqual(self.client.calls, [])
        raw = self.client.call('/summary', self.args)
        raw['snapshot']['metrics'][0]['id'] = 'heartRate'
        with self.assertRaises(APIError): project_summary(raw, self.args)
        self.client.fail = True
        with self.assertRaises(APIError) as failure: self.tool()
        self.assertNotIn('private-secret', str(failure.exception))
        self.assertEqual(self.http()[1]['recentActions'][0]['status'], 'failed')

    def test_grants_and_audit_persist_restart(self):
        self.allow(True, True)
        self.assertTrue(self.http(conversation='b')[1]['readSummary'])
        self.assertTrue(self.http(conversation='b')[1]['requestMeasurement'])
        self.tool()
        self.store.finish('incoming', 'complete')
        self.store.close(); self.store = Store(self.temp.name)
        self.app.store = self.store; self.runtime.store = self.store
        result = self.http()[1]
        self.assertTrue(result['readSummary'])
        self.assertTrue(result['requestMeasurement'])
        self.assertEqual(result['recentActions'][0]['action'], 'read_summary')

    def test_delivery_revoke_and_delete_gate(self):
        self.allow()
        result = self.tool(call='delivery')
        self.assertEqual(self.http()[1]['recentActions'][0]['status'], 'ready')
        with delivery_guard(self.runtime, 'a', 'cove_collar_summary', self.args, result):
            pass  # Synthetic successful wire flush.
        self.assertEqual(self.http()[1]['recentActions'][0]['status'], 'complete')
        self.allow(False)
        with self.assertRaises(APIError), delivery_guard(self.runtime, 'a', 'cove_collar_summary', self.args, result):
            self.fail('revoked delivery')
        self.allow(True)
        with self.assertRaises(APIError), delivery_guard(self.runtime, 'a', 'cove_collar_summary', self.args, result):
            self.fail('regrant must not revive cleared result')
        self.store.delete_health()
        self.assertFalse(self.http()[1]['readSummary'])
        self.assertEqual(self.http()[1]['recentActions'], [])

    def test_revoke_ack_waits_for_inflight_flush_then_blocks_delivery(self):
        self.allow()
        result = self.tool(call='inflight')
        entered, release, revoked = threading.Event(), threading.Event(), threading.Event()
        def flush():
            with delivery_guard(self.runtime, 'a', 'cove_collar_summary', self.args, result):
                entered.set(); release.wait(3)
        def revoke():
            self.store.set_collar_permissions('a', {'readSummary': False, 'requestMeasurement': False}, True)
            revoked.set()
        sender = threading.Thread(target=flush); sender.start()
        self.assertTrue(entered.wait(2))
        canceller = threading.Thread(target=revoke); canceller.start()
        try:
            self.assertFalse(revoked.wait(.05), 'Revoke must not ACK before a started flush ends')
        finally:
            release.set(); sender.join(3); canceller.join(3)
        self.assertTrue(revoked.is_set())
        with self.assertRaises(APIError), delivery_guard(self.runtime, 'a', 'cove_collar_summary', self.args, result):
            self.fail('Post-revoke data must never be flushed')

    def test_actual_fake_appserver_new_resume_and_no_inherited_bridge_secrets(self):
        self.app.close(); self.runtime.close(); self.store.finish('incoming', 'complete')
        self.store.bind_thread('b', 'original-collar-thread')
        command = shlex.quote(sys.executable)+' '+shlex.quote(str(Path(__file__).with_name('fake_app_server.py')))
        self.runtime = CodexRuntime(self.store, self.temp.name, command, timeout=8)
        self.runtime.collar_client = self.client
        self.app.runtime = self.runtime
        with patch.dict(os.environ, {'COVE_COLLAR_TOKEN': 'private-token-must-not-inherit', 'COVE_COLLAR_URL': 'https://private.invalid', 'COLLAR_COVE_TOKEN': 'also-private'}):
            for conversation in ('a', 'b'):
                self.store.set_collar_permissions(conversation, {'readSummary': True, 'requestMeasurement': True}, True)
                for suffix, marker, args in (('summary', 'COVE_TEST_COLLAR_SUMMARY', self.args), ('measure', 'COVE_TEST_COLLAR_MEASURE', {})):
                    self.store.accept({'id': conversation+suffix, 'conversationID': conversation, 'text': marker+' '+encode(args)})
                    job = self.store.claim()
                    status, error = self.runtime.run(job, threading.Event())
                    self.store.finish(job['message'], status, error)
                    self.assertEqual(status, 'complete', error)
        self.assertEqual(self.store.conversation('b')['thread'], 'original-collar-thread')
        self.assertEqual(len(self.client.calls), 4)

    def test_real_bridge_http_roundtrip_without_real_health_or_measurement(self):
        from collar_bridge import CollarBridge, make_server
        from test_collar_bridge import FakeStore
        with tempfile.TemporaryDirectory() as directory:
            hs = FakeStore()
            hs.samples = [{'type': 'step_count', 'value': 42, 'unit': 'count', 'at': self.args['endAt'], 'source': 'watch'}]
            bridge = CollarBridge(hs, 'x'*40, directory)
            server = make_server(bridge, port=0)
            worker = threading.Thread(target=server.serve_forever, daemon=True); worker.start()
            try:
                self.runtime.collar_client = CollarClient('http://127.0.0.1:'+str(server.server_port), 'x'*40)
                self.allow(True, True)
                self.assertEqual(self.tool()['snapshot']['metrics'][0]['value'], 42)
                created = self.tool('cove_collar_measure', {}, call='real-http')
                self.assertEqual(created['measurement']['status'], 'pending')
                self.assertEqual(len(hs.writes), 1)
                self.assertEqual(self.tool('cove_collar_measure', {}, call='real-http'), created)
                self.assertEqual(self.tool('cove_collar_measurement', {'id': created['measurement']['id']})['measurement']['status'], 'pending')
                self.assertEqual(len(hs.writes), 1)
                with self.assertRaises(APIError) as busy: self.tool('cove_collar_measure', {})
                self.assertEqual(busy.exception.status, 429)
            finally:
                server.shutdown(); server.server_close(); worker.join(timeout=3)

    def test_real_stdio_tools_list_and_authenticated_callback(self):
        self.allow()
        config = self.runtime.file_config('a')['mcp_servers.cove_files']
        env = config['env']
        self.assertNotIn('COVE_COLLAR_TOKEN', env)
        child = subprocess.Popen([config['command'], *config['args']], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=dict(os.environ, **env))
        try:
            child.stdin.write(encode({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'})+'\n'); child.stdin.flush()
            tools = json.loads(child.stdout.readline())['result']['tools']
            self.assertIn('cove_collar_summary', {t['name'] for t in tools})
            self.runtime.file_permits.append({'conversation': 'a', 'turn': 'turn', 'call': 'stdio', 'tool': 'cove_collar_summary', 'arguments': self.args, 'used': False})
            child.stdin.write(encode({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call', 'params': {'name': 'cove_collar_summary', 'arguments': self.args}})+'\n'); child.stdin.flush()
            value = json.loads(child.stdout.readline())['result']
            self.assertFalse(value['isError'])
            self.assertEqual(json.loads(value['content'][0]['text'])['snapshot']['metrics'][0]['value'], 42)
        finally:
            child.terminate(); child.communicate(timeout=3)


class ClientTests(unittest.TestCase):
    def test_wrong_source_and_impossible_completion_rejected(self):
        clock = now()
        args = {'metrics': ['steps'], 'startAt': (datetime.now(timezone.utc)-timedelta(hours=1)).isoformat(), 'endAt': clock}
        raw = SyntheticCollar().call('/summary', args)
        raw['snapshot']['metrics'][0]['source'] = 'manual'
        with self.assertRaises(APIError): project_summary(raw, args)
        raw = {'measurement': {'id': 'x', 'status': 'done', 'durationSeconds': 30, 'requestedAt': clock, 'completedAt': None, 'result': None}}
        with self.assertRaises(APIError): project_measurement(raw, 'x')
        raw['measurement']['completedAt'] = '1900-01-01T00:00:00Z'
        with self.assertRaises(APIError): project_measurement(raw, 'x')

    def test_url_and_token_fail_closed(self):
        for url, token in [('http://remote.test', 'x'*32), ('https://user:password@test', 'x'*32), ('https://test?token=x', 'x'*32), ('https://test', ''), ('https://test', 'x'*31+'\n')]:
            self.assertFalse(CollarClient(url, token).configured)
        self.assertTrue(CollarClient('https://example.test/collar-cove', 'x'*32).configured)
        self.assertTrue(CollarClient('http://127.0.0.1:8798', 'x'*32).configured)
        self.assertFalse(CollarClient('https://[', 'x'*32).configured)


if __name__ == '__main__':
    unittest.main()
