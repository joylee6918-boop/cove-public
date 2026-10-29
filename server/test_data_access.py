"""Synthetic-only standing permission, archive sync and actual MCP roundtrip tests."""
import copy
import json
import shlex
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from datetime import datetime, timezone, timedelta
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from cove import Application, health_snapshot
from data_access import delivery_guard
from health_requests import METRICS
from runtime import CodexRuntime
from storage import Store, APIError, now
import test_health_requests as health_support
import test_server as http_support
from test_server import TOKEN


class DataAccessTests(unittest.TestCase):
    http = health_support.HealthRequestsTests.http
    call = health_support.HealthRequestsTests.call
    payload = health_support.HealthRequestsTests.payload
    route = health_support.HealthRequestsTests.route
    tearDown = health_support.HealthRequestsTests.tearDown

    def setUp(self):
        health_support.HealthRequestsTests.setUp(self)
        self.runtime.app_events = self.app.app_events

    def enable(self):
        status, state = self.http('/v1/data-access', {'enabled': True})
        self.assertEqual(status, 200)
        return state

    def upload(self, snapshot=None):
        return self.http('/v1/health', {'snapshot': snapshot or self.payload()['snapshot'], 'standingAccess': True})

    def test_owner_only_explicit_persistent_state_and_no_model_grant(self):
        self.assertEqual(self.http('/v1/data-access', auth=False)[0], 401)
        self.assertEqual(self.http('/v1/data-access', {'enabled': True}, auth=False)[0], 401)
        self.assertFalse(self.http('/v1/data-access')[1]['enabled'])
        for body in ({}, {'enabled': 1}, {'enabled': 'true'}, {'enabled': True, 'conversationID': 'a'}):
            self.assertEqual(self.http('/v1/data-access', body)[0], 400)
        with self.assertRaises(APIError) as failure:
            self.call('cove_read_health', {})
        self.assertEqual(failure.exception.status, 403)
        state = self.enable()
        self.assertTrue(state['enabled']); self.assertIsNotNone(state['grantedAt'])
        self.assertEqual(self.enable(), state)
        self.assertEqual(self.call('cove_read_health', {})['entries'], [])
        self.assertEqual(self.store.health_requests('a')['requests'], [])
        supplemental = self.call('cove_request_health')['request']
        self.assertEqual(supplemental['status'], 'pending')
        self.assertEqual(self.store.data_access(), state)
        self.app.close(); self.runtime.close()
        self.store.finish('incoming', 'complete'); self.store.close()
        self.store = Store(self.temp.name)
        self.app.store = self.store; self.app.runtime.store = self.store; self.runtime.store = self.store
        self.assertEqual(self.store.data_access(), state)

    def test_standing_partial_data_supplement_waits_for_allow_and_preserves_existing(self):
        state = self.enable()
        self.assertEqual(self.upload()[0], 200)
        before = self.call('cove_read_health', {})['entries']
        self.assertIn('hrv', before[0]['missingMetricIDs'])
        request = self.call(args=dict(self.args, metrics=['hrv'], reason='Synthetic: missing HRV'))['request']
        self.assertEqual(request['metrics'], ['hrv'])
        self.assertEqual(request['status'], 'pending')
        self.assertIsNone(self.call('cove_read_health_request', {'requestID': request['id']})['snapshot'])
        self.assertEqual(self.call('cove_read_health', {})['entries'], before)
        payload = self.payload()
        payload['snapshot']['metrics'] = [{'id': 'hrv', 'title': 'HRV', 'value': 31, 'unit': '毫秒',
                                           'sampledAt': self.args['endAt'], 'source': 'synthetic'}]
        self.assertEqual(self.http(self.route(request['id']), payload)[0], 200)
        result = self.call('cove_read_health_request', {'requestID': request['id']})
        self.assertEqual(result['snapshot']['metrics'][0]['id'], 'hrv')
        self.assertEqual(result['missingMetricIDs'], [])
        self.assertEqual(self.store.data_access(), state)
        self.assertEqual(self.call('cove_read_health', {})['entries'][-1]['snapshot'], before[0]['snapshot'])

    def test_standing_supplement_keeps_denial_expiry_and_scope_guards(self):
        self.enable()
        health_support.HealthRequestsTests.test_deny_expiry_empty_data_and_restart(self)

    def test_standing_supplement_keeps_validation_and_active_turn_guards(self):
        self.enable()
        health_support.HealthRequestsTests.test_reject_broad_ranges_metrics_metadata_values_and_bad_capabilities(self)

    def test_all_34_metrics_details_historical_archives_and_idempotent_upload(self):
        self.enable()
        captured = now()
        snapshot = {'capturedAt': captured, 'metrics': [
            {'id': key, 'title': title, 'unit': unit, 'value': 1, 'sampledAt': captured,
             'source': 'Synthetic test device', 'detail': 'Synthetic interval detail'} for key, (title, unit) in METRICS.items()]}
        code, first = self.upload(snapshot)
        self.assertEqual(code, 200)
        self.assertEqual(self.upload(snapshot), (200, first))
        old = copy.deepcopy(snapshot); old['capturedAt'] = '2001-01-01T00:00:00Z'
        for metric in old['metrics']: metric['sampledAt'] = old['capturedAt']
        self.assertEqual(self.upload(old)[0], 200)
        self.assertEqual(self.store.health()['snapshot']['capturedAt'], captured)
        records = self.call('cove_read_health', {})['entries']
        self.assertEqual(len(records), 2)
        self.assertEqual(len(records[0]['snapshot']['metrics']), 34)
        self.assertEqual(records[0]['missingMetricIDs'], [])
        self.assertEqual(records[0]['snapshot']['metrics'][0]['detail'], 'Synthetic interval detail')
        different = copy.deepcopy(snapshot); different['metrics'][0]['value'] = 2
        self.assertEqual(self.upload(different)[0], 409)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM health_uploads').fetchone()[0], 2)

    def test_approved_request_history_cross_conversation_but_never_pending_or_denied(self):
        allowed = self.call()['request']
        self.assertEqual(self.http(self.route(allowed['id']), self.payload())[0], 200)
        pending = self.call()['request']
        denied = self.call()['request']
        self.assertEqual(self.http(self.route(denied['id']), {'decision': 'deny'})[0], 200)
        # Approved request belongs to another retained conversation; standing grant is owner-wide.
        with self.store.lock, self.store.db:
            self.store.db.execute('UPDATE health_requests SET conversation=? WHERE id=?', ('b', allowed['id']))
        self.enable()
        result = self.call('cove_read_health', {})
        self.assertEqual(len(result['entries']), 1)
        self.assertEqual(result['entries'][0]['snapshot']['metrics'][0]['value'], 42)
        self.assertEqual(result['entries'][0]['missingMetricIDs'], ['hrv'])
        self.assertEqual(result['entries'][0]['request']['id'], allowed['id'])
        self.assertEqual(result['entries'][0]['aggregationRange'], {'startAt': self.args['startAt'], 'endAt': self.args['endAt']})
        self.assertEqual(result['entries'][0]['source'], 'allowed-request')
        self.assertEqual(self.store._health_request('a', pending['id'])['status'], 'pending')

    def test_revoke_rechecks_cached_tools_and_uploads_without_deleting_records(self):
        self.enable(); self.assertEqual(self.upload()[0], 200)
        result = self.call('cove_read_health', {})
        self.assertTrue(result['available'])
        self.assertEqual(self.http('/v1/data-access', {'enabled': False})[0], 200)
        with self.assertRaises(APIError):
            self.runtime.mcp_file_call('a', 'cove_read_health', {})
        self.assertEqual(self.upload()[0], 403)
        self.assertIsNotNone(self.store.health()['snapshot'])
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM data_tool_results').fetchone()[0], 0)
        self.enable()
        self.assertEqual(len(self.call('cove_read_health', {})['entries']), 1)
        self.store.delete_health()
        self.assertFalse(self.store.data_access()['enabled'])
        self.assertIsNone(self.store.health()['snapshot'])
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM health_uploads').fetchone()[0], 0)

    def test_active_turn_and_delivery_revocation_fences(self):
        self.enable(); self.upload()
        result = self.call('cove_read_health', {})
        self.assertIsNone(self.store.health()['readAt'])
        with delivery_guard(self.runtime, 'a', 'cove_read_health', {}, result): pass
        self.assertIsNotNone(self.store.health()['readAt'])
        self.store.set_data_access({'enabled': False}); self.store.set_data_access({'enabled': True})
        with self.assertRaises(APIError), delivery_guard(self.runtime, 'a', 'cove_read_health', {}, result): pass
        with self.assertRaises(APIError): self.call('cove_read_health', {}, conversation='b')
        self.runtime.active['cancel'].set()
        with self.assertRaises(APIError): self.call('cove_read_health', {})
        self.runtime.active['cancel'].clear()
        with patch('runtime.MCP_EVENT_WAIT', .01), self.assertRaises(APIError):
            self.runtime.mcp_file_call('a', 'cove_read_health', {'limit': 5})
        self.store.finish('incoming', 'complete')
        with self.assertRaises(APIError): self.call('cove_read_health', {})

    def test_existing_system_pulse_wake_reads_without_creating_wake_or_card(self):
        self.enable(); self.upload()
        with self.store.lock, self.store.db:
            event = self.store._message('incoming'); event['role'] = 'system'
            self.store._put(event)
        self.assertTrue(self.call('cove_read_health', {})['available'])
        apps = self.call('cove_read_app_activity', {'day': '2026-09-22', 'timeZone': 'Asia/Shanghai'})
        self.assertEqual(apps['source'], 'cove-shortcuts'); self.assertEqual(apps['eventCount'], 0)
        self.assertFalse(apps['configured']); self.assertEqual(apps['apps'], [])
        self.assertEqual(self.store.health_requests('a')['requests'], [])
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0], 1)

    def test_standing_passive_collar_including_pulse_but_not_active_measurements(self):
        from test_collar import SyntheticCollar
        from collar import delivery_guard as collar_guard
        self.runtime.collar_client = SyntheticCollar()
        self.enable()
        arguments = {k: self.args[k] for k in ('metrics', 'startAt', 'endAt')}
        result = self.call('cove_collar_summary', arguments)
        self.assertEqual(result['snapshot']['metrics'][0]['value'], 42)
        with collar_guard(self.runtime, 'a', 'cove_collar_summary', arguments, result): pass
        with self.assertRaises(APIError): self.call('cove_collar_measure', {})
        with self.store.lock, self.store.db:
            event = self.store._message('incoming'); event['role'] = 'system'; self.store._put(event)
        result = self.call('cove_collar_summary', arguments)
        with collar_guard(self.runtime, 'a', 'cove_collar_summary', arguments, result): pass
        with self.assertRaises(APIError): self.call('cove_collar_measure', {})
        self.store.set_data_access({'enabled': False})
        with self.assertRaises(APIError), collar_guard(self.runtime, 'a', 'cove_collar_summary', arguments, result): pass
        with self.assertRaises(APIError): self.call('cove_collar_summary', arguments)
        self.assertTrue(all(path == '/summary' for path, _ in self.runtime.collar_client.calls))

    def test_validation_unknown_future_malformed_and_pagination(self):
        self.enable()
        for changed in ({'capturedAt': '2100-01-01T00:00:00Z'}, {'capturedAt': '2026-01-01'}, {'other': []}):
            snapshot = self.payload()['snapshot']; snapshot.update(changed)
            self.assertEqual(self.upload(snapshot)[0], 400)
        for changed in ({'value': float('nan')}, {'value': True}, {'id': 'medicalRecords'}, {'unit': 'miles'},
                        {'sampledAt': '2100-01-01T00:00:00Z'}, {'detail': 'x'*4001}, {'source': 'x'*121}):
            snapshot = self.payload()['snapshot']; snapshot['metrics'][0].update(changed)
            self.assertEqual(self.upload(snapshot)[0], 400)
        snapshot = self.payload()['snapshot']; snapshot['sleepSegments'] = [{'stageID': [], 'startAt': now(), 'endAt': now()}]
        self.assertEqual(self.upload(snapshot)[0], 400)
        clock = datetime.now(timezone.utc)
        for index in range(3):
            stamp = (clock-timedelta(days=index)).isoformat()
            self.assertEqual(self.upload({'capturedAt': stamp, 'metrics': []})[0], 200)
        first = self.call('cove_read_health', {'limit': 1})
        second = self.call('cove_read_health', {'limit': 2, 'offset': first['nextOffset']})
        self.assertEqual(len(first['entries']), 1); self.assertEqual(len(second['entries']), 2)
        self.assertIsNone(second['nextOffset'])
        for arguments in ({'limit': True}, {'limit': 101}, {'offset': -1}, {'offset': '1'}, {'path': '/etc/cove/cove.env'}):
            with self.assertRaises(APIError): self.call('cove_read_health', arguments)


class DataAccessRoundtripTests(unittest.TestCase):
    def test_new_resumed_thread_real_mcp_notifications_and_readonly_listing(self):
        with tempfile.TemporaryDirectory() as temp:
            store = Store(temp)
            store.create_conversation('new'); store.create_conversation('old'); store.bind_thread('old', 'retained-thread')
            store.set_data_access({'enabled': True})
            stamp = now()
            store.upload_health(health_snapshot({'capturedAt': stamp, 'metrics': [{'id': 'steps', 'unit': '步', 'value': 42, 'sampledAt': stamp}]}), standing=True)
            command = shlex.quote(sys.executable)+' '+shlex.quote(str(Path(__file__).with_name('fake_app_server.py')))
            runtime = CodexRuntime(store, temp, command, timeout=8)
            app = Application(store, TOKEN, runtime, '')
            server = ThreadingHTTPServer(('127.0.0.1', 0), app.handler())
            thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
            self.base = 'http://127.0.0.1:'+str(server.server_port)
            self.store = store
            request = lambda *args, **kwargs: http_support.HTTPTests.request(self, *args, **kwargs)
            try:
                for conversation in ('new', 'old'):
                    for kind, arguments in [('HEALTH', {}), ('APPS', {'day': '2026-09-22', 'timeZone': 'Asia/Shanghai'})]:
                        identifier = conversation+'-'+kind
                        code, _ = request('POST', '/v1/messages', {'id': identifier, 'conversationID': conversation, 'text': 'COVE_TEST_DATA_'+kind+' '+json.dumps(arguments)})
                        self.assertEqual(code, 200)
                        deadline = time.monotonic()+12
                        while time.monotonic() < deadline:
                            with store.lock:
                                job = store.db.execute('SELECT state,assistant FROM jobs WHERE message=?', (identifier,)).fetchone()
                            if job and job['state'] not in ('queued', 'running'):
                                self.assertEqual(job['state'], 'complete', store._message(job['assistant']))
                                self.assertTrue(store._message(job['assistant'])['text'].startswith('data fixture'))
                                break
                            time.sleep(.02)
                        else: self.fail('MCP standing data roundtrip timed out')
                    self.assertEqual(store.health_requests(conversation)['requests'], [])
                self.assertEqual(store.conversation('old')['thread'], 'retained-thread')
                config = runtime.file_config('old')['mcp_servers.cove_files']
                child = subprocess.run([config['command'], *config['args']], input=json.dumps({'jsonrpc':'2.0','id':1,'method':'tools/list'})+'\n', capture_output=True, text=True,
                                       env=config['env'], timeout=5)
                tools = json.loads(child.stdout)['result']['tools']
                for name in ('cove_read_health', 'cove_read_app_activity'):
                    self.assertTrue(next(t for t in tools if t['name']==name)['annotations']['readOnlyHint'])
            finally:
                server.shutdown(); server.server_close(); app.close(); store.close()


if __name__ == '__main__': unittest.main()
