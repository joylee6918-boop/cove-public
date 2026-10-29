import json
import shlex
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

from thinking_summary import ThinkingSummary, MAX_SUMMARY_CHARS
from storage import Store
from runtime import CodexRuntime


def item(key='r', **extra):
    return {'type': 'reasoning', 'id': key, **extra}


class SummaryTests(unittest.TestCase):
    def test_only_explicit_public_summary(self):
        summary = ThinkingSummary()
        self.assertIsNone(summary.observe('item/reasoning/textDelta', {'delta': 'RAW'}))
        self.assertIsNone(summary.observe('item/completed', {'item': item(text='RAW', content=['RAW'])}))
        self.assertIsNone(summary.observe('item/completed', {'item': {'type': 'agentMessage', 'id': 'a', 'summary': ['NO']}}))
        self.assertEqual(summary.observe('item/completed', {'item': item(summary=['First', 'Second'], content=['RAW'])}), 'First\n\nSecond')

    def test_completion_snapshot_dedupe_order_and_empty(self):
        summary = ThinkingSummary()
        first = item(summary=['First'])
        self.assertEqual(summary.observe('item/completed', {'item': first}), 'First')
        self.assertIsNone(summary.observe('turn/completed', {'turn': {'items': [first]}}))
        self.assertEqual(summary.observe('turn/completed', {'turn': {'items': [first, item('r2', summary=['Second'])]}}), 'First\n\nSecond')
        self.assertEqual(summary.observe('item/completed', {'item': item(summary=[])}), 'Second')
        self.assertEqual(summary.observe('item/completed', {'item': item('r2', summary=[])}), '')

    def test_bounds_and_malformed_fields(self):
        summary = ThinkingSummary()
        for parts in (None, 'wrong', 2, {}):
            self.assertIsNone(summary.observe('item/completed', {'item': item(summary=parts)}))
        self.assertEqual(summary.observe('item/completed', {'item': item(summary=[None, {}, '  ', 'x' * 40000])}), 'x' * MAX_SUMMARY_CHARS)
        summary.observe('item/completed', {'item': item('r2', summary=['y' * 40000])})
        self.assertLessEqual(len(summary.observe('item/completed', {'item': item('r3', summary=['z'])})), MAX_SUMMARY_CHARS)

    def test_durable_revision_and_turn_fences(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(directory)
            store.create_conversation('a')
            store.accept({'id': 'one', 'conversationID': 'a', 'text': 'fixture'})
            job = store.claim()
            store.bind_thread('a', 'thread')
            store.bind_turn('one', 'turn', 'thread')
            self.assertFalse(store.set_thinking_summary('one', 'wrong', 'NO'))
            self.assertFalse(store.set_thinking_summary('missing', 'turn', 'NO'))
            self.assertTrue(store.set_thinking_summary('one', 'turn', 'Public summary'))
            m = store._message(job['assistant'])
            revision = m['revision']
            store.set_thinking_summary('one', 'turn', 'Public summary')
            self.assertEqual(store._message(job['assistant'])['revision'], revision)
            self.assertTrue(any(m.get('thinkingSummary') == 'Public summary' for m in store.poll('a', 0)['messages']))
            store.stream('one', 'Final reply')
            store.finish('one', 'complete')
            self.assertFalse(store.set_thinking_summary('one', 'turn', 'late'))
            store.close()
            store = Store(directory)
            m = store._message(job['assistant'])
            self.assertEqual(m['thinkingSummary'], 'Public summary')
            self.assertEqual(m['text'], 'Final reply')
            store.close()

    def test_actual_stdio_runtime_public_summary_not_raw_or_wrong_turn(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(directory)
            store.create_conversation('a')
            store.accept({'id': 'one', 'conversationID': 'a', 'text': 'synthetic fixture'})
            job = store.claim()
            command = shlex.quote(sys.executable) + ' ' + shlex.quote(str(Path(__file__).with_name('fake_app_server.py')))
            runtime = CodexRuntime(store, directory, command, model='fixture-sol', timeout=8)
            try:
                with patch.object(runtime, 'request', wraps=runtime.request) as request:
                    status, error = runtime.run(job, threading.Event())
                    starts = [c for c in request.call_args_list if c.args[0] == 'turn/start']
                    self.assertEqual(starts[0].args[1]['summary'], 'none')
                self.assertEqual((status, error), ('complete', None))
                store.finish('one', status)
                m = store._message(job['assistant'])
                self.assertIsNone(m.get('thinkingSummary'))
                self.assertNotIn('SUMMARY', json.dumps(m))
                self.assertNotIn('PRIVATE REASONING', json.dumps(m))
                self.assertTrue(m['text'].startswith('actual final'))
            finally:
                runtime.close()
                store.close()


if __name__ == '__main__':
    unittest.main()
