"""Focused HTTP + durable-storage tests; fake runtime never sends a real model message."""
import base64
import json
import tempfile
import threading
import time
import sys
import shlex
import unittest
from unittest.mock import patch
from http.server import ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from urllib.parse import urlencode

from cove import Application, health_snapshot
from runtime import CodexRuntime
from storage import Store, now

TOKEN = 'test-only-independent-cove-token-12345'


class FakeRuntime:
    def __init__(self, store):
        self.store = store; self.calls = []; self.gate = threading.Event(); self.gate.set()
        self.running = threading.Event()

    def run(self, job, cancelled):
        self.calls.append(job['message']); self.running.set()
        self.store.bind_thread(job['user']['conversationID'], 'fake-' + job['user']['conversationID'])
        self.store.bind_turn(job['message'], 'turn-' + job['message'])
        self.store.stream(job['message'], '正在')
        while not self.gate.wait(.01):
            if cancelled.is_set():
                return 'interrupted', None
        self.store.stream(job['message'], '回复：' + job['user']['text'])
        return 'complete', None

    def interrupt(self, _, cancelled=None):
        pass

    def usage(self):
        raise RuntimeError('unavailable')

    def close(self):
        self.gate.set()


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.store = Store(self.temp.name)
        self.runtime = FakeRuntime(self.store)
        self.pulse = Path(self.temp.name) / 'pulse.json'
        self.app = Application(self.store, TOKEN, self.runtime, str(self.pulse))
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), self.app.handler())
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True); self.thread.start()
        self.base = 'http://127.0.0.1:' + str(self.server.server_port)
        self.request('POST', '/v1/conversations', {'id': 'a'})
        self.request('POST', '/v1/conversations', {'id': 'b'})

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.app.close(); self.store.close(); self.temp.cleanup()

    def request(self, method, path, body=None, auth=True):
        headers = {'Content-Type': 'application/json'}
        if auth:
            headers['Authorization'] = 'Bearer ' + TOKEN
        req = Request(self.base + path, data=json.dumps(body).encode() if body is not None else None, headers=headers, method=method)
        try:
            with urlopen(req, timeout=3) as response:
                data = response.read()
                return response.status, json.loads(data) if response.headers['Content-Type'].startswith('application/json') else data
        except HTTPError as error:
            return error.code, json.loads(error.read())

    def request_raw(self, filename, mime, data, auth=True):
        query = urlencode({'filename': filename, 'mime': mime})
        headers = {'Content-Type': 'application/octet-stream'}
        if auth:
            headers['Authorization'] = 'Bearer ' + TOKEN
        req = Request(self.base + '/v1/attachments?' + query, data=data, headers=headers, method='POST')
        try:
            with urlopen(req, timeout=3) as response:
                return response.status, json.loads(response.read())
        except HTTPError as error:
            return error.code, json.loads(error.read())

    def poll(self, id='a', cursor=0):
        return self.request('GET', f'/v1/messages?conversationID={id}&after={cursor}')[1]

    def wait_done(self, id='a'):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            result = self.poll(id)
            if result['messages'] and not result['busy']:
                return result
            time.sleep(.01)
        self.fail('runtime did not settle')

    def test_auth_and_readiness(self):
        self.assertEqual(self.request('GET', '/health', auth=False)[1], {'ok': True, 'service': 'cove'})
        self.assertEqual(self.request('GET', '/v1/health', auth=False)[0], 401)
        self.assertEqual(self.request('POST', '/v1/messages', {'id': 'x'}, auth=False)[0], 401)
        self.assertEqual(self.request('GET', '/v1/messages?conversationID=a&after=-1')[0], 400)

    def test_raw_attachment_upload_keeps_exact_bytes_and_legacy_json(self):
        payload = b'\x00raw\xffbytes'
        status, uploaded = self.request_raw('原图 1.bin', 'application/x-test', payload)
        self.assertEqual(status, 200)
        self.assertEqual(uploaded['filename'], '原图 1.bin')
        downloaded = self.request('GET', uploaded['url'])
        self.assertEqual(downloaded, (200, payload))

        legacy = self.request('POST', '/v1/attachments', {
            'filename': 'legacy.txt', 'mime': 'text/plain',
            'dataBase64': base64.b64encode(b'legacy').decode(),
        })
        self.assertEqual(legacy[0], 200)
        self.assertEqual(self.request_raw('empty.txt', 'text/plain', b'')[0], 200)
        self.assertEqual(self.request_raw('bad.bin', 'application/octet-stream', b'', auth=False)[0], 401)

    def test_memory_calendar_requires_auth_strict_month_and_reports_unavailable(self):
        from memory_calendar import CalendarError
        with patch('cove.read_memory_calendar') as read:
            self.assertEqual(self.request('GET', '/v1/memory/calendar?month=2026-09', auth=False)[0], 401)
            read.assert_not_called()
            for query in ('', '?month=', '?month=2026-09&month=2026-08', '?month=2026-09&path=secret'):
                if query == '?month=':
                    continue  # Module validates the value after route shape validation.
                self.assertEqual(self.request('GET', '/v1/memory/calendar' + query)[0], 400)
            read.assert_not_called()
            read.side_effect = CalendarError(503, 'OB 数据未知')
            status, body = self.request('GET', '/v1/memory/calendar?month=2026-09')
            self.assertEqual((status, body), (503, {'error': 'OB 数据未知'}))
            self.assertEqual(self.runtime.calls, [])

    def test_memory_calendar_returns_only_successful_metadata_payload(self):
        value = {'month':'2026-09','timezone':'Asia/Shanghai','source':'ombre','metric':'created',
                 'days':[{'date':'2026-09-16','count':3}],'total':3,'updatedAt':now()}
        with patch('cove.read_memory_calendar', return_value=value) as read:
            self.assertEqual(self.request('GET', '/v1/memory/calendar?month=2026-09'), (200, value))
            read.assert_called_once_with('2026-09')
            self.assertEqual(self.runtime.calls, [])

    def test_device_registration_unregister_and_offline_conversation_id(self):
        device = 'A' * 64
        self.assertEqual(self.request('POST', '/v1/devices', {'token': device})[0], 200)
        self.request('POST', '/v1/devices', {'token': device})
        self.assertEqual(self.store.device_tokens(), [device.lower()])
        self.assertEqual(self.request('DELETE', '/v1/devices', {'token': device}, auth=False)[0], 401)
        self.assertEqual(self.request('DELETE', '/v1/devices', {'token': device})[1], {'ok': True})
        self.assertEqual(self.store.device_tokens(), [])
        self.assertEqual(self.request('DELETE', '/v1/devices', {'token': device})[0], 200)
        self.assertEqual(self.request('DELETE', '/v1/devices', {'token': 'bad'})[0], 400)
        self.assertEqual(self.request('GET', '/v1/messages?conversationID=offline-id&after=0')[0], 404)
        one = self.request('POST', '/v1/conversations', {'id': 'offline-id'})[1]
        two = self.request('POST', '/v1/conversations', {'id': 'offline-id'})[1]
        self.assertEqual(one, two)
        self.assertEqual(self.request('GET', '/v1/messages?conversationID=offline-id&after=0')[0], 200)

    def test_dedupe_stream_final_and_conversation_cursor(self):
        self.runtime.gate.clear()
        body = {'id': 'one', 'conversationID': 'a', 'text': '你好'}
        status, ack = self.request('POST', '/v1/messages', body)
        self.assertEqual(status, 200); self.assertEqual(ack['message']['status'], 'sent')
        # Durable commit visible through another SQLite connection immediately after ACK.
        import sqlite3
        with sqlite3.connect(Path(self.temp.name) / 'cove.sqlite3') as external:
            self.assertEqual(external.execute('SELECT COUNT(*) FROM messages WHERE id="one"').fetchone()[0], 1)
        self.runtime.running.wait(1)
        first = self.poll(); cursor = first['cursor']
        self.assertTrue(first['busy']); self.assertEqual(self.request('POST', '/v1/messages', body)[1]['message']['id'], ack['message']['id'])
        self.assertEqual(self.request('POST', '/v1/messages', dict(body, text='other'))[0], 409)
        self.request('POST', '/v1/messages', {'id': 'two', 'conversationID': 'b', 'text': '乙'})
        # A global DB revision from B does not cause A to lose a later streaming change.
        self.runtime.gate.set(); done = self.wait_done(); b = self.wait_done('b')
        self.assertEqual(self.runtime.calls, ['one', 'two'])
        assistants = [m for m in done['messages'] if m['role'] == 'assistant']
        self.assertEqual(len(assistants), 1); self.assertEqual(assistants[0]['text'], '回复：你好'); self.assertEqual(assistants[0]['status'], 'complete')
        changes = self.poll(cursor=cursor)
        self.assertIn(assistants[0]['id'], [m['id'] for m in changes['messages']])
        self.assertTrue(all(m['conversationID'] == 'b' for m in b['messages']))
        final_cursor = changes['cursor']; self.assertEqual(self.poll(cursor=final_cursor)['cursor'], final_cursor)

    def test_health_sync_view_model_read_delete_distinction(self):
        snapshot = {'capturedAt': now(), 'metrics': [{'id': 'steps', 'title': '步数', 'value': 1234, 'unit': '步', 'sampledAt': now()}]}
        self.assertEqual(self.request('POST', '/v1/health', {'snapshot': snapshot})[0], 200)
        synced = self.request('GET', '/v1/health')[1]
        self.assertIsNone(synced['readAt']); self.assertEqual(synced['snapshot']['metrics'][0]['value'], 1234)
        history = self.request('GET', '/v1/health/history?days=7')[1]
        self.assertEqual(len(history['snapshots']), 1); self.assertEqual(history['updatedAt'], synced['syncedAt'])
        self.assertIsNone(self.request('GET', '/v1/health')[1]['readAt'])
        self.assertEqual(self.request('GET', '/v1/health/history?days=0')[0], 400)
        self.assertEqual(self.request('GET', '/v1/health/history?days=7', auth=False)[0], 401)
        self.request('POST', '/v1/messages', {'id': 'health-msg', 'conversationID': 'a', 'text': 'health'}); self.wait_done()
        viewed = self.request('GET', '/v1/health')[1]; self.assertIsNone(viewed['readAt']); self.assertEqual(viewed['syncedAt'], synced['syncedAt'])
        self.request('POST', '/v1/health', {'snapshot': snapshot}); self.assertIsNone(self.request('GET', '/v1/health')[1]['readAt'])
        bad = dict(snapshot, metrics=[dict(snapshot['metrics'][0], value=float('nan'))])
        self.assertEqual(self.request('POST', '/v1/health', {'snapshot': bad})[0], 400)
        self.request('DELETE', '/v1/health'); self.assertIsNone(self.request('GET', '/v1/health')[1]['snapshot'])
        self.assertEqual(self.request('GET', '/v1/health/history?days=7')[1]['snapshots'], [])
        health, version = self.store.health_for_tool()
        self.store.mark_health_read(health, version)
        self.assertIsNone(self.store.health()['readAt'])

    def test_health_upload_readback_is_authenticated_strict_and_exact(self):
        captured = '2026-09-24T12:34:56.789Z'
        snapshot = {'capturedAt': captured, 'metrics': [
            {'id': 'steps', 'title': '步数', 'value': 42, 'unit': '步', 'sampledAt': captured}
        ]}
        status, ack = self.request('POST', '/v1/health', {'snapshot': snapshot})
        self.assertEqual(status, 200)

        path = '/v1/health/uploads?' + urlencode({'capturedAt': '2026-09-24T20:34:56.789+08:00'})
        self.assertEqual(self.request('GET', path, auth=False)[0], 401)
        status, readback = self.request('GET', path)
        self.assertEqual(status, 200)
        self.assertEqual(readback, {'snapshot': health_snapshot(snapshot), 'syncedAt': ack['syncedAt']})

        for query in ('', '?capturedAt=', '?other=x',
                      '?capturedAt=2026-09-24T12%3A34%3A56.789Z&other=x',
                      '?capturedAt=2026-09-24T12%3A34%3A56.789Z&capturedAt=2026-09-24T12%3A34%3A56.789Z',
                      '?capturedAt=2026-09-24T12%3A34%3A56.789'):
            self.assertEqual(self.request('GET', '/v1/health/uploads' + query)[0], 400)
        missing = '/v1/health/uploads?' + urlencode({'capturedAt': '2026-09-24T12:34:56.788Z'})
        self.assertEqual(self.request('GET', missing)[0], 404)

    def test_health_upload_readback_selects_exact_capture_among_same_day(self):
        first = {'capturedAt': '2026-09-24T01:00:00.000Z', 'metrics': []}
        second = {'capturedAt': '2026-09-24T02:00:00.000Z', 'metrics': [
            {'id': 'steps', 'title': '步数', 'value': 7, 'unit': '步', 'sampledAt': '2026-09-24T02:00:00.000Z'}
        ]}
        self.request('POST', '/v1/health', {'snapshot': first})
        second_ack = self.request('POST', '/v1/health', {'snapshot': second})[1]
        query = urlencode({'capturedAt': second['capturedAt']})
        readback = self.request('GET', '/v1/health/uploads?' + query)[1]
        self.assertEqual(readback['snapshot'], health_snapshot(second))
        self.assertEqual(readback['syncedAt'], second_ack['syncedAt'])
        self.assertNotEqual(readback['snapshot'], first)

    def test_pulse_usage_attachment_interruption(self):
        original = {'updated_at': 1700000000, 'summary': '当前想靠近', 'last_signal': {'label': '过期的想靠近'}, 'physical': {'energy': .6},
                    'desires': {'intimacy': {'value': .7, 'label': '抱抱'}}, 'senses': {'touch': {'value': .4, 'label': '温暖'}}, 'heartbeat': {'last_tick_at': 0}}
        self.pulse.write_text(json.dumps(original)); before = self.pulse.read_bytes()
        pulse = self.request('GET', '/v1/pulse')[1]; self.assertEqual(pulse['summary'], '当前想靠近'); self.assertNotEqual(pulse['summary'], '过期的想靠近'); self.assertEqual(pulse['desires'][0]['detail'], '抱抱')
        self.assertEqual(self.pulse.read_bytes(), before); self.assertEqual(pulse['updatedAt'], '2023-11-14T22:13:20Z')
        usage = self.request('GET', '/v1/usage')[1]; self.assertEqual(usage['windows'], []); self.assertTrue(usage['error'])
        uploaded = self.request('POST', '/v1/attachments', {'filename': 'note.txt', 'mime': 'text/plain', 'dataBase64': base64.b64encode('用户'.encode()).decode()})[1]
        self.assertEqual(self.request('GET', uploaded['url'])[1], '用户'.encode())
        self.assertEqual(self.request('GET', uploaded['url'], auth=False)[0], 401)
        self.assertEqual(self.request('POST', '/v1/attachments', {'filename': '../bad', 'mime': 'text/plain', 'dataBase64': 'eA=='})[0], 400)
        self.runtime.gate.clear(); self.request('POST', '/v1/messages', {'id': 'stop', 'conversationID': 'a', 'text': '停止'})
        self.runtime.running.wait(1); self.request('POST', '/v1/interrupt', {'conversationID': 'b'}); self.assertTrue(self.poll()['busy'])
        self.request('POST', '/v1/interrupt', {'conversationID': 'a'}); result = self.wait_done()
        self.assertEqual([m for m in result['messages'] if m['role'] == 'assistant'][0]['status'], 'interrupted')

    def test_cursor_paging_does_not_skip_updates(self):
        # 205 revisions require two pages, unrelated conversation must never advance A cursor.
        with self.store.lock, self.store.db:
            for i in range(205):
                self.store._put({'id': f'page-{i}', 'conversationID': 'a', 'role': 'assistant', 'text': str(i), 'createdAt': now(), 'status': 'complete'})
            self.store._put({'id': 'unrelated', 'conversationID': 'b', 'role': 'assistant', 'text': 'B', 'createdAt': now(), 'status': 'complete'})
        one = self.poll(); two = self.poll(cursor=one['cursor'])
        self.assertEqual(len(one['messages']), 200); self.assertEqual(len(two['messages']), 5)
        self.assertEqual(self.poll(cursor=two['cursor'])['messages'], [])


class RecoveryTests(unittest.TestCase):
    def test_window_reset_detaches_thread_and_marker_is_one_shot(self):
        with tempfile.TemporaryDirectory() as temp:
            store = Store(temp); store.create_conversation('a'); store.bind_thread('a', 'old-thread')
            self.assertIsNone(store.consume_window_reset('a'))
            self.assertEqual(store.mark_window_reset('a'), 'old-thread')
            self.assertIsNone(store.conversation('a')['thread']); store.close()
            restored = Store(temp)
            self.assertEqual(restored.consume_window_reset('a'), {'previousThread': 'old-thread'})
            self.assertIsNone(restored.consume_window_reset('a'))
            restored.close()

    def test_health_upload_readback_survives_store_reopen(self):
        with tempfile.TemporaryDirectory() as temp:
            captured = '2026-09-24T08:09:10.123Z'
            snapshot = {'capturedAt': captured, 'metrics': []}
            store = Store(temp)
            synced = store.upload_health(snapshot)
            self.assertEqual(store.health_upload('2026-09-24T10:09:10.123+02:00'),
                             {'snapshot': snapshot, 'syncedAt': synced})
            store.close()
            restored = Store(temp)
            self.assertEqual(restored.health_upload(captured),
                             {'snapshot': snapshot, 'syncedAt': synced})
            restored.close()

    def test_pulse_note_is_wake_scoped_idempotent_and_dashboard_is_read_only(self):
        from pulse_read import dashboard, recent_user_messages
        with tempfile.TemporaryDirectory() as temp:
            store = Store(temp); store.create_conversation('a')
            store.accept({'id': 'normal', 'conversationID': 'a', 'text': 'hello'})
            with store.lock, store.db:
                store._put({'id': 'pulse-cove-one', 'conversationID': 'a', 'role': 'system', 'text': 'scheduled', 'createdAt': now(), 'status': 'sent'})
                store.db.execute("INSERT INTO jobs VALUES(?, 'running', ?, ?)", ('pulse-cove-one', 'pulse-turn', 'pulse-assistant'))
            args = {'thoughtSummary': '我想安静地看看她是否需要我。', 'intent': '保持安静'}
            one = store.record_pulse_note('pulse-cove-one', 'pulse-turn', 'call', args)
            self.assertEqual(store.record_pulse_note('pulse-cove-one', 'pulse-turn', 'call', args), one)
            with self.assertRaises(Exception):
                store.record_pulse_note('normal', 'pulse-turn', 'bad', args)
            state = Path(temp) / 'state.json'
            state.write_text(json.dumps({'updated_at': 1700000000, 'physical': {'energy': .5}}))
            result = dashboard(state, Path(temp) / 'cove.sqlite3')
            self.assertEqual(result['events'][0]['thoughtSummary'], args['thoughtSummary'])
            self.assertEqual(recent_user_messages(Path(temp) / 'cove.sqlite3')[0]['id'], 'normal')
            store.close()

    def test_message_revision_matches_durable_column_and_never_regresses(self):
        with tempfile.TemporaryDirectory() as temp:
            store=Store(temp); store.create_conversation('a')
            body={'id':'one','conversationID':'a','text':'revision proof'}
            ack=store.accept(body); initial=ack['revision']; self.assertIsInstance(initial,int)
            self.assertEqual(store.poll('a',0)['messages'][0]['revision'],initial)
            store.claim(); store.bind_thread('a','thread'); store.bind_turn('one','turn','thread')
            started=store._message('one')['revision']; self.assertGreater(started,initial)
            liked=store.set_reaction('a','one',True); self.assertGreater(liked['revision'],started)
            liked_revision=liked['revision']; self.assertEqual(store.set_reaction('a','one',True)['revision'],liked_revision)
            canceled=store.set_reaction('a','one',False); self.assertGreater(canceled['revision'],liked_revision)
            latest=canceled['revision']; self.assertEqual(store.accept(body)['revision'],latest)
            # The column is authoritative even for legacy bodies without a version.
            with store.lock,store.db:
                row=store.db.execute('SELECT body FROM messages WHERE id=?',('one',)).fetchone()
                legacy=json.loads(row[0]); legacy.pop('revision')
                store.db.execute('UPDATE messages SET body=? WHERE id=?',(json.dumps(legacy),'one'))
            self.assertEqual(store._message('one')['revision'],latest)
            self.assertEqual(next(m for m in store.poll('a',0)['messages'] if m['id']=='one')['revision'],latest)
            store.close(); restored=Store(temp)
            self.assertEqual(restored.accept(body)['revision'],latest)
            self.assertGreater(restored.set_reaction('a','one',True)['revision'],latest)
            restored.close()

    def test_read_receipt_waits_for_bound_active_turn_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temp:
            store=Store(temp); store.create_conversation('a'); store.create_conversation('b')
            body={'id':'one','conversationID':'a','text':'wait for actual start'}
            ack=store.accept(body); self.assertIsNone(ack['readAt'])
            before=store.poll('a',0)['cursor']
            self.assertFalse(store.bind_turn('one','queued-turn'))
            job=store.claim(); self.assertIsNone(store._message('one')['readAt'])
            store.bind_thread('a','thread-a')
            self.assertFalse(store.bind_turn('one','wrong-thread-turn','thread-b'))
            self.assertIsNone(store._message('one')['readAt'])
            self.assertTrue(store.bind_turn('one','real-turn','thread-a'))
            read=store._message('one')['readAt']; self.assertIsNotNone(read)
            changes=store.poll('a',before)
            self.assertIn('one',[m['id'] for m in changes['messages']]); cursor=changes['cursor']
            self.assertTrue(store.bind_turn('one','real-turn','thread-a'))
            self.assertEqual(store.poll('a',cursor)['messages'],[])
            self.assertFalse(store.bind_turn('one','other-turn','thread-a')); self.assertEqual(store._message('one')['readAt'],read)
            store.finish('one','complete')
            self.assertFalse(store.bind_turn('one','real-turn','thread-a'))
            store.accept({'id':'two','conversationID':'b','text':'another conversation'}); store.claim(); store.bind_thread('b','thread-b')
            self.assertFalse(store.bind_turn('two','real-turn','thread-b')); self.assertIsNone(store._message('two')['readAt'])
            self.assertTrue(store.bind_turn('two','new-turn','thread-b'))
            store.close(); restored=Store(temp)
            self.assertEqual(restored.accept(body)['readAt'],read); restored.close()

    def test_legacy_defaults_and_reaction_persist_cancel_without_revision_churn(self):
        with tempfile.TemporaryDirectory() as temp:
            store=Store(temp); store.create_conversation('a')
            with store.lock,store.db:
                store._put({'id':'legacy','conversationID':'a','role':'assistant','text':'legacy','createdAt':now(),'status':'complete'})
            legacy=store.poll('a',0)['messages'][0]
            self.assertIsNone(legacy['readAt']); self.assertFalse(legacy['isLiked'])
            store.set_reaction('a','legacy',True); read_cursor=store.poll('a',0)['cursor']
            store.close(); restored=Store(temp)
            self.assertTrue(restored.poll('a',0)['messages'][0]['isLiked'])
            restored.set_reaction('a','legacy',True); self.assertEqual(restored.poll('a',read_cursor)['messages'],[])
            restored.set_reaction('a','legacy',False); canceled=restored.poll('a',read_cursor)
            self.assertFalse(canceled['messages'][0]['isLiked'])
            restored.set_reaction('a','legacy',False); self.assertEqual(restored.poll('a',canceled['cursor'])['messages'],[])
            restored.close()

    def test_legacy_health_tool_never_discloses_or_marks_uploaded_health(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as temp:
            store = Store(temp)
            snapshot = {'capturedAt': now(), 'metrics': []}
            runtime = CodexRuntime(store, temp)
            runtime.active = {'thread': 'thread', 'turn': 'turn'}
            request = {'id': 'tool', 'method': 'item/tool/call', 'params': {'threadId': 'thread', 'turnId': 'turn', 'tool': 'cove_health_read', 'arguments': {}}}
            store.upload_health(snapshot)
            def failed_write(_):
                raise BrokenPipeError('simulated disconnected pipe')
            runtime._send = failed_write
            with self.assertRaises(BrokenPipeError):
                runtime._server_request(request)
            self.assertIsNone(store.health()['readAt'])
            def successful_write(response):
                self.assertIsNone(store.health()['readAt'])
                self.assertFalse(response['result']['success'])
                self.assertNotIn('snapshot', str(response))
            runtime._send = successful_write
            runtime._server_request(request)
            self.assertIsNone(store.health()['readAt'])
            # Identical content and identical sync timestamp still represent a new upload.
            with patch('storage.now', return_value='2026-09-13T00:00:00.000Z'):
                store.upload_health(snapshot)
                def concurrent_upload(_):
                    store.upload_health(snapshot)
                runtime._send = concurrent_upload
                runtime._server_request(request)
            self.assertIsNone(store.health()['readAt'])
            runtime.close(); store.close()

    def test_uncertain_started_turn_stops_owned_process_then_resumes_without_replay(self):
        class BoundedRuntime(CodexRuntime):
            def ensure_started(self):
                super().ensure_started()
                self.spawned = self.process
            def request(self, method, params=None, timeout=30):
                self.calls.append((method, params))
                return super().request(method, params, .2 if method == 'turn/start' else timeout)
        with tempfile.TemporaryDirectory() as temp:
            store = Store(temp); store.create_conversation('a')
            command = shlex.quote(sys.executable) + ' ' + shlex.quote(str(Path(__file__).parent / 'fake_app_server.py'))
            runtime = BoundedRuntime(store, temp, command, timeout=3); runtime.calls = []
            old = {'id': 'uncertain', 'conversationID': 'a', 'text': 'COVE_TEST_UNCERTAIN'}
            store.accept(old); job = store.claim()
            try:
                with self.assertRaisesRegex(RuntimeError, '请求超时'):
                    runtime.run(job, threading.Event())
                original = store.conversation('a')['thread']
                self.assertIsNotNone(runtime.spawned.poll())
                self.assertIsNone(runtime.process); self.assertFalse(runtime.loaded)
                store.finish(job['message'], 'failed', 'uncertain')
                self.assertEqual(store.accept(old)['id'], old['id'])
                self.assertIsNone(store.claim())
                store.accept({'id': 'next', 'conversationID': 'a', 'text': 'new explicit message'})
                next_job = store.claim(); status, error = runtime.run(next_job, threading.Event())
                store.finish(next_job['message'], status, error)
                self.assertEqual(status, 'complete'); self.assertEqual(store.conversation('a')['thread'], original)
                resumes = [params for method, params in runtime.calls if method == 'thread/resume']
                self.assertEqual(resumes[-1]['threadId'], original)
                self.assertEqual(resumes[-1]['cwd'], str(Path(temp).resolve()))
                self.assertIn('mcp_servers.cove_files', resumes[-1]['config'])
                starts = [p['input'][0]['text'] for method, p in runtime.calls if method == 'turn/start']
                self.assertEqual([text.split('\n', 1)[0] for text in starts], ['COVE_TEST_UNCERTAIN', 'new explicit message'])
                for text in starts:
                    self.assertEqual(text.split('\n', 1)[1], '[Cove 长期记忆分工] '+__import__('memory_outbox').MEMORY_GUIDANCE+'\n'+__import__('little_thoughts').GUIDANCE)
                from runtime import guidance_topics
                self.assertTrue(guidance_topics('看看我的睡眠和心率')['health'])
                self.assertTrue(guidance_topics('提醒我明早起床')['device'])
                self.assertFalse(any(guidance_topics('抱抱我').values()))
            finally:
                runtime.close(); store.close()

    def test_health_history_retains_real_capture_days_and_latest_daily_upload(self):
        from datetime import datetime, timezone, timedelta
        with tempfile.TemporaryDirectory() as temp:
            store = Store(temp)
            today = datetime.now(timezone.utc)
            for age in (10, 6, 1, 0):
                store.upload_health({'capturedAt': (today-timedelta(days=age)).isoformat(), 'metrics': []})
            store.upload_health({'capturedAt': (today+timedelta(seconds=1)).isoformat(), 'metrics': [{'id': 'steps', 'value': 42}]})
            week = store.health_history(7)['snapshots']
            self.assertEqual(len(week), 3); self.assertEqual(week[-1]['metrics'][0]['value'], 42)
            self.assertEqual(len(store.health_history(1)['snapshots']), 1)
            self.assertIsNone(store.health()['readAt'])
            store.close(); restored = Store(temp)
            self.assertEqual(len(restored.health_history(7)['snapshots']), 3)
            restored.delete_health(); self.assertEqual(restored.health_history(31)['snapshots'], [])
            restored.close()

    def test_stdio_adapter_schema_routing_tools_and_resume(self):
        with tempfile.TemporaryDirectory() as temp:
            store = Store(temp)
            snapshot = {'capturedAt': now(), 'metrics': []}
            store.upload_health(snapshot)
            command = shlex.quote(sys.executable) + ' ' + shlex.quote(str(Path(__file__).parent / 'fake_app_server.py'))
            runtime = CodexRuntime(store, temp, command, timeout=3)
            try:
                for conversation, message in [('a', 'one'), ('b', 'two'), ('a', 'three')]:
                    store.create_conversation(conversation)
                    store.accept({'id': message, 'conversationID': conversation, 'text': 'fixture'})
                    job = store.claim()
                    status, error = runtime.run(job, threading.Event())
                    store.finish(job['message'], status, error)
                    self.assertEqual(status, 'complete')
                    self.assertEqual(store._message(job['assistant'])['text'], 'actual final ' + store.conversation(conversation)['thread'])
                self.assertNotEqual(store.conversation('a')['thread'], store.conversation('b')['thread'])
                self.assertIsNone(store.health()['readAt'])
                self.assertEqual(runtime.usage()['windows'][0]['usedPercent'], 17)
                # New stdio connection resumes persisted app thread, never thread/list/latest.
                original = store.conversation('a')['thread']; runtime.close()
                runtime = CodexRuntime(store, temp, command, timeout=3)
                store.accept({'id': 'four', 'conversationID': 'a', 'text': 'fixture'})
                job = store.claim(); status, error = runtime.run(job, threading.Event())
                self.assertEqual(status, 'complete'); self.assertEqual(store.conversation('a')['thread'], original)
            finally:
                runtime.close(); store.close()

    def test_persistent_dedupe_and_no_uncertain_replay(self):
        with tempfile.TemporaryDirectory() as temp:
            store = Store(temp); store.create_conversation('a')
            body = {'id': 'one', 'conversationID': 'a', 'text': 'uncertain'}
            store.accept(body); job = store.claim(); store.stream('one', 'partial'); store.close()
            recovered = Store(temp)
            self.assertIsNone(recovered.claim()); self.assertEqual(recovered.accept(body)['id'], 'one')
            messages = recovered.poll('a', 0)['messages']; assistant = [m for m in messages if m['role'] == 'assistant'][0]
            self.assertEqual(assistant['status'], 'failed'); self.assertEqual(assistant['text'], 'partial'); self.assertTrue(assistant['error'])
            self.assertEqual(Path(temp).stat().st_mode & 0o777, 0o700)
            recovered.close()

    def test_official_quota_shape_and_final_message_selection(self):
        class SchemaRuntime(CodexRuntime):
            def ensure_started(self): pass
            def request(self, method, params=None, timeout=30):
                self.last_method = method
                return {'rateLimits': {'planType': 'plus', 'primary': {'usedPercent': 25, 'windowDurationMins': 300, 'resetsAt': 1700000000}, 'secondary': None}}
        runtime = SchemaRuntime(None, '/private/tmp')
        result = runtime.usage(); self.assertEqual(runtime.last_method, 'account/rateLimits/read')
        self.assertEqual(result['windows'][0]['usedPercent'], 25); self.assertEqual(result['plan'], 'plus')
        self.assertEqual(result['windows'][0]['title'], '5 小时窗口')
        self.assertEqual(CodexRuntime._text({'a': 'progress', 'b': 'final'}, {'a': 'commentary', 'b': 'final_answer'}), 'final')


if __name__ == '__main__':
    unittest.main()
