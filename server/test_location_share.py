"""Synthetic location fixtures only; no GPS, network, model or production data."""
import copy
import json
import tempfile
import unittest
from pathlib import Path
from location_share import LocationShare, LocationError, iso, tools


class LocationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.clock = 1800000000.0
        self.path = Path(self.temp.name) / 'location.sqlite'
        self.service = LocationShare(self.path, lambda: self.clock)
        self.scope = {'conversationID': 'fixture-a'}
        self.enable()

    def tearDown(self):
        self.service.close()
        self.temp.cleanup()

    def enable(self, enabled=True, device='fixture-device'):
        return self.service.save_access({'enabled': enabled, 'revision': self.service.access()['revision'], 'deviceID': device})

    def request(self, origin='fixture-turn', scope=None):
        return self.service.request(scope or self.scope, origin, 'Synthetic test only')['request']

    def body(self, request):
        return {'requestID': request['id'], 'deviceID': 'fixture-device', 'revision': self.service.access()['revision'],
                'snapshot': {'latitude': 1.25, 'longitude': 2.5, 'accuracyMeters': 30,
                             'source': 'current', 'capturedAt': iso(self.clock), 'name': 'Synthetic fixture'}}

    def test_grant_persists_across_restart_and_no_default_tracking(self):
        self.service.close()
        self.service = LocationShare(self.path, lambda: self.clock)
        self.assertTrue(self.service.access()['enabled'])
        self.assertEqual(self.service.status()['requests'], [])
        self.assertFalse(self.service.read(self.scope)['available'])

    def test_idempotent_request_and_pending_dedup(self):
        first = self.request()
        self.assertEqual(self.request(), first)
        self.assertEqual(self.request('other-turn'), first)
        with self.assertRaises(LocationError):
            self.request('other-scope', {'conversationID': 'b'})
        self.assertEqual(len(self.service.status()['requests']), 1)

    def test_snapshot_ack_retry_does_not_create_second_continuation(self):
        request = self.request(); body = self.body(request)
        receipt = self.service.respond(body)
        self.clock += 300
        self.assertEqual(self.service.respond(body), receipt)
        self.assertEqual(len(self.service.ready()), 1)
        self.assertTrue(self.service.read(self.scope)['stale'])
        body['snapshot']['latitude'] = 3
        with self.assertRaises(LocationError): self.service.respond(body)

    def test_scope_and_device_isolation(self):
        request = self.request(); body = self.body(request)
        body['deviceID'] = 'wrong'
        with self.assertRaises(LocationError): self.service.respond(body)
        body['deviceID'] = 'fixture-device'; self.service.respond(body)
        with self.assertRaises(LocationError): self.service.read({'conversationID': 'b'}, request['id'])

    def test_revocation_fences_late_upload_and_all_model_reads(self):
        request = self.request(); body = self.body(request)
        self.enable(False)
        with self.assertRaises(LocationError): self.service.respond(body)
        with self.assertRaises(LocationError): self.service.read(self.scope, request['id'])
        self.assertEqual(self.service.ready(), [])
        self.assertEqual(self.service.status()['requests'][0]['status'], 'revoked')

    def test_reenable_never_revives_old_grant_data(self):
        request = self.request(); self.service.respond(self.body(request))
        self.enable(False); self.enable()
        with self.assertRaises(LocationError): self.service.read(self.scope, request['id'])
        self.assertEqual(self.service.ready(), [])

    def test_access_cas_prevents_stale_enable(self):
        revision = self.service.access()['revision']; self.enable(False)
        with self.assertRaises(LocationError):
            self.service.save_access({'enabled': True, 'revision': revision, 'deviceID': 'fixture-device'})

    def test_expiry_is_not_success(self):
        request = self.request(); body = self.body(request); self.clock += 601
        with self.assertRaises(LocationError): self.service.respond(body)
        result = self.service.read(self.scope)
        self.assertFalse(result['available']); self.assertEqual(result['request']['status'], 'expired')
        self.assertEqual(len(self.service.ready()), 1)

    def test_reject_cached_and_future_samples(self):
        request = self.request(); body = self.body(request)
        for offset in (-10, 30):
            body['snapshot']['capturedAt'] = iso(self.clock + offset)
            with self.assertRaises(LocationError): self.service.respond(body)
        self.clock += 200
        body['snapshot']['capturedAt'] = iso(self.clock - 130)
        with self.assertRaises(LocationError): self.service.respond(body)

    def test_coordinate_and_metadata_validation(self):
        request = self.request(); original = self.body(request)
        for key, value in [('latitude', float('nan')), ('longitude', 181), ('latitude', True),
                           ('accuracyMeters', -1), ('accuracyMeters', float('inf')),
                           ('source', 'selected'), ('capturedAt', 'today'), ('name', 'x' * 241)]:
            body = copy.deepcopy(original); body['snapshot'][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(LocationError): self.service.respond(body)
        body = copy.deepcopy(original); body['snapshot']['track'] = [1, 2]
        with self.assertRaises(LocationError): self.service.respond(body)

    def test_failure_no_fabricated_coordinate(self):
        request = self.request(); body = self.body(request)
        del body['snapshot']; body['error'] = 'permission_denied'
        self.service.respond(body)
        result = self.service.read(self.scope)
        self.assertFalse(result['available']); self.assertIsNone(result['snapshot'])
        self.assertEqual(result['request']['status'], 'failed')

    def test_notification_only_once_no_coordinates(self):
        self.request()
        first = self.service.pending_notifications()
        self.assertEqual(len(first), 1)
        self.assertNotIn('snapshot', first[0][0])
        self.assertEqual(self.service.pending_notifications(), [])

    def test_dispatch_reservation_not_replayed_after_restart(self):
        request = self.request(); self.service.respond(self.body(request))
        self.service.continuation(request['id'], 'dispatching')
        self.service.close(); self.service = LocationShare(self.path, lambda: self.clock)
        self.assertEqual(self.service.ready(), [])

    def test_separate_app_databases(self):
        other = LocationShare(Path(self.temp.name) / 'ccc.sqlite', lambda: self.clock)
        try:
            self.request()
            self.assertFalse(other.access()['enabled']); self.assertEqual(other.status()['requests'], [])
        finally: other.close()

    def test_tools_cannot_write_gps_or_enable_grant(self):
        schemas = tools('cove') + tools('ccc', native=True)
        for tool in schemas:
            self.assertNotIn('latitude', tool['inputSchema']['properties'])
            self.assertNotIn('enabled', tool['inputSchema']['properties'])
        self.assertEqual(len(schemas), 4)


class CoveLocationTests(unittest.TestCase):
    def setUp(self):
        from storage import Store
        from cove_location import CoveLocation
        self.temp = tempfile.TemporaryDirectory(); self.store = Store(self.temp.name)
        self.store.create_conversation('fixture')
        self.store.accept({'id': 'owner-turn', 'conversationID': 'fixture', 'text': 'Synthetic fixture'})
        self.job = self.store.claim(); self.store.bind_turn('owner-turn', 'turn')
        self.service = CoveLocation(self.store)
        grant = self.service.data.access()
        self.service.data.save_access({'enabled': True, 'revision': grant['revision'], 'deviceID': 'phone'})

    def tearDown(self):
        self.service.data.close(); self.store.close(); self.temp.cleanup()

    def request(self):
        return self.service.tool('owner-turn', 'turn', 'cove_request_location', {'reason': 'Synthetic fixture'}, 'fixture')['request']

    def test_turn_scope_and_result_continuation_once(self):
        from storage import APIError, now
        with self.assertRaises(APIError): self.service.tool('owner-turn', 'wrong', 'cove_request_location', {'reason': 'fixture'}, 'fixture')
        request = self.request()
        self.service.data.respond({'requestID': request['id'], 'revision': request['revision'], 'deviceID': 'phone',
            'snapshot': {'latitude': 1, 'longitude': 2, 'accuracyMeters': 15, 'capturedAt': now(), 'source': 'current'}})
        self.service.drain(); self.assertEqual(self.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0], 1)
        self.store.finish('owner-turn', 'complete')
        self.service.drain(); self.service.drain()
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0], 2)
        job = self.store.claim()
        self.assertEqual(job['user']['role'], 'system')
        self.assertEqual(job['user']['locationRequestID'], request['id'])
        self.store.bind_turn(job['message'], 'result-turn')
        result = self.service.tool(job['message'], 'result-turn', 'cove_read_location', {'locationRequestID': request['id']}, 'fixture')
        self.assertTrue(result['available'])
        with self.assertRaises(APIError): self.service.tool(job['message'], 'result-turn', 'cove_request_location', {'reason': 'again'}, 'fixture')

    def test_parent_already_read_no_duplicate_reply(self):
        request = self.request()
        self.service.data.respond({'requestID': request['id'], 'revision': request['revision'], 'deviceID': 'phone', 'error': 'timeout'})
        self.service.tool('owner-turn', 'turn', 'cove_read_location', {'locationRequestID': request['id']}, 'fixture')
        self.store.finish('owner-turn', 'complete')
        self.service.drain()
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0], 1)

    def test_revoke_before_drain_no_model_job(self):
        request = self.request()
        self.service.data.respond({'requestID': request['id'], 'revision': request['revision'], 'deviceID': 'phone', 'error': 'timeout'})
        self.store.finish('owner-turn', 'complete')
        self.service.data.save_access({'enabled': False, 'revision': request['revision'], 'deviceID': 'phone'})
        self.service.drain(); self.assertEqual(self.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0], 1)


class CoveLocationHTTPTests(unittest.TestCase):
    def test_owner_only_routes_and_grant_roundtrip(self):
        from storage import Store
        from cove import Application
        from http.server import ThreadingHTTPServer
        from urllib.request import Request, urlopen
        from urllib.error import HTTPError
        import threading
        with tempfile.TemporaryDirectory() as root:
            store = Store(root); app = Application(store, 'synthetic-token-' + 'x'*32)
            server = ThreadingHTTPServer(('127.0.0.1', 0), app.handler())
            thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
            def call(path, body=None, auth=True):
                request = Request('http://127.0.0.1:' + str(server.server_port) + path,
                    data=json.dumps(body).encode() if body is not None else None,
                    headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + (app.token if auth else 'wrong')})
                try:
                    with urlopen(request, timeout=3) as result: return result.status, json.loads(result.read())
                except HTTPError as error: return error.code, json.loads(error.read())
            try:
                self.assertEqual(call('/v1/location/status', auth=False)[0], 401)
                code, value = call('/v1/location/status')
                self.assertEqual(code, 200); self.assertFalse(value['access']['enabled'])
                body = {'enabled': True, 'deviceID': 'fixture', 'revision': value['access']['revision']}
                code, granted = call('/v1/location/access', body)
                self.assertEqual(code, 200); self.assertTrue(granted['access']['enabled'])
                self.assertEqual(call('/v1/location/tools/request', {'reason': 'fixture'})[0], 404)
                self.assertEqual(call('/v1/location/status?unexpected=true')[0], 400)
            finally:
                server.shutdown(); server.server_close(); app.close(); store.close()


if __name__ == '__main__': unittest.main()
