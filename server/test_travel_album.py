import base64,tempfile,unittest
from unittest.mock import Mock
from storage import Store,APIError
from travel_bridge import TravelBridge
PNG=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP3cAAAAASUVORK5CYII=')
class AlbumTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.s=Store(self.tmp.name)
  self.s.create_conversation('a');self.s.create_conversation('b')
  self.s.accept({'id':'m','conversationID':'a','text':'synthetic photo request'})
  self.s.claim();self.s.bind_turn('m','t');self.b=TravelBridge(self.s)
  self.b._request=Mock(return_value={'scene':{'id':'scene','journeyID':'journey'}})
  self.a=self.s.create_assistant_file('m','t','file','generated.png','image/png',PNG)
 def tearDown(self):self.s.close();self.tmp.cleanup()
 def photo(self,call='call',**kw):
  a={'action':'photo','journeyID':'journey','sceneID':'scene','attachmentID':self.a['id'],'caption':'synthetic scene'};a.update(kw)
  return self.b.tool('a','m','t',call,'travel_memory',a)
 def test_photo_scoped_real_attachment_and_idempotent(self):
  p=self.photo()['photo'];self.assertEqual(self.photo()['photo'],p)
  self.assertEqual(len(self.b.album.photos('a','journey')),1);self.assertEqual(self.b.album.photos('b','journey'),[])
  self.assertEqual(self.photo('new-call')['photo'],p)
  with self.assertRaises(APIError):self.photo(caption='changed')
 def test_user_upload_and_non_image_rejected(self):
  own=self.s.add_attachment('user.png','image/png',PNG)
  with self.assertRaises(APIError):self.photo(attachmentID=own['id'])
  fake=self.s.create_assistant_file('m','t','fake','fake.png','image/png',b'not an image')
  with self.assertRaises(APIError):self.photo(attachmentID=fake['id'])
 def test_stale_turn_and_wrong_scene_rejected(self):
  self.b._request.return_value={'scene':{'id':'other','journeyID':'journey'}}
  with self.assertRaises(APIError):self.photo()
  self.b._request.return_value={'scene':{'id':'scene','journeyID':'journey'}}
  self.s.finish('m','complete')
  with self.assertRaises(APIError):self.photo()
 def test_cover_scope_and_old_ack_cannot_revert(self):
  p=self.photo()['photo'];a=self.s.create_assistant_file('m','t','f2','other.png','image/png',PNG)
  p2=self.photo('c2',attachmentID=a['id'])['photo']
  album=self.b.album;album.cover('a','journey',p['id'],'r1');album.cover('a','journey',p2['id'],'r2');album.cover('a','journey',p['id'],'r1')
  snap=album.decorate('a',{'journey':{'id':'journey'}})
  self.assertEqual(snap['journey']['coverPhoto']['id'],p2['id']);self.assertEqual(snap['journey']['photoCount'],2)
  with self.assertRaises(APIError):album.cover('b','journey',p['id'],'x')
  with self.assertRaises(APIError):album.cover('a','journey',p2['id'],'r1')
 def test_journal_is_readonly_and_preserves_cursor(self):
  self.photo();self.b._request.return_value={'journey':{'id':'journey','conversationID':'a'},'scenes':[],'nextCursor':4,'hasMore':False,'revision':10}
  result=self.b.journal('a','journey',4)
  self.assertEqual(result['nextCursor'],4);self.assertEqual(len(result['photos']),1)
  with self.assertRaises(APIError):self.b.journal('b','journey',0)
  with self.assertRaises(APIError):self.b.journal('a','journey',-1)
 def test_photo_persists_after_store_reopen(self):
  p=self.photo()['photo'];self.s.close();self.s=Store(self.tmp.name);self.b=TravelBridge(self.s)
  self.assertEqual(self.b.album.photos('a','journey'),[p])
if __name__=='__main__':unittest.main()
