"""Real Store/registry/runtime wiring with a synthetic native rollout and pane.

No Codex process, paid provider, external MCP service, or network is involved.
"""
import json
import sqlite3
import sys
import tempfile
import threading
import time
import unittest
import uuid
from pathlib import Path

from storage import APIError, Store
from tmux_registry import TmuxRegistry
from tmux_runtime import TmuxRuntime


THREAD = 'synthetic-thread'
CONVERSATION = 'synthetic-conversation'


class Pane:
    def __init__(self, *, socket_path, session_name, conversation_id, thread_id,
                 workspace, owner_token, **_):
        self.socket_path = Path(socket_path)
        self.session_name = session_name
        self.conversation_id = conversation_id
        self.thread_id = thread_id
        self.workspace = str(Path(workspace).resolve())
        self.owner_token = owner_token
        self.pane_id = '%7'
        self.expected_command = Path(sys.executable).resolve().name
        self.attached = False
        self.calls = []

    def attach_existing(self):
        self.attached = True
        self.calls.append(('attach',))

    def _require_attached(self):
        if not self.attached:
            raise RuntimeError('detached')

    def _verify_identity(self):
        return self.pane_id, self.expected_command, '0'

    def send_text(self, text):
        self._require_attached()
        self.calls.append(('text', text))

    def send_special(self, key):
        self._require_attached()
        self.calls.append(('key', key))

    def capture(self, **_):
        self._require_attached()
        return 'synthetic pane'

    def terminate_bound(self):
        self.calls.append(('terminate',))

    def detach(self):
        self.attached = False
        self.calls.append(('detach',))


class InteractiveRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.store = Store(self.root / 'store')
        self.store.create_conversation(CONVERSATION)
        self.store.bind_thread(CONVERSATION, THREAD)
        self.home = self.root / 'codex'
        (self.home / 'sessions').mkdir(parents=True)
        self.rollout = self.home / 'sessions' / 'synthetic.jsonl'
        self.record('session_meta', id=THREAD)
        self.registry = TmuxRegistry(db_path=self.root / 'registry.sqlite3',
                                     codex_binary=sys.executable, codex_home=self.home,
                                     transport_factory=Pane)
        self.pane = Pane(socket_path=self.root / 'synthetic.sock', session_name=str(uuid.uuid4()),
                         conversation_id=CONVERSATION, thread_id=THREAD,
                         workspace=self.root, owner_token='synthetic-capability')
        self.registry.register_existing(self.store.conversation(CONVERSATION), self.pane, self.rollout)
        self.runtime = TmuxRuntime(self.store, self.root, session_provider=self.registry,
                                   codex_home=self.home, enable_terminal_input=True)
        self.runtime.attach_console(CONVERSATION)
        # inspect() reconstructs a diagnostic transport; the console owns it.
        self.pane = self.runtime.tmux_console.bindings[self.pane.session_name]['transport']

    def tearDown(self):
        self.runtime.close()
        self.store.close()

    def record(self, kind, **payload):
        with self.rollout.open('a') as stream:
            stream.write(json.dumps({'type': kind, 'payload': payload}) + '\n')

    def start(self, turn, text):
        self.record('event_msg', type='task_started', turn_id=turn)
        self.record('response_item', type='message', role='user',
                    content=[{'type': 'input_text', 'text': text}],
                    internal_chat_message_metadata_passthrough={
                        'turn_id': turn, 'content_item_kinds': ['user.text']})

    def complete(self, turn, answer='synthetic answer'):
        self.record('event_msg', type='task_complete', turn_id=turn,
                    last_agent_message=answer)

    def control(self, operation, value):
        return self.runtime.tmux_console.control(CONVERSATION, self.pane.session_name,
                                                  str(uuid.uuid4()), operation, value)

    def wait(self, predicate, timeout=3):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(.01)
        self.fail('synthetic observer did not reach expected state')

    def job(self, turn):
        with self.store.lock:
            return self.store.db.execute('SELECT * FROM jobs WHERE turn=?', (turn,)).fetchone()

    def test_raw_turn_and_next_turn_with_exact_native_messages(self):
        self.control('input', 'first')
        self.control('key', 'Enter')
        self.start('raw-1', 'first')
        self.complete('raw-1', 'one')
        self.wait(lambda: self.job('raw-1') is not None and self.job('raw-1')['state'] == 'complete')
        self.assertEqual(self.store._message(self.job('raw-1')['assistant'])['text'], 'one')
        self.assertEqual(self.registry.db.execute('SELECT state FROM bindings').fetchone()[0], 'ready')
        self.control('input', 'second')
        self.control('key', 'Enter')
        self.start('raw-2', 'second')
        self.complete('raw-2', 'two')
        self.wait(lambda: self.job('raw-2') is not None and self.job('raw-2')['state'] == 'complete')
        self.assertEqual([c for c in self.pane.calls if c[0] == 'text'],
                         [('text', 'first'), ('text', 'second')])
        self.assertIsNone(self.registry.db.execute('SELECT 1 FROM console_pending').fetchone())

    def test_native_tool_waits_for_verified_user_input_then_binds(self):
        self.store.set_data_access({'enabled': True})
        self.control('input', 'health please')
        self.control('key', 'Enter')
        self.record('event_msg', type='task_started', turn_id='raw-tool')
        self.wait(lambda: self.runtime.active is not None and self.runtime.active['turn'] == 'raw-tool')
        meta = {'callId': 'call-1', 'threadId': THREAD,
                'x-codex-turn-metadata': {'thread_id': THREAD, 'turn_id': 'raw-tool'}}
        result = []
        worker = threading.Thread(target=lambda: result.append(self.runtime.mcp_file_call_native(
            CONVERSATION, 'cove_read_health', {}, meta, 1)))
        worker.start()
        time.sleep(.1)
        self.assertTrue(worker.is_alive())
        self.record('response_item', type='message', role='user',
                    content=[{'type': 'input_text', 'text': 'health please'}],
                    internal_chat_message_metadata_passthrough={
                        'turn_id': 'raw-tool', 'content_item_kinds': ['user.text']})
        worker.join(3)
        self.assertFalse(worker.is_alive())
        self.assertEqual(len(result), 1)
        self.assertIsNotNone(self.job('raw-tool'))
        self.complete('raw-tool')
        self.wait(lambda: self.job('raw-tool')['state'] == 'complete')

    def test_interrupt_quarantines_and_close_stops_writer(self):
        self.control('input', 'interrupted')
        self.control('key', 'Enter')
        self.start('raw-stop', 'interrupted')
        self.wait(lambda: self.job('raw-stop') is not None)
        self.control('key', 'C-c')
        self.wait(lambda: self.registry.db.execute('SELECT state FROM bindings').fetchone()[0] == 'quarantine')
        self.assertIsNone(self.runtime.active)
        self.assertEqual(self.job('raw-stop')['state'], 'failed')
        self.runtime.close()
        self.complete('raw-stop', 'late')
        time.sleep(.08)
        self.assertEqual(self.job('raw-stop')['state'], 'failed')
        self.assertFalse(self.pane.attached)

    def test_queued_app_worker_cannot_claim_while_editor_or_raw_turn_owns_pane(self):
        self.store.accept({'id': 'queued-app', 'conversationID': CONVERSATION,
                           'text': 'app message'})
        self.control('input', 'owner text')
        self.assertIsNone(self.runtime.claim_job())
        self.control('key', 'Enter')
        self.start('raw-before-app', 'owner text')
        self.wait(lambda: self.job('raw-before-app') is not None)
        self.assertIsNone(self.runtime.claim_job())
        self.complete('raw-before-app')
        self.wait(lambda: self.job('raw-before-app')['state'] == 'complete')
        claimed = self.runtime.claim_job()
        self.assertEqual(claimed['message'], 'queued-app')

    def test_shutdown_fails_unfinished_native_writer_without_replay(self):
        self.control('input', 'in flight')
        self.control('key', 'Enter')
        self.start('raw-shutdown', 'in flight')
        self.wait(lambda: self.job('raw-shutdown') is not None)
        self.runtime.close()
        self.assertEqual(self.job('raw-shutdown')['state'], 'failed')
        self.assertIsNone(self.runtime.active)
        with sqlite3.connect(self.root / 'registry.sqlite3') as db:
            self.assertEqual(db.execute('SELECT state FROM bindings').fetchone()[0], 'busy')
        self.complete('raw-shutdown', 'too late')
        time.sleep(.08)
        self.assertEqual(self.job('raw-shutdown')['state'], 'failed')

    def test_local_slash_or_modal_enter_without_native_receipt_stays_fenced(self):
        # A /status-like local command and a modal Enter can consume keys
        # entirely inside the TUI. No rollout turn is proof of either result.
        self.store.accept({'id': 'behind-local', 'conversationID': CONVERSATION,
                           'text': 'queued app message'})
        self.control('input', '/status')
        self.control('key', 'Enter')
        self.assertIsNone(self.runtime.claim_job())
        self.control('key', 'Escape')
        self.assertIsNone(self.runtime.claim_job())
        self.control('key', 'Enter')
        self.assertIsNone(self.runtime.claim_job())
        self.assertEqual(self.runtime.interactive.states[CONVERSATION]['credits'], 2)
        # Even a later verified native turn consumes only its own credit; the
        # earlier local Enter cannot be inferred away from a quiet rollout.
        self.start('after-local', 'later owner text')
        self.complete('after-local')
        self.wait(lambda: self.job('after-local') is not None and self.job('after-local')['state'] == 'complete')
        self.assertIsNone(self.runtime.claim_job())
        self.assertEqual(self.runtime.interactive.states[CONVERSATION]['credits'], 1)


if __name__ == '__main__':
    unittest.main()
