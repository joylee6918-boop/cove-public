import hashlib
import json
import os
import shutil
import sys
import tempfile
import time
import unittest
import uuid
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from types import SimpleNamespace

from tmux_provision import ProvisionError, TmuxProvisioner
from tmux_registry import TmuxRegistry, TmuxRegistryError


THREAD = 'a48c2f83-0a41-4b2b-81da-b19d37605f7e'


class FakeTransport:
    status_ids = [THREAD]
    starts = []

    def __init__(self, *, socket_path, session_name, conversation_id, thread_id,
                 workspace, owner_token, **kwargs):
        self.socket_path = Path(socket_path)
        self.session_name = session_name
        self.conversation_id = conversation_id
        self.thread_id = thread_id
        self.workspace = str(Path(workspace).resolve())
        self.owner_token = owner_token
        self.pane_id = '%1'
        self.expected_command = Path(sys.executable).name
        self.attached = False
        self.sent = []

    def start(self, argv, *, rows, cols):
        self.attached = True
        self.starts.append(tuple(argv))

    def attach_existing(self):
        self.attached = True

    def _require_attached(self):
        if not self.attached:
            raise RuntimeError('detached')

    def _verify_identity(self):
        return self.pane_id, self.expected_command, '0'

    def _verify_binding(self):
        self._require_attached()

    def _run(self, *argv):
        if argv[0] == 'display-message':
            return SimpleNamespace(stdout='12345\n')
        if argv[0] == 'set-option':
            return SimpleNamespace(stdout='')
        raise AssertionError(argv)

    def send_text(self, value):
        self.sent.append(value)

    def send_special(self, value):
        self.sent.append(value)

    def capture(self, **kwargs):
        if self.sent and self.sent[-1] == '/status':
            return '› /status'
        return '\n'.join('Session: ' + item for item in self.status_ids)

    def detach(self):
        self.attached = False

    def terminate_bound(self):
        self.attached = False


class ProvisionTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.private = self.root / 'private'
        self.private.mkdir(mode=0o700)
        (self.private / 'sessions').mkdir(mode=0o700)
        self.work = self.root / 'work'
        self.work.mkdir()
        config = self.private / 'config.toml'
        config.write_text('model_provider = "fake"\n')
        config.chmod(0o600)
        self.sha = hashlib.sha256(config.read_bytes()).hexdigest()
        self.registry = TmuxRegistry(db_path=self.private / 'registry.sqlite3',
                                     codex_binary=sys.executable,
                                     codex_home=self.private,
                                     transport_factory=FakeTransport)
        self.addCleanup(self.registry.close)
        self.provision = TmuxProvisioner(
            registry=self.registry, socket_dir=self.private,
            workspace=self.work,
            launch_config=lambda conversation: {'config_sha256': self.sha},
            ready_probe=lambda transport, thread: True,
            lock_verifier=lambda pid, thread: pid == 12345 and thread == THREAD,
            transport_factory=FakeTransport)
        self.addCleanup(self.provision.close)
        FakeTransport.status_ids = [THREAD]
        FakeTransport.starts = []

    def _rollout(self, thread=THREAD):
        path = self.private / 'sessions' / ('rollout-' + thread + '.jsonl')
        path.write_text(json.dumps({'type': 'session_meta', 'payload': {'id': thread}}) + '\n')
        return path

    def test_new_empty_tui_two_phase_exact_rollout_and_one_shot_intent(self):
        op = str(uuid.uuid4())
        pending = self.provision.create_new('conversation-1', operation_id=op)
        self.assertEqual(pending['threadID'], THREAD)
        self.assertIsNone(pending['rolloutPath'])
        self.assertEqual(pending['transport'].sent, ['/status', 'Enter', 'Escape'])
        self.assertEqual(len(FakeTransport.starts), 1)
        with self.assertRaises(ProvisionError):
            self.provision.create_new('conversation-1', operation_id=str(uuid.uuid4()))
        self.assertEqual(len(FakeTransport.starts), 1)
        with self.assertRaises(ProvisionError):
            self.provision.bind_first_rollout(op, {'id': 'conversation-1', 'thread': THREAD},
                                              message_id='message-1')
        self.provision.begin_first_dispatch(op, 'message-1')
        with self.assertRaises(ProvisionError):
            self.provision.begin_first_dispatch(op, 'message-1')
        path = self._rollout()
        binding = self.provision.bind_first_rollout(
            op, {'id': 'conversation-1', 'thread': THREAD}, message_id='message-1')
        self.assertEqual(binding['rolloutPath'], str(path))
        self.assertEqual(self.registry.db.execute('SELECT state FROM bindings').fetchone()['state'], 'busy')
        self.provision.finish_first_dispatch(op, 'conversation-1', 'message-1')
        self.assertEqual(self.registry.db.execute('SELECT state FROM bindings').fetchone()['state'], 'ready')
        with self.assertRaises(ProvisionError):
            self.provision.begin_first_dispatch(op, 'message-2')

    def test_restart_never_replays_first_message(self):
        op = str(uuid.uuid4())
        self.provision.create_new('conversation-1', operation_id=op)
        self.provision.begin_first_dispatch(op, 'message-1')
        self.provision.close()
        restarted = TmuxProvisioner(
            registry=self.registry, socket_dir=self.private, workspace=self.work,
            launch_config=lambda _: {'config_sha256': self.sha},
            ready_probe=lambda *_: True, lock_verifier=lambda *_: True,
            transport_factory=FakeTransport)
        self.addCleanup(restarted.close)
        with self.assertRaises(ProvisionError):
            restarted.begin_first_dispatch(op, 'message-1')
        with self.assertRaises(ProvisionError):
            restarted.create_new('conversation-1', operation_id=op)
        self.assertEqual(len(FakeTransport.starts), 1)

    def test_explicit_force_pending_after_restart_does_not_replay(self):
        op = str(uuid.uuid4())
        self.provision.create_new('conversation-1', operation_id=op)
        self.provision.begin_first_dispatch(op, 'message-1')
        self.provision.close()
        restarted = TmuxProvisioner(
            registry=self.registry, socket_dir=self.private, workspace=self.work,
            launch_config=lambda _: {'config_sha256': self.sha},
            ready_probe=lambda *_: True, lock_verifier=lambda *_: True,
            transport_factory=FakeTransport)
        self.addCleanup(restarted.close)
        inspected = restarted.inspect_pending('conversation-1')
        self.assertEqual(inspected['bootstrapID'], op)
        self.assertEqual((inspected['threadID'], inspected['firstMessageID']), (THREAD, 'message-1'))
        self.assertEqual(inspected['paneID'], '%1')
        ended = restarted.terminate_pending(op)
        self.assertEqual((ended['threadID'], ended['firstMessageID']), (THREAD, 'message-1'))
        with self.assertRaises(ProvisionError):
            restarted.begin_first_dispatch(op, 'message-1')
        with self.assertRaises(ProvisionError):
            restarted.terminate_pending(op)

    def test_new_requires_ready_lock_and_unique_status(self):
        self.provision.ready_probe = lambda *_: False
        with self.assertRaises(ProvisionError):
            self.provision.create_new('conversation-1', operation_id=str(uuid.uuid4()))
        self.provision.ready_probe = lambda *_: True
        FakeTransport.status_ids = [THREAD, str(uuid.uuid4())]
        with self.assertRaises(ProvisionError):
            self.provision.create_new('conversation-1', operation_id=str(uuid.uuid4()))
        FakeTransport.status_ids = [THREAD]
        self.provision.lock_verifier = lambda *_: False
        with self.assertRaises(ProvisionError):
            self.provision.create_new('conversation-1', operation_id=str(uuid.uuid4()))

    def test_resume_explicit_thread_no_last_and_no_replace_ready(self):
        path = self._rollout()
        conversation = {'id': 'conversation-1', 'thread': THREAD}
        binding = self.provision.resume_existing(conversation, operation_id=str(uuid.uuid4()),
                                                  rollout_path=path)
        self.assertEqual(binding['threadID'], THREAD)
        self.assertEqual(FakeTransport.starts[-1][-2:], ('resume', THREAD))
        with self.assertRaises(ProvisionError):
            self.provision.resume_existing(conversation, operation_id=str(uuid.uuid4()),
                                           rollout_path=path)

    def test_additive_profile_is_private_hashed_and_only_name_in_argv(self):
        profile = self.private / 'cove_synthetic.config.toml'
        profile.write_text('model="profile-fake"\n')
        profile.chmod(0o600)
        digest = hashlib.sha256(profile.read_bytes()).hexdigest()
        self.provision.launch_config = lambda _: {
            'config_sha256': self.sha, 'profile_name': 'cove_synthetic',
            'profile_sha256': digest}
        self.provision.create_new('conversation-1', operation_id=str(uuid.uuid4()))
        self.assertEqual(FakeTransport.starts[-1][1:3], ('-p', 'cove_synthetic'))
        self.assertNotIn(str(profile), FakeTransport.starts[-1])
        profile.write_text('model="tampered"\n')
        with self.assertRaises(ProvisionError):
            self.provision.create_new('conversation-2', operation_id=str(uuid.uuid4()))

    def test_rollout_must_match_proven_native_uuid(self):
        op = str(uuid.uuid4())
        self.provision.create_new('conversation-1', operation_id=op)
        self.provision.begin_first_dispatch(op, 'message-1')
        path = self._rollout()
        path.write_text(json.dumps({'type': 'session_meta', 'payload': {'id': 'wrong'}}) + '\n')
        with self.assertRaises(ProvisionError):
            self.provision.bind_first_rollout(op, {'id': 'conversation-1', 'thread': THREAD},
                                              message_id='message-1')


class NativeEmptyTUISmoke(unittest.TestCase):
    @unittest.skipUnless(os.environ.get('COVE_NATIVE_CODEX_SMOKE') == '1',
                         'explicit local native fake-provider smoke only')
    def test_empty_tui_status_uuid_and_writer_lock_without_model(self):
        native = Path('/nonexistent/cove-native-test')
        if not native.is_file() or not shutil.which('tmux'):
            self.fail('native Codex 0.155.1 and tmux required for requested smoke')
        # macOS AF_UNIX paths are short; the default per-user TMPDIR is too long.
        with tempfile.TemporaryDirectory(prefix='cove-native-', dir='/private/tmp') as name:
            root = Path(name).resolve()
            private = root / 'private'
            home = root / 'home'
            work = root / 'work'
            for directory in (private, home, work):
                directory.mkdir(mode=0o700)
            config = home / 'config.toml'
            config.write_text(
                'model="fake-model"\nmodel_provider="fake"\n'
                '[model_providers.fake]\nname="Fake"\n'
                'base_url="http://127.0.0.1:18765/v1"\n'
                'wire_api="responses"\nrequires_openai_auth=false\n'
                '[projects."' + str(work) + '"]\ntrust_level="trusted"\n')
            config.chmod(0o600)
            profile = home / 'cove_synthetic.config.toml'
            profile.write_text('model="profile-fake"\n')
            profile.chmod(0o600)
            registry = TmuxRegistry(db_path=private / 'registry.sqlite3',
                                    codex_binary=str(native.resolve()),
                                    codex_home=home)
            provision = TmuxProvisioner(
                registry=registry, socket_dir=private, workspace=work,
                launch_config=lambda _: {
                    'config_sha256': hashlib.sha256(config.read_bytes()).hexdigest(),
                    'profile_name': 'cove_synthetic',
                    'profile_sha256': hashlib.sha256(profile.read_bytes()).hexdigest()})
            try:
                try:
                    result = provision.create_new('synthetic-conversation',
                                                  operation_id=str(uuid.uuid4()), status_timeout=10)
                except ProvisionError as error:
                    screens = [transport.capture(max_lines=100)[-500:]
                               for transport in provision._live.values()]
                    self.fail(str(error) + ' synthetic screen=' + repr(screens))
                self.assertEqual(result['state'], 'awaiting-first-message')
                self.assertIn('profile-fake', result['transport'].capture(max_lines=100))
                self.assertFalse(list((home / 'sessions').rglob('*.jsonl')))
            finally:
                for transport in list(provision._live.values()):
                    transport.close_created()  # only this test's created session
                provision.close()
                registry.close()

    @unittest.skipUnless(os.environ.get('COVE_NATIVE_CODEX_SMOKE') == '1',
                         'explicit local native fake-provider smoke only')
    def test_first_turn_creates_exact_rollout_then_binds_without_replay(self):
        native = Path('/nonexistent/cove-native-test')
        if not native.is_file() or not shutil.which('tmux'):
            self.fail('native Codex 0.155.1 and tmux required for requested smoke')
        requests = []

        class FakeProvider(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                size = int(self.headers.get('Content-Length', '0'))
                self.rfile.read(size)  # never store or print task contents
                requests.append(self.path)
                item = {'id': 'msg_1', 'type': 'message', 'role': 'assistant',
                        'phase': 'final_answer', 'content': [{'type': 'output_text',
                        'text': 'FAKE_DONE', 'annotations': []}], 'status': 'completed'}
                response = {'id': 'resp_fake_1', 'object': 'response', 'created_at': 1790160000,
                            'model': 'fake-model', 'output': [item], 'parallel_tool_calls': False,
                            'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2},
                            'status': 'completed'}
                events = [('response.created', {'response': dict(response, output=[], status='in_progress')}),
                          ('response.output_item.added', {'output_index': 0, 'item': item}),
                          ('response.output_item.done', {'output_index': 0, 'item': item}),
                          ('response.completed', {'response': response})]
                data = ''.join('event: ' + kind + '\ndata: ' + json.dumps(dict(value, type=kind)) + '\n\n'
                               for kind, value in events) + 'data: [DONE]\n\n'
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()
                self.wfile.write(data.encode())

        server = HTTPServer(('127.0.0.1', 0), FakeProvider)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            with tempfile.TemporaryDirectory(prefix='cove-first-', dir='/private/tmp') as name:
                root = Path(name).resolve()
                private, home, work = (root / part for part in ('private', 'home', 'work'))
                for directory in (private, home, work):
                    directory.mkdir(mode=0o700)
                config = home / 'config.toml'
                config.write_text(
                    'model="fake-model"\nmodel_provider="fake"\n'
                    '[model_providers.fake]\nname="Fake"\n'
                    'base_url="http://127.0.0.1:' + str(server.server_port) + '/v1"\n'
                    'wire_api="responses"\nrequires_openai_auth=false\n'
                    '[projects."' + str(work) + '"]\ntrust_level="trusted"\n')
                config.chmod(0o600)
                registry = TmuxRegistry(db_path=private / 'registry.sqlite3',
                                        codex_binary=str(native.resolve()), codex_home=home)

                provision = TmuxProvisioner(
                    registry=registry, socket_dir=private, workspace=work,
                    launch_config=lambda _: {'config_sha256': hashlib.sha256(config.read_bytes()).hexdigest()})
                try:
                    op = str(uuid.uuid4())
                    pending = provision.create_new('synthetic-conversation', operation_id=op)
                    conversation = {'id': 'synthetic-conversation', 'thread': pending['threadID']}
                    provision.begin_first_dispatch(op, 'synthetic-message')
                    pending['transport'].send_text('SYNTHETIC first-turn fake-provider only')
                    pending['transport'].send_special('Enter')
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline and not provision._rollouts_for(pending['threadID']):
                        time.sleep(.05)
                    binding = provision.bind_first_rollout(op, conversation, message_id='synthetic-message')
                    self.assertEqual(binding['threadID'], pending['threadID'])
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline and len(requests) < 1:
                        time.sleep(.05)
                    self.assertGreaterEqual(len(requests), 1)
                    rollout = Path(binding['rolloutPath'])
                    while time.monotonic() < deadline:
                        if 'task_complete' in rollout.read_text():
                            break
                        time.sleep(.05)
                    self.assertIn('task_complete', rollout.read_text())
                    events = [json.loads(line) for line in rollout.read_text().splitlines()]
                    user_events = [item for item in events if item.get('type') == 'response_item'
                                   and item.get('payload', {}).get('type') == 'message'
                                   and item.get('payload', {}).get('role') == 'user']
                    self.assertEqual(sum('SYNTHETIC first-turn fake-provider only' in
                                         json.dumps(item.get('payload', {})) for item in user_events), 1)
                    provision.finish_first_dispatch(op, conversation['id'], 'synthetic-message')
                    self.assertEqual(registry.ensure(conversation)['threadID'], pending['threadID'])
                finally:
                    for transport in list(provision._live.values()):
                        transport.close_created()
                    provision.close()
                    registry.close()
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=2)


if __name__ == '__main__':
    unittest.main()
