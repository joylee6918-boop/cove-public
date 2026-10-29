"""Synthetic fixtures only: original audio is analyzed for the ordinary turn."""
import io
import os
from pathlib import Path
import shlex
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
import wave

from audio_inputs import AUDIO_GUIDANCE, validate_audio
from runtime import CodexRuntime
from storage import Store


def wav():
    result = io.BytesIO()
    with wave.open(result, 'wb') as writer:
        writer.setnchannels(1); writer.setsampwidth(2); writer.setframerate(16000)
        writer.writeframes(b'\0\0' * 160)
    return result.getvalue()


def attachment(data=None, mime='audio/wav', filename='synthetic.wav'):
    return {'data': wav() if data is None else data, 'mime': mime, 'filename': filename}


class AudioInputTests(unittest.TestCase):
    def test_supported_containers(self):
        for mime, data in [('audio/wav', wav()), ('audio/mpeg', b'ID3\x04\0\0\0\0\0\0test'),
                           ('audio/mp4', b'\0\0\0\x18ftypM4A \0\0\0\0isommp42'),
                           ('audio/webm', b'\x1a\x45\xdf\xa3\x9ftest'), ('audio/ogg', b'OggS\0' + b'\0' * 22)]:
            self.assertIsNone(validate_audio(attachment(data, mime)))

    def test_invalid_or_oversized_container(self):
        for value in [attachment(b''), attachment(b'invalid'), attachment(wav(), 'audio/flac'),
                      attachment(b'RIFF\0\0\0\0WEBP'), attachment(b'\xff\xf9\x90\0', 'audio/mpeg')]:
            self.assertIsNotNone(validate_audio(value))
        with patch('audio_inputs.AUDIO_PER_FILE', 5):
            self.assertIsNotNone(validate_audio(attachment()))


class CaptureRuntime(CodexRuntime):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.calls = []

    def request(self, method, params=None, timeout=30):
        self.calls.append((method, params))
        return super().request(method, params, timeout)


class AudioRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(self.temp.name)
        command = shlex.quote(sys.executable) + ' ' + shlex.quote(str(Path(__file__).with_name('fake_app_server.py')))
        self.env = patch.dict(os.environ, {'COVE_MODEL_PROVIDER': 'synthetic-provider'})
        self.env.start()
        self.runtime = CaptureRuntime(self.store, self.temp.name, command, model='fixture-sol', timeout=5)

    def tearDown(self):
        self.runtime.close(); self.store.close(); self.temp.cleanup(); self.env.stop()

    def run_fixture(self, conversation, message, files):
        ids = [self.store.add_attachment(f['filename'], f['mime'], f['data'])['id'] for f in files]
        self.store.accept({'id': message, 'conversationID': conversation, 'text': 'SYNTHETIC AUDIO TEST', 'attachmentIDs': ids})
        job = self.store.claim()
        status, error = self.runtime.run(job, threading.Event())
        self.store.finish(message, status, error)
        self.assertEqual((status, error), ('complete', None))
        return [p for method, p in self.runtime.calls if method == 'turn/start'][-1]

    def test_analysis_start_and_resume_preserve_thread_model_and_other_inputs(self):
        self.store.create_conversation('new'); self.store.create_conversation('old')
        self.store.bind_thread('old', 'existing-original-thread')
        data = wav()
        files = [attachment(data), attachment(b'\x89PNG\r\n\x1a\nfixture', 'image/png', 'fixture.png'),
                 attachment(b'EXISTING TEXT', 'text/plain', 'fixture.txt')]
        result = {'ok': True, 'transcript': '合成测试你好', 'duration': .01,
                  'observations': ['样本中有停顿'], 'warnings': []}
        with patch('runtime.voice_ingest.analyze', return_value=result) as analyzer:
            for conversation in ('new', 'old'):
                turn = self.run_fixture(conversation, 'message-' + conversation, files)
                self.assertEqual(turn['model'], 'fixture-sol')
                self.assertEqual([i['type'] for i in turn['input']], ['text', 'image'])
                text = turn['input'][0]['text']
                for expected in ('合成测试你好', '样本中有停顿', 'EXISTING TEXT', AUDIO_GUIDANCE):
                    self.assertIn(expected, text)
            self.assertEqual(analyzer.call_count, 2)
            self.assertEqual(analyzer.call_args.args[0]['data'], data)
        self.assertEqual(turn['threadId'], 'existing-original-thread')
        self.assertEqual(self.store.conversation('old')['thread'], 'existing-original-thread')
        self.assertFalse(any(m.startswith('thread/realtime') or m == 'model/list' for m, _ in self.runtime.calls))

    def test_count_and_byte_budget(self):
        self.store.create_conversation('a')
        result = {'ok': False, 'error': 'synthetic failure'}
        with patch('runtime.voice_ingest.analyze', return_value=result) as analyzer:
            turn = self.run_fixture('a', 'count', [attachment(filename=str(n)+'.wav') for n in range(4)])
            self.assertEqual(analyzer.call_count, 3)
            self.assertIn('分析预算', turn['input'][0]['text'])
        with patch('runtime.AUDIO_TOTAL', len(wav())), patch('runtime.voice_ingest.analyze', return_value=result) as analyzer:
            turn = self.run_fixture('a', 'bytes', [attachment(filename=str(n)+'.wav') for n in range(2)])
            self.assertEqual(analyzer.call_count, 1)
            self.assertIn('分析预算', turn['input'][0]['text'])

    def test_unavailable_analysis_does_not_drop_message_or_fake_heard(self):
        self.store.create_conversation('a')
        with patch('runtime.voice_ingest.analyze', return_value={'ok': False, 'error': '本次未识别成功'}):
            turn = self.run_fixture('a', 'bad', [attachment(b'invalid wav')])
        self.assertEqual(len(turn['input']), 1)
        self.assertIn('本次未识别成功', turn['input'][0]['text'])
        self.assertIn('不能', turn['input'][0]['text'])

    def test_cancellation_during_analysis_does_not_dispatch_model_turn(self):
        self.store.create_conversation('a')
        item = self.store.add_attachment('synthetic.wav', 'audio/wav', wav())
        self.store.accept({'id':'cancelled', 'conversationID':'a', 'text':'TEST', 'attachmentIDs':[item['id']]})
        job = self.store.claim(); cancellation = threading.Event()
        def stop(*args):
            cancellation.set(); return {'ok': False, 'error': 'cancelled'}
        with patch('runtime.voice_ingest.analyze', side_effect=stop):
            self.assertEqual(self.runtime.run(job, cancellation), ('interrupted', None))
        self.assertFalse(any(m == 'turn/start' for m, _ in self.runtime.calls))


if __name__ == '__main__':
    unittest.main()
