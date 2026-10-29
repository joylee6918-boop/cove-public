"""Authenticated media/PTY route contract with a fake protocol, never live audio/model."""
import base64
import json
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from cove import Application
from realtime import RealtimeBridge
from storage import Store


class FakeMediaRuntime(RealtimeBridge):
    def __init__(self, store, workspace):
        self.store, self.workspace = store, workspace
        self.shell_console = None
        self.calls = []
        self.process_events = {}
        self.process_lock = threading.Lock()
        self.process = type('Alive', (), {'poll': lambda _: None})()
        self.init_realtime()

    def request(self, method, params, timeout=30):
        self.calls.append((method, params))
        if method == 'thread/realtime/listVoices':
            return {'voices': {'v1': ['cove'], 'v2': ['marin'], 'defaultV1': 'cove', 'defaultV2': 'marin'}}
        if method == 'thread/realtime/start':
            self._realtime_notification({'method': 'thread/realtime/started', 'params': {
                'threadId': params['threadId'], 'realtimeSessionId': params['realtimeSessionId'], 'version': 'v3'}})
        if method == 'command/exec':
            with self.process_lock:
                event = self.process_events.setdefault(params['processId'], threading.Event())
            event.wait(30)
            return {'exitCode': 0}
        if method == 'command/exec/terminate':
            with self.process_lock:
                self.process_events.setdefault(params['processId'], threading.Event()).set()
        return {}

    def ensure_started(self):
        pass

    def start_voice_conversation(self, conversation, voice='cove', transport=None):
        return self.realtime_start(self.store.conversation(conversation)['thread'], voice, transport)

    def close(self):
        if self.shell_console:
            self.shell_console.close()
        with self.process_lock:
            for event in self.process_events.values(): event.set()
        self.realtime_disconnect()


class MediaRoutesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(self.temp.name)
        for name in ('a', 'b'):
            self.store.create_conversation(name)
            self.store.bind_thread(name, 'thread-' + name)
        self.runtime = FakeMediaRuntime(self.store, self.temp.name)
        self.token = 'synthetic-owner-token-not-production'
        self.app = Application(self.store, self.token, self.runtime)
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), self.app.handler())
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = 'http://127.0.0.1:' + str(self.server.server_port)

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join()
        self.app.close(); self.store.close(); self.temp.cleanup()

    def call(self, path, body=None, auth=True):
        headers = {'Content-Type': 'application/json'}
        if auth: headers['Authorization'] = 'Bearer ' + self.token
        request = Request(self.base + path, data=None if body is None else json.dumps(body).encode(), headers=headers)
        try:
            with urlopen(request, timeout=5) as response:
                return response.status, json.loads(response.read())
        except HTTPError as error:
            return error.code, json.loads(error.read())

    def test_realtime_auth_scope_format_and_restart(self):
        self.assertEqual(self.call('/v1/realtime/start', {'conversationID': 'a'}, auth=False)[0], 401)
        self.assertEqual(self.runtime.calls, [])
        code, started = self.call('/v1/realtime/start', {'conversationID': 'a'})
        self.assertEqual(code, 200)
        key = {'conversationID': 'a', 'sessionID': started['sessionID']}
        code, events = self.call('/v1/realtime/events?' + urlencode(dict(key, after=0)))
        self.assertEqual(code, 200)
        self.assertEqual(events['events'][0]['method'], 'thread/realtime/started')
        audio = {'data': base64.b64encode(b'\0\0' * 160).decode(), 'sampleRate': 16000, 'numChannels': 1, 'samplesPerChannel': 160}
        self.assertEqual(self.call('/v1/realtime/audio', dict(key, audio=audio))[0], 200)
        self.assertEqual(self.call('/v1/realtime/audio', dict(audio=dict(audio, sampleRate=True), **key))[0], 400)
        self.assertEqual(self.call('/v1/realtime/stop', dict(conversationID='b', **key))[0], 409)
        self.assertEqual(self.call('/v1/realtime/stop', key)[0], 200)
        code, second = self.call('/v1/realtime/start', {'conversationID': 'a'})
        self.assertEqual(code, 200)
        self.assertNotEqual(second['sessionID'], key['sessionID'])
        self.assertEqual(self.call('/v1/realtime/stop', key)[0], 409)
        self.assertEqual(self.call('/v1/realtime/stop', dict(key, sessionID=second['sessionID']))[0], 200)

    def test_realtime_webrtc_sdp_is_bounded_and_forwarded(self):
        offer = 'v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\n'
        code, started = self.call('/v1/realtime/start', {'conversationID': 'a', 'sdp': offer})
        self.assertEqual(code, 200)
        start = next(params for method, params in self.runtime.calls if method == 'thread/realtime/start')
        self.assertEqual(start['transport'], {'type': 'webrtc', 'sdp': offer})
        key = {'conversationID': 'a', 'sessionID': started['sessionID']}
        self.assertEqual(self.call('/v1/realtime/stop', key)[0], 200)
        self.assertEqual(self.call('/v1/realtime/start', {'conversationID': 'a', 'sdp': 'not-sdp'})[0], 400)

    def test_shell_routes_reject_permission_injection_and_other_conversation(self):
        self.assertEqual(self.call('/v1/shell/start', {'conversationID': 'a'}, auth=False)[0], 401)
        self.assertEqual(self.call('/v1/shell/start', {'conversationID': 'a', 'sandboxPolicy': 'danger-full-access'})[0], 400)
        code, shell = self.call('/v1/shell/start', {'conversationID': 'a', 'rows': 24, 'cols': 80})
        self.assertEqual(code, 200)
        key = {'conversationID': 'a', 'sessionID': shell['id']}
        code, interrupted = self.call('/v1/shell/write', dict(key, dataBase64='Aw==', closeStdin=False))
        self.assertEqual(code, 200)
        self.assertTrue(interrupted['restarted'])
        self.assertEqual(self.call('/v1/shell/write', dict(key, dataBase64=base64.b64encode(b'printf ready\n').decode(), closeStdin=False))[0], 200)
        self.assertEqual(self.call('/v1/shell/write', dict(dataBase64='Aw==', closeStdin='yes', **key))[0], 400)
        self.assertEqual(self.call('/v1/shell/events?' + urlencode(dict(conversationID='b', **key)))[0], 404)
        self.assertEqual(self.call('/v1/shell/terminate', key)[0], 200)


if __name__ == '__main__': unittest.main()
