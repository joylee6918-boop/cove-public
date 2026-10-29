import base64, time, unittest
from unittest.mock import patch
from realtime import RealtimeBridge
from storage import APIError

class FakeRealtime(RealtimeBridge):
    def __init__(self): self.calls=[]; self.init_realtime()
    def request(self, method, params=None, timeout=30):
        self.calls.append((method,params))
        if method == 'thread/realtime/listVoices': return {'voices':{'v1':['cove','sol'],'v2':['alloy','marin'],'defaultV1':'cove','defaultV2':'marin'}}
        return {}

class FailingRealtime(FakeRealtime):
    def request(self, method, params=None, timeout=30):
        if method == 'thread/realtime/listVoices': return super().request(method,params,timeout)
        self.calls.append((method,params)); raise RuntimeError('unknown')

class RealtimeTests(unittest.TestCase):
    def test_native_voice_v3_uses_v1_catalog_and_server_managed_same_thread(self):
        rt=FakeRealtime()
        rt.realtime_start('original-thread', transport={'type':'webrtc','sdp':'v=0\r\n'})
        method, params = rt.calls[-1]
        self.assertEqual(method, 'thread/realtime/start')
        self.assertEqual(params['threadId'], 'original-thread')
        self.assertEqual(params['version'], 'v3')
        self.assertEqual(params['voice'], 'cove')
        self.assertIs(params['clientManagedHandoffs'], False)
        for voice in ('marin', 'alloy'):
            bad=FakeRealtime()
            with self.assertRaises(APIError): bad.realtime_start('thread', voice)
            self.assertFalse(any(method == 'thread/realtime/start' for method, _ in bad.calls))
        explicit=FakeRealtime(); explicit.realtime_start('thread', 'sol')
        self.assertEqual(explicit.calls[-1][1]['voice'], 'sol')

    def test_exact_0155_methods_and_bounded_events(self):
        rt=FakeRealtime(); session=rt.realtime_start('thread','cove')['sessionID']
        rt._realtime_notification({'method':'thread/realtime/started','params':{'threadId':'thread','realtimeSessionId':session,'version':'v3'}})
        pcm=base64.b64encode(b'\0\0'*160).decode(); rt.realtime_append_audio('thread',session,pcm,16000,1,160)
        rt._realtime_notification({'method':'thread/realtime/transcript/done','params':{'threadId':'thread','role':'user','text':'hello'}})
        self.assertEqual([x[0] for x in rt.calls],['thread/realtime/listVoices','thread/realtime/start','thread/realtime/appendAudio'])
        self.assertEqual(next(e['text'] for e in rt.realtime_poll('thread',session)['events'] if e['method'].endswith('/done')),'hello')
        rt.realtime_stop('thread',session); self.assertEqual(rt.calls[-1][0],'thread/realtime/stop')
    def test_rejects_bad_audio_and_wrong_thread(self):
        rt=FakeRealtime(); session=rt.realtime_start('thread')['sessionID']
        rt._realtime_notification({'method':'thread/realtime/started','params':{'threadId':'thread','realtimeSessionId':session,'version':'v3'}})
        with self.assertRaises(APIError): rt.realtime_append_audio('thread',session,'!',16000,1)
        with self.assertRaises(APIError): rt.realtime_append_audio('other',session,base64.b64encode(b'x').decode(),16000,1)
        with self.assertRaises(APIError): rt.realtime_stop('thread','stale')
        with self.assertRaises(APIError): rt.realtime_poll('thread','stale')
        rt.realtime_stop('thread',session)
        next_session=rt.realtime_start('thread')['sessionID']
        self.assertNotEqual(session,next_session)
        with self.assertRaises(APIError): rt.realtime_append_audio('thread',session,base64.b64encode(b'x').decode(),16000,1)

    def test_validation_and_unrelated_notifications_do_not_leak(self):
        rt=FakeRealtime(); session=rt.realtime_start('thread')['sessionID']
        rt._realtime_notification({'method':'thread/realtime/started','params':{'threadId':'thread','realtimeSessionId':'stale','version':'v3'}})
        self.assertEqual(rt.realtime_poll('thread',session)['events'],[])
        rt._realtime_notification({'method':'thread/realtime/started','params':{'threadId':'thread','realtimeSessionId':session,'version':'v3','secret':'no'}})
        with self.assertRaises(APIError): rt.realtime_append_audio('thread',session,base64.b64encode(b'xx').decode(),True,1,1)
        with self.assertRaises(APIError): rt.realtime_append_audio('thread',session,base64.b64encode(b'xxx').decode(),16000,1)
        with self.assertRaises(APIError): rt.realtime_append_audio('thread',session,base64.b64encode(b'xx').decode(),16000,1,2)
        text=str(rt.realtime_poll('thread',session)); self.assertNotIn('secret',text); self.assertNotIn('no',text)
        with self.assertRaises(APIError): rt.realtime_start('bad',[])

    def test_webrtc_offer_and_answer_are_bounded(self):
        offer='v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\n'
        rt=FakeRealtime(); session=rt.realtime_start('thread','cove',{'type':'webrtc','sdp':offer})['sessionID']
        self.assertEqual(rt.calls[-1][1]['transport'], {'type':'webrtc','sdp':offer})
        rt._realtime_notification({'method':'thread/realtime/started','params':{'threadId':'thread','realtimeSessionId':session,'version':'v3'}})
        answer='v=0\r\no=- 2 2 IN IP4 127.0.0.1\r\n'
        rt._realtime_notification({'method':'thread/realtime/sdp','params':{'threadId':'thread','sdp':answer,'secret':'no'}})
        events=rt.realtime_poll('thread',session)['events']
        self.assertEqual(events[-1], {'method':'thread/realtime/sdp','sdp':answer,'id':2})
        with self.assertRaises(APIError): FakeRealtime().realtime_start('thread',transport={'type':'webrtc','sdp':'bad'})

    def test_unknown_start_failure_keeps_reservation_and_prestart_error_is_generic(self):
        rt=FailingRealtime()
        with self.assertRaises(RuntimeError): rt.realtime_start('thread')
        with self.assertRaises(APIError): rt.realtime_start('thread')
        ok=FakeRealtime(); session=ok.realtime_start('thread')['sessionID']
        ok._realtime_notification({'method':'thread/realtime/error','params':{'threadId':'thread','message':'private/provider/path'}})
        result=ok.realtime_poll('thread',session)
        self.assertTrue(result['closed']); self.assertIn('启动失败',str(result)); self.assertNotIn('private',str(result))

    def test_audio_backpressure_closes_explicitly_and_idle_expires(self):
        rt=FakeRealtime(); session=rt.realtime_start('thread')['sessionID']
        rt._realtime_notification({'method':'thread/realtime/started','params':{'threadId':'thread','realtimeSessionId':session,'version':'v3'}})
        audio={'data':base64.b64encode(b'xx').decode(),'sampleRate':24000,'numChannels':1,'samplesPerChannel':1,'itemId':None}
        with patch('realtime.MAX_BUFFERED_AUDIO',1):
            rt._realtime_notification({'method':'thread/realtime/outputAudio/delta','params':{'threadId':'thread','audio':audio,'private':'no'}})
        result=rt.realtime_poll('thread',session)
        self.assertTrue(result['closed']); self.assertIn('缓冲区已满',str(result)); self.assertNotIn('private',str(result))
        next_id=rt.realtime_start('idle')['sessionID']; rt.realtime_sessions['idle']['lastActivity']=-1000
        rt.realtime_idle_timeout=30; self.assertTrue(rt.realtime_busy())
        for _ in range(20):
            if not rt.realtime_busy(): break
            time.sleep(.001)
        self.assertFalse(rt.realtime_busy())

if __name__ == '__main__': unittest.main()
