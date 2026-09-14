"""Real HTTP/SQLite/stdin console regressions; fixture only, no model/network turns."""
import json
import os
import shlex
import sys
import tempfile
import threading
import time
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from unittest.mock import patch

from cove import Application
from runtime import CodexRuntime
from storage import Store, APIError
from terminal import redact

TOKEN = 'test-only-cove-terminal-credential-123456'


class ConsoleHTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.store = Store(self.temp.name)
        self.command = shlex.quote(sys.executable)+' '+shlex.quote(str(Path(__file__).with_name('fake_app_server.py')))
        self.runtime = CodexRuntime(self.store, self.temp.name, self.command, model='fixture-sol', timeout=4)
        self.app = Application(self.store, TOKEN, self.runtime)
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), self.app.handler())
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = 'http://127.0.0.1:'+str(self.server.server_port)
        for c in ('a','b'):
            self.req('POST', '/v1/conversations', {'id':c})

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.app.close(); self.store.close(); self.temp.cleanup()

    def req(self, method, path, body=None, auth=True):
        req = Request(self.base+path, data=json.dumps(body).encode() if body is not None else None,
                      headers={'Content-Type':'application/json', **({'Authorization':'Bearer '+TOKEN} if auth else {})}, method=method)
        try:
            with urlopen(req, timeout=3) as r:
                return r.status,json.loads(r.read())
        except HTTPError as e:
            return e.code,json.loads(e.read())

    def console(self, c='a', after=0):
        status,value=self.req('GET','/v1/terminal?conversationID='+c+'&after='+str(after)); self.assertEqual(status,200); return value

    def wait_for(self, predicate):
        deadline=time.monotonic()+4
        while time.monotonic()<deadline:
            value=self.console()
            if predicate(value): return value
            time.sleep(.01)
        self.fail('console did not settle')

    def input(self, id, text, c='a'):
        return self.req('POST','/v1/terminal/input',{'id':id,'conversationID':c,'text':text})

    def approve(self, a, decision='accept', **extra):
        return self.req('POST','/v1/terminal/approval',dict(conversationID='a',approvalID=a['id'],threadID=a['threadID'],turnID=a['turnID'],decision=decision,**extra))

    def test_queue_dedupe_paging_isolation_and_reasoning_hidden(self):
        self.assertEqual(self.req('GET','/v1/terminal?conversationID=a',auth=False)[0],401)
        self.assertEqual(self.req('GET','/v1/terminal?conversationID=absent')[0],404)
        self.assertEqual(self.req('GET','/v1/terminal?conversationID=a&after=-1')[0],400)
        first=self.input('one','ordinary instruction'); self.assertEqual(first[0],200)
        self.assertEqual(self.input('one','ordinary instruction')[1]['message']['id'],first[1]['message']['id'])
        self.assertEqual(self.input('one','changed')[0],409)
        done=self.wait_for(lambda x:not x['busy'] and x['threadID'])
        self.assertEqual(sum(e['kind']=='input' for e in done['events']),1)
        self.assertNotIn('PRIVATE REASONING',json.dumps(done)); self.assertNotIn('MUST NOT LEAK',json.dumps(done))
        self.assertEqual(self.console('b')['events'],[])
        for n in range(230): self.store.terminal_event('a','output','row '+str(n))
        page=self.console(); self.assertEqual(len(page['events']),200)
        rest=self.console(after=page['cursor']); self.assertGreater(len(rest['events']),0)
        self.assertFalse(set(e['id'] for e in page['events']) & set(e['id'] for e in rest['events']))
        self.assertEqual(self.input('bad','/unknown')[0],400)
        help=self.input('help','/help'); self.assertEqual(help[1]['kind'],'help'); self.assertEqual(self.input('help','/help'),help)
        self.assertEqual(self.input('help','ordinary')[0],409)
        self.assertEqual(self.input('one','/help')[0],409)

    def test_real_rpc_approval_and_next_turn_model_on_same_thread(self):
        catalog=self.req('GET','/v1/terminal/models')[1]; self.assertEqual(catalog['models'][0]['supportedEfforts'],['low','high'])
        self.input('approve1','COVE_TEST_APPROVAL'); current=self.wait_for(lambda x:bool(x['pendingApprovals'])); a=current['pendingApprovals'][0]
        self.assertEqual(a['kind'],'command'); self.assertEqual(a['decisions'],['accept','decline'])
        wrong=dict(conversationID='b',approvalID=a['id'],threadID=a['threadID'],turnID=a['turnID'],decision='accept')
        self.assertEqual(self.req('POST','/v1/terminal/approval',wrong)[0],409)
        wrong.update(conversationID='a',turnID='old-turn'); self.assertEqual(self.req('POST','/v1/terminal/approval',wrong)[0],409)
        self.assertEqual(self.approve(a,'acceptForSession')[0],400)
        self.assertEqual(self.req('POST','/v1/terminal/model',{'conversationID':'a','model':'fixture-other','effort':'high'})[0],400)
        self.assertEqual(self.req('POST','/v1/terminal/model',{'conversationID':'a','model':'unknown','effort':'high'})[0],400)
        self.assertEqual(self.req('POST','/v1/terminal/model',{'conversationID':'a','model':'fixture-other','effort':'medium'})[0],200)
        self.assertEqual(self.approve(a)[0],200); self.assertEqual(self.approve(a)[0],409)
        done=self.wait_for(lambda x:not x['busy']); text=json.dumps(done)
        self.assertIn('console accept fixture-sol high',text); self.assertIn('COVE_CONSOLE_PROOF',text)
        self.assertNotIn('fixture-private-secret',text); self.assertIn('[redacted]',text)
        thread=done['threadID']; self.input('approve2','COVE_TEST_APPROVAL')
        next=self.wait_for(lambda x:bool(x['pendingApprovals'])); self.assertEqual(next['threadID'],thread)
        self.assertEqual(self.approve(next['pendingApprovals'][0],'decline')[0],200)
        done=self.wait_for(lambda x:not x['busy']); self.assertIn('console decline fixture-other medium',json.dumps(done))
        # Restart only this adapter; next request resumes the original stored thread.
        self.runtime.close(); self.runtime=CodexRuntime(self.store,self.temp.name,self.command,model='fixture-sol',timeout=4); self.app.runtime=self.runtime
        self.input('approve3','COVE_TEST_APPROVAL'); current=self.wait_for(lambda x:bool(x['pendingApprovals']))
        self.assertEqual(current['threadID'],thread); self.approve(current['pendingApprovals'][0]); done=self.wait_for(lambda x:not x['busy'])
        self.assertIn('console accept fixture-other medium',json.dumps(done))
        self.assertEqual(self.input('switch','/model fixture-sol high')[0],200)
        self.assertEqual(self.console()['model'],'fixture-sol')

    def test_tail_returns_latest_page_and_incremental_cursor_keeps_new_events(self):
        for n in range(450):
            self.store.terminal_event('a','output','row '+str(n))
            if n % 3 == 0:
                self.store.terminal_event('b','output','other '+str(n))
        status, tail = self.req('GET','/v1/terminal?conversationID=a&after=0&tail=1')
        self.assertEqual(status,200); self.assertEqual(len(tail['events']),200)
        self.assertEqual(tail['events'][0]['text'],'row 250'); self.assertEqual(tail['events'][-1]['text'],'row 449')
        self.assertEqual(tail['cursor'],tail['events'][-1]['id'])
        self.assertEqual(sorted(e['id'] for e in tail['events']),[e['id'] for e in tail['events']])
        self.store.terminal_event('b','output','invisible')
        new = self.store.terminal_event('a','output','after tail')
        incremental = self.console(after=tail['cursor'])
        self.assertEqual([e['id'] for e in incremental['events']],[new]); self.assertEqual(incremental['cursor'],new)
        self.assertEqual(self.req('GET','/v1/terminal?conversationID=a&after=1&tail=1')[0],400)
        self.assertEqual(self.req('GET','/v1/terminal?conversationID=a&tail=bogus')[0],400)
        # Original full-history paging remains opt-in by omitting tail.
        self.assertEqual(self.console()['events'][0]['text'],'row 0')

    def test_stop_clears_pending_and_retry_does_not_stop_later_turn(self):
        self.input('pending','COVE_TEST_APPROVAL'); active=self.wait_for(lambda x:bool(x['pendingApprovals'])); stale=active['pendingApprovals'][0]
        self.input('queued','queued ordinary'); self.assertEqual(self.input('stop','/stop')[0],200)
        self.wait_for(lambda x:not x['busy']); self.assertEqual(self.approve(stale)[0],409)
        self.assertEqual(self.store._message(next(j['assistant'] for j in self.store.db.execute('SELECT * FROM jobs').fetchall() if j['message']=='queued'))['status'],'interrupted')
        self.input('next','COVE_TEST_APPROVAL'); active=self.wait_for(lambda x:bool(x['pendingApprovals']))
        self.assertEqual(self.input('stop','/stop')[0],200)
        self.assertEqual(self.console()['pendingApprovals'][0]['id'],active['pendingApprovals'][0]['id'])
        self.assertEqual(self.approve(active['pendingApprovals'][0])[0],200); self.wait_for(lambda x:not x['busy'])

    def test_read_receipt_actual_started_and_reaction_http_revision(self):
        accepted = self.input('receipts','COVE_TEST_APPROVAL')[1]['message']
        self.assertIsNone(accepted['readAt']); self.assertFalse(accepted['isLiked'])
        active = self.wait_for(lambda x:bool(x['pendingApprovals']))
        user = next(m for m in self.req('GET','/v1/messages?conversationID=a&after=0')[1]['messages'] if m['id']=='receipts')
        self.assertIsNotNone(user['readAt'])
        with self.store.lock:
            assistant = self.store.db.execute('SELECT assistant FROM jobs WHERE message=?',('receipts',)).fetchone()[0]
        def react(liked, conversation='a', message=assistant, auth=True):
            return self.req('POST','/v1/messages/reaction',{'conversationID':conversation,'messageID':message,'isLiked':liked},auth)
        self.assertEqual(react(True,auth=False)[0],401)
        self.assertEqual(react(True,conversation='b')[0],400)
        self.assertEqual(react(True,message='missing')[0],404)
        self.assertEqual(react(1)[0],400)
        before = self.req('GET','/v1/messages?conversationID=a&after=0')[1]['cursor']
        liked = react(True); self.assertEqual(liked[0],200); self.assertTrue(liked[1]['message']['isLiked'])
        updates = self.req('GET','/v1/messages?conversationID=a&after='+str(before))[1]
        self.assertEqual([m['id'] for m in updates['messages']],[assistant]); self.assertTrue(updates['messages'][0]['isLiked'])
        same = react(True); self.assertEqual(same,liked)
        self.assertEqual(self.req('GET','/v1/messages?conversationID=a&after='+str(updates['cursor']))[1]['messages'],[])
        self.assertEqual(react(True,message='receipts')[1]['message']['readAt'],user['readAt'])
        self.approve(active['pendingApprovals'][0]); self.wait_for(lambda x:not x['busy'])
        self.assertTrue(self.store._message(assistant)['isLiked'])  # Streaming/finalization preserves reaction.
        self.assertFalse(react(False)[1]['message']['isLiked']); self.assertEqual(react(False)[0],200)

    def test_failure_before_started_and_identical_retry_remain_unread(self):
        body = {'id':'not-started','conversationID':'a','text':'COVE_TEST_PRESTART_FAILURE'}
        accepted=self.req('POST','/v1/messages',body)[1]['message']; self.assertIsNone(accepted['readAt'])
        self.wait_for(lambda x:not x['busy'])
        retry=self.req('POST','/v1/messages',body)[1]['message']; self.assertIsNone(retry['readAt'])
        self.assertFalse(self.console()['busy']); self.assertIsNone(self.store.claim())
        self.assertEqual(len([m for m in self.store.poll('a',0)['messages'] if m['role']=='assistant']),1)

    def test_timeout_and_disconnect_invalidate_pending_no_replay(self):
        self.runtime.approval_timeout=.1
        self.input('expires','COVE_TEST_APPROVAL'); old=self.wait_for(lambda x:bool(x['pendingApprovals']))['pendingApprovals'][0]
        done=self.wait_for(lambda x:not x['busy']); self.assertEqual(done['pendingApprovals'],[]); self.assertEqual(self.approve(old)[0],409)
        self.assertIn('审批超时',json.dumps(done,ensure_ascii=False))
        self.runtime.approval_timeout=5
        self.input('disconnect','COVE_TEST_APPROVAL'); old=self.wait_for(lambda x:bool(x['pendingApprovals']))['pendingApprovals'][0]
        self.runtime.process.terminate(); done=self.wait_for(lambda x:not x['busy'])
        self.assertEqual(done['pendingApprovals'],[]); self.assertEqual(self.approve(old)[0],409)
        self.assertIn('未自动重发',json.dumps(done,ensure_ascii=False))
        self.assertIsNone(self.store.health()['readAt'])


class ConsoleStorageTests(unittest.TestCase):
    def test_persistent_settings_events_and_permission_response(self):
        with tempfile.TemporaryDirectory() as temp:
            store=Store(temp);store.create_conversation('a');store.set_terminal_model('a','fixture-sol','high');store.terminal_event('a','output','Authorization: Bearer secret-value')
            rt=CodexRuntime(store,temp);sent=[];rt._send=sent.append
            rt.active={'conversation':'a','thread':'thread','turn':'turn','cancel':threading.Event(),'message':'none'}
            message={'id':'rpc','method':'item/permissions/requestApproval','params':{'threadId':'thread','turnId':'turn','itemId':'item','permissions':{'network':{'enabled':True}},'cwd':'/synthetic'}}
            rt._server_request(message); a=rt.terminal_state('a')['pendingApprovals'][0]
            rt.resolve_approval('a',a['id'],'thread','turn','accept');self.assertEqual(sent[-1],{'id':'rpc','result':{'permissions':{'network':{'enabled':True}},'scope':'turn'}})
            rt._server_request(message); rt._terminal_notification({'method':'serverRequest/resolved','params':{'threadId':'thread','requestId':'rpc'}}); self.assertEqual(rt.terminal_state('a')['pendingApprovals'],[])
            old_cancel=threading.Event(); rt.interrupt('a',old_cancel); self.assertFalse(rt.active['cancel'].is_set())
            rt._terminal_notification({'method':'item/started','params':{'threadId':'thread','turnId':'turn','item':{'type':'fileChange','id':'file','changes':[{'path':'/synthetic/proof.txt','diff':'+new'}]}}})
            file_request={'id':'file-rpc','method':'item/fileChange/requestApproval','params':{'threadId':'thread','turnId':'turn','itemId':'file','reason':'Synthetic file change'}}
            rt._server_request(file_request); approval=rt.terminal_state('a')['pendingApprovals'][0]
            self.assertIn('proof.txt',approval['details']); rt.resolve_approval('a',approval['id'],'thread','turn','decline');self.assertEqual(sent[-1]['result'],{'decision':'decline'})
            rt.active=None;rt._server_request(message);self.assertEqual(sent[-1]['result'],{'permissions':{},'scope':'turn'})
            rt.close();store.close();store=Store(temp)
            self.assertEqual(store.terminal_settings('a'),{'model':'fixture-sol','effort':'high'});self.assertNotIn('secret-value',json.dumps(store.terminal_poll('a',0)))
            store.close()
        with patch.dict(os.environ,{'COVE_TOKEN':TOKEN}):
            self.assertNotIn(TOKEN,redact(TOKEN));self.assertNotIn('abcdef',redact('{"refresh_token":"abcdef"}'))
