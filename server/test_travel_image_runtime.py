"""Synthetic native-event integration against actual Store/runtime/album; no generation."""
import base64
import copy
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch
from urllib.parse import parse_qs, urlsplit

from runtime import CodexRuntime
from storage import APIError, Store
from travel_bridge import TravelBridge

PNG=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aV1cAAAAASUVORK5CYII=')


class NativeImageRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.store=Store(self.temp.name)
        self.store.create_conversation('a'); self.store.create_conversation('b')
        self.store.accept({'id':'origin','conversationID':'a','text':'Synthetic photo request'})
        self.job=self.store.claim(); self.store.bind_turn('origin','turn')
        self.runtime=CodexRuntime(self.store,self.temp.name)
        self.runtime.active={'message':'origin','conversation':'a','thread':'thread','turn':'turn','cancel':threading.Event()}
        self.travel=TravelBridge(self.store,token_path='/unused-synthetic')
        self.runtime.travel=self.travel
        self.travel._request=Mock(side_effect=AssertionError('unexpected travel IO'))
        self.runtime._console=Mock()
        self.bindings={}
        self.event={'method':'item/completed','params':{'threadId':'thread','turnId':'turn','item':{
            'type':'imageGeneration','id':'image-1','status':'completed','result':base64.b64encode(PNG).decode()}}}

    def tearDown(self):
        self.runtime.active=None; self.runtime.close(); self.store.close(); self.temp.cleanup()

    def cache(self,scene='scene-1',journey='journey-1',revision=1,**extra):
        trip={'id':journey,'sceneID':scene,'status':'active','position':{'lat':35,'lon':135}}
        trip.update(extra)
        self.travel._record('a',{'conversationID':'a','revision':revision,'invitation':None,'journey':trip,'archives':[]})

    def start(self):
        event=copy.deepcopy(self.event);event['method']='item/started'
        event['params']['item'].update(status='in_progress',result='')
        self.runtime._native_image_event(event,self.bindings)

    def complete(self):
        self.runtime._native_image_event(self.event,self.bindings)

    def attachments(self):
        return self.store._message(self.job['assistant']).get('attachments',[])

    def valid_scene(self):
        self.travel._request.side_effect=None
        self.travel._request.return_value={'scene':{'id':'scene-1','journeyID':'journey-1','text':'Synthetic scenery'}}

    def test_started_freezes_scene_even_after_cache_changes_and_duplicate_completion(self):
        self.cache();self.start()
        self.assertEqual(self.bindings['image-1'],('journey-1','scene-1'))
        self.cache('scene-2','journey-2',2)
        self.start()  # duplicate started event must not silently rebind
        self.valid_scene();self.complete();self.complete()
        self.assertEqual(len(self.attachments()),1)
        attachment=self.attachments()[0]
        self.assertEqual(self.store.attachment(attachment['id'])['data'],PNG)
        photos=self.travel.album.photos('a','journey-1')
        self.assertEqual(len(photos),1);self.assertEqual(photos[0]['sceneID'],'scene-1')
        self.assertEqual(photos[0]['source'],'ai_generated')
        self.assertEqual(self.travel.album.photos('a','journey-2'),[])
        self.assertEqual(self.travel.album.photos('b','journey-1'),[])
        for call in self.travel._request.call_args_list:
            self.assertEqual(parse_qs(urlsplit(call.args[0]).query),{'conversationID':['a'],'journeyID':['journey-1'],'sceneID':['scene-1']})

    def test_wrong_thread_turn_cancelled_and_finished_job_no_attachment(self):
        self.start()
        for field in ('threadId','turnId'):
            event=copy.deepcopy(self.event);event['params'][field]='other'
            self.runtime._native_image_event(event,self.bindings)
        self.runtime.active['cancel'].set();self.complete()
        self.runtime.active['cancel'].clear()
        self.store.finish('origin','complete');self.complete()
        self.assertEqual(self.attachments(),[]);self.travel._request.assert_not_called()

    def test_active_turn_changes_during_scene_lookup_no_attachment(self):
        self.cache();self.start()
        def stale(*args,**kwargs):
            self.runtime.active=dict(self.runtime.active,turn='new-turn')
            return {'scene':{'id':'scene-1','journeyID':'journey-1'}}
        self.travel._request.side_effect=stale
        self.complete()
        self.assertEqual(self.attachments(),[])
        self.assertEqual(self.travel.album.photos('a','journey-1'),[])

    def test_no_travel_delivers_normal_image_without_album_or_network(self):
        self.start();self.complete()
        self.assertIsNone(self.bindings['image-1'])
        self.assertEqual(len(self.attachments()),1)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM travel_photos').fetchone()[0],0)
        self.travel._request.assert_not_called()

    def test_missing_started_does_not_guess_scene_from_current_cache(self):
        self.cache();self.complete()
        self.assertEqual(len(self.attachments()),1)
        self.assertEqual(self.travel.album.photos('a','journey-1'),[])
        self.travel._request.assert_not_called()

    def test_unverified_scene_delivers_image_but_never_archives(self):
        self.cache();self.start()
        self.travel._request.side_effect=APIError(503,'synthetic unavailable')
        self.complete()
        self.assertEqual(len(self.attachments()),1)
        self.assertEqual(self.travel.album.photos('a','journey-1'),[])
        self.assertTrue(self.runtime._console.called)
        self.travel._request.side_effect=None
        self.travel._request.return_value={'scene':{'id':'wrong-scene','journeyID':'journey-1'}}
        self.complete()
        self.assertEqual(len(self.attachments()),1)
        self.assertEqual(self.travel.album.photos('a','journey-1'),[])

    def test_unknown_position_not_bound_and_empty_result_never_reads_saved_path(self):
        self.cache(outcomeUnknown=True);self.start()
        self.assertIsNone(self.bindings['image-1'])
        self.event['params']['item'].update(result='',savedPath='/etc/passwd')
        with patch('builtins.open',side_effect=AssertionError('must not read path')):
            self.complete()
        self.assertEqual(self.attachments(),[])
        self.travel._request.assert_not_called();self.assertTrue(self.runtime._console.called)


if __name__=='__main__':unittest.main()
