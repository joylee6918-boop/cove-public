"""Synthetic transport tests; no real tmux, Codex, network, or user session."""

import tempfile
import threading
import unittest
import uuid
from pathlib import Path

from storage import APIError
from tmux_console import TmuxConsole
from tmux_session import TmuxSessionError


class FakeTransport:
    def __init__(self, conversation='conversation-a', thread='thread-a'):
        self.conversation_id = conversation
        self.thread_id = thread
        self.calls = []
        self.screen = 'prompt'
        self.capture_error = False
        self.send_error = False

    def attach_existing(self):
        self.calls.append(('attach',))

    def capture(self, *, max_lines, max_bytes):
        self.calls.append(('capture', max_lines, max_bytes))
        if self.capture_error:
            raise TmuxSessionError('unavailable')
        return self.screen

    def send_text(self, value):
        self.calls.append(('send_text', value))
        if self.send_error:
            raise TmuxSessionError('uncertain send')

    def send_special(self, value):
        self.calls.append(('send_special', value))
        if self.send_error:
            raise TmuxSessionError('uncertain send')

    def detach(self):
        self.calls.append(('detach',))

    def terminate_bound(self):
        self.calls.append(('terminate',))


class ConsoleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name).resolve()
        self.directory.chmod(0o700)
        self.lock = threading.RLock()
        self.gate_calls = []
        self.deny = False

        def gate(*args):
            self.gate_calls.append(args)
            if self.deny:
                raise RuntimeError('dispatch gate closed')

        self.gate = gate
        self.console = TmuxConsole(self.directory, lock=self.lock, before_control=self.gate)
        self.session = str(uuid.uuid4())
        self.transport = FakeTransport()
        self.console.register(self.session, self.transport)

    def tearDown(self):
        if self.console is not None:
            self.console.close()
        self.temp.cleanup()

    def request(self):
        return str(uuid.uuid4())

    def test_binding_wrong_conversation_and_second_thread_rejected(self):
        self.assertEqual(self.transport.calls, [('attach',)])
        with self.assertRaises(APIError) as caught:
            self.console.capture('conversation-b', self.session)
        self.assertEqual(caught.exception.status, 404)
        with self.assertRaises(APIError) as caught:
            self.console.control('conversation-b', self.session, self.request(), 'input', 'text')
        self.assertEqual(caught.exception.status, 404)
        with self.assertRaises(ValueError):
            self.console.register(str(uuid.uuid4()), FakeTransport('conversation-a', 'wrong-thread'))
        # Only the original bound thread is disclosed by a successful capture.
        self.assertEqual(self.console.capture('conversation-a', self.session)['threadID'], 'thread-a')

    def test_attach_only_existing_registered_pane_no_creation(self):
        self.assertEqual(self.console.attach('conversation-a')['sessionID'], self.session)
        self.assertEqual(self.transport.calls[0], ('attach',))
        self.assertTrue(any(call[0] == 'capture' for call in self.transport.calls))
        with self.assertRaises(APIError) as caught:
            self.console.attach('conversation-b')
        self.assertEqual(caught.exception.status, 409)
        self.assertFalse(any(call[0] in ('send_text', 'send_special', 'terminate') for call in self.transport.calls))

    def test_unavailable_capture_preserves_id_for_explicit_force_exit(self):
        self.transport.capture_error = True
        result = self.console.capture('conversation-a', self.session)
        self.assertEqual((result['sessionID'], result['state']), (self.session, 'unavailable'))
        self.assertEqual(self.console.control('conversation-a', self.session,
                                              self.request(), 'terminate'),
                         {'ok': True, 'duplicate': False})
        self.assertIn(('terminate',), self.transport.calls)
        self.assertEqual(self.console.capture('conversation-a', self.session)['state'], 'terminated')

    def test_close_detaches_and_only_explicit_terminate_kills(self):
        self.console.close()
        self.console = None
        self.assertEqual(self.transport.calls, [('attach',), ('detach',)])

    def test_restart_restores_only_exact_termination_ack_without_touching_pane(self):
        self.console.control('conversation-a', self.session, self.request(), 'terminate')
        self.console.close()
        self.console = TmuxConsole(self.directory, lock=self.lock, before_control=self.gate)
        replacement = FakeTransport()
        self.console.restore_terminated(self.session, replacement)
        self.assertEqual(self.console.attach('conversation-a')['state'], 'terminated')
        self.assertFalse(self.console.attach('conversation-a')['inputAvailable'])
        self.assertEqual(replacement.calls, [])
        with self.assertRaises(APIError):
            self.console.control('conversation-a', self.session, self.request(), 'input', 'not sent')
        with self.assertRaises(APIError):
            self.console.restore_terminated(self.session, FakeTransport(thread='other-thread'))

    def test_unknown_termination_never_rehydrated_as_success(self):
        with self.assertRaises(APIError):
            self.console.restore_terminated(str(uuid.uuid4()), FakeTransport())
        self.assertFalse(self.console.termination_recorded('conversation-a', self.session, 'thread-a'))

    def test_successful_duplicate_id_not_resent_and_conflict_rejected(self):
        request = self.request()
        self.assertEqual(self.console.control('conversation-a', self.session, request, 'input', 'hello'),
                         {'ok': True, 'duplicate': False})
        self.assertEqual(self.console.control('conversation-a', self.session, request, 'input', 'hello'),
                         {'ok': True, 'duplicate': True})
        self.assertEqual(self.transport.calls.count(('send_text', 'hello')), 1)
        with self.assertRaises(APIError) as caught:
            self.console.control('conversation-a', self.session, request, 'input', 'changed')
        self.assertEqual(caught.exception.status, 409)
        self.assertEqual(len(self.gate_calls), 1)

    def test_unknown_send_is_not_retried_even_after_new_console(self):
        request = self.request()
        self.transport.send_error = True
        with self.assertRaises(APIError) as caught:
            self.console.control('conversation-a', self.session, request, 'input', 'hello')
        self.assertEqual(caught.exception.status, 503)
        with self.assertRaises(APIError) as caught:
            self.console.control('conversation-a', self.session, request, 'input', 'hello')
        self.assertEqual(caught.exception.status, 409)
        self.assertEqual(self.transport.calls.count(('send_text', 'hello')), 1)
        self.console.close()
        self.console = TmuxConsole(self.directory, lock=self.lock, before_control=self.gate)
        self.transport.send_error = False
        self.console.register(self.session, self.transport)
        with self.assertRaises(APIError) as caught:
            self.console.control('conversation-a', self.session, request, 'input', 'hello')
        self.assertEqual(caught.exception.status, 409)
        self.assertEqual(self.transport.calls.count(('send_text', 'hello')), 1)

    def test_control_gate_denial_sends_nothing_and_consumes_id(self):
        self.deny = True
        request = self.request()
        with self.assertRaises(APIError) as caught:
            self.console.control('conversation-a', self.session, request, 'key', 'Enter')
        self.assertEqual(caught.exception.status, 503)
        self.assertEqual(self.gate_calls, [('conversation-a', self.session, 'key', 'Enter')])
        self.assertFalse(any(call[0].startswith('send_') for call in self.transport.calls))
        self.deny = False
        with self.assertRaises(APIError) as caught:
            self.console.control('conversation-a', self.session, request, 'key', 'Enter')
        self.assertEqual(caught.exception.status, 409)


if __name__ == '__main__':
    unittest.main()
