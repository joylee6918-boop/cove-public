import json, os, sys, tempfile, threading, unittest
import urllib.error, urllib.request
from unittest.mock import patch
sys.path.insert(0, os.path.dirname(__file__))
from voice_provider import MiniMaxVoiceConfig, MiniMaxVoiceProvider, VoiceProviderError, _NoRedirect
from voice_tools import synthesize_attachment, synthesize_once
from storage import Store
from storage import APIError
from runtime import CodexRuntime


class Response:
    def __init__(self, body): self.body = body
    def __enter__(self): return self
    def __exit__(self, *_): pass
    def read(self, _): return self.body


class VoiceProviderTests(unittest.TestCase):
    def test_selected_china_voice_request(self):
        config = MiniMaxVoiceConfig.from_env({
            "COVE_MINIMAX_API_KEY": "test-secret", "COVE_MINIMAX_VOICE_ID": "selected-voice",
            "COVE_MINIMAX_ENDPOINT": "https://api.minimax.cn/v1/t2a_v2",
            "COVE_MINIMAX_MODEL": "speech-2.6-hd", "COVE_MINIMAX_EMOTION": "fluent",
            "COVE_MINIMAX_SPEED": "1.02", "COVE_MINIMAX_VOLUME": "1.0"})
        def open_(request, timeout):
            self.assertEqual(request.full_url, "https://api.minimax.cn/v1/t2a_v2")
            payload = json.loads(request.data)
            self.assertEqual(payload["voice_setting"], {"voice_id": "selected-voice", "speed": 1.02, "vol": 1.0, "pitch": 0, "emotion": "fluent"})
            self.assertEqual(payload["text"], "你好。<#0.25#>我在。")
            return Response(b'{"data":{"audio":"494433"}}')
        self.assertEqual(MiniMaxVoiceProvider(config, open_).synthesize("你好。<#0.25#>我在。")[0], b"ID3")

    def test_config_rejects_unsafe_endpoint_and_bad_voice_settings(self):
        for override in ({"COVE_MINIMAX_ENDPOINT": "https://evil.invalid/tts"},
                         {"COVE_MINIMAX_SPEED": "nan"}, {"COVE_MINIMAX_SPEED": "2.1"},
                         {"COVE_MINIMAX_VOLUME": "inf"}, {"COVE_MINIMAX_VOLUME": "0"},
                         {"COVE_MINIMAX_EMOTION": "whisper"}, {"COVE_MINIMAX_EMOTION": "unknown"}):
            with self.subTest(override=override), self.assertRaises(VoiceProviderError):
                MiniMaxVoiceConfig.from_env({"COVE_MINIMAX_API_KEY": "k", "COVE_MINIMAX_VOICE_ID": "v", **override})

    def test_old_default_config_is_unchanged(self):
        config = MiniMaxVoiceConfig.from_env({"COVE_MINIMAX_API_KEY": "k", "COVE_MINIMAX_VOICE_ID": "v"})
        self.assertEqual((config.model, config.endpoint, config.speed, config.volume, config.emotion),
                         ("speech-2.8-turbo", "https://api.minimax.io/v1/t2a_v2", 1.0, 1.0, ""))

    def test_unconfigured_is_explicit(self):
        with self.assertRaisesRegex(VoiceProviderError, "未配置"):
            MiniMaxVoiceConfig.from_env({})

    def test_redirect_handler_refuses_forwarding_authorization_without_network(self):
        request = urllib.request.Request('https://api.minimax.io/v1/t2a_v2', headers={'Authorization':'Bearer secret'})
        redirected = _NoRedirect().redirect_request(request, None, 307, 'redirect', {}, 'https://evil.invalid/steal')
        self.assertIsNone(redirected)

    def test_provider_does_not_retry_uncertain_network_failure(self):
        calls=[]
        def fail(request, timeout): calls.append(request); raise urllib.error.URLError('uncertain')
        with self.assertRaisesRegex(VoiceProviderError, '请求失败'):
            MiniMaxVoiceProvider(MiniMaxVoiceConfig('secret','voice'), fail).synthesize('hello')
        self.assertEqual(len(calls), 1)

    def test_request_does_not_take_phone_credentials(self):
        seen = {}
        def open_(request, timeout):
            seen.update(headers=dict(request.header_items()), body=json.loads(request.data), timeout=timeout)
            return Response(json.dumps({"base_resp":{"status_code":0}, "data":{"audio":"494433"}}).encode())
        config = MiniMaxVoiceConfig("server-secret", "authorized-voice", timeout=9)
        data, mime = MiniMaxVoiceProvider(config, open_).synthesize(" 你好 ")
        self.assertEqual((data, mime), (b"ID3", "audio/mpeg"))
        self.assertEqual(seen["body"]["voice_setting"]["voice_id"], "authorized-voice")
        self.assertEqual(seen["body"]["output_format"], "hex")
        self.assertEqual(seen["headers"]["Authorization"], "Bearer server-secret")
        self.assertEqual(seen["timeout"], 9)

    def test_rejects_empty_long_error_and_oversize(self):
        config = MiniMaxVoiceConfig("k", "v", maximum_characters=2, maximum_audio_bytes=2)
        for text in ("", "abc"):
            with self.assertRaises(VoiceProviderError): MiniMaxVoiceProvider(config).synthesize(text)
        def failed(*_args, **_kwargs):
            return Response(b'{"base_resp":{"status_code":1004,"status_msg":"denied"}}')
        with self.assertRaisesRegex(VoiceProviderError, "1004"):
            MiniMaxVoiceProvider(config, failed).synthesize("ok")
        def big(*_args, **_kwargs):
            return Response(b'{"data":{"audio":"010203"}}')
        with self.assertRaisesRegex(VoiceProviderError, "20 MiB"):
            MiniMaxVoiceProvider(config, big).synthesize("ok")

    def test_store_adapter(self):
        class Store:
            def add_attachment(self, filename, mime, data): return {"filename":filename,"mime":mime,"size":len(data)}
        class Provider:
            def synthesize(self, text): return (b"ID3", "audio/mpeg")
        self.assertEqual(synthesize_attachment(Store(), "hello", Provider())["size"], 3)

    def test_paid_synthesis_receipt_is_reused(self):
        class Provider:
            calls = 0
            def synthesize(self, text): self.calls += 1; return (b"ID3", "audio/mpeg")
        provider = Provider()
        with tempfile.TemporaryDirectory() as directory:
            store = Store(directory)
            self.assertEqual(synthesize_once(store, "same-call", "hello", provider)[0], b"ID3")
            self.assertEqual(synthesize_once(store, "same-call", "hello", provider)[0], b"ID3")
            self.assertEqual(provider.calls, 1)
            store.close()

    def test_reservation_rejects_oversize_without_persisting_audio(self):
        class Provider:
            def synthesize(self, text): return (b'x' * (20 * 1024 * 1024 + 1), 'audio/mpeg')
        with tempfile.TemporaryDirectory() as directory:
            store = Store(directory)
            with self.assertRaisesRegex(VoiceProviderError, '20 MiB'):
                synthesize_once(store, 'oversize', 'hello', Provider())
            row = store.db.execute('SELECT state,audio FROM voice_tool_results WHERE call=?', ('oversize',)).fetchone()
            self.assertEqual(row['state'], 'failed'); self.assertIsNone(row['audio']); store.close()


class VoiceRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.store = Store(self.temp.name)
        self.store.create_conversation('a'); self.store.create_conversation('b')
        self.store.accept({'id':'voice-user','conversationID':'a','text':'voice please'})
        self.job = self.store.claim(); self.store.bind_turn('voice-user','turn')
        self.runtime = CodexRuntime(self.store, self.temp.name)
        self.runtime.active = {'conversation':'a','thread':'thread','turn':'turn','message':'voice-user','cancel':threading.Event()}
        self.args = {'text':'你好'}

    def tearDown(self):
        self.runtime.close(); self.store.close(); self.temp.cleanup()

    def permit(self, call='voice-call'):
        self.runtime.file_permits.append({'conversation':'a','turn':'turn','call':call,'tool':'cove_send_voice','arguments':self.args,'used':False})

    def test_actual_permit_attachment_and_no_duplicate_charge(self):
        self.permit(); calls = []
        with patch.dict(os.environ, {'COVE_MINIMAX_API_KEY':'secret','COVE_MINIMAX_VOICE_ID':'owned'}), \
             patch.object(MiniMaxVoiceProvider, 'synthesize', side_effect=lambda text: (calls.append(text) or (b'ID3audio','audio/mpeg'))):
            first = self.runtime.mcp_file_call('a','cove_send_voice',self.args)
            second = self.runtime.mcp_file_call('a','cove_send_voice',self.args)
        self.assertEqual(first, second); self.assertEqual(calls, ['你好'])
        self.assertEqual(self.store.attachment(first['id'])['data'], b'ID3audio')
        self.assertEqual(self.store._message(self.job['assistant'])['attachments'], [first])

    def test_slow_provider_cancel_does_not_attach(self):
        self.permit('slow'); started = threading.Event(); release = threading.Event(); result = []
        def slow(_): started.set(); release.wait(2); return b'ID3audio','audio/mpeg'
        def invoke():
            try: self.runtime.mcp_file_call('a','cove_send_voice',self.args)
            except Exception as error: result.append(error)
        with patch.dict(os.environ, {'COVE_MINIMAX_API_KEY':'secret','COVE_MINIMAX_VOICE_ID':'owned'}), patch.object(MiniMaxVoiceProvider,'synthesize',side_effect=slow):
            thread=threading.Thread(target=invoke); thread.start(); self.assertTrue(started.wait(1))
            self.runtime.active['cancel'].set(); release.set(); thread.join(2)
        self.assertEqual(len(result),1); self.assertIsInstance(result[0],APIError)
        self.assertEqual(self.store._message(self.job['assistant'])['attachments'], [])

    def test_stale_cross_conversation_and_oversize_rejected(self):
        self.runtime.file_permits.append({'conversation':'a','turn':'old','call':'stale','tool':'cove_send_voice','arguments':self.args,'used':False})
        with patch('runtime.MCP_EVENT_WAIT', .01):
            with self.assertRaises(APIError): self.runtime.mcp_file_call('a','cove_send_voice',self.args)
        with self.assertRaises(APIError): self.runtime.mcp_file_call('b','cove_send_voice',self.args)
        config=MiniMaxVoiceConfig('k','v',maximum_audio_bytes=2)
        def big(*_args, **_kwargs): return Response(b'{"data":{"audio":"010203"}}')
        with self.assertRaises(VoiceProviderError): MiniMaxVoiceProvider(config,big).synthesize('ok')

if __name__ == "__main__": unittest.main()
