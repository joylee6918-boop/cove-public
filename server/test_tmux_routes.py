"""Owner HTTP bridge tests. Only fake transports and temporary Cove storage."""
import json
import tempfile
import threading
import unittest
import uuid
from http.server import ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from cove import Application
from storage import Store
from tmux_console import TmuxConsole
from test_tmux_console import FakeTransport


class TmuxRouteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        directory = Path(self.temp.name).resolve()
        directory.chmod(0o700)
        self.store = Store(directory)
        self.store.create_conversation('a')
        self.store.create_conversation('b')
        self.store.bind_thread('a', 'thread-a')
        self.console = TmuxConsole(directory, lock=threading.RLock(), before_control=lambda *args: None)
        self.transport = FakeTransport('a', 'thread-a')
        self.session = str(uuid.uuid4())
        self.console.register(self.session, self.transport)
        self.runtime = SimpleNamespace(tmux_console=self.console, close=self.console.close)
        self.token = 'test-only-cove-owner-auth-123456789'
        self.app = Application(self.store, self.token, self.runtime)
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), self.app.handler())
        self.worker = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.worker.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.app.close()
        self.store.close()
        self.temp.cleanup()

    def request(self, method, path, body=None, auth=True):
        headers = {'Content-Type': 'application/json'}
        if auth:
            headers['Authorization'] = 'Bearer ' + self.token
        req = Request('http://127.0.0.1:' + str(self.server.server_port) + path,
                      data=None if body is None else json.dumps(body).encode(), headers=headers, method=method)
        try:
            with urlopen(req, timeout=3) as response:
                return response.status, json.loads(response.read())
        except HTTPError as error:
            return error.code, json.loads(error.read())

    def control(self, operation, **extras):
        return self.request('POST', '/v1/tmux/' + operation, dict(
            conversationID='a', sessionID=self.session, requestID=str(uuid.uuid4()), **extras))

    def test_owner_auth_attach_capture_literal_and_explicit_kill(self):
        self.assertEqual(self.request('POST', '/v1/tmux/attach', {'conversationID': 'a'}, auth=False)[0], 401)
        code, result = self.request('POST', '/v1/tmux/attach', {'conversationID': 'a'})
        self.assertEqual(code, 200)
        self.assertEqual(result['sessionID'], self.session)
        self.assertEqual(self.control('input', text='literal ; $(not-a-shell)')[0], 200)
        self.assertEqual(self.control('key', key='Enter')[0], 200)
        self.assertIn(('send_text', 'literal ; $(not-a-shell)'), self.transport.calls)
        self.assertEqual(self.request('GET', '/v1/tmux/capture?conversationID=a&sessionID=' + self.session)[0], 200)
        self.assertNotIn(('terminate',), self.transport.calls)
        self.assertEqual(self.control('terminate')[0], 200)
        self.assertIn(('terminate',), self.transport.calls)

    def test_wrong_conversation_or_thread_never_controls(self):
        body = dict(conversationID='b', sessionID=self.session, requestID=str(uuid.uuid4()), key='Enter')
        self.assertEqual(self.request('POST', '/v1/tmux/key', body)[0], 404)
        self.store.bind_thread('a', 'replacement-thread')
        self.assertEqual(self.control('key', key='Enter')[0], 409)
        self.assertFalse(any(c[0] == 'send_special' for c in self.transport.calls))

    def test_strict_routes_and_parameters(self):
        self.assertEqual(self.request('GET', '/v1/tmux/capture?conversationID=a&conversationID=b&sessionID=' + self.session)[0], 400)
        self.assertEqual(self.request('POST', '/v1/tmux/attach?extra=1', {'conversationID': 'a'})[0], 400)
        self.assertEqual(self.request('POST', '/v1/tmux/wrong/attach', {'conversationID': 'a'})[0], 404)
        self.assertEqual(self.request('POST', '/v1/tmux/attach', {'conversationID': 'a', 'command': '/bin/sh'})[0], 400)
        self.assertEqual(self.control('input', text='line\ncommand')[0], 400)
        self.assertEqual(self.control('key', key='run-shell')[0], 400)

    def test_old_runtime_fails_closed_without_shell_fallback(self):
        self.runtime.tmux_console = None
        self.assertEqual(self.request('POST', '/v1/tmux/attach', {'conversationID': 'a'})[0], 503)
        self.assertEqual(self.transport.calls, [('attach',)])


if __name__ == '__main__':
    unittest.main()
