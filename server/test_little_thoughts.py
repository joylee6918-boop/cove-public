import json
import shlex
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

from little_thoughts import split_reply, GUIDANCE
from runtime import CodexRuntime, COVE_DEVELOPER_GUIDANCE
from storage import Store


def field(value, close=True):
    return '```cove_little_thoughts\n' + value + ('\n```' if close else '')


class LittleThoughtsTests(unittest.TestCase):
    def test_plain_and_valid_field(self):
        self.assertEqual(split_reply('Hello\n'), ('Hello\n', None))
        self.assertEqual(split_reply('Hello\n\n'+field('A little aside.')), ('Hello', 'A little aside.'))
        self.assertIn(GUIDANCE, COVE_DEVELOPER_GUIDANCE)
        self.assertIn('Every ordinary visible reply to the user', GUIDANCE)
        self.assertIn('not hidden', GUIDANCE)
        self.assertIn('Do not invent personal', GUIDANCE)
        self.assertIn('main reply', GUIDANCE)

    def test_no_fallback_from_reasoning_or_prose(self):
        text = 'My thoughts: hello\n<thinking>not a field</thinking>'
        self.assertEqual(split_reply(text), (text, None))

    def test_invalid_reserved_fields_do_not_escape(self):
        for value in (field(''), field('x'*1001), field('incomplete', False), field('a')+'\n'+field('b')):
            self.assertEqual(split_reply('Hello\n'+value), ('Hello', None))
        self.assertEqual(split_reply('Hello\n'+field('not last')+'\nFinal.'), ('Hello\nFinal.', None))

    def test_examples_widgets_and_code_remain_untouched(self):
        for text in ('````markdown\n'+field('example')+'\n````',
                     '~~~markdown\n'+field('example')+'\n~~~',
                     '```widget\n{"id":"a"}\n```',
                     '    ```cove_little_thoughts\n    example\n    ```'):
            self.assertEqual(split_reply(text), (text, None))
        text = '```widget\n{"id":"a"}\n```'
        self.assertEqual(split_reply(text+'\n'+field('aside')), (text, 'aside'))

    def test_streaming_open_field_is_hidden(self):
        self.assertEqual(split_reply('Reply\n```cove_little_thoughts\npart'), ('Reply', None))

    def test_atomic_store_revision_fences_and_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(directory)
            try:
                store.create_conversation('a')
                store.accept({'id':'one','conversationID':'a','text':'fixture'})
                job = store.claim()
                store.bind_thread('a','thread'); store.bind_turn('one','turn','thread')
                self.assertFalse(store.complete_reply('one','wrong','Body','Aside'))
                self.assertTrue(store.complete_reply('one','turn','Body','Aside'))
                first = store._message(job['assistant'])
                store.complete_reply('one','turn','Body','Aside')
                self.assertEqual(store._message(job['assistant'])['revision'], first['revision'])
                store.finish('one','complete')
                self.assertFalse(store.complete_reply('one','turn','Late','Late'))
            finally:
                store.close()
            store = Store(directory)
            try:
                m = store._message(job['assistant'])
                self.assertEqual((m['text'],m['littleThoughts']), ('Body','Aside'))
            finally:
                store.close()

    def test_same_stdio_turn_extracts_public_aside(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(directory)
            store.create_conversation('a')
            store.accept({'id':'one','conversationID':'a','text':'COVE_TEST_LITTLE_THOUGHTS'})
            job=store.claim()
            command=shlex.quote(sys.executable)+' '+shlex.quote(str(Path(__file__).with_name('fake_app_server.py')))
            runtime=CodexRuntime(store,directory,command,model='fixture-sol',timeout=8)
            try:
                with patch.object(runtime,'request',wraps=runtime.request) as request:
                    status,error=runtime.run(job,threading.Event())
                    starts = [c for c in request.call_args_list if c.args[0]=='turn/start']
                    self.assertEqual(len(starts), 1)
                    self.assertIn(GUIDANCE, starts[0].args[1]['input'][0]['text'])
                self.assertEqual((status,error),('complete',None))
                store.finish('one',status)
                m=store._message(job['assistant'])
                self.assertEqual(m['littleThoughts'],'Synthetic authored aside.')
                self.assertNotIn('cove_little_thoughts',m['text'])
                self.assertNotIn('Synthetic authored aside.',m['text'])
                self.assertIsNone(m.get('thinkingSummary'))
                self.assertNotIn('PRIVATE REASONING',json.dumps(m))
                self.assertTrue(m['text'].startswith('actual final'))
                # Simulate a process restart resuming an existing thread whose
                # original developer instructions do not include the new contract.
                runtime.close()
                runtime=CodexRuntime(store,directory,command,model='fixture-sol',timeout=8)
                store.accept({'id':'two','conversationID':'a','text':'COVE_TEST_LITTLE_THOUGHTS'})
                next_job = store.claim()
                with patch.object(runtime,'request',wraps=runtime.request) as request:
                    status,error=runtime.run(next_job,threading.Event())
                    self.assertTrue(any(c.args[0]=='thread/resume' for c in request.call_args_list))
                    starts=[c for c in request.call_args_list if c.args[0]=='turn/start']
                    self.assertEqual(len(starts),1)
                    self.assertIn(GUIDANCE, starts[0].args[1]['input'][0]['text'])
                self.assertEqual((status,error),('complete',None))
                self.assertEqual(store._message(next_job['assistant'])['littleThoughts'],'Synthetic authored aside.')
            finally:
                runtime.close(); store.close()


if __name__ == '__main__':
    unittest.main()
