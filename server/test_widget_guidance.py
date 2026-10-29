"""Offline tests: no real app-server requests, turns, or chat writes."""
import ast
import json
import re
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from runtime import COVE_DEVELOPER_GUIDANCE, CodexRuntime, guidance_topics
from widget_guidance import WIDGET_GUIDANCE

class WidgetGuidanceTests(unittest.TestCase):
    def test_start_and_resume_keep_only_base_guidance_and_thread_identity(self):
        class Captured(Exception): pass
        for thread, expected in [(None, 'thread/start'), ('existing-thread', 'thread/resume')]:
            with self.subTest(thread=thread):
                calls = []
                def request(method, params, timeout=0):
                    calls.append((method, params))
                    raise Captured()
                fake = SimpleNamespace(ensure_started=lambda: None, model_provider=None, model=None,
                    workspace='/isolated-test', loaded=set(), file_config=lambda _: {}, request=request)
                with self.assertRaises(Captured):
                    CodexRuntime._run(fake, {'conversation': {'id': 'isolated', 'thread': thread}}, threading.Event())
                self.assertEqual(len(calls), 1)
                self.assertEqual(calls[0][0], expected)
                self.assertEqual(calls[0][1]['developerInstructions'], COVE_DEVELOPER_GUIDANCE)
                self.assertNotIn(WIDGET_GUIDANCE, calls[0][1]['developerInstructions'])
                if thread: self.assertEqual(calls[0][1]['threadId'], thread)

    def test_widget_contract_is_routed_only_by_relevant_turn_text(self):
        self.assertTrue(guidance_topics('给我做一个选择卡片')['widget'])
        self.assertTrue(guidance_topics('use an inline UI form')['widget'])
        self.assertFalse(guidance_topics('抱抱我，陪我说会儿话')['widget'])

    def test_minimal_author_example_is_complete_json(self):
        example = json.loads(re.search(r'```widget\n(.*?)\n```', WIDGET_GUIDANCE, re.S).group(1))
        self.assertEqual(example['version'], 1)
        self.assertEqual(example['root']['children'][-1]['props']['action']['type'], 'send')
        self.assertIn('explicit confirmation', WIDGET_GUIDANCE)

if __name__ == '__main__': unittest.main()
