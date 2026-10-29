import os
import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

from tmux_registry import TmuxRegistry, TmuxRegistryError
from tmux_session import TmuxSessionError


class FakeTransport:
    should_fail = False

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

    def attach_existing(self):
        if self.should_fail:
            raise TmuxSessionError('fake unavailable')
        self.attached = True

    def _require_attached(self):
        if not self.attached or self.should_fail:
            raise TmuxSessionError('fake unavailable')

    def _verify_identity(self):
        if self.should_fail:
            raise TmuxSessionError('fake unavailable')
        return self.pane_id, self.expected_command, '0'

    def detach(self):
        self.attached = False

    def capture(self):
        self._require_attached()
        return 'synthetic pane'


class TmuxRegistryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.parent = Path(self.temp.name).resolve() / 'private'
        self.parent.mkdir(mode=0o700)
        (self.parent / 'sessions').mkdir(mode=0o700)
        self.rollout = self.parent / 'sessions' / 'rollout.jsonl'
        self.rollout.write_text(json.dumps({'type': 'session_meta', 'payload': {'id': 'verified-thread-a'}}) + '\n')
        self.conversation = {'id': 'conversation-a', 'thread': 'verified-thread-a'}
        FakeTransport.should_fail = False

    def registry(self):
        return TmuxRegistry(db_path=self.parent / 'registry.sqlite3',
                            codex_binary=sys.executable, codex_home=self.parent,
                            transport_factory=FakeTransport)

    def transport(self):
        return FakeTransport(socket_path=self.parent / 'fake.sock', session_name='d1a0d51b-3653-4d5d-9f2e-7944d4cfb773',
                             conversation_id=self.conversation['id'], thread_id=self.conversation['thread'],
                             workspace=self.parent, owner_token='private-capability')

    def test_register_restart_ensure_and_close_only_detaches(self):
        registry = self.registry()
        transport = self.transport()
        binding = registry.register_existing(self.conversation, transport, self.rollout)
        self.assertEqual(binding['threadID'], 'verified-thread-a')
        self.assertEqual(binding['sessionID'], 'd1a0d51b-3653-4d5d-9f2e-7944d4cfb773')
        self.assertEqual(binding['rolloutPath'], str(self.rollout))
        self.assertEqual((self.parent / 'registry.sqlite3').stat().st_mode & 0o777, 0o600)
        registry.close()
        self.assertFalse(transport.attached)
        restarted = self.registry()
        recovered = restarted.ensure(self.conversation)
        self.assertTrue(recovered['transport'].attached)
        self.assertEqual(recovered['transport'].owner_token, 'private-capability')
        restarted.close()

    def test_unknown_and_thread_mismatch_are_quarantined_no_launch(self):
        registry = self.registry()
        with self.assertRaises(TmuxRegistryError): registry.ensure(self.conversation)
        row = registry.db.execute('SELECT state FROM bindings WHERE conversation_id=?', ('conversation-a',)).fetchone()
        self.assertEqual(row['state'], 'quarantine')
        registry.register_existing(self.conversation, self.transport(), self.rollout)
        with self.assertRaises(TmuxRegistryError): registry.ensure({'id': 'conversation-a', 'thread': 'different'})
        self.assertEqual(registry.db.execute('SELECT state FROM bindings').fetchone()['state'], 'quarantine')
        registry.close()

    def test_failed_reattach_quarantines_instead_of_relaunching(self):
        registry = self.registry()
        registry.register_existing(self.conversation, self.transport(), self.rollout)
        registry.close()
        FakeTransport.should_fail = True
        restarted = self.registry()
        with self.assertRaises(TmuxRegistryError): restarted.ensure(self.conversation)
        self.assertEqual(restarted.db.execute('SELECT state FROM bindings').fetchone()['state'], 'quarantine')
        restarted.close()

    def test_dispatch_intent_is_durable_and_restart_busy_quarantines(self):
        registry = self.registry()
        registry.register_existing(self.conversation, self.transport(), self.rollout)
        registry.begin_dispatch('conversation-a', 'message-1')
        inspected = registry.inspect(self.conversation)
        self.assertEqual(inspected['sessionID'], 'd1a0d51b-3653-4d5d-9f2e-7944d4cfb773')
        with self.assertRaises(TmuxRegistryError): registry.begin_dispatch('conversation-a', 'message-1')
        registry.close()
        restarted = self.registry()
        with self.assertRaises(TmuxRegistryError): restarted.ensure(self.conversation)
        row = restarted.db.execute('SELECT state,dispatch_message FROM bindings').fetchone()
        self.assertEqual((row['state'], row['dispatch_message']), ('quarantine', 'message-1'))
        self.assertEqual(restarted.db.execute('SELECT state FROM dispatches WHERE message_id=?',
                                              ('message-1',)).fetchone()['state'], 'intent')
        self.assertEqual(restarted.inspect(self.conversation)['threadID'], 'verified-thread-a')
        with self.assertRaises(TmuxRegistryError): restarted.finish_dispatch('conversation-a', 'message-1')
        # Explicit recovery may make the binding ready, but the uncertain
        # previously submitted message may never be submitted a second time.
        restarted.register_existing(self.conversation, self.transport(), self.rollout)
        with self.assertRaises(TmuxRegistryError): restarted.begin_dispatch('conversation-a', 'message-1')
        self.assertEqual(restarted.db.execute('SELECT state FROM bindings').fetchone()['state'], 'ready')
        restarted.close()

    def test_finish_requires_exact_message_and_native_complete_caller(self):
        registry = self.registry()
        registry.register_existing(self.conversation, self.transport(), self.rollout)
        registry.begin_dispatch('conversation-a', 'message-1')
        with self.assertRaises(TmuxRegistryError): registry.finish_dispatch('conversation-a', 'message-2')
        self.assertEqual(registry.db.execute('SELECT state FROM bindings').fetchone()['state'], 'busy')
        registry.finish_dispatch('conversation-a', 'message-1')
        self.assertEqual(registry.db.execute('SELECT state FROM bindings').fetchone()['state'], 'ready')
        self.assertEqual(registry.db.execute('SELECT state FROM dispatches WHERE message_id=?',
                                             ('message-1',)).fetchone()['state'], 'complete')
        with self.assertRaises(TmuxRegistryError): registry.begin_dispatch('conversation-a', 'message-1')
        self.assertEqual(registry.db.execute('SELECT state FROM bindings').fetchone()['state'], 'ready')
        registry.close()
        restarted = self.registry()
        with self.assertRaises(TmuxRegistryError): restarted.begin_dispatch('conversation-a', 'message-1')
        restarted.begin_dispatch('conversation-a', 'message-2')
        self.assertEqual(restarted.db.execute('SELECT state FROM bindings').fetchone()['state'], 'busy')
        restarted.close()

    def test_quarantine_preserves_attached_transport_for_interrupt_and_capture(self):
        registry = self.registry()
        transport = self.transport()
        registry.register_existing(self.conversation, transport, self.rollout)
        registry.quarantine('conversation-a', 'uncertain timeout')
        self.assertTrue(transport.attached)
        self.assertEqual(transport.capture(), 'synthetic pane')
        with self.assertRaises(TmuxRegistryError): registry.ensure(self.conversation)
        self.assertEqual(registry.inspect(self.conversation)['threadID'], 'verified-thread-a')
        registry.close()
        self.assertFalse(transport.attached)

    def test_rollout_header_scope_and_inode_rechecked_on_recovery(self):
        registry = self.registry()
        outside = self.parent / 'outside.jsonl'
        outside.write_text(self.rollout.read_text())
        with self.assertRaises(TmuxRegistryError): registry.register_existing(self.conversation, self.transport(), outside)
        self.rollout.write_text(json.dumps({'type': 'session_meta', 'payload': {'id': 'other-thread'}}) + '\n')
        with self.assertRaises(TmuxRegistryError): registry.register_existing(self.conversation, self.transport(), self.rollout)
        self.rollout.write_text(json.dumps({'type': 'session_meta', 'payload': {'id': 'verified-thread-a'}}) + '\n')
        registry.register_existing(self.conversation, self.transport(), self.rollout)
        replacement = self.rollout.with_suffix('.new')
        replacement.write_text(self.rollout.read_text())
        os.replace(replacement, self.rollout)
        with self.assertRaises(TmuxRegistryError): registry.ensure(self.conversation)
        with self.assertRaises(TmuxRegistryError): registry.inspect(self.conversation)
        registry.close()

    def test_dispatch_intent_insert_failure_rolls_back_busy_transition(self):
        registry = self.registry()
        registry.register_existing(self.conversation, self.transport(), self.rollout)
        registry.db.execute('''CREATE TRIGGER reject_dispatch BEFORE INSERT ON dispatches
            BEGIN SELECT RAISE(ABORT, 'synthetic insert failure'); END''')
        with self.assertRaises(sqlite3.IntegrityError):
            registry.begin_dispatch('conversation-a', 'message-failed')
        self.assertEqual(tuple(registry.db.execute('SELECT state,dispatch_message FROM bindings').fetchone()),
                         ('ready', None))
        self.assertIsNone(registry.db.execute('SELECT 1 FROM dispatches').fetchone())
        registry.close()

    def test_console_ownership_adoption_is_durable_and_not_app_dispatch(self):
        registry = self.registry()
        registry.register_existing(self.conversation, self.transport(), self.rollout)
        registry.begin_console('conversation-a', 'control-1')
        with self.assertRaises(TmuxRegistryError):
            registry.begin_dispatch('conversation-a', 'app-message')
        with self.assertRaises(TmuxRegistryError):
            registry.adopt_console_dispatch('conversation-a', 'other-control', 'native-message')
        registry.adopt_console_dispatch('conversation-a', 'control-1', 'native-message')
        registry.finish_dispatch('conversation-a', 'native-message')
        self.assertEqual(registry.db.execute('SELECT state FROM bindings').fetchone()['state'], 'ready')
        registry.begin_console('conversation-a', 'control-2')
        registry.close()
        restarted = self.registry()
        with self.assertRaises(TmuxRegistryError):
            restarted.ensure(self.conversation)
        self.assertEqual(restarted.db.execute('SELECT state FROM bindings').fetchone()['state'], 'quarantine')
        self.assertEqual(restarted.inspect(self.conversation)['threadID'], 'verified-thread-a')
        restarted.close()


if __name__ == '__main__':
    unittest.main()
