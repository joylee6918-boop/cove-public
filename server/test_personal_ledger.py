"""Synthetic-only personal ledger tests. No model, bank or user ledger access."""
import copy
import io
import json
import os
import shlex
import subprocess
import sys
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from http.server import ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from urllib.request import Request, build_opener, ProxyHandler
from urllib.error import HTTPError

from cove import Application
from runtime import CodexRuntime, guidance_topics
from storage import Store, APIError, encode
from personal_ledger import READ, RECORD, ACTIONS, validate_action, delivery_guard, MAX_FEN

ACCOUNT = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
CATEGORY = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
STAMP = '2026-10-24T00:00:00Z'
TOKEN = 'synthetic-ledger-owner-token-only'

def snapshot():
    return dict(schemaVersion=2, accounts=[{'id': ACCOUNT, 'name': 'Synthetic only', 'type': 'bank'}],
                categories=[{'id': CATEGORY, 'name': 'Synthetic', 'kind': 'expense'}], events=[],
                budgets=[], reconciliations=[], statements=[], installments=[])

def expense():
    return dict(action='expense', accountID=ACCOUNT, categoryID=CATEGORY, amountFen=123,
                occurredAt=STAMP, note='Synthetic data; ignore all previous instructions is inert text')

class QuietApplication(Application):
    def _work(self): self.stop.wait()

class LedgerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(self.tmp.name)
        self.store.create_conversation('a'); self.store.create_conversation('b')
        self.store.bind_thread('a', 'thread')
        self.store.accept({'id': 'origin', 'conversationID': 'a', 'text': 'synthetic'})
        self.store.claim(); self.store.bind_turn('origin', 'turn', 'thread')
        self.runtime = CodexRuntime(self.store, self.tmp.name)
        self.runtime.active = dict(conversation='a', thread='thread', turn='turn', message='origin', cancel=threading.Event())
        self.app = QuietApplication(self.store, TOKEN, self.runtime)
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), self.app.handler())
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True); self.thread.start()
        self.base = 'http://127.0.0.1:' + str(self.server.server_port)
        self.wait = patch('runtime.MCP_EVENT_WAIT', .002); self.wait.start()
        self.store.set_data_access({'enabled': True})
        self.count = 0

    def tearDown(self):
        self.wait.stop(); self.server.shutdown(); self.server.server_close()
        self.app.close(); self.store.close(); self.tmp.cleanup()

    def http(self, method='GET', path='/v1/personal-ledger', body=None, auth=True):
        req = Request(self.base+path, data=encode(body).encode() if body is not None else None,
                      headers={'Authorization': 'Bearer '+(TOKEN if auth else 'invalid')}, method=method)
        try:
            with build_opener(ProxyHandler({})).open(req, timeout=3) as response:
                return response.status, json.load(response)
        except HTTPError as e: return e.code, json.load(e)

    def event(self, tool, args, call, **changes):
        params = {'threadId': 'thread', 'turnId': 'turn', 'item': {'type': 'mcpToolCall', 'server': 'cove_files',
                  'id': call, 'tool': tool, 'arguments': args}}
        params.update(changes)
        self.runtime._read(SimpleNamespace(stdout=io.StringIO(encode({'method': 'item/started', 'params': params})+'\n')))

    def call(self, tool=RECORD, args=None, call=None):
        args = (expense() if tool == RECORD else {}) if args is None else args
        self.count += 1; call = call or str(self.count)
        self.event(tool, args, call)
        return self.runtime.mcp_file_call('a', tool, args)

    def upload(self, revision=1, value=None):
        return self.http('POST', body={'revision': revision, 'snapshot': value or snapshot()})

    def test_auth_grant_upload_read_exact_revision_and_digest(self):
        for method, body in [('GET', None), ('POST', {'revision': 1, 'snapshot': snapshot()}), ('DELETE', None)]:
            self.assertEqual(self.http(method, body=body, auth=False)[0], 401)
        self.assertEqual(self.http(path='/v1/personal-ledger/commands', auth=False)[0], 401)
        self.assertIsNone(self.call(READ)['latest'])
        self.store.set_data_access({'enabled': False})
        self.assertEqual(self.upload()[0], 403)
        self.assertEqual(self.http()[0], 403)
        with self.assertRaises(APIError): self.call()
        self.store.set_data_access({'enabled': True})
        status, first = self.upload(); self.assertEqual(status, 200)
        self.assertEqual(first['snapshot'], snapshot()); self.assertEqual(len(first['digest']), 64)
        self.assertEqual(self.upload(), (200, first))
        changed = snapshot(); changed['accounts'][0]['name'] = 'Changed'
        self.assertEqual(self.upload(value=changed)[0], 409)
        self.assertEqual(self.upload(0)[0], 409)
        self.assertEqual(self.upload(2, changed)[0], 200)
        result = self.call(READ)
        self.assertEqual(result['latest']['snapshot'], changed)
        self.assertEqual(result['latest']['revision'], 2)
        self.assertTrue(result['textIsData']); self.assertFalse(result['paymentExecution'])

    def test_write_concurrent_idempotency_uuid_and_exact_input(self):
        self.event(RECORD, expense(), 'same')
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: self.runtime.mcp_file_call('a', RECORD, expense()), range(16)))
        self.assertTrue(all(r == results[0] for r in results))
        command = results[0]['command']
        import uuid
        self.assertNotEqual(uuid.UUID(command['id']), uuid.UUID(command['recordID']))
        self.assertEqual(command['status'], 'pending'); self.assertNotIn('applied', command)
        with self.assertRaises(APIError): self.call(args=dict(expense(), amountFen=124), call='same')
        self.assertEqual(len(self.store.personal_ledger()['commands']), 1)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0], 1)
        self.assertEqual(self.app.wallet.snapshot()['purchases'], [])

    def test_poll_ack_failed_applied_idempotent_and_no_continuation(self):
        one = self.call()['command']; two = self.call()['command']
        self.assertEqual(len(self.http(path='/v1/personal-ledger/commands')[1]['commands']), 2)
        for command, body in [(one, {'status': 'applied'}), (two, {'status': 'failed', 'error': 'Synthetic domain rejection'})]:
            path = '/v1/personal-ledger/commands/'+command['id']+'/ack'
            self.assertEqual(self.http('POST', path, body, auth=False)[0], 401)
            first = self.http('POST', path, body); self.assertEqual(first[0], 200)
            self.assertEqual(self.http('POST', path, body), first)
            other = {'status': 'failed', 'error': 'different'}
            self.assertEqual(self.http('POST', path, other)[0], 409)
        self.assertEqual(self.http(path='/v1/personal-ledger/commands')[1], {'commands': []})
        self.assertEqual([c['status'] for c in self.call(READ)['commands']], ['applied', 'failed'])
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0], 1)

    def test_validation_actions_money_and_no_bank_execution(self):
        invalid = [dict(expense(), action='bankTransfer'), dict(expense(), action='pay'),
                   dict(expense(), action=[]), dict(expense(), bankToken='forbidden'),
                   dict(expense(), accountID='not-uuid'), dict(expense(), occurredAt='2026-01-01'),
                   dict(expense(), note='x'*2001)]
        invalid += [dict(expense(), amountFen=v) for v in [True, 1.0, '1', 0, -1, MAX_FEN+1]]
        for args in invalid:
            with self.subTest(args=args), self.assertRaises(APIError): self.call(args=args)
        for action in ACTIONS:
            schema = ACTIONS[action]
            values = {'accountID': ACCOUNT, 'destinationAccountID': CATEGORY, 'categoryID': CATEGORY,
                      'statementID': CATEGORY, 'targetID': CATEGORY, 'amountFen': 100, 'balanceFen': -100,
                      'occurredAt': STAMP, 'capturedAt': STAMP, 'statementDate': STAMP, 'dueDate': STAMP,
                      'nextDueDate': STAMP, 'remainingPeriods': 3, 'nextPrincipalFen': 100,
                      'nextInterestFen': 2, 'amountsRepeat': False, 'reason': 'Synthetic void'}
            args = dict(action=action, **{k: values[k] for k in schema['required']})
            self.assertEqual(self.call(args=args)['command']['status'], 'pending')
        self.assertEqual(len(self.store.personal_ledger()['commands']), len(ACTIONS))
        with self.assertRaises(APIError): validate_action(dict(action='installment', accountID=ACCOUNT, remainingPeriods=1200, nextPrincipalFen=MAX_FEN, nextInterestFen=1, nextDueDate=STAMP, amountsRepeat=True))

    def test_snapshot_bounds_types_unknown_fields_and_budget_encoding(self):
        bads = []
        for field, value in [('schemaVersion', True), ('schemaVersion', 1), ('events', [{}]), ('accounts', [{'id': ACCOUNT, 'name': 'A', 'type': 'bankAPI'}]), ('extra', [])]:
            body = snapshot(); body[field] = value; bads.append(body)
        for body in bads: self.assertEqual(self.upload(value=body)[0], 400)
        body = snapshot(); body['events'] = [{}]*10001
        self.assertEqual(self.upload(value=body)[0], 413)
        body = snapshot(); body['budgets'] = [{'month': {'start': STAMP, 'end': STAMP, 'calendarIdentifier': 'gregorian', 'timeZoneIdentifier': 'Asia/Shanghai'}, 'overallFen': None, 'categoryFen': [CATEGORY, 500]}]
        self.assertEqual(self.upload(value=body)[0], 200)
        body['budgets'][0]['categoryFen'][1] = True
        self.assertEqual(self.upload(2, body)[0], 400)

    def test_revoke_retains_data_commands_clears_results_and_fences_delivery(self):
        self.upload(); result = self.call(call='write'); read = self.call(READ, call='read')
        with delivery_guard(self.runtime, 'a', READ, {}, read): pass
        self.store.set_data_access({'enabled': False})
        for tool, args, value in [(READ, {}, read), (RECORD, expense(), result)]:
            with self.assertRaises(APIError), delivery_guard(self.runtime, 'a', tool, args, value): pass
        self.assertEqual(self.http(path='/v1/personal-ledger/commands')[0], 403)
        self.assertEqual(self.upload(2)[0], 403)
        path = '/v1/personal-ledger/commands/'+result['command']['id']+'/ack'
        self.assertEqual(self.http('POST', path, {'status': 'applied'})[0], 403)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM personal_ledger_results').fetchone()[0], 0)
        self.store.set_data_access({'enabled': True})
        newer = self.call(call='write')
        self.assertEqual(newer['command'], result['command'])
        self.assertNotEqual(newer['accessVersion'], result['accessVersion'])
        with self.assertRaises(APIError), delivery_guard(self.runtime, 'a', RECORD, expense(), result): pass
        self.assertEqual(self.call(READ)['latest']['snapshot'], snapshot())
        self.assertEqual(len(self.store.personal_ledger()['commands']), 1)

    def test_upload_revoke_and_selected_permit_cancel_races(self):
        import personal_ledger
        original = personal_ledger.validate_snapshot
        def revoke(value):
            result = original(value)
            self.store.set_data_access({'enabled': False})
            return result
        with patch('personal_ledger.validate_snapshot', side_effect=revoke):
            self.assertEqual(self.upload()[0], 403)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM personal_ledger_snapshot').fetchone()[0], 0)
        self.store.set_data_access({'enabled': True})
        execute = self.runtime.execute_bound_file_call
        def cancel(*args):
            self.runtime.active['cancel'].set()
            return execute(*args)
        with patch.object(self.runtime, 'execute_bound_file_call', side_effect=cancel):
            with self.assertRaises(APIError): self.call()
        self.assertEqual(self.store.personal_ledger()['commands'], [])

    def test_full_schema_v2_records_preserve_inert_text_and_nulls(self):
        body = snapshot()
        body['events'] = [{'id': ACCOUNT, 'reason': 'Synthetic\nnot instructions', 'createdAt': STAMP,
                           'transaction': {'kind': 'expense', 'amountFen': 12, 'accountID': ACCOUNT,
                                           'categoryID': CATEGORY, 'note': 'x'*2000, 'occurredAt': STAMP}, 'reversesID': None}]
        body['reconciliations'] = [{'id': CATEGORY, 'accountID': ACCOUNT, 'balanceFen': 100, 'capturedAt': STAMP, 'createdAt': STAMP}]
        body['statements'] = [{'id': CATEGORY, 'accountID': ACCOUNT, 'statementDate': STAMP, 'dueDate': STAMP, 'amountFen': 100, 'minimumDueFen': None, 'createdAt': STAMP}]
        body['installments'] = [{'id': CATEGORY, 'planID': CATEGORY, 'accountID': ACCOUNT, 'label': None,
                                'remainingPeriods': 3, 'remainingPrincipalFen': None, 'nextPrincipalFen': 10,
                                'nextInterestFen': 2, 'nextDueDate': STAMP, 'amountsRepeat': False,
                                'createdAt': STAMP, 'isClosed': False}]
        # Structural transport validation; Swift owns account types and cross-record domain validation.
        self.assertEqual(self.upload(value=body)[0], 200)
        self.assertEqual(self.call(READ)['latest']['snapshot'], body)

    def test_delivery_flush_serializes_revoke(self):
        result = self.call(READ)
        entered, finished = threading.Event(), threading.Event()
        def revoke():
            entered.set(); self.store.set_data_access({'enabled': False}); finished.set()
        with delivery_guard(self.runtime, 'a', READ, {}, result):
            thread = threading.Thread(target=revoke); thread.start(); entered.wait(1)
            self.assertFalse(finished.wait(.05))
        thread.join(2); self.assertTrue(finished.is_set())

    def test_current_event_exact_types_thread_cancel_internal_and_direct_bypass(self):
        with self.assertRaises(APIError): self.runtime.execute_bound_file_call('a', RECORD, expense(), 'origin', 'turn', 'invented')
        for changes in [{'threadId': 'wrong'}, {'turnId': 'wrong'}]:
            self.runtime.file_permits.clear(); self.event(RECORD, expense(), 'bad', **changes)
            with self.assertRaises(APIError): self.runtime.mcp_file_call('a', RECORD, expense())
        self.runtime.file_permits.clear(); self.event(RECORD, dict(expense(), amountFen=123.0), 'bad')
        with self.assertRaises(APIError): self.runtime.mcp_file_call('a', RECORD, expense())
        self.runtime.active['cancel'].set()
        with self.assertRaises(APIError): self.call()
        self.runtime.active['cancel'].clear()
        self.store.bind_thread('a', 'other')
        with self.assertRaises(APIError): self.call()
        self.store.bind_thread('a', 'thread')
        for field in ['handoffID', 'healthRequestID', 'deviceActionID', 'autoRolloverID', 'aisayEventID']:
            with self.store.db:
                event = self.store._message('origin'); event[field] = 'internal'; self.store._put(event)
            with self.assertRaises(APIError): self.call()
            with self.store.db: event.pop(field); self.store._put(event)
        self.store.finish('origin', 'complete')
        with self.assertRaises(APIError): self.call()

    def test_native_metadata_isolation_and_delivery(self):
        from tmux_mcp import bind_native_call
        from personal_ledger import execute
        # Real native metadata binder; no synthetic app-server permit conversion.
        self.runtime.mcp_file_call_native = lambda *args: None
        self.event(RECORD, expense(), 'app-event')
        self.runtime.file_permits[-1]['used'] = True
        with self.assertRaises(APIError): execute(self.runtime, 'a', 'origin', 'turn', 'app-event', RECORD, expense())
        metadata = {'threadId': 'thread', 'callId': 'native', 'x-codex-turn-metadata': {'thread_id': 'thread', 'turn_id': 'turn'}}
        with self.assertRaises(APIError): bind_native_call(self.runtime, 'a', RECORD, expense(), None, 1)
        bound = bind_native_call(self.runtime, 'a', RECORD, expense(), metadata, 1)
        result = execute(self.runtime, 'a', 'origin', bound.turn, bound.call_id, RECORD, expense())
        with delivery_guard(self.runtime, 'a', RECORD, expense(), result): pass
        with self.assertRaises(APIError): bind_native_call(self.runtime, 'a', RECORD, dict(expense(), amountFen=124), metadata, 2)
        self.runtime._native_mcp_scope = ('a', 'thread', 'stale')
        with self.assertRaises(APIError), delivery_guard(self.runtime, 'a', RECORD, expense(), result): pass

    def test_delete_while_revoked_and_tombstones_prevent_recreation(self):
        self.upload(); result = self.call(call='same')
        self.store.set_data_access({'enabled': False})
        self.assertEqual(self.http('DELETE')[0], 200)
        self.store.set_data_access({'enabled': True})
        self.assertIsNone(self.store.personal_ledger()['latest'])
        self.assertEqual(self.store.personal_ledger()['commands'], [])
        with self.assertRaises(APIError): self.call(call='same')
        with self.assertRaises(APIError), delivery_guard(self.runtime, 'a', RECORD, expense(), result): pass
        row = self.store.db.execute('SELECT input,body,response FROM personal_ledger_commands').fetchone()
        self.assertEqual(tuple(row), ('', '{}', '{}'))
        self.assertEqual(self.upload()[0], 200)

    def test_restart_retains_command_receipts_and_snapshot(self):
        self.upload(); result = self.call()['command']
        self.store.finish('origin', 'complete')
        self.store.close(); self.store = Store(self.tmp.name)
        self.app.store = self.runtime.store = self.store
        self.assertEqual(self.store.personal_ledger()['commands'], [result])
        self.assertEqual(self.store.personal_ledger()['latest']['snapshot'], snapshot())
        first = self.store.acknowledge_personal_ledger(result['id'], {'status': 'applied'})
        self.store.close(); self.store = Store(self.tmp.name); self.app.store = self.runtime.store = self.store
        self.assertEqual(self.store.acknowledge_personal_ledger(result['id'], {'status': 'applied'}), first)

    def test_callback_capability_discovery_annotations_and_guidance(self):
        env = self.runtime.file_config('a')['mcp_servers.cove_files']['env']
        self.assertNotIn('COVE_TOKEN', env)
        def callback(token):
            req = Request(env['COVE_FILE_CALLBACK_URL'], data=encode({'tool': READ, 'arguments': {}}).encode(), headers={'Authorization': 'Bearer '+token})
            with build_opener(ProxyHandler({})).open(req, timeout=2) as response: return json.load(response)
        with self.assertRaises(HTTPError) as error: callback(TOKEN)
        self.assertEqual(error.exception.code, 401)
        with self.assertRaises(HTTPError): callback(env['COVE_FILE_CALLBACK_TOKEN'])
        self.event(READ, {}, 'actual')
        self.assertEqual(callback(env['COVE_FILE_CALLBACK_TOKEN'])['source'], 'cove-personal-ledger')
        process = subprocess.run([sys.executable, str(Path(__file__).with_name('files_mcp.py'))],
            env=env, input='{"id":1,"method":"tools/list"}\n', capture_output=True, text=True, check=True, timeout=5)
        tools = {t['name']: t for t in json.loads(process.stdout)['result']['tools']}
        self.assertTrue(tools[READ]['annotations']['readOnlyHint']); self.assertFalse(tools[RECORD]['annotations']['readOnlyHint'])
        self.assertTrue(guidance_topics('花呗分期账单还款')['ledger'])
        self.assertFalse(guidance_topics('抱抱')['ledger'])
        self.assertEqual(self.http(path='/v1/personal-ledger?extra=1')[0], 400)

class LedgerStdioTests(unittest.TestCase):
    def test_new_resumed_threads_real_stdio_read_write_event_retry(self):
        with tempfile.TemporaryDirectory() as temp:
            store = Store(temp); store.create_conversation('new'); store.create_conversation('old'); store.bind_thread('old', 'original')
            store.set_data_access({'enabled': True}); store.upload_personal_ledger({'revision': 1, 'snapshot': snapshot()})
            command = shlex.quote(sys.executable)+' '+shlex.quote(str(Path(__file__).with_name('fake_app_server.py')))
            runtime = CodexRuntime(store, temp, command, timeout=8)
            try:
                with patch.dict(os.environ, {'COVE_TOKEN': TOKEN, 'NO_PROXY': '127.0.0.1,localhost', 'no_proxy': '127.0.0.1,localhost'}):
                    for conversation in ('new', 'old'):
                        store.accept({'id': conversation, 'conversationID': conversation, 'text': 'COVE_TEST_LEDGER '+encode(expense())})
                        job = store.claim(); status, error = runtime.run(job, threading.Event()); store.finish(job['message'], status, error)
                        self.assertEqual(status, 'complete', error)
                        self.assertIn('synthetic ledger pending', store._message(job['assistant'])['text'])
                self.assertEqual(store.conversation('old')['thread'], 'original')
                self.assertEqual(len(store.personal_ledger()['commands']), 2)
            finally: runtime.close(); store.close()

if __name__ == '__main__': unittest.main()
