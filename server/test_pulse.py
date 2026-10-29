import json
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from pulse_read import dashboard, snapshot
from runtime import CodexRuntime, pulse_context
from storage import APIError, Store, now
from cove import Application
from terminal import TerminalRuntime


class PulseBackendTests(unittest.TestCase):
    def _wake(self, store, message='pulse-cove-wake', conversation='a'):
        with store.lock, store.db:
            store._put({'id': message, 'conversationID': conversation, 'role': 'system', 'text': 'timer',
                        'pulseReason': 'attachment', 'createdAt': now(), 'status': 'sent'})
            store.db.execute('INSERT INTO jobs VALUES(?,?,NULL,?)', (message, 'queued', 'assistant-' + message))
        turn = 'turn-' + message
        job = store.claim(); store.bind_thread(conversation, 'thread'); store.bind_turn(message, turn, 'thread')
        job['testTurn'] = turn
        return job

    def test_note_boundaries_replay_cancel_and_quiet_completion(self):
        with tempfile.TemporaryDirectory() as temp:
            store = Store(temp); store.create_conversation('a'); store.create_conversation('b')
            job = self._wake(store)
            self.assertNotIn(job['assistant'], [m['id'] for m in store.poll('a', 0)['messages']])
            args = {'thoughtSummary': '这是可公开的短反思', 'intent': '安静观察'}
            first = store.record_pulse_note(job['message'], job['testTurn'], 'call', args)
            self.assertEqual(first, store.record_pulse_note(job['message'], job['testTurn'], 'call', args))
            with self.assertRaises(APIError):
                store.record_pulse_note(job['message'], job['testTurn'], 'call', dict(args, intent='更改同一调用的意图'))
            with self.assertRaises(APIError):
                store.accept({'id':'pulse-cove-spoof','conversationID':'a','text':'普通消息不得伪装唤醒'})
            with self.assertRaises(APIError): store.record_pulse_note(job['message'], 'wrong', 'x', args)
            with self.assertRaises(APIError): store.record_pulse_note('ordinary', 'turn', 'x', args)
            # The runtime rejects a callback after in-flight cancellation even
            # when an otherwise matching MCP item permit exists.
            runtime = CodexRuntime(store, temp, 'true'); cancelled = threading.Event(); cancelled.set()
            runtime.active = {'conversation': 'a', 'message': job['message'], 'thread': 'thread', 'turn': job['testTurn'], 'cancel': cancelled}
            runtime.file_permits = [{'conversation': 'a', 'turn': job['testTurn'], 'call': 'cancelled', 'tool': 'cove_record_pulse_note', 'arguments': args, 'used': False}]
            with self.assertRaises(APIError): runtime.mcp_file_call('a', 'cove_record_pulse_note', args)
            runtime.active = dict(runtime.active, conversation='b', cancel=threading.Event())
            with self.assertRaises(APIError): runtime.mcp_file_call('a', 'cove_record_pulse_note', args)
            runtime.active = None; runtime.close()
            store.finish(job['message'], 'complete')
            assistant = store._message(job['assistant']); self.assertTrue(assistant['hidden'])
            self.assertNotIn(job['assistant'], [m['id'] for m in store.poll('a', 0)['messages']])
            with self.assertRaises(APIError): store.record_pulse_note(job['message'], 'turn', 'late', args)
            # Note remains readable after completion.
            state = Path(temp) / 'state.json'; state.write_text(json.dumps({'updatedAt': now()}))
            event = dashboard(state, Path(temp) / 'cove.sqlite3')['events'][0]
            self.assertEqual(event['thoughtSummary'], args['thoughtSummary'])
            self.assertEqual(event['status'], 'quiet')
            self.assertEqual(event['resultSummary'], '本次已完成，未发送聊天消息')
            store.close()

    def test_stream_failure_attachment_visibility_and_quiet_push(self):
        with tempfile.TemporaryDirectory() as temp:
            store = Store(temp); store.create_conversation('a')
            whitespace = self._wake(store, 'pulse-cove-whitespace')
            store.stream(whitespace['message'], '\n\n')
            self.assertNotIn(whitespace['assistant'], [m['id'] for m in store.poll('a', 0)['messages']])
            store.finish(whitespace['message'], 'complete')
            quiet = store._message(whitespace['assistant'])
            self.assertEqual(quiet['text'], '')
            self.assertTrue(quiet['hidden'])
            self.assertNotIn(whitespace['assistant'], [m['id'] for m in store.poll('a', 0)['messages']])

            streamed = self._wake(store, 'pulse-cove-stream')
            store.stream(streamed['message'], 'hello')
            self.assertIn(streamed['assistant'], [m['id'] for m in store.poll('a', 0)['messages']])
            store.finish(streamed['message'], 'complete')

            failed = self._wake(store, 'pulse-cove-failed')
            store.finish(failed['message'], 'failed', 'wake failed')
            visible = {m['id']: m for m in store.poll('a', 0)['messages']}
            self.assertEqual(visible[failed['assistant']]['error'], 'wake failed')

            attached = self._wake(store, 'pulse-cove-file')
            store.create_assistant_file(attached['message'], attached['testTurn'], 'file-call', 'x.txt', 'text/plain', b'x')
            self.assertIn(attached['assistant'], [m['id'] for m in store.poll('a', 0)['messages']])
            store.finish(attached['message'], 'complete')

            class QuietRuntime:
                def run(self, job, cancelled):
                    store.bind_thread('a', 'thread'); store.bind_turn(job['message'], 'turn-q', 'thread')
                    return 'complete', None
                def close(self): pass
            pushed = []
            app = Application(store, 'test-only-independent-cove-token-12345', QuietRuntime(), push=lambda *x: pushed.append(x))
            quiet_id = 'pulse-cove-push'
            with store.lock, store.db:
                store._put({'id': quiet_id, 'conversationID': 'a', 'role': 'system', 'text': 'timer', 'createdAt': now(), 'status': 'sent'})
                store.db.execute('INSERT INTO jobs VALUES(?,?,NULL,?)', (quiet_id, 'queued', 'assistant-' + quiet_id))
            app.wake.set()
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                with store.lock:
                    row = store.db.execute('SELECT state FROM jobs WHERE message=?', (quiet_id,)).fetchone()
                if row and row[0] == 'complete': break
                time.sleep(.01)
            self.assertEqual(row[0], 'complete'); self.assertEqual(pushed, [])
            app.close(); store.close()

    def test_nonempty_wake_reply_is_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            store = Store(temp); store.create_conversation('a'); job = self._wake(store)
            store.stream(job['message'], '真实回复'); store.finish(job['message'], 'complete')
            assistant = store._message(job['assistant'])
            self.assertEqual(assistant['text'], '真实回复'); self.assertFalse(assistant.get('hidden', False)); store.close()

    def test_projection_clears_inactive_legacy_labels_and_never_exposes_reasoning(self):
        with tempfile.TemporaryDirectory() as temp:
            store = Store(temp); store.create_conversation('a'); job = self._wake(store)
            turn = job['testTurn']
            store.terminal_event('a', 'reasoning', 'PRIVATE_CHAIN', 'thread', turn, 'secret')
            store.terminal_event('a', 'message', 'PRIVATE_MESSAGE', 'thread', turn, 'secret2')
            store.terminal_event('a', 'command', '$ false', 'thread', turn, 'cmd')
            store.terminal_event('a', 'command', '完成：false\nexitCode=1\ncwd=/tmp', 'thread', turn, 'cmd')
            store.terminal_event('a', 'tool', 'cove_files cove_record_pulse_note · 失败', 'thread', turn, 'tool-fail')
            store.terminal_event('a', 'tool', 'memory breath · 完成', 'thread', turn, 'tool-legacy')
            store.terminal_event('a', 'turn', '回合结束：completed', 'thread', turn)
            store.finish(job['message'], 'complete')
            state = Path(temp) / 'state.json'
            state.write_text(json.dumps({'updatedAt': now(), 'summary': 'current', 'last_signal': {'label': 'old'},
                                         'desires': {'attachment': {'value': .14, 'label': 'expired prose'},
                                                     'curiosity': {'value': .15, 'label': 'current prose'}}}))
            view = dashboard(state, Path(temp) / 'cove.sqlite3')
            self.assertEqual(view['snapshot']['summary'], 'current')
            metrics = {m['id']: m for m in view['snapshot']['desires']}
            self.assertEqual(metrics['attachment']['detail'], ''); self.assertEqual(metrics['curiosity']['detail'], 'current prose')
            encoded = json.dumps(view); self.assertNotIn('PRIVATE_CHAIN', encoded); self.assertNotIn('PRIVATE_MESSAGE', encoded)
            self.assertEqual(len(view['events'][0]['actions']), 3)
            self.assertEqual(view['events'][0]['actions'][0]['status'], 'failed')
            actions = {a['id']: a for a in view['events'][0]['actions']}
            self.assertEqual(actions['tool-fail']['status'], 'failed')
            self.assertEqual(actions['tool-fail']['title'], '留下想法摘要')
            self.assertEqual(actions['tool-legacy']['status'], 'unknown')
            self.assertEqual(actions['tool-legacy']['title'], '检索记忆')
            self.assertIsNotNone(view['events'][0]['completedAt'])
            self.assertEqual(view['events'][0]['reason'], 'attachment_crossed_threshold')
            store.close()

    def test_terminal_tool_completion_requires_explicit_non_error_result(self):
        class Capture(TerminalRuntime):
            def __init__(self):
                self.active = {'conversation': 'a', 'thread': 't', 'turn': 'u'}
                self.state_lock = threading.RLock(); self.approvals = {}; self.command_output = {}; self.terminal_items = {}
                self.values = []
            def _console(self, kind, text, item=None): self.values.append((kind, text, item))
            def _clear_approvals(self, *args, **kwargs): pass
        runtime = Capture()
        def completed(identifier, result=None, status='completed', error=None):
            item = {'id': identifier, 'type': 'mcpToolCall', 'server': 'cove_files', 'tool': 'cove_record_pulse_note', 'status': status}
            if result is not None: item['result'] = result
            if error is not None: item['error'] = error
            runtime._terminal_notification({'method': 'item/completed', 'params': {'threadId': 't', 'turnId': 'u', 'item': item}})
        completed('bad', {'isError': True, 'content': [{'text': 'PRIVATE RESULT'}]})
        completed('good', {'isError': False, 'content': [{'text': 'PRIVATE RESULT'}]})
        completed('old')
        texts = [x[1] for x in runtime.values]
        self.assertTrue(texts[0].endswith('· 失败')); self.assertTrue(texts[1].endswith('· 成功'))
        self.assertTrue(texts[2].endswith('· 已结束（结果未记录）'))
        self.assertNotIn('PRIVATE RESULT', ''.join(texts))

    def test_jsonl_tail_is_bounded_and_chat_context_is_optional(self):
        with tempfile.TemporaryDirectory() as temp:
            state = Path(temp) / 'state.json'; state.write_text(json.dumps({'updatedAt': now(), 'summary': 'here'}))
            # Oversized hostile prefix is neither parsed nor returned; valid tail survives.
            history = Path(temp) / 'history.jsonl'
            history.write_bytes(b'x' * (3 * 1024 * 1024) + b'\n' + json.dumps({'id': 'last', 'at': now(), 'heartRate': 70, 'temperature': 37, 'breathingRate': 14}).encode() + b'\n')
            self.assertEqual(dashboard(state)['history'][0]['id'], 'last')
            with patch.dict('os.environ', {'COVE_PULSE_PATH': str(state)}):
                context = pulse_context()
            self.assertIn('数字身体模型', context); self.assertIn('不是医疗或传感器测量', context)
            with patch.dict('os.environ', {'COVE_PULSE_PATH': str(Path(temp) / 'missing')}):
                self.assertEqual(pulse_context(), '')


if __name__ == '__main__':
    unittest.main()
