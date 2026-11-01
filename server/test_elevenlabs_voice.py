"""Synthetic voice tests only; never contact paid APIs or live chat."""
import json, os, tempfile, unittest, urllib.error
from pathlib import Path
from unittest.mock import patch
from voice_provider import ElevenLabsVoiceProvider, MiniMaxVoiceProvider, VoiceProviderError, selected_voice_provider
from voice_tools import synthesize_once
from files import VOICE_SEND_TOOL
import test_voice_provider as fixtures

class Response:
    def __init__(self,data=b'ID3audio',status=200): self.data,self.status=data,status
    def __enter__(self): return self
    def __exit__(self,*_): pass
    def read(self,n): return self.data[:n]

class ElevenLabsTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.key=Path(self.tmp.name)/'key'; self.key.write_text('fixture-secret'); self.key.chmod(0o600)
        self.calls=[]
    def provider(self,data=b'ID3audio',status=200,error=False):
        def open_(request,timeout):
            self.calls.append(request)
            if error: raise urllib.error.URLError('fixture-secret')
            self.assertEqual(timeout,60); return Response(data,status)
        return ElevenLabsVoiceProvider(self.key,voice_id="SyntheticVoice000001",opener=open_)
    def test_operator_voice_plain_text_one_request(self):
        p=self.provider(); self.assertEqual(p.synthesize('这是一条合成测试语音。'),(b'ID3audio','audio/mpeg'))
        self.assertEqual(len(self.calls),1); r=self.calls[0]; b=json.loads(r.data)
        self.assertEqual(r.full_url,'https://api.elevenlabs.io/v1/text-to-speech/SyntheticVoice000001?output_format=mp3_44100_128')
        self.assertEqual(b,{'text':'这是一条合成测试语音。','model_id':'eleven_v4','voice_settings':{'stability':.5,'similarity_boost':.75}})
        self.assertEqual(r.get_header('Xi-api-key'),'fixture-secret')
    def test_errors_redacted_no_retry(self):
        with self.assertRaises(VoiceProviderError) as ctx:self.provider(error=True).synthesize('正文')
        self.assertNotIn('fixture-secret',str(ctx.exception)); self.assertEqual(len(self.calls),1)
    def test_bad_mp3_status_and_size(self):
        for data,status in [(b'',200),(b'{"error":"bad"}',200),(b'ID3audio',503),(b'ID3'+b'x'*20*1024*1024,200)]:
            self.calls.clear()
            with self.assertRaises(VoiceProviderError):self.provider(data,status).synthesize('正文')
            self.assertEqual(len(self.calls),1)
    def test_text_invalid_no_network(self):
        for value in ['',None,' ','x'*2001]:
            with self.assertRaises(VoiceProviderError):self.provider().synthesize(value)
        self.assertFalse(self.calls)
    def test_bad_key_permissions_and_link(self):
        self.key.chmod(0o644)
        with self.assertRaises(VoiceProviderError):self.provider().synthesize('正文')
        self.key.chmod(0o600); link=self.key.with_name('link'); link.symlink_to(self.key)
        with self.assertRaises(VoiceProviderError):ElevenLabsVoiceProvider(link,voice_id='SyntheticVoice000001').synthesize('正文')
        self.assertFalse(self.calls)
    def test_legacy_and_new_default_without_fallback(self):
        env={'COVE_MINIMAX_API_KEY':'fixture','COVE_MINIMAX_VOICE_ID':'original-clone'}
        self.assertIsInstance(selected_voice_provider(env=env),MiniMaxVoiceProvider)
        env.update(COVE_VOICE_DEFAULT='elevenlabs',COVE_ELEVENLABS_KEY_PATH=str(self.key),COVE_ELEVENLABS_VOICE_ID='SyntheticVoice000001')
        self.assertIsInstance(selected_voice_provider(env=env),ElevenLabsVoiceProvider)
        self.assertEqual(selected_voice_provider('minimax',env).config.voice_id,'original-clone')
        with self.assertRaises(VoiceProviderError):selected_voice_provider('other',env)
        del env['COVE_ELEVENLABS_KEY_PATH']
        with self.assertRaises(VoiceProviderError):selected_voice_provider(env=env)
    def test_no_bundled_voice_or_implicit_opt_in(self):
        with self.assertRaises(VoiceProviderError):
            ElevenLabsVoiceProvider(self.key)
        with self.assertRaises(VoiceProviderError):
            selected_voice_provider(env={'COVE_VOICE_DEFAULT':'elevenlabs', 'COVE_ELEVENLABS_KEY_PATH':str(self.key)})
        self.assertFalse(self.calls)
    def test_schema_backwards_compatible(self):
        s=VOICE_SEND_TOOL['inputSchema']; self.assertEqual(s['required'],['text'])
        self.assertEqual(s['properties']['voice']['enum'],['elevenlabs','minimax'])
        self.assertFalse(s['additionalProperties']); self.assertIn('operator-configured',VOICE_SEND_TOOL['description'])

class VoiceSelectionRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.f=fixtures.VoiceRuntimeTests(); self.f.setUp(); self.addCleanup(self.f.tearDown)
        self.env=patch.dict(os.environ,{'COVE_VOICE_DEFAULT':'elevenlabs','COVE_ELEVENLABS_KEY_PATH':'/fixture/key','COVE_ELEVENLABS_VOICE_ID':'SyntheticVoice000001','COVE_MINIMAX_API_KEY':'fixture','COVE_MINIMAX_VOICE_ID':'original-clone'})
        self.env.start(); self.addCleanup(self.env.stop)
    def call(self):return self.f.runtime.mcp_file_call('a','cove_send_voice',self.f.args)
    def test_default_and_original_clone_each_idempotent(self):
        self.f.permit()
        with patch.object(ElevenLabsVoiceProvider,'synthesize',return_value=(b'ID3new','audio/mpeg')) as new:
            one=self.call(); self.assertEqual(one,self.call()); self.assertEqual(new.call_count,1)
        self.f.args={'text':'旧声音','voice':'minimax'}; self.f.permit('old-clone')
        with patch.object(MiniMaxVoiceProvider,'synthesize',return_value=(b'ID3old','audio/mpeg')) as old:
            two=self.call(); self.assertEqual(two,self.call()); self.assertEqual(old.call_count,1)
        self.assertNotEqual(one['id'],two['id'])
    def test_unknown_same_key_no_double_charge_or_fallback(self):
        self.f.permit()
        with patch.object(ElevenLabsVoiceProvider,'synthesize',side_effect=VoiceProviderError('unknown')) as new, patch.object(MiniMaxVoiceProvider,'synthesize') as old:
            for _ in range(2):
                with self.assertRaises(fixtures.APIError):self.call()
            self.assertEqual(new.call_count,1); old.assert_not_called()
    def test_invalid_choice_never_sends(self):
        self.f.args={'text':'正文','voice':'other'}; self.f.permit()
        with patch.object(ElevenLabsVoiceProvider,'synthesize') as synth:
            with self.assertRaises(fixtures.APIError):self.call()
            synth.assert_not_called()
    def test_completed_receipt_not_rebilled_when_default_changes(self):
        self.f.permit()
        with patch.object(ElevenLabsVoiceProvider,'synthesize',return_value=(b'ID3new','audio/mpeg')) as new:
            first=self.call(); self.assertEqual(new.call_count,1)
        with patch.dict(os.environ,{'COVE_VOICE_DEFAULT':'minimax'}),patch.object(MiniMaxVoiceProvider,'synthesize') as old:
            self.assertEqual(first,self.call()); old.assert_not_called()

if __name__=='__main__':unittest.main()
