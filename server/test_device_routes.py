"""Synthetic phone HTTP -> durable request -> MCP receipt roundtrip; no Apple/model calls."""
import json
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from unittest.mock import patch
from storage import Store, APIError
from cove import Application
from runtime import CodexRuntime

TOKEN = 'synthetic-device-bridge-test-token'
DEVICE = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'

class QuietApplication(Application):
    def _work(self):
        self.stop.wait()

class DeviceRoutesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(self.tmp.name)
        self.store.create_conversation('a'); self.store.create_conversation('b')
        self.store.set_data_access({'enabled': True})
        self.store.accept({'id':'origin','conversationID':'a','text':'fixture only'})
        self.job = self.store.claim(); self.store.bind_turn('origin','turn')
        self.runtime = CodexRuntime(self.store,self.tmp.name)
        self.runtime.active = {'conversation':'a','message':'origin','thread':'thread','turn':'turn','cancel':threading.Event()}
        self.app = QuietApplication(self.store,TOKEN,self.runtime)
        self.server = ThreadingHTTPServer(('127.0.0.1',0),self.app.handler())
        self.thread = threading.Thread(target=self.server.serve_forever,daemon=True); self.thread.start()
        self.base = 'http://127.0.0.1:'+str(self.server.server_port)
        self.counter = 0

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.app.close(); self.store.close(); self.tmp.cleanup()

    def http(self,path,body=None,auth=True):
        req=Request(self.base+path,data=json.dumps(body).encode() if body is not None else None,
                    headers={'Content-Type':'application/json','Authorization':'Bearer '+(TOKEN if auth else 'invalid')})
        try:
            with urlopen(req,timeout=3) as response: return response.status,json.loads(response.read())
        except HTTPError as e: return e.code,json.loads(e.read())

    def tool(self,name,args):
        self.counter+=1
        self.runtime.file_permits.append({'conversation':'a','turn':self.runtime.active['turn'],
            'call':str(self.counter),'tool':name,'arguments':args,'used':False})
        return self.runtime.mcp_file_call('a',name,args)

    def register(self):
        body={'deviceID':DEVICE,'statuses':dict(calendar='authorized',reminders='authorized',alarms='authorized')}
        self.assertEqual(self.http('/v1/device-actions/device',body,auth=False)[0],401)
        self.assertEqual(self.http('/v1/device-actions/device',body)[0],200)

    def test_roundtrip_read_confirmation_receipt_and_continuation(self):
        self.register()
        capability=self.tool('cove_device_capabilities',{})
        self.assertTrue(capability['online'])
        request=self.tool('cove_request_device_action',{'operation':'listReminders'})['request']
        path='/v1/conversations/a/device-actions'; endpoint=path+'/'+request['id']
        self.assertEqual(request['status'],'pending'); self.assertFalse(request.get('result'))
        code, listing=self.http(path+'?deviceID='+DEVICE)
        self.assertEqual(code,200); self.assertEqual(listing['requests'][0]['id'],request['id'])
        self.assertEqual(self.http(path)[0],400)
        self.assertEqual(self.http('/v1/conversations/b/device-actions/'+request['id']+'/claim',{'deviceID':DEVICE})[0],404)
        self.assertEqual(self.http(endpoint+'/claim',{'deviceID':DEVICE})[0],200)
        self.assertEqual(self.http(endpoint+'/claim',{'deviceID':DEVICE})[0],409)
        result={'actionID':request['id'],'records':[{'id':'fixture','title':'synthetic only','completed':False}],'message':'synthetic read'}
        response={'deviceID':DEVICE,'status':'succeeded','result':result}
        code, ack=self.http(endpoint+'/response',response)
        self.assertEqual(code,200); self.assertEqual(ack['request']['status'],'succeeded')
        self.assertEqual(self.http(endpoint+'/response',response)[0],200)
        read=self.tool('cove_read_device_action',{'requestID':request['id']})
        self.assertEqual(read['request']['result'],result)
        self.store.finish('origin','complete',None)
        continuation=self.store.claim()
        self.assertEqual(continuation['user']['deviceActionID'],request['id'])
        self.store.bind_turn(continuation['message'],'receipt-turn')
        self.runtime.active.update(message=continuation['message'],turn='receipt-turn')
        inputs,_=self.runtime.prepare_inputs(continuation,threading.Event())
        self.assertIn('cove_read_device_action',inputs[0]['text'])
        self.assertNotIn('synthetic read',inputs[0]['text'])
        with self.assertRaises(APIError): self.tool('cove_request_device_action',{'operation':'listAlarms'})
        with self.assertRaises(APIError): self.tool('cove_send_voice',{'text':'should not run'})
        self.assertEqual(self.tool('cove_read_device_action',{'requestID':request['id']})['request']['status'],'succeeded')
        self.store.finish(continuation['message'],'complete',None)
        self.assertIsNone(self.store.claim())

    def test_mcp_directory_lists_three_tools(self):
        from files import FILE_TOOLS
        names={x['name'] for x in FILE_TOOLS}
        self.assertTrue({'cove_device_capabilities','cove_request_device_action','cove_read_device_action'} <= names)
        import os, subprocess,sys
        from pathlib import Path
        env=dict(os.environ,COVE_FILE_CALLBACK_URL='http://127.0.0.1:1/call',COVE_FILE_CALLBACK_TOKEN='synthetic-unused')
        process=subprocess.run([sys.executable,str(Path(__file__).with_name('files_mcp.py'))],
            input='{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n',text=True,capture_output=True,env=env,timeout=5,check=True)
        actual={x['name'] for x in json.loads(process.stdout)['result']['tools']}
        self.assertEqual(actual,names)
