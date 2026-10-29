"""Synthetic transport selection tests; no real account/model/health calls."""
import os
from pathlib import Path
import shlex
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
from runtime import CodexRuntime
from storage import Store


class TransportTests(unittest.TestCase):
    def test_new_and_original_resume_explicit_provider_preserves_tools_and_model(self):
        class Recorded(CodexRuntime):
            def request(self, method, params=None, timeout=30):
                calls.append((method, params))
                return super().request(method, params, timeout)
        with tempfile.TemporaryDirectory() as temp, patch.dict(os.environ, {'COVE_MODEL_PROVIDER': 'cove_http'}):
            store = Store(temp); store.create_conversation('a'); calls = []
            command = shlex.join([sys.executable, str(Path(__file__).with_name('fake_app_server.py'))])
            original = None
            try:
                for index in range(2):
                    runtime = Recorded(store, temp, command, model='fixture-sol')
                    try:
                        store.accept({'id': str(index), 'conversationID': 'a', 'text': 'synthetic transport fixture'})
                        job = store.claim(); status, error = runtime.run(job, threading.Event())
                        store.finish(job['message'], status, error)
                        self.assertEqual(status, 'complete')
                        thread = store.conversation('a')['thread']
                        if original is None: original = thread
                        self.assertEqual(thread, original)
                    finally: runtime.close()
                for method in ('thread/start', 'thread/resume'):
                    params = next(p for m,p in calls if m == method)
                    self.assertEqual(params['modelProvider'], 'cove_http')
                    self.assertIn('mcp_servers.cove_files', params['config'])
                self.assertEqual(next(p for m,p in calls if m=='thread/start')['model'], 'fixture-sol')
            finally: store.close()

    def test_mismatched_or_missing_provider_fails_before_turn(self):
        with tempfile.TemporaryDirectory() as temp, patch.dict(os.environ, {'COVE_MODEL_PROVIDER': 'cove_http'}):
            store = Store(temp); store.create_conversation('a'); store.bind_thread('a','original')
            runtime = CodexRuntime(store,temp); calls=[]
            runtime.ensure_started=lambda: None
            runtime.file_config=lambda _: {'mcp_servers.cove_files': {}}
            def reply(method,params=None,timeout=30):
                calls.append(method)
                return {'thread': {'id':'original'}, 'modelProvider':'openai'}
            runtime.request=reply
            try:
                store.accept({'id':'x','conversationID':'a','text':'synthetic'})
                with self.assertRaisesRegex(RuntimeError,'连接配置未生效'):
                    runtime.run(store.claim(),threading.Event())
                self.assertNotIn('turn/start',calls)
                with self.assertRaises(RuntimeError):runtime._check_thread_provider({})
                self.assertEqual(store.conversation('a')['thread'],'original')
            finally:runtime.close();store.close()

    def test_unconfigured_keeps_legacy_default(self):
        with tempfile.TemporaryDirectory() as temp, patch.dict(os.environ, {'COVE_MODEL_PROVIDER':''}):
            store=Store(temp);runtime=CodexRuntime(store,temp)
            try:
                self.assertIsNone(runtime.model_provider)
                runtime._check_thread_provider({})
            finally:runtime.close();store.close()

if __name__=='__main__':unittest.main()
