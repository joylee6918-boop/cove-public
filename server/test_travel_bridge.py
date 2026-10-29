"""Isolated bridge regressions: synthetic SQLite/HTTP only, no model or travel IO."""
import json
import io
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError
from pathlib import Path
from urllib.request import Request, build_opener, ProxyHandler
from unittest.mock import Mock, patch

from cove import Application
from runtime import CodexRuntime
from storage import APIError, Store
from travel_bridge import TravelBridge, TRAVEL_TOOLS

TOKEN = 'synthetic-travel-owner-token'


class QuietApplication(Application):
    def _work(self):
        self.stop.wait()


class TravelBridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(self.temp.name)
        self.store.create_conversation('a'); self.store.create_conversation('b')
        self.bridge = TravelBridge(self.store, token_path='/unused-synthetic-token')
        self.bridge._request = Mock(side_effect=AssertionError('unexpected travel IO'))

    def tearDown(self):
        self.store.close(); self.temp.cleanup()

    def state(self, revision=1, conversation='a', decision=None):
        return {'available': True, 'conversationID': conversation, 'revision': revision,
                'invitation': {'id': 'invite-1', 'status': decision or 'pending'},
                'journey': None, 'archives': []}

    def error(self, status, fn, *args):
        with self.assertRaises(APIError) as caught:
            fn(*args)
        self.assertEqual(caught.exception.status, status)

    def test_scene_identity_is_persistent_and_conflicting_retries_rejected(self):
        body = {'id': 'reply', 'conversationID': 'a', 'text': 'synthetic reply', 'travelSceneID': 'scene-1'}
        self.assertEqual(self.store.accept(body)['travelSceneID'], 'scene-1')
        self.assertEqual(self.store.accept(body)['travelSceneID'], 'scene-1')
        self.error(409, self.store.accept, dict(body, travelSceneID='scene-2'))
        old = dict(body); old.pop('travelSceneID')
        self.error(409, self.store.accept, old)
        self.store.close(); self.store = Store(self.temp.name)
        self.assertEqual(self.store.accept(body)['travelSceneID'], 'scene-1')
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0], 1)
        for scene in ('', 'a/b', [], 1, 'a'*601):
            self.error(400, self.store.accept, dict(body, id='invalid', travelSceneID=scene))

    def test_ordinary_chat_and_legacy_scene_missing_never_unlock(self):
        user = self.store.accept({'id': 'reply', 'conversationID': 'a', 'text': 'ordinary'})
        self.assertEqual(self.bridge.context_for_job({'user': user}), '')
        empty = {'available': True, 'conversationID': 'a', 'revision': 1,
                 'invitation': None, 'journey': None, 'archives': []}
        self.bridge._record('a', empty)
        self.assertEqual(self.bridge.context_for_job({'user': user}), '')
        travel_user = dict(user, text='我们去旅行吧')
        self.assertIn('旅行工具为', self.bridge.context_for_job({'user': travel_user}))
        snapshot = self.state(); snapshot['journey'] = {'id':'journey-1','conversationID':'a','sceneID': 'scene-1', 'waitingForUser': True}
        self.bridge._record('a', snapshot)
        context = self.bridge.context_for_job({'user': user})
        self.assertIn('scene-1', context)
        self.bridge._request.assert_not_called()

    def test_scene_reply_exact_binding_and_unknown_result_warning(self):
        user = self.store.accept({'id': 'reply', 'conversationID': 'a', 'text': 'synthetic', 'travelSceneID': 'scene-1'})
        self.bridge._request.side_effect = None
        self.bridge._request.return_value = {'snapshot': self.state(2)}
        self.bridge.context_for_job({'user': user})
        self.bridge._request.assert_called_once_with('/reply', {'conversationID': 'a', 'messageID': 'reply', 'sceneID': 'scene-1', 'text': 'synthetic'}, timeout=5)
        self.bridge._request.side_effect = APIError(503, 'unknown')
        self.assertIn('未确认解锁', self.bridge.context_for_job({'user': user}))
        self.assertEqual(self.bridge._request.call_count, 2)  # one per attempt, never auto-retry

    def test_receipt_once_snapshot_recovers_lost_response_and_restart(self):
        self.bridge._request.side_effect = APIError(503, 'response lost')
        self.error(503, self.bridge.respond, 'a', 'invite-1', 'accept', 'request-1')
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0], 0)
        self.bridge._request.side_effect = None
        self.bridge._request.return_value = self.state(2, decision='accepted')
        self.bridge.snapshot('a'); self.bridge.snapshot('a')
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0], 1)
        job = self.store.claim()
        self.assertEqual(job['user']['role'], 'system')
        self.assertEqual(job['user']['travelDecision'], 'accepted')
        self.assertEqual(job['user']['text'], '')
        self.store.finish(job['message'], 'complete')
        self.store.close(); self.store = Store(self.temp.name)
        bridge = TravelBridge(self.store, token_path='/unused')
        bridge._request = Mock(return_value=self.state(2, decision='accepted'))
        bridge.snapshot('a')
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0], 1)
        self.assertIsNone(self.store.claim())

    def test_decline_receipt_once_and_stable_decision_operation(self):
        self.bridge._request.side_effect = None
        self.bridge._request.return_value = {'snapshot': self.state(2, decision='declined')}
        self.bridge.respond('a', 'invite-1', 'decline', 'first')
        self.bridge.respond('a', 'invite-1', 'decline', 'retry')
        args = [call.args[1] for call in self.bridge._request.call_args_list]
        self.assertEqual(args[0]['operationID'], args[1]['operationID'])
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0], 1)
        self.assertEqual(self.store.claim()['user']['travelDecision'], 'declined')

    def test_concurrent_old_revision_cannot_replace_new_or_cross_conversation(self):
        with ThreadPoolExecutor(max_workers=4) as executor:
            list(executor.map(lambda revision: self.bridge._record('a', self.state(revision)), [9, 2, 8, 1, 10, 3]))
        self.assertEqual(self.bridge.cached('a')['revision'], 10)
        self.assertEqual(self.bridge._record('a', self.state(1))['revision'], 10)
        self.assertIsNone(self.bridge.cached('b'))
        self.error(503, self.bridge._record, 'b', self.state())
        self.error(503, self.bridge._record, 'a', dict(self.state(), revision=True))

    def test_malformed_success_envelope_never_returns_success(self):
        token = Path(self.temp.name) / 'envelope-token'; token.write_text('s' * 40)
        bridge = TravelBridge(self.store, token_path=str(token))
        for payload in ({}, {'snapshot': None}, [], None, {'snapshot': []}):
            with self.subTest(payload=payload):
                response = io.BytesIO(json.dumps(payload).encode())
                opener = Mock(); opener.open.return_value = response
                with patch('travel_bridge.build_opener', return_value=opener):
                    self.error(503, bridge._request, '/tool', {'conversationID':'a'})
                self.assertEqual(opener.open.call_count, 1)
        self.assertIsNone(bridge.cached('a'))

    def test_malformed_error_json_becomes_bounded_api_error(self):
        token = Path(self.temp.name) / 'error-token'; token.write_text('s' * 40)
        bridge = TravelBridge(self.store, token_path=str(token))
        for payload in ([], None, 'not-an-object', 1):
            with self.subTest(payload=payload):
                failure = HTTPError(bridge.base+'/tool', 503, 'unavailable', {}, io.BytesIO(json.dumps(payload).encode()))
                opener = Mock(); opener.open.side_effect = failure
                with patch('travel_bridge.build_opener', return_value=opener):
                    self.error(503, bridge._request, '/tool', {'conversationID':'a'})
                self.assertEqual(opener.open.call_count, 1)
        self.assertIsNone(bridge.cached('a'))

    def test_http_error_snapshot_cannot_poison_other_conversation(self):
        token = Path(self.temp.name) / 'test-token'
        token.write_text('s' * 40)
        bridge = TravelBridge(self.store, token_path=str(token))
        payload = {'error': 'synthetic conflict', 'snapshot': self.state(99, conversation='b')}
        failure = HTTPError(bridge.base+'/tool', 409, 'conflict', {}, io.BytesIO(json.dumps(payload).encode()))
        opener = Mock(); opener.open.side_effect = failure
        with patch('travel_bridge.build_opener', return_value=opener):
            self.error(503, bridge._request, '/tool', {'conversationID':'a'})
        self.assertIsNone(bridge.cached('a'))
        self.assertIsNone(bridge.cached('b'))

    def test_internal_receipt_cannot_move_or_accept(self):
        self.bridge._queue_invitation_result('a', self.state(2, decision='accepted'))
        job = self.store.claim()
        for tool, args in [('travel_move', {'action':'walk'}), ('travel_journey', {'action':'start'})]:
            self.error(403, self.bridge.tool, 'a', job['message'], 'turn', 'call', tool, args)
        self.error(403, self.bridge.tool, 'b', job['message'], 'turn', 'call', 'travel_journey', {'action':'status'})
        self.bridge._request.assert_not_called()
        self.store.accept({'id':'user-origin','conversationID':'a','text':'fixture'})
        for action in ('accept','decline'):
            self.error(400, self.bridge.tool, 'a', 'user-origin', 'turn', 'call', 'travel_journey', {'action':action})
        self.bridge._request.assert_not_called()
        journey = next(x for x in TRAVEL_TOOLS if x['name'] == 'travel_journey')
        self.assertNotIn('accept', journey['inputSchema']['properties']['action']['enum'])
        self.assertNotIn('decline', journey['inputSchema']['properties']['action']['enum'])


class TravelHTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(self.temp.name)
        self.store.create_conversation('a'); self.store.create_conversation('b')
        self.store.accept({'id':'origin', 'conversationID':'a', 'text':'synthetic'})
        self.store.claim(); self.store.bind_turn('origin', 'turn')
        self.runtime = CodexRuntime(self.store, self.temp.name)
        self.runtime.active = {'conversation':'a', 'message':'origin', 'thread':'thread', 'turn':'turn', 'cancel':threading.Event()}
        self.app = QuietApplication(self.store, TOKEN, self.runtime)
        self.app.travel.token_path = '/unused'
        self.network = Mock(return_value={'snapshot': {'conversationID':'a', 'revision':1, 'invitation':None, 'journey':None}})
        self.app.travel._request = self.network
        self.server = ThreadingHTTPServer(('127.0.0.1',0), self.app.handler())
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True); self.thread.start()
        self.base = 'http://127.0.0.1:'+str(self.server.server_port)

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.app.close(); self.store.close(); self.temp.cleanup()

    def http(self, path, body=None, auth=True):
        req = Request(self.base+path, data=json.dumps(body).encode() if body is not None else None,
                      headers={'Content-Type':'application/json', 'Authorization':'Bearer '+(TOKEN if auth else 'wrong')})
        try:
            with build_opener(ProxyHandler({})).open(req, timeout=3) as response:
                return response.status, json.loads(response.read())
        except HTTPError as error:
            return error.code, json.loads(error.read())

    def test_owner_auth_and_strict_input_validation(self):
        endpoint = '/v1/travel/invitations/invite-1/respond'
        valid = {'conversationID':'a', 'decision':'accept', 'requestID':'req'}
        self.assertEqual(self.http(endpoint, valid, False)[0], 401)
        self.assertEqual(self.http('/v1/travel?conversationID=a', auth=False)[0], 401)
        for query in ('', '?conversationID=a&conversationID=b', '?conversationID=a&extra=x'):
            self.assertEqual(self.http('/v1/travel'+query)[0], 400)
        for body in ({}, [], dict(valid, extra=True), dict(valid, decision='accepted'), dict(valid, decision=[]), dict(valid, requestID='a/b')):
            self.assertEqual(self.http(endpoint, body)[0], 400)
        self.assertEqual(self.http('/v1/travel/control', {'conversationID':'a','journeyID':'j','requestID':'r','action':'walk'})[0],400)
        self.network.assert_not_called()
        self.assertEqual(self.http(endpoint, valid)[0], 200)
        self.assertEqual(self.network.call_args.args[0], '/invitation')

    def test_actual_active_matching_mcp_permit_required(self):
        args = {'action':'status'}
        with patch('runtime.MCP_EVENT_WAIT', 0.01):
            with self.assertRaises(APIError): self.runtime.mcp_file_call('a','travel_journey',args)
            self.runtime.file_permits.append({'conversation':'a','turn':'old','call':'old','tool':'travel_journey','arguments':args,'used':False})
            with self.assertRaises(APIError): self.runtime.mcp_file_call('a','travel_journey',args)
            with self.assertRaises(APIError): self.runtime.mcp_file_call('b','travel_journey',args)
        self.network.assert_not_called()
        self.runtime.file_permits.append({'conversation':'a','turn':'turn','call':'real-event','tool':'travel_journey','arguments':args,'used':False})
        self.runtime.mcp_file_call('a','travel_journey',args)
        self.assertEqual(self.network.call_args.args[1]['operationID'],'a:origin:turn:real-event')
        self.runtime.active['cancel'].set()
        with self.assertRaises(APIError): self.runtime.mcp_file_call('a','travel_journey',args)
        self.assertEqual(self.network.call_count, 1)

    def test_service_redirect_never_reaches_target(self):
        seen = []
        class RedirectService(BaseHTTPRequestHandler):
            def do_GET(handler):
                seen.append(handler.path)
                handler.send_response(302)
                handler.send_header('Location', '/must-not-follow')
                handler.end_headers()
            def log_message(self, *args):
                pass
        service = ThreadingHTTPServer(('127.0.0.1', 0), RedirectService)
        thread = threading.Thread(target=service.serve_forever, daemon=True); thread.start()
        token = Path(self.temp.name) / 'redirect-token'; token.write_text('s' * 40)
        bridge = TravelBridge(self.store, token_path=str(token), base='http://127.0.0.1:'+str(service.server_port))
        try:
            with self.assertRaises(APIError) as caught:
                bridge._request('/state?conversationID=a', timeout=2)
            self.assertEqual(caught.exception.status, 503)
            self.assertEqual(seen, ['/state?conversationID=a'])
        finally:
            service.shutdown(); service.server_close()

    def test_service_error_not_reported_as_success(self):
        self.network.side_effect = APIError(503, 'synthetic unknown outcome')
        code, result = self.http('/v1/travel/invitations/invite-1/respond', {'conversationID':'a','decision':'accept','requestID':'req'})
        self.assertEqual(code, 503)
        self.assertNotIn('snapshot', result)
        self.assertEqual(self.network.call_count, 1)
        self.assertEqual(self.store.db.execute("SELECT count(*) FROM jobs WHERE message LIKE 'travel-event-%'").fetchone()[0], 0)


if __name__ == '__main__':
    unittest.main()
