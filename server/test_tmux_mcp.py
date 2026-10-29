"""Synthetic native MCP binding and callback tests; never invoke a model."""
import json
import os
import io
import tempfile
import threading
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from unittest.mock import patch

from file_bridge import FileBridge
import files_mcp
from storage import APIError
from tmux_mcp import bind_native_call


class NativeRuntime:
    def __init__(self):
        self.state_lock = threading.RLock()
        self.active = {'conversation': 'c', 'thread': 't', 'turn': 'u', 'cancel': threading.Event()}
        self.calls = []

    def mcp_file_call_native(self, conversation, tool, arguments, metadata, rpc_id):
        call = bind_native_call(self, conversation, tool, arguments, metadata, rpc_id)
        self.calls.append(call)
        return {'call': call.call_id}


class LegacyRuntime:
    def __init__(self):
        self.calls = []

    def mcp_file_call(self, conversation, tool, arguments):
        self.calls.append((conversation, tool, arguments))
        return {'ok': True}


def meta(call='call-1', thread='t', turn='u'):
    return {'callId': call, 'threadId': thread,
            'x-codex-turn-metadata': {'thread_id': thread, 'turn_id': turn}}


class NativeBindingTests(unittest.TestCase):
    def setUp(self):
        self.runtime = NativeRuntime()

    def bind(self, metadata=None, arguments=None, rpc_id=1):
        return bind_native_call(self.runtime, 'c', 'cove_list_stickers',
                                {} if arguments is None else arguments,
                                meta() if metadata is None else metadata, rpc_id)

    def test_valid_native_id_and_same_call_retry(self):
        call = self.bind()
        self.assertEqual((call.conversation, call.thread, call.turn, call.call_id, call.rpc_id),
                         ('c', 't', 'u', 'call-1', 1))
        self.assertEqual(self.bind(rpc_id=2).call_id, 'call-1')

    def test_missing_mismatch_and_cancel_fail_closed(self):
        for bad in ({}, {'callId': 'x', 'threadId': 't'}, meta(thread='other'), meta(turn='other')):
            with self.subTest(bad=bad), self.assertRaises(APIError):
                self.bind(metadata=bad)
        with self.assertRaises(APIError):
            bind_native_call(self.runtime, 'other', 'cove_list_stickers', {}, meta(), 1)
        self.runtime.active['cancel'].set()
        with self.assertRaises(APIError):
            self.bind()

    def test_call_id_argument_conflict(self):
        self.bind(arguments={'a': 1})
        with self.assertRaises(APIError) as caught:
            self.bind(arguments={'a': 2})
        self.assertEqual(caught.exception.status, 409)

    def test_no_argument_field_can_supply_missing_metadata(self):
        with self.assertRaises(APIError):
            self.bind(metadata={}, arguments={'_meta': meta(), 'callId': 'call-1'})

    def test_native_capability_file_private_scope_and_no_argv_secret(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            bridge = FileBridge(self.runtime, persistence_path=root / 'bridge.json')
            try:
                config = bridge.cli_config('c')
                env = config['mcp_servers.cove_files']['env']
                self.assertEqual(set(env), {'COVE_FILE_CAPABILITY_PATH'})
                private = Path(env['COVE_FILE_CAPABILITY_PATH'])
                self.assertEqual(private.stat().st_mode & 0o777, 0o600)
                with patch.dict('os.environ', env):
                    callback, token = files_mcp.callback_credentials()
                self.assertTrue(callback.startswith('http://127.0.0.1:'))
                self.assertNotIn(token, json.dumps(config))
                self.assertEqual(bridge.cli_config('c'), config)
                os.chmod(private, 0o644)
                with patch.dict('os.environ', env), self.assertRaises(RuntimeError):
                    files_mcp.callback_credentials()
            finally:
                bridge.close()

    def test_stdio_mcp_forwards_protocol_metadata_and_rpc_id(self):
        captured = []

        class Response:
            def __enter__(self): return self
            def __exit__(self, *_): pass
            def read(self): return b'{"ok":true}'

        def fake_urlopen(request, **_):
            captured.append(json.loads(request.data))
            return Response()

        command = {'jsonrpc': '2.0', 'id': 17, 'method': 'tools/call',
                   'params': {'name': 'cove_list_stickers', 'arguments': {}, '_meta': meta()}}
        output = io.StringIO()
        with patch.dict('os.environ', {'COVE_FILE_CALLBACK_URL': 'http://127.0.0.1:1/call',
                                       'COVE_FILE_CALLBACK_TOKEN': 'synthetic-invalid-token'}), \
             patch.object(files_mcp.sys, 'stdin', io.StringIO(json.dumps(command) + '\n')), \
             patch.object(files_mcp.sys, 'stdout', output), patch.object(files_mcp, 'urlopen', fake_urlopen):
            files_mcp.main()
        self.assertEqual(captured, [{'tool': 'cove_list_stickers', 'arguments': {},
                                     'metadata': meta(), 'rpcID': 17}])
        self.assertEqual(json.loads(output.getvalue())['id'], 17)


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name).resolve()
        self.directory.chmod(0o700)
        self.path = self.directory / 'callback.json'
        self.bridges = []

    def tearDown(self):
        for bridge in reversed(self.bridges):
            bridge.close()
        self.temp.cleanup()

    def bridge(self, runtime, persist=True):
        bridge = FileBridge(runtime, persistence_path=self.path if persist else None)
        self.bridges.append(bridge)
        return bridge

    def post(self, config, body):
        env = config['mcp_servers.cove_files']['env']
        request = Request(env['COVE_FILE_CALLBACK_URL'], data=json.dumps(body).encode(),
                          headers={'Authorization': 'Bearer ' + env['COVE_FILE_CALLBACK_TOKEN'],
                                   'Content-Type': 'application/json'}, method='POST')
        try:
            with urlopen(request, timeout=2) as response:
                return response.status, json.loads(response.read())
        except HTTPError as error:
            return error.code, json.loads(error.read())

    def test_native_metadata_forwarded_and_missing_rejected(self):
        runtime = NativeRuntime()
        bridge = self.bridge(runtime)
        config = bridge.config('c')
        body = {'tool': 'cove_list_stickers', 'arguments': {}, 'metadata': meta(), 'rpcID': 7}
        self.assertEqual(self.post(config, body), (200, {'call': 'call-1'}))
        self.assertEqual(runtime.calls[0].rpc_id, 7)
        body.pop('metadata')
        self.assertEqual(self.post(config, body)[0], 400)
        self.assertEqual(len(runtime.calls), 1)

    def test_legacy_runtime_keeps_original_dispatch(self):
        runtime = LegacyRuntime()
        bridge = self.bridge(runtime, persist=False)
        config = bridge.config('c')
        self.assertEqual(self.post(config, {'tool': 'cove_list_stickers', 'arguments': {},
                                            'metadata': {'junk': True}, 'rpcID': 4}),
                         (200, {'ok': True}))
        self.assertEqual(runtime.calls, [('c', 'cove_list_stickers', {})])

    def test_fixed_port_and_token_survive_restart(self):
        first = self.bridge(LegacyRuntime())
        config = first.config('c')
        with self.assertRaises(RuntimeError):
            self.bridge(LegacyRuntime())
        first.close(); self.bridges.remove(first)
        second = self.bridge(LegacyRuntime())
        self.assertEqual(second.config('c')['mcp_servers.cove_files']['env'],
                         config['mcp_servers.cove_files']['env'])

    def test_symlinked_state_rejected(self):
        target = self.directory / 'target'
        target.write_text('{}')
        self.path.symlink_to(target)
        with self.assertRaises(ValueError):
            self.bridge(LegacyRuntime())


if __name__ == '__main__':
    unittest.main()
