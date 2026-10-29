import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from tmux_session import TmuxSession, TmuxSessionError


class FakeRunner:
    def __init__(self):
        self.calls = []
        self.options = {}
        self.session = None
        self.pane = '%0'
        self.command = Path(sys.executable).resolve().name
        self.dead = '0'

    def __call__(self, argv, **kwargs):
        self.calls.append((argv, kwargs))
        command = argv[3]
        if command == 'list-sessions':
            return subprocess.CompletedProcess(argv, 0 if self.session else 1, (self.session or '') + '\n', '')
        if command == 'new-session':
            self.session = argv[argv.index('-s') + 1]
        elif command == 'set-option':
            self.options[argv[-2]] = argv[-1]
        elif command == 'show-options':
            return subprocess.CompletedProcess(argv, 0, self.options.get(argv[-1], '') + '\n', '')
        elif command == 'list-panes':
            return subprocess.CompletedProcess(argv, 0, self.pane + '|' + self.command + '|' + self.dead + '\n', '')
        elif command == 'capture-pane':
            return subprocess.CompletedProcess(argv, 0, 'synthetic output\n', '')
        elif command == 'kill-session':
            self.session = None
        return subprocess.CompletedProcess(argv, 0, '', '')


class TmuxSessionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.parent = Path(self.temp.name).resolve() / 'private'
        self.parent.mkdir(mode=0o700)
        self.socket = self.parent / 'tmux.sock'

    def make(self, runner=None, **overrides):
        values = dict(socket_path=self.socket, session_name='cove_test', conversation_id='conversation-a',
                      thread_id='thread-a', workspace=self.parent, owner_token='private-owner-token',
                      runner=subprocess.run if runner is None else runner)
        values.update(overrides)
        return TmuxSession(**values)

    def test_requires_explicit_private_socket_and_exact_binding(self):
        with self.assertRaises(ValueError): self.make(socket_path='relative.sock')
        with self.assertRaises(ValueError): self.make(session_name='another;session')
        with self.assertRaises(ValueError): self.make(thread_id='thread\nother')
        self.parent.chmod(0o755)
        with self.assertRaises(TmuxSessionError): self.make().start([sys.executable, '-c', 'pass'])

    def test_start_uses_argv_without_shell_or_credentials_and_no_fallback(self):
        runner = FakeRunner()
        session = self.make(runner)
        # Fake the socket tmux would create; no real model or external service.
        original_verify = session._verify_binding
        session._verify_binding = lambda: None
        session.start([sys.executable, '-c', 'print("synthetic")'])
        commands = [call[0] for call in runner.calls]
        start = next(call for call in commands if 'new-session' in call)
        self.assertEqual(start[:3], ['tmux', '-S', str(self.socket)])
        self.assertIn('--', start)
        self.assertEqual(start[start.index('--') + 1:start.index('--') + 3], ['/usr/bin/env', '-i'])
        self.assertEqual(start[-3:], [sys.executable, '-c', 'print("synthetic")'])
        for argv, kwargs in runner.calls:
            self.assertFalse(kwargs['shell'])
            self.assertEqual(argv[1:3], ['-S', str(self.socket)])
            self.assertNotIn('COVE_TOKEN', kwargs['env'])
        session._verify_binding = original_verify

    def test_send_limits_special_whitelist_and_no_automatic_replay(self):
        runner = FakeRunner()
        session = self.make(runner)
        session._verify_binding = lambda: None
        session._attached = True
        session.send_text('literal ; $(do-not-run)')
        session.send_special('Enter')
        session.resize(rows=40, cols=120)
        self.assertEqual(session.capture(max_lines=10), 'synthetic output\n')
        with self.assertRaises(ValueError): session.send_special('run-shell')
        with self.assertRaises(ValueError): session.send_text('x' * (session.MAX_TEXT + 1))
        for invalid in ('line\nnext', 'return\r', 'tab\t', '\x1b[31m', 'del\x7f'):
            with self.subTest(invalid=repr(invalid)), self.assertRaises(ValueError):
                session.send_text(invalid)
        with self.assertRaises(TmuxSessionError): session.capture(max_bytes=1)
        self.assertEqual([c[0][3] for c in runner.calls if c[0][3] == 'send-keys'], ['send-keys', 'send-keys'])
        self.assertEqual(runner.calls[0][0][-1], 'literal ; $(do-not-run)')
        before = len(runner.calls)
        session.detach()
        self.assertEqual(len(runner.calls), before)
        with self.assertRaises(TmuxSessionError): session.send_special('Enter')

    def test_paste_requires_verified_mode_and_never_sends_enter(self):
        runner = FakeRunner()
        session = self.make(runner)
        session._verify_binding = lambda: None
        session._attached = True
        session.pane_id = '%0'
        with self.assertRaises(TmuxSessionError): session.send_paste('one\ntwo')
        for invalid in ('x\x1by', 'x\ry', 'x\ty', 'x\x7fy', 'x' * (session.MAX_PASTE + 1)):
            with self.subTest(invalid=repr(invalid[:10])), self.assertRaises(ValueError):
                session.send_paste(invalid, bracketed_verified=True)
        session.send_paste('one\ntwo', bracketed_verified=True)
        commands = [call[0][3] for call in runner.calls]
        self.assertEqual(commands, ['load-buffer', 'paste-buffer'])
        self.assertEqual(runner.calls[0][1]['input'], 'one\ntwo')
        self.assertIn('-dpr', runner.calls[1][0])
        self.assertNotIn('send-keys', commands)

    def test_reattach_checks_all_metadata_and_never_kills_adopted_session(self):
        runner = FakeRunner()
        runner.session = 'cove_test'
        runner.options = {'@cove_owner': 'private-owner-token', '@cove_conversation': 'conversation-a',
                          '@cove_thread': 'thread-a', '@cove_workspace': str(self.parent.resolve()),
                          '@cove_pane': '%0', '@cove_command': Path(sys.executable).resolve().name}
        session = self.make(runner)
        # A real private socket check is covered by the integration test below.
        session._private_socket = lambda: None
        session.attach_existing()
        session.close_created()
        self.assertEqual(runner.session, 'cove_test')
        wrong = self.make(runner, thread_id='thread-b')
        wrong._private_socket = lambda: None
        with self.assertRaises(TmuxSessionError): wrong.attach_existing()

    def test_force_terminate_owned_session_even_when_command_changed(self):
        runner = FakeRunner()
        runner.session = 'cove_test'
        runner.options = {'@cove_owner': 'private-owner-token', '@cove_conversation': 'conversation-a',
                          '@cove_thread': 'thread-a', '@cove_workspace': str(self.parent),
                          '@cove_pane': '%0', '@cove_command': 'codex'}
        runner.command = 'stuck-other-program'
        handle = self.make(runner)
        handle._private_socket = lambda: None
        handle.terminate_bound()
        self.assertIsNone(runner.session)
        self.assertFalse(any(call[0][3] == 'kill-server' for call in runner.calls))

    def test_recycled_session_and_substituted_pane_cannot_be_terminated(self):
        runner = FakeRunner()
        runner.session = 'cove_test'
        runner.options = {'@cove_owner': 'old-token', '@cove_conversation': 'conversation-a',
                          '@cove_thread': 'thread-a', '@cove_workspace': str(self.parent),
                          '@cove_pane': '%0', '@cove_command': 'codex'}
        handle = self.make(runner)
        handle._private_socket = lambda: None
        with self.assertRaises(TmuxSessionError): handle.terminate_bound()
        self.assertEqual(runner.session, 'cove_test')
        runner.options['@cove_owner'] = 'private-owner-token'
        runner.pane = '%1'
        with self.assertRaises(TmuxSessionError): handle.terminate_bound()
        self.assertEqual(runner.session, 'cove_test')

    def test_missing_socket_and_parent_report_transport_error(self):
        handle = self.make(FakeRunner())
        with self.assertRaises(TmuxSessionError): handle.attach_existing()
        with self.assertRaises(TmuxSessionError): handle.terminate_bound()
        self.parent.rmdir()
        with self.assertRaises(TmuxSessionError): handle.attach_existing()
        with self.assertRaises(ValueError): self.make(workspace=self.parent / 'missing')

    @unittest.skipUnless(subprocess.run(['sh', '-c', 'command -v tmux >/dev/null'], check=False).returncode == 0,
                         'tmux not installed')
    def test_real_tmux_private_socket_fake_program_only(self):
        # This never starts Codex or a model. The session and socket live only
        # under this test's private TemporaryDirectory.
        session = self.make()
        program = ['/bin/cat']  # fake PTY echo; never Codex or a model
        try:
            session.start(program)
            self.assertTrue(stat.S_ISSOCK(self.socket.stat().st_mode))
            adopted = self.make()
            adopted.attach_existing()
            adopted.send_text('hello')
            adopted.send_special('Enter')
            import time
            for _ in range(20):
                output = adopted.capture()
                if 'echo:hello' in output: break
                time.sleep(.1)
            self.assertIn('hello', output)
            adopted.detach()
            self.assertTrue(session._session_exists())
        finally:
            if session._created_here:
                session.close_created()

    @unittest.skipUnless(subprocess.run(['sh', '-c', 'command -v tmux >/dev/null'], check=False).returncode == 0,
                         'tmux not installed')
    def test_real_bracketed_paste_fake_program_no_enter(self):
        session = self.make()
        program = [sys.executable, '-u', '-c',
                   'import os,tty\n'
                   'tty.setraw(0)\n'
                   'os.write(1,b"\\x1b[?2004hREADY\\n")\n'
                   'b=b""\n'
                   'while b"\\x1b[201~" not in b:\n'
                   '    b+=os.read(0,4096)\n'
                   'os.write(1,b"HEX:"+b.hex().encode()+b"\\n")\n'
                   'os.read(0,1)\n']
        try:
            # macOS reports the interpreter running `-c` as "Python" rather
            # than the native python3.9 binary. Bootstrap this synthetic pane
            # explicitly so the production `start` executable check stays strict.
            session._run('new-session', '-d', '-s', session.session_name,
                         '-c', session.workspace, '--', '/usr/bin/env', '-i',
                         'PATH=' + os.environ.get('PATH', '/usr/bin:/bin'),
                         'HOME=' + os.environ.get('HOME', '/'), *program)
            session._created_here = True
            import time
            for _ in range(20):
                if 'READY' in session._run('capture-pane', '-p', '-t', session.session_name).stdout:
                    break
                time.sleep(.05)
            session.pane_id, session.expected_command, _ = session._pane_details()
            for option, attribute in session._fields.items():
                session._run('set-option', '-t', session.session_name, option, getattr(session, attribute))
            session._metadata_complete = True
            session.attach_existing()
            for _ in range(20):
                if 'READY' in session.capture(): break
                time.sleep(.05)
            self.assertIn('READY', session.capture())
            session.send_paste('one\ntwo', bracketed_verified=True)
            for _ in range(20):
                output = session.capture()
                if 'HEX:' in output: break
                time.sleep(.05)
            self.assertIn(('HEX:' + (b'\x1b[200~one\ntwo\x1b[201~').hex()), output)
        finally:
            if session._created_here:
                session.close_created()


if __name__ == '__main__':
    unittest.main()
