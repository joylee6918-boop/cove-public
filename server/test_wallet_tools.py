"""Temporary local wallets + actual reader/MCP/callback; no real model or service."""
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, build_opener, ProxyHandler

from runtime import CodexRuntime
from storage import APIError, Store, encode
from wallet import Wallet
from wallet_tools import READ, REQUEST, WALLET_NAMES


class WalletToolTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(self.temp.name)
        self.wallet = Wallet(self.temp.name)
        self.store.create_conversation('a'); self.store.create_conversation('b')
        self.store.bind_thread('a', 'thread')
        self.runtime = CodexRuntime(self.store, self.temp.name)
        self.runtime.wallet = self.wallet
        self.start_turn('user', 'turn')
        self.args = {'amountFen': 100, 'reason': '测试：书'}
        self.wait = patch('runtime.MCP_EVENT_WAIT', .002); self.wait.start()

    def tearDown(self):
        self.wait.stop(); self.runtime.close(); self.wallet.close(); self.store.close(); self.temp.cleanup()

    def start_turn(self, message, turn):
        self.store.accept({'id': message, 'conversationID': 'a', 'text': 'synthetic wallet test'})
        self.job = self.store.claim(); self.store.bind_turn(message, turn, 'thread')
        self.runtime.active = dict(conversation='a', thread='thread', turn=turn, message=message, cancel=threading.Event())
        self.runtime.file_permits.clear()

    def event(self, tool=REQUEST, args=None, call='call', thread='thread', turn=None,
              method='item/started', server='cove_files'):
        # Exercise actual runtime._read filtering, not hand-made permit injection.
        event = {'method': method, 'params': {'threadId': thread, 'turnId': turn or self.runtime.active['turn'],
                 'item': {'type': 'mcpToolCall', 'id': call, 'server': server, 'tool': tool,
                          'arguments': self.args if args is None else args, 'status': 'inProgress'}}}
        process = SimpleNamespace(stdout=io.StringIO(encode(event)+'\n'))
        self.runtime._read(process)

    def invoke(self, tool=REQUEST, args=None, conversation='a'):
        return self.runtime.mcp_file_call(conversation, tool, self.args if args is None else args)

    def test_requires_actual_started_exact_thread_turn_server_tool_and_arguments(self):
        for overrides in ({'thread': 'foreign'}, {'turn': 'stale'}, {'method': 'item/completed'},
                          {'server': 'foreign'}, {'tool': READ}, {'args': dict(self.args, reason='different')},
                          {'args': dict(self.args, amountFen=100.0)}, {'call': ''}):
            with self.subTest(overrides=overrides):
                self.runtime.file_permits.clear(); self.event(**overrides)
                with self.assertRaises(APIError): self.invoke()
        self.assertEqual(self.wallet.snapshot()['purchases'], [])
        self.event(); result = self.invoke()
        self.assertEqual(result['operation'], 'request')
        self.assertEqual(self.wallet.snapshot()['reservedFen'], 100)

    def test_active_scope_cancel_finished_job_and_thread_mapping_fenced(self):
        self.event()
        with self.assertRaises(APIError): self.invoke(conversation='b')
        for key, value in [('thread', 'other'), ('turn', 'other'), ('message', 'missing')]:
            old = self.runtime.active[key]; self.runtime.active[key] = value
            with self.assertRaises(APIError): self.invoke()
            self.runtime.active[key] = old
        self.runtime.active['cancel'].set()
        with self.assertRaises(APIError): self.invoke()
        self.runtime.active['cancel'].clear()
        self.store.bind_thread('a', 'other')
        with self.assertRaises(APIError): self.invoke()
        self.store.bind_thread('a', 'thread')
        self.store.finish('user', 'complete')
        with self.assertRaises(APIError): self.invoke()
        self.assertEqual(self.wallet.snapshot()['purchases'], [])

    def test_cancellation_after_permit_selection_before_wallet_commit_is_denied(self):
        self.event()
        original = self.runtime.execute_bound_file_call
        def cancel(*args):
            self.runtime.active['cancel'].set()
            return original(*args)
        with patch.object(self.runtime, 'execute_bound_file_call', side_effect=cancel):
            with self.assertRaises(APIError): self.invoke()
        self.assertEqual(self.wallet.db.execute('SELECT COUNT(*) FROM model_requests').fetchone()[0], 0)
        self.assertEqual(self.wallet.snapshot()['purchases'], [])

    def test_internal_turns_and_direct_executor_without_event_denied(self):
        with self.assertRaises(APIError):
            self.runtime.execute_bound_file_call('a', REQUEST, self.args, 'user', 'turn', 'invented')
        self.event()
        for key in ('handoffID', 'healthRequestID', 'deviceActionID', 'aisayEventID'):
            with self.store.lock, self.store.db:
                origin = self.store._message('user'); origin[key] = 'internal'; self.store._put(origin)
            with self.assertRaises(APIError): self.invoke()
            with self.store.lock, self.store.db:
                origin.pop(key); self.store._put(origin)
        with self.store.lock, self.store.db:
            origin['role'] = 'system'; self.store._put(origin)
        with self.assertRaises(APIError): self.invoke()
        self.assertEqual(self.wallet.snapshot()['purchases'], [])

    def test_replay_concurrency_and_new_event_never_changes_purchase_identity(self):
        self.event()
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: self.invoke(), range(16)))
        self.assertTrue(all(result == results[0] for result in results))
        self.event(call='new-call')
        with self.assertRaises(APIError): self.invoke()
        self.event(args=dict(self.args, amountFen=101))
        with self.assertRaises(APIError): self.invoke(args=dict(self.args, amountFen=101))
        snapshot = self.wallet.snapshot()
        self.assertEqual((len(snapshot['purchases']), snapshot['balanceFen'], snapshot['reservedFen']), (1, 500, 100))
        row = self.wallet.db.execute('SELECT * FROM model_requests').fetchone()
        self.assertEqual(row['event'], 'call')
        self.assertEqual(json.loads(row['scope']), ['a', 'thread', 'user', 'turn'])
        self.assertEqual(row['id'], results[0]['purchaseID'])
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0], 1)
        self.assertNotIn('wallet', self.store._message(self.job['assistant']))
        self.wallet.mutate('review', {'id': 'owner-approval', 'purchaseID': results[0]['purchaseID'], 'decision': 'approve'})
        self.event(READ, {})
        approved = self.invoke(READ, {})
        self.assertEqual(approved['purchases'][0]['status'], 'approved')
        self.assertEqual((approved['balanceFen'], approved['reservedFen']), (400, 0))

    def test_lost_ack_recovers_original_receipt_after_wallet_reopen_without_dispatch(self):
        original = self.wallet.mutate
        def lost(*args):
            original(*args)
            raise OSError('synthetic private diagnostic must not leak')
        self.event()
        with patch.object(self.wallet, 'mutate', side_effect=lost):
            with self.assertRaises(APIError) as caught: self.invoke()
        self.assertNotIn('private', caught.exception.message)
        self.wallet.close(); self.wallet = Wallet(self.temp.name); self.runtime.wallet = self.wallet
        with patch.object(self.wallet, 'mutate', side_effect=AssertionError('no replay')):
            receipt = self.invoke()
        self.assertEqual(receipt['purchaseID'], self.wallet.snapshot()['purchases'][0]['id'])
        self.assertEqual(len(self.wallet.snapshot()['purchases']), 1)
        self.store.finish('user', 'complete'); self.start_turn('next-user', 'next-turn')
        self.event(call='replacement-after-lost-ack')
        with self.assertRaises(APIError) as rejected: self.invoke()
        self.assertIn(receipt['purchaseID'], rejected.exception.message)
        self.assertEqual(len(self.wallet.snapshot()['purchases']), 1)

    def test_unknown_before_commit_survives_restart_blocks_new_event_and_later_turn(self):
        self.event()
        with patch.object(self.wallet, 'mutate', side_effect=OSError('synthetic failed dispatch')):
            with self.assertRaises(APIError): self.invoke()
        self.wallet.close(); self.wallet = Wallet(self.temp.name); self.runtime.wallet = self.wallet
        with patch.object(self.wallet, 'mutate', side_effect=AssertionError('must never replay')):
            with self.assertRaises(APIError): self.invoke()
            self.event(call='replacement')
            with self.assertRaises(APIError): self.invoke()
            self.runtime.close(); self.store.close()
            self.store = Store(self.temp.name)
            self.runtime = CodexRuntime(self.store, self.temp.name); self.runtime.wallet = self.wallet
            self.assertIsNone(self.store.claim())  # uncertain old job never replayed
            with self.assertRaises(APIError): self.invoke()
            self.start_turn('next-user', 'next-turn'); self.event(call='next-call')
            with self.assertRaises(APIError): self.invoke()
        self.event(READ, {})
        self.assertEqual(self.invoke(READ, {})['purchases'], [])
        self.assertEqual(self.wallet.db.execute('SELECT COUNT(*) FROM model_requests').fetchone()[0], 1)

    def test_definitive_rejection_is_durable_but_does_not_block_later_turn(self):
        args = dict(self.args, amountFen=501)
        self.event(args=args)
        with self.assertRaises(APIError): self.invoke(args=args)
        with patch.object(self.wallet, 'mutate', side_effect=AssertionError('no replay')):
            with self.assertRaises(APIError): self.invoke(args=args)
        self.store.finish('user', 'complete'); self.start_turn('next-user', 'next-turn'); self.event()
        self.assertEqual(self.invoke()['operation'], 'request')

    def test_credit_review_and_privilege_arguments_denied_even_with_started_event(self):
        for name in ('credit', 'review', 'approve', 'deny', 'cancel', 'fulfill'):
            tool = 'cove_wallet_'+name
            self.event(tool)
            with self.assertRaises(APIError): self.invoke(tool)
            answers = []
            with patch.object(self.runtime, '_send', side_effect=answers.append):
                self.runtime._server_request({'id': 'dynamic', 'method': 'item/tool/call', 'params': {
                    'threadId': 'thread', 'turnId': 'turn', 'tool': tool, 'arguments': self.args}})
            self.assertFalse(answers[0]['result']['success'])
        for extra in ({'wallet': 'ian'}, {'id': 'chosen'}, {'operation': 'credit'},
                      {'decision': 'approve'}, {'purchaseID': 'other'}):
            args = dict(self.args, **extra); self.event(args=args)
            with self.assertRaises(APIError): self.invoke(args=args)
        for value in (True, 100.0, -1, 0):
            args = dict(self.args, amountFen=value); self.event(args=args)
            with self.assertRaises(APIError): self.invoke(args=args)
        self.event(READ, {'wallet': 'ian'})
        with self.assertRaises(APIError): self.invoke(READ, {'wallet': 'ian'})
        self.assertEqual(self.wallet.snapshot()['balanceFen'], 500)
        self.assertEqual(self.wallet.snapshot()['purchases'], [])

    def test_loopback_capability_is_not_owner_token_or_sufficient_without_event(self):
        config = self.runtime.file_config('a')['mcp_servers.cove_files']['env']
        opener = build_opener(ProxyHandler({}))
        def call(token):
            request = Request(config['COVE_FILE_CALLBACK_URL'], data=encode({'tool': REQUEST, 'arguments': self.args}).encode(),
                              headers={'Authorization': 'Bearer '+token, 'Content-Type': 'application/json'})
            with opener.open(request, timeout=2) as response: return json.load(response)
        with self.assertRaises(HTTPError) as rejected: call('synthetic-owner-token')
        self.assertEqual(rejected.exception.code, 401)
        with self.assertRaises(HTTPError) as rejected: call(config['COVE_FILE_CALLBACK_TOKEN'])
        self.assertEqual(rejected.exception.code, 409)
        self.event()
        self.assertEqual(call(config['COVE_FILE_CALLBACK_TOKEN'])['operation'], 'request')

    def test_stdio_discovery_exactly_two_wallet_tools_and_no_retry_on_transport_failure(self):
        env = dict(os.environ, COVE_FILE_CALLBACK_URL='http://127.0.0.1:1/call', COVE_FILE_CALLBACK_TOKEN='synthetic',
                   NO_PROXY='127.0.0.1,localhost', no_proxy='127.0.0.1,localhost')
        env.pop('COVE_FILE_CAPABILITY_PATH', None)
        commands = [{'id': 1, 'method': 'tools/list'},
                    {'id': 2, 'method': 'tools/call', 'params': {'name': REQUEST, 'arguments': self.args}}]
        result = subprocess.run([sys.executable, str(Path(__file__).with_name('files_mcp.py'))],
                                input=''.join(encode(c)+'\n' for c in commands), text=True,
                                capture_output=True, env=env, timeout=5, check=True)
        listed, failed = [json.loads(line)['result'] for line in result.stdout.splitlines()]
        tools = {t['name']: t for t in listed['tools']}
        wallet_names = {name for name in tools if 'wallet' in name or 'purchase' in name}
        self.assertEqual(wallet_names, WALLET_NAMES)
        self.assertTrue(tools[READ]['annotations']['readOnlyHint'])
        self.assertFalse(tools[REQUEST]['annotations']['readOnlyHint'])
        self.assertEqual(set(tools[REQUEST]['inputSchema']['properties']), {'amountFen', 'reason'})
        self.assertTrue(failed['isError']); self.assertIn('do not issue a new purchase', failed['content'][0]['text'])


class WalletStdioIntegrationTests(unittest.TestCase):
    def test_new_and_original_resumed_thread_real_stdio_mcp_path(self):
        command = shlex.quote(sys.executable)+' '+shlex.quote(str(Path(__file__).with_name('fake_app_server.py')))
        with tempfile.TemporaryDirectory() as directory:
            store = Store(directory); wallet = Wallet(directory)
            runtime = CodexRuntime(store, directory, command, timeout=8); runtime.wallet = wallet
            try:
                store.create_conversation('new'); store.create_conversation('old'); store.bind_thread('old', 'original-thread')
                for conversation in ('new', 'old'):
                    store.accept({'id': conversation, 'conversationID': conversation, 'text': 'COVE_TEST_WALLET'})
                    job = store.claim(); status, error = runtime.run(job, threading.Event()); store.finish(job['message'], status, error)
                    self.assertEqual(status, 'complete', error)
                    self.assertIn('synthetic wallet', store._message(job['assistant'])['text'])
                self.assertEqual(store.conversation('old')['thread'], 'original-thread')
                self.assertEqual(len(wallet.snapshot()['purchases']), 2)
                self.assertEqual(wallet.snapshot()['reservedFen'], 200)
                self.assertEqual(store.db.execute('SELECT count(*) FROM jobs').fetchone()[0], 2)
            finally:
                runtime.close(); wallet.close(); store.close()


if __name__ == '__main__': unittest.main()
