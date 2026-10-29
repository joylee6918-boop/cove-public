"""Real temporary Store + rollout reader, synthetic native CLI/MCP only."""
import json
import tempfile
import threading
import time
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

from storage import Store, APIError
from tmux_runtime import TmuxRuntime


class Session:
    def __init__(self, path):
        self.conversation_id, self.thread_id = 'conversation', 'native-thread'
        self.path, self.calls = path, []
        self.auto_complete = True
        self.fail_send = False

    def attach_existing(self):
        self.calls.append(('attach',))

    def send_text(self, text):
        self.calls.append(('text', text))
        if self.fail_send:
            raise RuntimeError('uncertain send')

    def append(self, kind, payload):
        with self.path.open('a') as stream:
            stream.write(json.dumps({'type': kind, 'payload': payload}) + '\n')

    def send_special(self, key):
        self.calls.append(('key', key))
        if key == 'Enter':
            self.append('event_msg', {'type': 'task_started', 'turn_id': 'native-turn'})
            if self.auto_complete:
                self.finish()

    def finish(self):
        self.append('response_item', {'type': 'message', 'role': 'assistant', 'phase': 'final_answer',
                                     'content': [{'type': 'output_text', 'text': 'synthetic reply'}]})
        self.append('event_msg', {'type': 'task_complete', 'turn_id': 'native-turn'})

    def capture(self, **kwargs):
        return 'synthetic terminal screen'

    def terminate_bound(self):
        self.calls.append(('terminate',))

    def detach(self):
        self.calls.append(('detach',))


class Provider:
    def __init__(self, session):
        self.session = session
        self.session_id = str(uuid.uuid4())
        self.state = 'ready'
        self.message = None

    def ensure(self, conversation):
        if self.state != 'ready':
            raise RuntimeError('quarantined')
        return {'sessionID': self.session_id, 'threadID': self.session.thread_id,
                'rolloutPath': self.session.path, 'transport': self.session}

    def inspect(self, conversation):
        return {'sessionID': self.session_id, 'threadID': self.session.thread_id,
                'rolloutPath': self.session.path, 'transport': self.session}

    def begin_dispatch(self, conversation, message):
        if self.state != 'ready':
            raise RuntimeError('not ready')
        self.state, self.message = 'busy', message

    def finish_dispatch(self, conversation, message):
        assert self.state == 'busy' and message == self.message
        self.state = 'ready'

    def quarantine(self, conversation, reason):
        self.state = 'quarantined'

    def close(self):
        self.session.detach()


class TmuxRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.store = Store(self.root / 'data')
        self.store.create_conversation('conversation')
        self.store.bind_thread('conversation', 'native-thread')
        self.home = self.root / 'codex'
        (self.home / 'sessions').mkdir(parents=True)
        self.path = self.home / 'sessions' / 'native.jsonl'
        self.path.write_text('')
        self.session = Session(self.path)
        self.provider = Provider(self.session)
        self.runtime = TmuxRuntime(self.store, self.root, session_provider=self.provider,
                                   codex_home=self.home, timeout=3)
        self.cancelled = threading.Event()
        self.thread = None

    def tearDown(self):
        self.cancelled.set()
        if self.thread:
            self.thread.join(3)
        self.runtime.close()
        self.store.close()
        self.temp.cleanup()

    def job(self, text='hello\nsecond line'):
        self.store.accept({'id': str(uuid.uuid4()), 'conversationID': 'conversation', 'text': text})
        return self.store.claim()

    def begin(self):
        self.session.auto_complete = False
        self.current = self.job()
        self.result = []
        self.errors = []
        def run():
            try:
                self.result.append(self.runtime.run(self.current, self.cancelled))
            except Exception as error:
                self.errors.append(error)
        self.thread = threading.Thread(target=run)
        self.thread.start()
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            with self.runtime.state_lock:
                if self.runtime.active and self.runtime.active['turn']:
                    return
            time.sleep(.005)
        self.fail('native task did not bind')

    def metadata(self, turn='native-turn'):
        return {'callId': 'native-call', 'threadId': 'native-thread',
                'x-codex-turn-metadata': {'thread_id': 'native-thread', 'turn_id': turn}}

    def test_text_dispatch_native_completion_and_shared_terminal(self):
        job = self.job()
        self.assertEqual(self.runtime.run(job, self.cancelled), ('complete', None))
        sent = next(call[1] for call in self.session.calls if call[0] == 'text')
        self.assertNotIn('\n', sent)
        self.assertIn('hello\\nsecond line', sent)
        self.assertEqual(self.session.calls.count(('key', 'Enter')), 1)
        self.assertEqual(self.store._message(job['assistant'])['text'], 'synthetic reply')
        screen = self.runtime.tmux_console.attach('conversation')
        self.assertEqual(screen['threadID'], 'native-thread')
        self.assertEqual(screen['output'], 'synthetic terminal screen')
        self.assertEqual(self.provider.state, 'ready')

    def test_application_worker_delivers_reply_and_terminal_uses_same_thread(self):
        from cove import Application
        self.store.accept({'id': 'queued-native-job', 'conversationID': 'conversation', 'text': 'synthetic'})
        app = Application(self.store, 'synthetic-owner-token-long-enough', self.runtime)
        try:
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                result = self.store.poll('conversation', 0)
                if not result['busy']:
                    break
                time.sleep(.01)
            self.assertFalse(result['busy'])
            replies = [m for m in result['messages'] if m['role'] == 'assistant']
            self.assertEqual(replies[0]['status'], 'complete')
            self.assertEqual(replies[0]['text'], 'synthetic reply')
            screen = app.tmux_request('attach', {'conversationID': 'conversation'})
            self.assertEqual(screen['threadID'], 'native-thread')
            self.assertEqual(self.session.calls.count(('key', 'Enter')), 1)
        finally:
            app.close()

    def test_phase_null_uses_only_matching_native_completion_final(self):
        def finish():
            self.session.append('response_item', {'type': 'message', 'role': 'assistant', 'phase': None,
                                'content': [{'type': 'output_text', 'text': 'not authoritative yet'}]})
            self.session.append('event_msg', {'type': 'task_complete', 'turn_id': 'native-turn',
                                             'last_agent_message': 'native final receipt'})
        self.session.finish = finish
        job = self.job()
        self.assertEqual(self.runtime.run(job, self.cancelled), ('complete', None))
        self.assertEqual(self.store._message(job['assistant'])['text'], 'native final receipt')

    def test_private_native_health_call_and_stale_turn_rejected(self):
        self.store.set_data_access({'enabled': True})
        self.begin()
        with self.assertRaises(APIError):
            self.runtime.mcp_file_call_native('conversation', 'cove_read_health', {}, self.metadata('old-turn'), 1)
        result = self.runtime.mcp_file_call_native('conversation', 'cove_read_health', {}, self.metadata(), 2)
        self.assertEqual(result['source'], 'cove-health')
        self.assertFalse(result['available'])
        self.assertEqual(self.runtime.file_permits, [])
        self.session.finish()
        self.thread.join(2)
        self.assertEqual(self.result, [('complete', None)])
        with self.assertRaises(APIError):
            self.runtime.mcp_file_call_native('conversation', 'cove_read_health', {}, self.metadata(), 3)

    def test_native_voice_uses_existing_executor_and_exact_active_message(self):
        self.begin()
        with patch('voice_tools.synthesize_once', return_value=(b'synthetic-audio', 'audio/mpeg')) as synthesize:
            result = self.runtime.mcp_file_call_native('conversation', 'cove_send_voice',
                                                      {'text': 'synthetic voice'}, self.metadata(), 1)
            synthesize.assert_called_once()
        self.assertTrue(result)
        files = self.store._message(self.current['assistant'])['attachments']
        self.assertEqual(len(files), 1)
        self.assertEqual(self.store.attachment(files[0]['id'])['data'], b'synthetic-audio')
        self.session.finish()
        self.thread.join(2)

    def test_unknown_dispatch_not_replayed_and_timeout_not_complete(self):
        self.session.fail_send = True
        job = self.job()
        with self.assertRaises(RuntimeError):
            self.runtime.run(job, self.cancelled)
        self.assertEqual(self.provider.state, 'quarantined')
        with self.assertRaises(RuntimeError):
            self.runtime.run(job, threading.Event())
        self.assertEqual(len([c for c in self.session.calls if c[0] == 'text']), 1)

    def test_timeout_quarantines_and_requests_interrupt_without_replay(self):
        self.session.auto_complete = False
        self.runtime.timeout = .05
        with self.assertRaises(APIError) as caught:
            self.runtime.run(self.job(), self.cancelled)
        self.assertEqual(caught.exception.status, 504)
        self.assertEqual(self.provider.state, 'quarantined')
        self.assertEqual(self.session.calls.count(('key', 'Enter')), 1)
        self.assertEqual(self.session.calls.count(('key', 'C-c')), 1)

    def test_owner_force_exit_cancels_before_late_health_call(self):
        self.store.set_data_access({'enabled': True})
        self.begin()
        self.runtime.tmux_console.control('conversation', self.provider.session_id,
                                          str(uuid.uuid4()), 'terminate')
        self.assertTrue(self.cancelled.is_set())
        self.assertIn(('terminate',), self.session.calls)
        with self.assertRaises(APIError):
            self.runtime.mcp_file_call_native('conversation', 'cove_read_health', {}, self.metadata(), 1)
        self.thread.join(2)
        self.assertEqual(self.result[0][0], 'interrupted')
        self.assertEqual(self.provider.state, 'quarantined')

    def test_cancel_during_session_setup_does_not_dispatch(self):
        ensure = self.provider.ensure
        def cancelled_ensure(conversation):
            self.cancelled.set()
            return ensure(conversation)
        self.provider.ensure = cancelled_ensure
        self.assertEqual(self.runtime.run(self.job(), self.cancelled)[0], 'interrupted')
        self.assertFalse(any(c[0] == 'text' for c in self.session.calls))
        self.assertEqual(self.provider.state, 'ready')

    def test_cancel_after_text_never_submits_enter_and_clears_once(self):
        send = self.session.send_text
        def cancelled_text(text):
            send(text)
            self.cancelled.set()
        self.session.send_text = cancelled_text
        self.assertEqual(self.runtime.run(self.job(), self.cancelled)[0], 'interrupted')
        self.assertNotIn(('key', 'Enter'), self.session.calls)
        self.assertEqual(self.session.calls.count(('key', 'C-c')), 1)
        self.assertEqual(self.provider.state, 'quarantined')

    def test_cancel_after_enter_cannot_lose_interrupt_when_active_clears(self):
        send = self.session.send_special
        def cancelled_enter(key):
            send(key)
            if key == 'Enter':
                self.cancelled.set()
        self.session.send_special = cancelled_enter
        self.assertEqual(self.runtime.run(self.job(), self.cancelled)[0], 'interrupted')
        self.runtime.interrupt('conversation', self.cancelled)
        self.assertEqual(self.session.calls.count(('key', 'C-c')), 1)
        self.assertEqual(self.provider.state, 'quarantined')

    def test_active_turn_is_not_permission_to_queue_untracked_terminal_input(self):
        self.begin()
        before = len(self.session.calls)
        snapshot = self.runtime.tmux_console.attach('conversation')
        self.assertFalse(snapshot['inputAvailable'])
        self.assertEqual(snapshot['allowedKeys'], ['C-c'])
        with self.assertRaises(APIError):
            self.runtime.tmux_console.control('conversation', self.provider.session_id,
                                              str(uuid.uuid4()), 'key', 'Enter')
        self.assertEqual(len(self.session.calls), before)
        self.session.finish()
        self.thread.join(2)

    def test_incomplete_projection_never_completes_or_replays(self):
        self.begin()
        with self.path.open('a') as stream:
            stream.write(json.dumps({'type': 'response_item', 'payload': {'type': 'reasoning', 'text': 'x' * 70000}}) + '\n')
        self.session.finish()
        # Run in this test thread to capture the expected projection exception.
        self.thread.join(2)
        self.assertEqual(self.result, [])
        self.assertEqual(len(self.errors), 1)
        self.assertIsInstance(self.errors[0], APIError)
        self.assertEqual(self.provider.state, 'quarantined')

    def test_legacy_mcp_and_unimplemented_capabilities_fail_explicitly(self):
        with self.assertRaises(APIError):
            self.runtime.mcp_file_call('conversation', 'cove_send_voice', {'text': 'not permitted'})
        with self.assertRaises(APIError):
            self.runtime._cli_text([{'type': 'text', 'text': 'hi'}, {'type': 'image', 'url': 'data:image/png;base64,eA=='}])
        with self.assertRaises(APIError):
            self.runtime.start_voice_conversation('conversation')
        self.assertIsNone(self.runtime.process)

    def test_changed_model_is_not_silently_ignored(self):
        self.store.set_terminal_model('conversation', 'different-model', 'low')
        with self.assertRaises(APIError):
            self.runtime.run(self.job(), self.cancelled)
        self.assertEqual(self.session.calls, [])

    def test_shutdown_detaches_without_killing_or_replaying(self):
        self.begin()
        self.runtime.close()
        self.thread.join(2)
        self.assertEqual(self.result[0][0], 'interrupted')
        self.assertNotIn(('terminate',), self.session.calls)
        self.assertEqual(self.provider.state, 'quarantined')

    def test_configured_runtime_requires_explicit_known_mode(self):
        from cove import configured_runtime
        with patch.dict('os.environ', {'COVE_RUNTIME': 'not-a-mode'}):
            with self.assertRaises(ValueError):
                configured_runtime(self.store, self.root)
        with patch.dict('os.environ', {'COVE_RUNTIME': 'tmux', 'COVE_CODEX_BINARY': ''}):
            with self.assertRaises(ValueError):
                configured_runtime(self.store, self.root)
        self.assertIsNone(self.runtime.process)


if __name__ == '__main__':
    unittest.main()
