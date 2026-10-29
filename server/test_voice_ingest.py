"""Isolated helper subprocess tests; no model downloads, audio APIs or user data."""
import json
import os
from pathlib import Path
import sys
import shlex
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from test_audio_inputs import attachment, wav, CaptureRuntime
from storage import Store
import voice_ingest


class VoiceIngestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name)
        self.fake = self.path / 'voice_analyze_worker.py'
        self.env = patch.dict(os.environ, {'COVE_VOICE_PYTHON': sys.executable,
                                          'COVE_VOICE_MODEL': '/synthetic/model',
                                          'COVE_VOICE_BASELINE': str(self.path / 'voice-baseline.json'),
                                          'COVE_TOKEN': 'SYNTHETIC_SECRET',
                                          'OPENAI_API_KEY': 'SYNTHETIC_SECRET',
                                          'PYTHONPATH': '/synthetic/do-not-inherit'})
        self.env.start()
        self.location = patch.object(voice_ingest, '__file__', str(self.path / 'voice_ingest.py'))
        self.location.start()

    def tearDown(self):
        self.location.stop(); self.env.stop(); self.temp.cleanup()

    def helper(self, body):
        self.fake.write_text('import sys,os,json,time\n' + body)

    def test_exact_original_bytes_and_isolated_child_environment(self):
        self.helper(
            'assert sys.argv[1:] == ["--model", "/synthetic/model"]\n'
            'assert not any(k in os.environ for k in ["COVE_TOKEN", "OPENAI_API_KEY", "PYTHONPATH"])\n'
            'assert os.environ["OMP_NUM_THREADS"] == "1"\n'
            'assert os.environ["HF_HUB_OFFLINE"] == "1"\n'
            'assert sys.stdin.buffer.read() == bytes.fromhex(' + repr(wav().hex()) + ')\n'
            'print(json.dumps({"ok":True,"transcript":"合成测试", "duration":0.01, '
            '"observations":["片段中有停顿"], "features":{"not_a_report":123}, "warnings":[]}))\n')
        result = voice_ingest.analyze(attachment(), threading.Event())
        self.assertTrue(result['ok']); self.assertEqual(result['transcript'], '合成测试')
        self.assertEqual(result['observations'], ['片段中有停顿'])
        self.assertNotIn('features', result)

    def test_empty_transcript_keeps_only_validated_breath_hint(self):
        self.helper('sys.stdin.buffer.read(); print(json.dumps({"ok":True,"transcript":"  ","duration":1,'
                    '"observations":["unsupported emotion"],"features":{"breath_like_count":3,"breath_like_seconds":.8},"warnings":[]}))\n')
        result = voice_ingest.analyze(attachment(), threading.Event())
        self.assertTrue(result['ok']); self.assertEqual(result['transcript'], '')
        self.assertEqual(len(result['observations']), 1)
        self.assertIn('呼吸或喘气', result['observations'][0])
        self.assertNotIn('unsupported emotion', result['observations'])
        self.assertIn('没有识别出', result['warnings'][0])

    def test_cove_baseline_is_numeric_private_and_enables_relative_voice_quality(self):
        base = '{"f0_mean":220,"loudness_db":-22,"syllable_rate":5,"h1_h2":2,"hnr_db":1,"spectral_tilt":-10,"jitter":.01,"shimmer":.1}'
        self.helper('sys.stdin.buffer.read(); print(json.dumps({"ok":True,"transcript":"合成基线","duration":2,"observations":[],"features":' + base + ',"warnings":[]}))\n')
        for _ in range(5):
            self.assertTrue(voice_ingest.analyze(attachment(), threading.Event())['ok'])
        stored = json.loads((self.path / 'voice-baseline.json').read_text())
        self.assertEqual(len(stored['samples']), 5)
        self.assertNotIn('transcript', json.dumps(stored))
        changed = '{"f0_mean":245,"loudness_db":-28,"syllable_rate":3,"h1_h2":7,"hnr_db":-4,"spectral_tilt":-16,"jitter":.06,"shimmer":.5}'
        self.helper('sys.stdin.buffer.read(); print(json.dumps({"ok":True,"transcript":"合成变化","duration":2,"observations":[],"features":' + changed + ',"warnings":[]}))\n')
        result = voice_ingest.analyze(attachment(), threading.Event())
        joined = ' '.join(result['observations'])
        self.assertIn('个人基线', joined)
        self.assertIn('更松、更带气声', joined)
        self.assertNotIn('features', result)

    def test_invalid_result_and_child_failure_never_leak_stderr(self):
        for body in ['print("not-json")', 'print("{}")', 'print(json.dumps({"ok":True,"transcript":"x","duration":122}))',
                     'print(json.dumps({"ok":True,"transcript":"x","duration":float("nan")}))',
                     'print(json.dumps({"ok":True,"transcript":"x","duration":1,"observations":[23]}))',
                     'sys.stderr.write("SYNTHETIC_SECRET"); sys.exit(3)']:
            with self.subTest(body=body):
                self.helper('sys.stdin.buffer.read(); ' + body + '\n')
                result = voice_ingest.analyze(attachment(), threading.Event())
                self.assertFalse(result['ok']); self.assertEqual(result['transcript'], '')
                self.assertNotIn('SYNTHETIC_SECRET', json.dumps(result))

    def test_timeout_and_cancellation_terminate_helper_without_retry(self):
        self.helper('sys.stdin.buffer.read(); time.sleep(10)\n')
        begin = time.monotonic()
        with patch.object(voice_ingest, 'TIMEOUT', .05):
            result = voice_ingest.analyze(attachment(), threading.Event())
        self.assertFalse(result['ok']); self.assertIn('超时', result['error'])
        cancellation = threading.Event(); timer = threading.Timer(.05, cancellation.set)
        timer.start()
        try:
            result = voice_ingest.analyze(attachment(), cancellation)
        finally:
            timer.join()
        self.assertFalse(result['ok']); self.assertIn('取消', result['error'])
        self.assertLess(time.monotonic() - begin, 3)

    def test_missing_helper_invalid_signature_and_pre_cancel_do_not_claim_success(self):
        result = voice_ingest.analyze(attachment(), threading.Event())
        self.assertFalse(result['ok'])
        with patch.object(voice_ingest.subprocess, 'Popen') as popen:
            self.assertFalse(voice_ingest.analyze(attachment(b'invalid'), threading.Event())['ok'])
            cancelled = threading.Event(); cancelled.set()
            self.assertFalse(voice_ingest.analyze(attachment(), cancelled)['ok'])
            popen.assert_not_called()

    def test_result_size_limit(self):
        with self.assertRaises(ValueError):
            voice_ingest._result(b'x' * (voice_ingest.MAX_RESULT + 1))

    def test_real_fake_helper_through_runtime_original_resumed_thread(self):
        self.helper('assert sys.stdin.buffer.read() == bytes.fromhex(' + repr(wav().hex()) + ')\n'
                    'print(json.dumps({"ok":True,"transcript":"完整链路合成测试", "duration":.01, '
                    '"observations":["有可测停顿"],"warnings":[]}))\n')
        store = Store(str(self.path / 'store')); store.create_conversation('a')
        store.bind_thread('a', 'original-audio-test-thread')
        command = shlex.quote(sys.executable) + ' ' + shlex.quote(str(Path(__file__).with_name('fake_app_server.py')))
        runtime = CaptureRuntime(store, self.temp.name, command, model='fixture-sol', timeout=5)
        try:
            item = store.add_attachment('synthetic.wav', 'audio/wav', wav())
            store.accept({'id':'full-route', 'conversationID':'a', 'text':'SYNTHETIC', 'attachmentIDs':[item['id']]})
            job = store.claim()
            self.assertEqual(runtime.run(job, threading.Event()), ('complete', None))
            turn = [p for m, p in runtime.calls if m == 'turn/start'][-1]
            self.assertEqual(turn['threadId'], 'original-audio-test-thread')
            self.assertEqual(turn['model'], 'fixture-sol')
            self.assertEqual(len(turn['input']), 1)
            self.assertIn('完整链路合成测试', turn['input'][0]['text'])
            self.assertIn('有可测停顿', turn['input'][0]['text'])
            self.assertEqual(store.attachment(item['id'])['data'], wav())
            self.assertFalse(any(m.startswith('thread/realtime') for m, _ in runtime.calls))
        finally:
            runtime.close(); store.close()


if __name__ == '__main__':
    unittest.main()
