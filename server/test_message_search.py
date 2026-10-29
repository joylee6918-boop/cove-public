"""Synthetic authenticated read-only search; no model or production access."""
import json
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from urllib.request import Request,urlopen
from urllib.error import HTTPError
from urllib.parse import urlencode
from cove import Application
from storage import Store,APIError,now,encode


class SearchTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.store=Store(self.temp.name)
        self.store.create_conversation('a');self.store.create_conversation('b')
    def tearDown(self):self.store.close();self.temp.cleanup()
    def add(self,id,text,conversation='a',role='user',hidden=False,createdAt=None,**extra):
        with self.store.lock,self.store.db:
            self.store._put(dict(id=id,conversationID=conversation,role=role,text=text,createdAt=createdAt or now(),status='complete',hidden=hidden,**extra))
    def test_all_conversations_literals_case_and_bounded_snippet(self):
        self.add('a','中文 Alpha %_ 100%');self.add('b','alpha 中文',conversation='b',role='assistant')
        self.add('long','x'*500+'Alpha'+'y'*500)
        result=self.store.search_messages(' ALPHA ')
        self.assertEqual([r['messageID'] for r in result['results']],['long','b','a'])
        self.assertEqual({r['conversationID'] for r in result['results']},{'a','b'})
        self.assertIn('Alpha',result['results'][0]['snippet']);self.assertLessEqual(len(result['results'][0]['snippet']),320)
        self.assertEqual(len(self.store.search_messages('%_')['results']),1)
        self.assertEqual(self.store.search_messages("' OR 1=1 --")['results'],[])
    def test_hidden_system_and_incomplete_handoff_targets_excluded(self):
        self.add('visible','needle');self.add('sys','needle',role='system');self.add('hidden','needle',role='assistant',hidden=True)
        self.store.create_conversation('target');self.add('target-message','needle',conversation='target',role='assistant',handoffID='h')
        with self.store.lock,self.store.db:self.store.db.execute('INSERT INTO handoffs VALUES(?,?,?,?)',('h','a','target',encode({'status':'restoring'})))
        self.assertEqual([r['messageID'] for r in self.store.search_messages('needle')['results']],['visible'])
        with self.store.lock,self.store.db:self.store.db.execute('UPDATE handoffs SET body=?',(encode({'status':'failed'}),))
        self.assertEqual(len(self.store.search_messages('needle')['results']),1)
        with self.store.lock,self.store.db:self.store.db.execute('UPDATE handoffs SET body=?',(encode({'status':'complete'}),))
        self.assertEqual(len(self.store.search_messages('needle')['results']),2)
    def test_keyset_paging_ignores_new_rows_and_revision_updates(self):
        for i in range(7):self.add(str(i),'needle')
        page=self.store.search_messages('needle',limit=3);self.assertEqual([r['messageID'] for r in page['results']],['6','5','4'])
        self.add('new','needle');self.store.set_reaction('a','1',True)
        second=self.store.search_messages('needle',page['nextCursor'],3)
        third=self.store.search_messages('needle',second['nextCursor'],3)
        self.assertEqual([r['messageID'] for r in second['results']+third['results']],['3','2','1','0']);self.assertIsNone(third['nextCursor'])
    def test_validation_and_read_only(self):
        self.add('m','needle');before=self.store.db.total_changes;active=self.store.conversations()['activeConversationID']
        self.store.search_messages('needle');self.assertEqual(self.store.db.total_changes,before);self.assertEqual(self.store.conversations()['activeConversationID'],active)
        for q in ('','  ','x'*201,None,'\0'):
            with self.assertRaises(APIError):self.store.search_messages(q)
        for cursor in ('','-1','0','1.1','1 OR 1=1',str(2**63),True):
            with self.assertRaises(APIError):self.store.search_messages('needle',cursor)
        for limit in ('',0,51,True,'１'):
            with self.assertRaises(APIError):self.store.search_messages('needle',limit=limit)

    def test_date_filter_timezone_boundary_and_attachment_only(self):
        self.add('before','same','a',createdAt='2026-09-20T15:59:59.999Z')
        self.add('start','same','a',createdAt='2026-09-21T00:00:00+08:00')
        self.add('attachment','',createdAt='2026-09-21T02:00:00.000Z',attachments=[{'id':'fake'}])
        self.add('end','same','a',createdAt='2026-09-22T00:00:00+08:00')
        result=self.store.search_messages('',date='2026-09-21',time_zone='Asia/Shanghai')
        self.assertEqual([r['messageID'] for r in result['results']],['attachment','start'])
        self.assertEqual(result['results'][0]['snippet'],'[附件]')
        self.assertEqual(result['date'],'2026-09-21');self.assertEqual(result['timeZone'],'Asia/Shanghai')
        self.assertEqual([r['messageID'] for r in self.store.search_messages('same',date='2026-09-21',time_zone='Asia/Shanghai')['results']],['start'])

    def test_dst_day_uses_local_midnights(self):
        self.add('pre','dst',createdAt='2026-03-08T04:59:59.999Z')
        self.add('first','dst',createdAt='2026-03-08T05:00:00.000Z')
        self.add('last','dst',createdAt='2026-03-09T03:59:59.999Z')
        self.add('next','dst',createdAt='2026-03-09T04:00:00.000Z')
        result=self.store.search_messages('dst',date='2026-03-08',time_zone='America/New_York')
        self.assertEqual([r['messageID'] for r in result['results']],['last','first'])

    def test_calendar_aggregation_range_and_visibility(self):
        self.add('aug','keep',createdAt='2026-08-01T00:00:00.000Z')
        self.add('one','keep',createdAt='2026-09-20T16:00:00.000Z')
        self.add('two','keep',role='assistant',createdAt='2026-09-21T10:00:00.000Z')
        self.add('other','discard',createdAt='2026-10-01T00:00:00.000Z')
        self.add('hidden-cal','keep',hidden=True,createdAt='2026-09-21T10:00:00.000Z')
        self.add('system-cal','keep',role='system',createdAt='2026-09-21T10:00:00.000Z')
        self.store.create_conversation('calendar-target')
        self.add('handoff-cal','keep',conversation='calendar-target',createdAt='2026-07-01T00:00:00.000Z')
        with self.store.lock,self.store.db:
            self.store.db.execute('INSERT INTO handoffs VALUES(?,?,?,?)',('calendar-handoff','a','calendar-target',encode({'status':'restoring'})))
        result=self.store.message_calendar('2026-09','Asia/Shanghai','keep')
        self.assertEqual(result['days'],[{'date':'2026-09-21','count':2}])
        self.assertEqual((result['firstMonth'],result['lastMonth']),('2026-08','2026-09'))
        self.assertEqual(self.store.message_calendar('2026-09','UTC','missing')['days'],[])
        self.assertIsNone(self.store.message_calendar('2026-09','UTC','missing')['firstMonth'])

    def test_date_and_calendar_validation(self):
        for date,zone in (('2026-2-01','UTC'),('2026-02-30','UTC'),('2026-02-01','No/Such_Zone'),('', 'UTC'),('9999-12-31','UTC')):
            with self.assertRaises(APIError):self.store.search_messages('',date=date,time_zone=zone)
        for args in (('2026-2','UTC'),('2026-13','UTC'),('2026-02','No/Such_Zone')):
            with self.assertRaises(APIError):self.store.message_calendar(*args)
        with self.assertRaises(APIError):self.store.search_messages('',date='2026-02-01')
        with self.assertRaises(APIError):self.store.search_messages('',time_zone='UTC')
    def test_http_auth_parameters_and_shape(self):
        token='test-only-cove-search-owner-token';self.add('m','synthetic needle')
        app=Application(self.store,token);server=ThreadingHTTPServer(('127.0.0.1',0),app.handler());thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        def get(query,auth=True,path='/v1/messages/search'):
            request=Request('http://127.0.0.1:'+str(server.server_port)+path+'?'+query,headers={'Authorization':'Bearer '+token} if auth else {})
            try:
                with urlopen(request,timeout=3) as response:return response.status,json.load(response)
            except HTTPError as error:return error.code,json.load(error)
        try:
            self.assertEqual(get('q=needle',False)[0],401)
            status,value=get('q=needle');self.assertEqual(status,200);self.assertEqual(value['results'][0]['messageID'],'m')
            for query in ('q=needle&q=x','q=needle&limit=51','q=needle&before=0','q=needle&unknown=1','q=','limit=2'):
                self.assertEqual(get(query)[0],400)
            status,value=get(urlencode({'q':'','date':'2026-09-22','timeZone':'Asia/Shanghai'}))
            self.assertEqual(status,200);self.assertEqual(value['date'],'2026-09-22')
            for query in ('q=&date=2026-09-22','q=&timeZone=UTC','q=&date=2026-09-22&timeZone=UTC&date=2026-09-21'):
                self.assertEqual(get(query)[0],400)
            status,value=get(urlencode({'month':'2026-09','timeZone':'Asia/Shanghai'}),path='/v1/messages/calendar')
            self.assertEqual(status,200);self.assertEqual(value['month'],'2026-09')
            self.assertEqual(get('month=2026-09&timeZone=UTC',False,path='/v1/messages/calendar')[0],401)
            for query in ('month=2026-09','timeZone=UTC','month=2026-09&timeZone=UTC&x=1','month=2026-09&month=2026-08&timeZone=UTC'):
                self.assertEqual(get(query,path='/v1/messages/calendar')[0],400)
            self.assertEqual(self.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0],0)
        finally:server.shutdown();server.server_close();app.close()

if __name__=='__main__':unittest.main()
