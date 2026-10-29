"""Opt-in isolated native 0.155.1 + localhost fake provider integration.

No real account, model endpoint, user session, or health data is involved.
Run with COVE_NATIVE_CODEX_SMOKE=1 after approving local tmux/loopback access.
"""
import json
import io
import os
import shutil
import tempfile
import threading
import time
import unittest
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from storage import Store
from tmux_provision import TmuxProvisioner
from tmux_registry import TmuxRegistry
from tmux_runtime import TmuxRuntime


NATIVE = Path('/nonexistent/cove-native-test')


@unittest.skipUnless(os.environ.get('COVE_NATIVE_CODEX_SMOKE') == '1',
                     'explicit isolated native fake-provider smoke only')
class NativeRuntimeTests(unittest.TestCase):
    def test_new_thread_and_second_text_turn_with_real_store_and_profile(self):
        if not NATIVE.is_file() or not shutil.which('tmux'):
            self.fail('native Codex 0.155.1 and tmux required')
        requests = []
        tool_issued = [False]

        def contains_type(value, kind):
            if isinstance(value, dict):
                return value.get('type') == kind or any(contains_type(item, kind) for item in value.values())
            if isinstance(value, list):
                return any(contains_type(item, kind) for item in value)
            return False

        class FakeProvider(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                size = int(self.headers.get('Content-Length', '0'))
                body = json.loads(self.rfile.read(size))
                fourth = 'SYNTHETIC runtime turn 4' in json.dumps(body.get('input', []))
                has_tool_result = contains_type(body.get('input', []), 'function_call_output')
                requests.append({'path': self.path,
                                 'image': contains_type(body.get('input', []), 'input_image'),
                                 'tool_result': has_tool_result,
                                 'mcp_namespace': any(item.get('name') == 'mcp__cove_files'
                                                      for item in body.get('tools', []) if isinstance(item, dict))})
                index = len(requests)
                if fourth and not tool_issued[0] and requests[-1]['mcp_namespace']:
                    tool_issued[0] = True
                    item = {'id': 'fc_' + str(index), 'type': 'function_call',
                            'name': 'cove_read_health', 'namespace': 'mcp__cove_files',
                            'arguments': '{}', 'call_id': 'synthetic-health-call',
                            'status': 'completed'}
                else:
                    item = {'id': 'msg_' + str(index), 'type': 'message', 'role': 'assistant',
                            'phase': 'final_answer', 'content': [{'type': 'output_text',
                            'text': 'FAKE_DONE', 'annotations': []}], 'status': 'completed'}
                response = {'id': 'resp_fake_' + str(index), 'object': 'response',
                            'created_at': 1790160000, 'model': 'fake-model', 'output': [item],
                            'parallel_tool_calls': False,
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
        old_pulse = os.environ.pop('COVE_PULSE_PATH', None)
        old_provider = os.environ.pop('COVE_MODEL_PROVIDER', None)
        try:
            with tempfile.TemporaryDirectory(prefix='cove-runtime-', dir='/private/tmp') as name:
                root = Path(name).resolve()
                home, work = root / 'home', root / 'work'
                home.mkdir(mode=0o700)
                work.mkdir(mode=0o700)
                config = home / 'config.toml'
                config.write_text(
                    'model="fake-model"\nmodel_provider="fake"\n'
                    '[model_providers.fake]\nname="Fake"\n'
                    'base_url="http://127.0.0.1:' + str(server.server_port) + '/v1"\n'
                    'wire_api="responses"\nrequires_openai_auth=false\n'
                    '[projects."' + str(work) + '"]\ntrust_level="trusted"\n')
                config.chmod(0o600)
                store = Store(root / 'data')
                conversation_id = str(uuid.uuid4())
                store.create_conversation(conversation_id)
                registry = TmuxRegistry(db_path=store.directory / 'tmux-registry.sqlite3',
                                        codex_binary=str(NATIVE), codex_home=home)
                runtime = TmuxRuntime(store, work, session_provider=registry,
                                      codex_home=home, timeout=20,
                                      enable_terminal_input=True)
                socket_dir = store.directory / 'tmux-sockets'
                socket_dir.mkdir(mode=0o700)
                runtime.provisioner = TmuxProvisioner(
                    registry=registry, socket_dir=socket_dir, workspace=work,
                    launch_config=runtime.launch_config)
                try:
                    # This is a fixture Store only; the explicit standing grant
                    # authorizes an empty synthetic health read, not real data.
                    store.set_data_access({'enabled': True})
                    for number in (1, 2, 3, 4):
                        message_id = str(uuid.uuid4())
                        body = {'id': message_id, 'conversationID': conversation_id,
                                'text': 'SYNTHETIC runtime turn ' + str(number)}
                        if number == 3:
                            from PIL import Image
                            output = io.BytesIO()
                            Image.new('RGB', (64, 64), (120, 40, 210)).save(output, format='PNG')
                            png = output.getvalue()
                            attachment = store.add_attachment('synthetic.png', 'image/png', png)
                            body['attachmentID'] = attachment['id']
                        store.accept(body)
                        job = store.claim()
                        self.assertEqual(job['message'], message_id)
                        try:
                            status, error = runtime.run(job, threading.Event())
                        except Exception as failure:
                            bound = runtime.bindings.get(conversation_id)
                            shape = []
                            if bound and bound.get('rolloutPath'):
                                for line in Path(bound['rolloutPath']).read_text().splitlines():
                                    item = json.loads(line)
                                    payload = item.get('payload', {})
                                    if payload.get('role') == 'user':
                                        shape.append([part.get('type') for part in payload.get('content', [])
                                                      if isinstance(part, dict)])
                            self.fail('native turn ' + str(number) + ' failed: ' + str(failure)
                                      + '; request shape=' + repr(requests[-3:])
                                      + '; rollout user content types=' + repr(shape[-3:]))
                        self.assertEqual((status, error), ('complete', None))
                        store.finish(message_id, status, error)
                        self.assertIn('FAKE_DONE', store._message(job['assistant'])['text'])
                        self.assertIsNotNone(store.conversation(conversation_id)['thread'])
                        self.assertEqual(registry.ensure(store.conversation(conversation_id))['threadID'],
                                         store.conversation(conversation_id)['thread'])
                    self.assertGreaterEqual(len(requests), 4)
                    self.assertTrue(any(item['image'] for item in requests))
                    self.assertTrue(any(item['mcp_namespace'] for item in requests))
                    self.assertTrue(any(item['tool_result'] for item in requests))
                    self.assertEqual(store.db.execute('SELECT count(*) FROM data_tool_results').fetchone()[0], 1)
                    terminal = runtime.tmux_console.attach(conversation_id)
                    self.assertTrue(terminal['inputAvailable'])
                    session_id = terminal['sessionID']
                    runtime.tmux_console.control(conversation_id, session_id, str(uuid.uuid4()),
                                                 'input', 'SYNTHETIC terminal owned')
                    runtime.tmux_console.control(conversation_id, session_id, str(uuid.uuid4()),
                                                 'key', 'Enter')
                    deadline = time.monotonic() + 10
                    terminal_status = None
                    while time.monotonic() < deadline:
                        with store.lock:
                            row = store.db.execute('''SELECT jobs.state FROM jobs JOIN messages
                                ON jobs.message=messages.id WHERE json_extract(messages.body,'$.source')
                                ='native-terminal' ORDER BY messages.rowid DESC LIMIT 1''').fetchone()
                        terminal_status = row[0] if row else None
                        if terminal_status in ('complete', 'failed', 'interrupted'):
                            break
                        time.sleep(.05)
                    self.assertEqual(terminal_status, 'complete')
                    message_id = str(uuid.uuid4())
                    store.accept({'id': message_id, 'conversationID': conversation_id,
                                  'text': 'SYNTHETIC runtime turn 5 after terminal'})
                    job = store.claim()
                    self.assertEqual(runtime.run(job, threading.Event()), ('complete', None))
                    store.finish(message_id, 'complete', None)
                    self.assertIn('FAKE_DONE', store._message(job['assistant'])['text'])
                    old_thread = store.conversation(conversation_id)['thread']
                    old_session = session_id
                    self.assertTrue(runtime.tmux_console.control(
                        conversation_id, old_session, str(uuid.uuid4()), 'terminate')['ok'])
                    self.assertEqual(runtime.tmux_console.capture(conversation_id, old_session)['state'],
                                     'terminated')
                    state = runtime.interactive.states.get(conversation_id)
                    if state:
                        state['worker'].join(timeout=3)
                        self.assertFalse(state['worker'].is_alive())
                    recovery_id = str(uuid.uuid4())
                    try:
                        recovered = runtime.recover_console(conversation_id, old_session, recovery_id)
                    except Exception as failure:
                        screens = []
                        for transport in runtime.provisioner._live.values():
                            if transport._session_exists():
                                screens.append(transport.capture(max_lines=100)[-500:])
                        self.fail('explicit synthetic recovery failed: ' + str(failure)
                                  + '; screens=' + repr(screens))
                    self.assertEqual(recovered['threadID'], old_thread)
                    self.assertNotEqual(recovered['sessionID'], old_session)
                    self.assertEqual(runtime.recover_console(conversation_id, old_session, recovery_id)['sessionID'],
                                     recovered['sessionID'])
                    self.assertEqual(len(list(home.glob('cove_*.config.toml'))), 2)
                    message_id = str(uuid.uuid4())
                    store.accept({'id': message_id, 'conversationID': conversation_id,
                                  'text': 'SYNTHETIC after explicit force recovery'})
                    job = store.claim()
                    self.assertEqual(runtime.run(job, threading.Event()), ('complete', None))
                    store.finish(message_id, 'complete', None)
                    self.assertEqual(store.conversation(conversation_id)['thread'], old_thread)
                    self.assertIn('FAKE_DONE', store._message(job['assistant'])['text'])
                    profiles = list(home.glob('cove_*.config.toml'))
                    self.assertEqual(len(profiles), 2)  # initial + explicit owner recovery only
                    self.assertTrue(all(profile.stat().st_mode & 0o777 == 0o600 for profile in profiles))
                    capability_files = [path for path in store.directory.glob('tmux-mcp-*.json')
                                        if len(path.stem) == len('tmux-mcp-') + 64]
                    self.assertEqual(len(capability_files), 1)
                    self.assertTrue(all(path.stat().st_mode & 0o077 == 0 for path in capability_files
                                        if path.is_file()))
                finally:
                    for transport in list(runtime.provisioner._live.values()):
                        if transport._session_exists():
                            transport.close_created()  # exact test-created tmux session only
                    runtime.close()
                    store.close()
        finally:
            if old_pulse is not None:
                os.environ['COVE_PULSE_PATH'] = old_pulse
            if old_provider is not None:
                os.environ['COVE_MODEL_PROVIDER'] = old_provider
            server.shutdown()
            server.server_close()
            worker.join(timeout=2)


if __name__ == '__main__':
    unittest.main()
