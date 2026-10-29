"""Opt-in, no-model native app-server + Cove ShellConsole PTY smoke.

Uses a fixed Codex 0.155.1 executable and a fresh private CODEX_HOME. No auth,
model endpoint, user workspace, or live Cove service is involved.
"""
import base64
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from runtime import CodexRuntime
from shell_console import ShellConsole
from storage import Store


NATIVE = Path('/nonexistent/cove-native-test')


@unittest.skipUnless(os.environ.get('COVE_NATIVE_SHELL_SMOKE') == '1',
                     'explicit isolated native shell smoke only')
class NativeShellTests(unittest.TestCase):
    def test_real_runtime_three_immediate_writes_after_readiness(self):
        if not NATIVE.is_file():
            self.fail('fixed Codex 0.155.1 binary is missing')
        version = subprocess.run([str(NATIVE), '--version'], capture_output=True,
                                 text=True, check=False, timeout=5)
        self.assertEqual(version.stdout.strip(), 'codex-cli 0.155.1')
        with tempfile.TemporaryDirectory(prefix='cove-native-shell-') as root:
            base = Path(root)
            home, workspace, data = base / 'home', base / 'workspace', base / 'data'
            home.mkdir(mode=0o700); workspace.mkdir(mode=0o700)
            env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
                   # Native macOS sandbox needs the host HOME for its own
                   # bootstrap; CODEX_HOME remains isolated and unauthenticated.
                   'HOME': os.environ.get('HOME', str(home)),
                   'CODEX_HOME': str(home), 'COVE_SANDBOX': 'read-only'}
            with patch.dict(os.environ, env, clear=True):
                store = Store(data)
                runtime = CodexRuntime(store, workspace,
                                       command=str(NATIVE) + ' app-server', timeout=30)
                shell = ShellConsole(runtime, workspace, idle_timeout=30, max_lifetime=60)
                runtime.shell_console = shell
                original_request = runtime.request
                write_calls, exec_results = [], []
                def counted_request(method, params=None, timeout=30):
                    if method == 'command/exec/write':
                        write_calls.append(params.get('processId'))
                    try:
                        result = original_request(method, params, timeout)
                        if method == 'command/exec':
                            exec_results.append(('result', result.get('exitCode')))
                        return result
                    except Exception as error:
                        if method == 'command/exec':
                            exec_results.append(('error', type(error).__name__))
                        raise
                runtime.request = counted_request
                try:
                    runtime.ensure_started()
                    for index in range(3):
                        started = shell.start(24, 80)
                        self.assertEqual(started['state'], 'running')
                        marker = ('SYNTHETIC_COVE_SHELL_' + str(index)).encode()
                        # Intentionally no sleep between start ACK and first write.
                        try:
                            shell.write(started['id'], base64.b64encode(
                                b"printf 'SYNTHETIC_COVE_SHELL_%s\\n' " + str(index).encode() + b"\n").decode())
                        except Exception as error:
                            self.fail(f'write refused after ready: {type(error).__name__}; '
                                      f'state={shell.status(started["id"])["state"]}; '
                                      f'execResults={exec_results}; processPoll={runtime.process.poll()}')
                        cursor, observed, output = 0, False, bytearray()
                        deadline = time.monotonic() + 5
                        while time.monotonic() < deadline and not observed:
                            snapshot = shell.status(started['id'], cursor)
                            cursor = snapshot['cursor']
                            for event in snapshot['events']:
                                output.extend(base64.b64decode(event['dataBase64']))
                            observed = marker in output
                            if not observed: time.sleep(.025)
                        self.assertTrue(observed,
                                        'native PTY did not emit the synthetic marker '
                                        f'(events={cursor}, bytes={len(output)}, '
                                        f'echoOnly={b"printf" in output}, state={snapshot["state"]}, '
                                        f'execResults={exec_results}, '
                                        f'diagnostic={bytes(output).decode("utf-8", "replace").replace(str(base), "<TMP>")!r})')
                        self.assertEqual(shell.resize(started['id'], 30, 100), {'ok': True})
                        self.assertEqual(shell.terminate(started['id']), {'ok': True})
                        self.assertEqual(shell.status(started['id'])['state'], 'terminated')
                    self.assertEqual(len(write_calls), 3)  # never replay a write
                    self.assertEqual(len(set(write_calls)), 3)  # exact new PTY each time
                finally:
                    runtime.close(); store.close()


if __name__ == '__main__':
    unittest.main()
