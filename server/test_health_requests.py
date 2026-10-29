"""Local synthetic consent tests. No real model/HealthKit data or remote service."""
import copy
import json
import tempfile
import threading
import unittest
from datetime import datetime, timezone, timedelta
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from unittest.mock import patch
from http.server import ThreadingHTTPServer
from pathlib import Path
import subprocess
import os

from storage import Store, APIError, now, encode
from runtime import CodexRuntime
from cove import Application
from test_server import FakeRuntime, TOKEN


class HealthRequestsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(self.temp.name)
        for id in ('a','b'): self.store.create_conversation(id)
        self.store.accept({'id':'incoming','conversationID':'a','text':'fixture'})
        self.job = self.store.claim(); self.store.bind_turn('incoming','turn')
        self.runtime = CodexRuntime(self.store,self.temp.name)
        self.runtime.active = {'conversation':'a','thread':'thread','turn':'turn','message':'incoming','cancel':threading.Event()}
        self.app = Application(self.store,TOKEN,FakeRuntime(self.store),'')
        self.server = ThreadingHTTPServer(('127.0.0.1',0),self.app.handler())
        self.thread = threading.Thread(target=self.server.serve_forever,daemon=True); self.thread.start()
        self.base = 'http://127.0.0.1:'+str(self.server.server_port)
        clock = datetime.now(timezone.utc)
        self.args = {'metrics':['steps','hrv'],'startAt':(clock-timedelta(days=1)).isoformat(),'endAt':clock.isoformat(),'reason':'Synthetic test: check today'}
        self.count = 0

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.app.close(); self.runtime.close(); self.store.close(); self.temp.cleanup()

    def call(self, tool='cove_request_health', args=None, conversation='a'):
        self.count += 1; args = self.args if args is None else args
        self.runtime.file_permits.append({'conversation':conversation,'turn':'turn','call':str(self.count),'tool':tool,'arguments':args,'used':False})
        return self.runtime.mcp_file_call(conversation,tool,args)

    def http(self,path,body=None,auth=True):
        req = Request(self.base+path, data=json.dumps(body).encode() if body is not None else None,headers={'Content-Type':'application/json','Authorization':'Bearer '+(TOKEN if auth else 'wrong')})
        try:
            with urlopen(req,timeout=3) as response: return response.status,json.loads(response.read())
        except HTTPError as error: return error.code,json.loads(error.read())

    def payload(self):
        return {'decision':'allow','snapshot':{'capturedAt':now(),'metrics':[{'id':'steps','title':'步数','value':42,'unit':'步','sampledAt':self.args['endAt'],'source':'synthetic'}]}}

    def route(self,id,conversation='a'):
        return '/v1/conversations/'+conversation+'/health-requests/'+id+'/response'

    def test_allow_minimal_summary_missing_read_scope_and_idempotency(self):
        self.store.upload_health({'capturedAt':now(),'metrics':[{'id':'private','value':999}]})
        request = self.call()['request']; id=request['id']; body=self.payload()
        code,result=self.http(self.route(id),body); self.assertEqual(code,200)
        self.assertEqual(result['request']['status'],'allowed'); self.assertIsNone(result['request']['readAt'])
        self.assertEqual(self.http(self.route(id),body),(200,result))
        listing=self.http('/v1/conversations/a/health-requests')[1]; self.assertNotIn('snapshot',str(listing)); self.assertNotIn("'value': 999",str(listing))
        read=self.call('cove_read_health_request',{'requestID':id})
        self.assertEqual(read['snapshot']['metrics'][0]['value'],42); self.assertEqual(read['missingMetricIDs'],['hrv'])
        self.assertIsNone(self.store.health()['readAt'])
        self.assertEqual(self.http(self.route(id),{'decision':'deny'})[0],409)
        self.assertEqual(self.http(self.route(id,'b'),body)[0],404)
        self.assertEqual(self.http(self.route(id),body,False)[0],401)
        self.assertEqual(self.http('/v1/conversations/missing/health-requests')[0],404)
        self.assertEqual(self.http('/v1/conversations/b/health-requests')[1],{'requests':[]})
        self.runtime.active['conversation']='b'
        with self.assertRaises(APIError): self.call('cove_read_health_request',{'requestID':id},'b')

    def test_deny_expiry_empty_data_and_restart(self):
        id=self.call()['request']['id']
        self.assertEqual(self.http(self.route(id),{'decision':'deny','snapshot':{}})[0],400)
        result=self.http(self.route(id),{'decision':'deny'})
        self.assertEqual(result[0],200); self.assertEqual(self.http(self.route(id),{'decision':'deny'}),result)
        self.assertIsNone(self.call('cove_read_health_request',{'requestID':id})['snapshot'])
        self.assertEqual(self.http(self.route(id),self.payload())[0],409)
        expired=self.call()['request']; expired['expiresAt']='2000-01-01T00:00:00Z'
        with self.store.lock,self.store.db:self.store.db.execute('UPDATE health_requests SET body=? WHERE id=?',(encode(expired),expired['id']))
        self.assertEqual(self.http(self.route(expired['id']),{'decision':'deny'})[0],409)
        self.assertEqual(self.call('cove_read_health_request',{'requestID':expired['id']})['request']['status'],'expired')
        empty=self.call()['request']['id']; body=self.payload(); body['snapshot']['metrics']=[]
        self.assertEqual(self.http(self.route(empty),body)[0],200)
        read=self.call('cove_read_health_request',{'requestID':empty}); self.assertEqual(read['missingMetricIDs'],['steps','hrv']); self.assertEqual(read['snapshot']['metrics'],[])
        # Stop the background consumer before replacing its SQLite connection.
        # Closing a connection concurrently with claim() can abort native sqlite.
        self.app.close()
        self.store.finish('incoming','complete'); self.store.close(); self.store=Store(self.temp.name); self.app.store=self.store; self.runtime.store=self.store
        self.app.runtime.store = self.store
        self.assertEqual(self.http(self.route(id),{'decision':'deny'}),result)
        self.store.delete_health(); self.assertEqual(self.store.health_requests('a'),{'requests':[]})
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM health_tool_results').fetchone()[0],0)

    def test_reject_broad_ranges_metrics_metadata_values_and_bad_capabilities(self):
        invalid=[dict(self.args,metrics=['clinicalRecord']),dict(self.args,metrics=['steps','steps']),dict(self.args,metrics=[]),dict(self.args,metrics=[{}]),dict(self.args,startAt='2020-01-01T00:00:00Z'),dict(self.args,endAt='2099-01-01T00:00:00Z'),dict(self.args,reason=''),dict(self.args,conversationID='b')]
        for args in invalid:
            with self.subTest(args=args),self.assertRaises(APIError):self.call(args=args)
        id=self.call()['request']['id']
        for change in ({'id':'heartRate'},{'sampledAt':'2000-01-01T00:00:00Z'},{'unit':'miles'},{'value':True},{'value':float('nan')},{'value':-1},{'detail':'private full history'},{'history':[]},{'source':'x'*121}):
            body=self.payload(); body['snapshot']['metrics'][0].update(change)
            self.assertEqual(self.http(self.route(id),body)[0],400,change)
        config=self.runtime.file_config('a')['mcp_servers.cove_files']['env']
        req=Request(config['COVE_FILE_CALLBACK_URL'],data=json.dumps({'tool':'cove_request_health','arguments':self.args}).encode(),headers={'Authorization':'Bearer '+TOKEN})
        with self.assertRaises(HTTPError) as failure:urlopen(req,timeout=3)
        self.assertEqual(failure.exception.code,401)
        with patch('runtime.MCP_EVENT_WAIT',.01),self.assertRaises(APIError):self.runtime.mcp_file_call('a','cove_read_health_request',{'requestID':id})
        self.runtime.active['cancel'].set()
        with self.assertRaises(APIError): self.call()

    def test_expanded_sleep_activity_vitals_and_fitness_are_exactly_scoped(self):
        requested = ['sleepCore', 'sleepDeep', 'sleepREM', 'oxygenSaturation',
                     'restingHeartRate', 'bloodGlucose', 'bloodPressureSystolic',
                     'sleepingWristTemperature', 'dietaryWater', 'activeEnergy', 'steps', 'workoutDuration']
        args = dict(self.args, metrics=requested)
        request = self.call(args=args)['request']
        body = {'decision': 'allow', 'snapshot': {'capturedAt': now(), 'metrics': [
            {'id': 'sleepDeep', 'value': 1.25, 'unit': '小时', 'sampledAt': args['endAt']},
            {'id': 'oxygenSaturation', 'value': 97, 'unit': '%', 'sampledAt': args['endAt']},
            {'id': 'bloodGlucose', 'value': 5.2, 'unit': '毫摩尔/升', 'sampledAt': args['endAt']},
            {'id': 'bloodPressureSystolic', 'value': 116, 'unit': '毫米汞柱', 'sampledAt': args['endAt']},
            {'id': 'workoutDuration', 'value': 48, 'unit': '分钟', 'sampledAt': args['endAt']},
        ], 'sleepSegments': [
            {'stageID': 'sleepDeep', 'startAt': (datetime.fromisoformat(args['endAt'])-timedelta(hours=1)).isoformat(),
             'endAt': args['endAt'], 'source': 'Synthetic Watch'}
        ], 'workouts': [
            {'id': 'workout-1', 'type': '跑步',
             'startAt': (datetime.fromisoformat(args['endAt'])-timedelta(minutes=48)).isoformat(),
             'endAt': args['endAt'], 'durationSeconds': 48*60, 'energyKcal': 360,
             'distanceMeters': 7200, 'source': 'Synthetic Watch'}
        ]}}
        self.assertEqual(self.http(self.route(request['id']), body)[0], 200)
        read = self.call('cove_read_health_request', {'requestID': request['id']})
        self.assertEqual([m['id'] for m in read['snapshot']['metrics']],
                         ['bloodGlucose', 'bloodPressureSystolic', 'oxygenSaturation', 'sleepDeep', 'workoutDuration'])
        self.assertEqual(read['missingMetricIDs'],
                         ['sleepCore', 'sleepREM', 'restingHeartRate', 'sleepingWristTemperature',
                          'dietaryWater', 'activeEnergy', 'steps'])
        self.assertEqual(read['snapshot']['sleepSegments'][0]['stageID'], 'sleepDeep')
        self.assertEqual(read['snapshot']['workouts'][0]['type'], '跑步')

        second = self.call(args=dict(self.args, metrics=['steps']))['request']
        leaked = copy.deepcopy(body)
        self.assertEqual(self.http(self.route(second['id']), leaked)[0], 400)

    def test_rejects_malformed_or_excess_health_detail_records(self):
        args = dict(self.args, metrics=['sleep', 'workoutCount'])
        clock = datetime.fromisoformat(args['endAt'])
        base = {'decision': 'allow', 'snapshot': {'capturedAt': now(), 'metrics': [],
                'sleepSegments': [{'stageID': 'sleepREM', 'startAt': (clock-timedelta(minutes=20)).isoformat(),
                                   'endAt': clock.isoformat()}],
                'workouts': [{'id': 'w', 'type': '瑜伽', 'startAt': (clock-timedelta(minutes=20)).isoformat(),
                              'endAt': clock.isoformat(), 'durationSeconds': 1200}]}}
        mutations = []
        bad = copy.deepcopy(base); bad['snapshot']['sleepSegments'][0]['stageID'] = 'clinical'; mutations.append(bad)
        bad = copy.deepcopy(base); bad['snapshot']['sleepSegments'] *= 5001; mutations.append(bad)
        bad = copy.deepcopy(base); bad['snapshot']['workouts'][0]['durationSeconds'] = float('nan'); mutations.append(bad)
        bad = copy.deepcopy(base); bad['snapshot']['workouts'][0]['durationSeconds'] = 999999; mutations.append(bad)
        bad = copy.deepcopy(base); bad['snapshot']['workouts'][0]['endAt'] = (clock+timedelta(minutes=1)).isoformat(); mutations.append(bad)
        bad = copy.deepcopy(base); bad['snapshot']['workouts'][0]['route'] = []; mutations.append(bad)
        for body in mutations:
            request = self.call(args=args)['request']
            with self.subTest(body=body): self.assertEqual(self.http(self.route(request['id']), body)[0], 400)
            self.assertEqual(self.http(self.route(request['id']), {'decision': 'deny'})[0], 200)

    def test_real_stdio_mcp_callback_to_http_consent_and_read(self):
        config=self.runtime.file_config('a')['mcp_servers.cove_files']
        child=subprocess.Popen([config['command'],*config['args']],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,env=dict(os.environ,**config['env']))
        def mcp(name,args,ordinal):
            self.runtime.file_permits.append({'conversation':'a','turn':'turn','call':str(ordinal),'tool':name,'arguments':args,'used':False})
            child.stdin.write(json.dumps({'jsonrpc':'2.0','id':ordinal,'method':'tools/call','params':{'name':name,'arguments':args}})+'\n');child.stdin.flush()
            result=json.loads(child.stdout.readline())['result']; self.assertFalse(result['isError']);return json.loads(result['content'][0]['text'])
        try:
            request=mcp('cove_request_health',self.args,1)['request']
            self.assertEqual(mcp('cove_request_health',self.args,1)['request'],request)
            self.assertEqual(self.http(self.route(request['id']),self.payload())[0],200)
            read=mcp('cove_read_health_request',{'requestID':request['id']},2)
            self.assertEqual(read['snapshot']['metrics'][0]['value'],42)
            self.assertIsNotNone(self.store.health_requests('a')['requests'][0]['readAt'])
            self.assertFalse(self.app.runtime.calls) # no automatic new user/model turn
        finally:child.terminate();child.wait(timeout=3);child.stdin.close();child.stdout.close()



class HealthAppServerRoundtripTests(unittest.TestCase):
    """HTTP queue → fake app-server events → actual MCP bridge, no injected permits."""
    def test_new_and_resumed_threads_allow_automatically_reads_and_replies(self):
        import shlex
        import sys
        import time
        import test_server as support
        with tempfile.TemporaryDirectory() as temp:
            self.store = Store(temp)
            self.store.create_conversation('new'); self.store.create_conversation('old')
            self.store.bind_thread('old', 'original-health-thread')
            command = shlex.quote(sys.executable)+' '+shlex.quote(str(Path(__file__).with_name('fake_app_server.py')))
            runtime = CodexRuntime(self.store, temp, command, timeout=8)
            app = Application(self.store, TOKEN, runtime, '')
            server = ThreadingHTTPServer(('127.0.0.1', 0), app.handler())
            thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
            self.base = 'http://127.0.0.1:'+str(server.server_port)
            request = lambda *args, **kwargs: support.HTTPTests.request(self, *args, **kwargs)
            def finish(conversation, user_id):
                deadline = time.monotonic()+12
                while time.monotonic() < deadline:
                    messages = request('GET', '/v1/messages?conversationID='+conversation)[1]['messages']
                    user = next((m for m in messages if m['id']==user_id), None)
                    with self.store.lock:
                        job = self.store.db.execute('SELECT assistant FROM jobs WHERE message=?', (user_id,)).fetchone()
                    assistants = [m for m in messages if job and m['id']==job[0]]
                    if assistants and assistants[-1]['status'] in ('complete','failed','interrupted'):
                        self.assertEqual(assistants[-1]['status'], 'complete', assistants[-1])
                        if user is not None:
                            self.assertIsNotNone(user['readAt'])
                        else:
                            self.assertTrue(user_id.startswith('health-consent-'))
                        return assistants[-1]
                    time.sleep(.02)
                self.fail('fake app-server health turn did not complete')
            try:
                for conversation, mode in [('new','start'),('old','resume')]:
                    clock = datetime.now(timezone.utc)
                    args = {'metrics':['steps','hrv'], 'startAt':(clock-timedelta(hours=24)).isoformat(), 'endAt':clock.isoformat(), 'reason':'Synthetic app-server roundtrip'}
                    ask_id=conversation+'-ask'
                    self.assertEqual(request('POST','/v1/messages', {'id':ask_id,'conversationID':conversation,'text':'COVE_TEST_HEALTH_REQUEST '+json.dumps(args)})[0],200)
                    reply=finish(conversation,ask_id)
                    original_thread=self.store.conversation(conversation)['thread']
                    self.assertEqual(reply['text'],'health pending '+mode+' '+original_thread)
                    requests=request('GET','/v1/conversations/'+conversation+'/health-requests')[1]['requests']
                    self.assertEqual(len(requests),1); health=requests[0]
                    self.assertEqual(health['conversationID'],conversation); self.assertIsNone(health['readAt'])
                    with self.store.lock:
                        before=self.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0]
                    payload={'decision':'allow','snapshot':{'capturedAt':now(),'metrics':[{'id':'steps','title':'步数','unit':'步','value':42,'sampledAt':args['endAt']}]}}
                    path='/v1/conversations/'+conversation+'/health-requests/'+health['id']+'/response'
                    self.assertEqual(request('POST',path,payload)[0],200)
                    self.assertEqual(request('POST',path,payload)[0],200)
                    with self.store.lock:
                        self.assertEqual(self.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0],before+1)
                    # No second visible user message: approval itself continues.
                    read_id='health-consent-'+health['id']
                    reply=finish(conversation,read_id)
                    self.assertEqual(reply['text'],'health allowed '+mode+' '+original_thread)
                    self.assertEqual(self.store.conversation(conversation)['thread'],original_thread)
                    self.assertIsNotNone(request('GET','/v1/conversations/'+conversation+'/health-requests')[1]['requests'][0]['readAt'])
                    visible=request('GET','/v1/messages?conversationID='+conversation)[1]['messages']
                    self.assertEqual(len([m for m in visible if m['role']=='user']),1)
                    self.assertFalse(any(m['role']=='system' or m['id']==read_id for m in visible))
                    self.assertEqual(request('POST',path,payload)[0],200)
                    with self.store.lock:
                        self.assertEqual(self.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0],before+1)
                    events=self.store.terminal_poll(conversation,0)['events']
                    self.assertTrue(any('cove_request_health' in e['text'] for e in events))
                    self.assertTrue(any('cove_read_health_request' in e['text'] for e in events))
                    self.assertNotIn('Synthetic app-server roundtrip', ''.join(e['text'] for e in events if e['kind']=='tool'))
                self.assertEqual(self.store.conversation('old')['thread'],'original-health-thread')
                self.assertNotEqual(self.store.conversation('new')['thread'],'original-health-thread')
            finally:
                server.shutdown(); server.server_close(); app.close(); self.store.close()


class HealthContinuationLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(self.temp.name)
        self.store.create_conversation('a')
        self.store.accept({'id': 'origin', 'conversationID': 'a', 'text': 'I feel tired'})
        self.store.claim(); self.store.bind_turn('origin', 'origin-turn')
        clock = datetime.now(timezone.utc)
        self.args = {'metrics': ['steps'], 'startAt': (clock-timedelta(hours=24)).isoformat(), 'endAt': clock.isoformat(), 'reason': 'Synthetic contextual ask'}
        self.request = self.store.assistant_health_tool('origin', 'origin-turn', 'ask', 'cove_request_health', self.args, 'a')['request']
        self.payload = {'decision': 'allow', 'snapshot': {'capturedAt': now(), 'metrics': [{'id': 'steps', 'unit': '步', 'value': 42, 'sampledAt': self.args['endAt']}]}}
    def tearDown(self):
        self.store.close(); self.temp.cleanup()
    def allow(self):
        return self.store.respond_health_request('a', self.request['id'], self.payload)['request']
    def test_allow_waits_for_active_turn_then_claims_once_and_is_not_visible(self):
        approved = self.allow()
        self.assertEqual(approved['continuationStatus'], 'queued')
        self.assertIsNone(self.store.claim(), 'Must not overlap the origin turn')
        self.assertEqual(self.allow()['continuationMessageID'], approved['continuationMessageID'])
        page = self.store.poll('a', 0)
        self.assertFalse(any(m['role'] == 'system' for m in page['messages']))
        with self.store.lock:
            internal_revision = self.store.db.execute('SELECT revision FROM messages WHERE id=?', (approved['continuationMessageID'],)).fetchone()[0]
        self.assertGreaterEqual(page['cursor'], internal_revision, 'Invisible consent events still advance the cursor')
        self.store.finish('origin', 'complete')
        job = self.store.claim()
        self.assertEqual(job['message'], approved['continuationMessageID'])
        self.assertEqual(job['conversation']['id'], 'a')
        self.assertIsNone(self.store.claim())
        self.store.bind_turn(job['message'], 'continuation-turn')
        with self.assertRaises(APIError):
            self.store.assistant_health_tool(job['message'], 'continuation-turn', 'bad', 'cove_request_health', self.args, 'a')
        with self.assertRaises(APIError):
            self.store.assistant_health_tool(job['message'], 'continuation-turn', 'other', 'cove_read_health_request', {'requestID': 'other'}, 'a')
        self.store.stream(job['message'], 'Here is the health reply'); self.store.finish(job['message'], 'complete')
        self.assertEqual(self.allow()['continuationStatus'], 'complete')
        self.assertIsNone(self.store.claim())
        self.assertEqual(len([m for m in self.store.poll('a',0)['messages'] if m['role']=='user']), 1)
    def test_original_turn_already_read_and_replied_skips_duplicate(self):
        approved = self.allow()
        self.store.assistant_health_tool('origin', 'origin-turn', 'read', 'cove_read_health_request', {'requestID': self.request['id']}, 'a')
        self.store.mark_health_request_delivered('a', self.request['id'])
        self.store.stream('origin', 'Already responded with the approved health summary')
        self.store.finish('origin', 'complete')
        self.assertIsNone(self.store.claim())
        self.assertEqual(self.allow()['continuationStatus'], 'skipped')
        self.assertEqual(len([m for m in self.store.poll('a',0)['messages'] if m['role']=='assistant']),1)
    def test_queued_survives_restart_but_dispatched_is_never_replayed(self):
        approved = self.allow(); self.store.finish('origin', 'complete')
        self.store.close(); self.store = Store(self.temp.name)
        self.assertEqual(self.allow()['continuationStatus'], 'queued')
        job = self.store.claim(); self.assertEqual(job['message'], approved['continuationMessageID'])
        self.store.bind_turn(job['message'], 'sent-to-model')
        self.store.close(); self.store = Store(self.temp.name)
        self.assertEqual(self.allow()['continuationStatus'], 'failed')
        self.assertIsNone(self.store.claim())
        self.assertFalse(self.store.poll('a',0)['busy'])
        message = next(m for m in self.store.poll('a',0)['messages'] if m['id']==job['assistant'])
        self.assertEqual(message['status'], 'failed')
        self.assertIn('未自动重发', message['error'])
    def test_uncertain_origin_that_already_read_is_not_answered_twice(self):
        approved = self.allow()
        self.store.assistant_health_tool('origin', 'origin-turn', 'read', 'cove_read_health_request', {'requestID': self.request['id']}, 'a')
        self.store.mark_health_request_delivered('a', self.request['id'])
        self.store.close(); self.store = Store(self.temp.name)
        self.assertIsNone(self.store.claim())
        self.assertEqual(self.allow()['continuationStatus'], 'failed')
        self.assertFalse(self.store.poll('a',0)['busy'])
    def test_denial_never_enqueues_and_delete_cancels_pending_continuation(self):
        denied = self.store.respond_health_request('a',self.request['id'],{'decision':'deny'})['request']
        self.assertNotIn('continuationMessageID', denied)
        self.store.finish('origin','complete'); self.assertIsNone(self.store.claim())
        self.store.accept({'id':'second','conversationID':'a','text':'another relevant context'})
        self.store.claim(); self.store.bind_turn('second','second-turn')
        self.request = self.store.assistant_health_tool('second','second-turn','ask2','cove_request_health',self.args,'a')['request']
        self.allow(); self.store.finish('second','complete')
        self.store.delete_health()
        self.assertIsNone(self.store.claim())
        self.assertFalse(self.store.poll('a',0)['busy'])


if __name__=='__main__':unittest.main()
