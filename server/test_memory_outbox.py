"""Synthetic isolated tests. No real user data, remote MCP, OB writes or model calls."""
import json
import os
import tempfile
import threading
import unittest
from unittest.mock import patch

from storage import Store, APIError
from runtime import CodexRuntime
from continuity import LocalHandoff
from memory_outbox import MemoryWriter, validate


def ok(text): return {'content':[{'type':'text','text':text}],'isError':False}


class FakeOB:
    def __init__(self,store):
        self.store=store; self.calls=[]; self.bodies={}; self.fail=None
        self.write_count=0; self.available=True; self.hide=False; self.read_failure=False
    def request(self,method,params=None,timeout=30):
        self.calls.append((method,params))
        if method=='mcpServerStatus/list':
            if not self.available: raise RuntimeError('offline')
            return {'data':[{'name':'codex_apps','tools':{n:{'name':n} for n in ['assistant_ombre_brain.hold','assistant_ombre_brain.trace','assistant_ombre_brain.breath_search']}}]}
        if method!='mcpServer/tool/call': raise AssertionError(method)
        name=params['tool'].split('.')[-1];args=params['arguments']
        if name=='breath_search':
            if self.read_failure:return {'content':[{'type':'text','text':'failure'}],'isError':True}
            return ok('\n---\n'.join('[bucket_id:'+k+']\n'+v for k,v in self.bodies.items() if args['query'] in v) or '没有匹配') if not self.hide else ok('没有匹配')
        self.write_count+=1
        if self.fail=='before':raise RuntimeError('timeout')
        if name=='hold':self.bodies['fixture-bucket']=args['content']
        else:
            old=self.bodies.get(args['bucket_id'],'')
            if old.count(args['old_str'])!=1:return ok('修改失败')
            self.bodies[args['bucket_id']]=old.replace(args['old_str'],args['new_str'])
        if self.fail=='after':raise RuntimeError('response lost')
        return ok('已写入')


class MemoryTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.store=Store(self.temp.name)
        self.store.create_conversation('old');self.store.bind_thread('old','old-thread')
        self.store.accept({'id':'m1','conversationID':'old','text':'我喜欢冰蓝色。新的记忆只是补充，OB还是要写。'})
        self.job=self.store.claim();self.store.bind_turn('m1','turn1','old-thread')
        self.args={'title':'测试偏好','content':'合成测试：偏好冰蓝色。','reason':'合成测试已确认偏好','sourceQuote':'我喜欢冰蓝色'}
        self.fake=FakeOB(self.store);self.writer=MemoryWriter(self.fake);self.cancel=threading.Event()
    def tearDown(self):self.store.close();self.temp.cleanup()
    def queue(self,args=None,call='call1'):
        return self.store.remember('m1','turn1',call,args or self.args,'old')
    def test_persist_before_remote_and_exact_dedupe(self):
        identifier=self.queue();self.assertEqual(self.store.memory_item(identifier)['state'],'queued')
        self.assertEqual(self.fake.calls,[])
        self.assertEqual(identifier,self.queue(call='other'))
        self.assertEqual(identifier,self.queue(dict(self.args,title='同一正文新标题'),call='third'))
        self.writer.process(identifier,'old-thread',self.cancel)
        self.assertEqual(self.store.memory_item(identifier)['state'],'confirmed');self.assertEqual(self.fake.write_count,1)
        self.writer.process(identifier,'old-thread',self.cancel);self.assertEqual(self.fake.write_count,1)
    def test_quote_missing_rejected(self):
        with self.assertRaises(APIError):self.queue(dict(self.args,sourceQuote='不存在的原话'))
    def test_wrong_turn_and_conversation_rejected(self):
        for turn,conv in [('other','old'),('turn1','other')]:
            with self.assertRaises(APIError):self.store.remember('m1',turn,'a',self.args,conv)
    def test_same_call_changed_payload_conflicts(self):
        self.queue()
        with self.assertRaises(APIError):self.queue(dict(self.args,content='changed'))
    def test_finished_turn_cannot_queue(self):
        self.store.finish('m1','complete')
        with self.assertRaises(APIError):self.queue()
    def test_validation_bounds(self):
        for args in [dict(self.args,content=''),dict(self.args,content='x'*6001),dict(self.args,extra=1),dict(self.args,bucketID='x'),dict(self.args,bucketID='../x',oldText='x')]:
            with self.assertRaises(APIError):validate(args)
    def test_restart_preserves_queued(self):
        identifier=self.queue();self.store.finish('m1','complete');self.store.close();self.store=Store(self.temp.name)
        self.assertEqual(self.store.memory_item(identifier)['state'],'queued')
    def test_offline_remains_queued(self):
        identifier=self.queue();self.fake.available=False;self.writer.process(identifier,'old-thread',self.cancel)
        row=self.store.memory_item(identifier);self.assertEqual(row['state'],'queued');self.assertGreater(row['next_attempt'],0)
        self.assertEqual(self.fake.write_count,0)
    def test_failed_preread_does_not_dispatch(self):
        identifier=self.queue();self.fake.read_failure=True;self.writer.process(identifier,'old-thread',self.cancel)
        self.assertEqual(self.store.memory_item(identifier)['state'],'queued');self.assertEqual(self.fake.write_count,0)
    def test_success_without_readback_is_not_confirmed(self):
        identifier=self.queue();self.fake.hide=True;self.writer.process(identifier,'old-thread',self.cancel)
        self.assertEqual(self.store.memory_item(identifier)['state'],'unknown')
        self.writer.process(identifier,'old-thread',self.cancel);self.assertEqual(self.fake.write_count,1)
    def test_uncertain_write_reconciles_without_replay(self):
        identifier=self.queue();self.fake.fail='after';self.writer.process(identifier,'old-thread',self.cancel)
        self.assertEqual(self.store.memory_item(identifier)['state'],'unknown')
        self.fake.fail=None;self.writer.process(identifier,'old-thread',self.cancel)
        self.assertEqual(self.store.memory_item(identifier)['state'],'confirmed');self.assertEqual(self.fake.write_count,1)
    def test_timeout_before_write_is_still_not_replayed(self):
        identifier=self.queue();self.fake.fail='before';self.writer.process(identifier,'old-thread',self.cancel)
        self.fake.fail=None;self.writer.process(identifier,'old-thread',self.cancel)
        self.assertEqual(self.store.memory_item(identifier)['state'],'unknown');self.assertEqual(self.fake.write_count,1)
    def test_dispatched_survives_restart(self):
        identifier=self.queue()
        with self.store.db:self.store.db.execute("UPDATE memory_outbox SET state='dispatched' WHERE id=?",(identifier,))
        self.store.finish('m1','complete');self.store.close();self.store=Store(self.temp.name)
        self.fake.store=self.store;self.writer=MemoryWriter(self.fake);self.writer.process(identifier,'old-thread',self.cancel)
        self.assertEqual(self.store.memory_item(identifier)['state'],'unknown');self.assertEqual(self.fake.write_count,0)
    def test_update_exact_target_not_new_bucket(self):
        self.fake.bodies['existing']='保留前段\n旧偏好\n保留后段'
        identifier=self.queue(dict(self.args,bucketID='existing',oldText='旧偏好'))
        self.writer.process(identifier,'old-thread',self.cancel)
        self.assertEqual(self.store.memory_item(identifier)['bucket'],'existing')
        self.assertIn('保留前段',self.fake.bodies['existing']);self.assertIn('保留后段',self.fake.bodies['existing'])
        self.assertEqual(list(self.fake.bodies),['existing'])
    def test_update_conflict_not_success(self):
        self.fake.bodies['existing']='其他正文'
        identifier=self.queue(dict(self.args,bucketID='existing',oldText='旧偏好'));self.writer.process(identifier,'old-thread',self.cancel)
        self.assertEqual(self.store.memory_item(identifier)['state'],'unknown');self.assertEqual(self.fake.bodies['existing'],'其他正文')
    def test_wrong_bucket_readback_not_confirmation(self):
        identifier=self.queue(dict(self.args,bucketID='existing',oldText='旧偏好'))
        self.fake.bodies['wrong']=self.args['content']+'\n\n[Cove memory: '+identifier+']'
        self.writer.process(identifier,'old-thread',self.cancel)
        self.assertEqual(self.store.memory_item(identifier)['state'],'unknown')
    def test_cancel_pending_prevents_dispatch(self):
        identifier=self.queue();self.store.cancel_pending_memory(identifier);self.writer.resume_one('old-thread',self.cancel)
        self.writer.process(identifier,'old-thread',self.cancel)
        self.assertEqual(self.fake.calls,[]);self.assertEqual(self.store.memory_item(identifier)['state'],'cancelled')
    def test_cannot_claim_cancel_after_dispatch(self):
        identifier=self.queue();self.writer.process(identifier,'old-thread',self.cancel)
        with self.assertRaises(APIError):self.store.cancel_pending_memory(identifier)
    def test_cancelled_turn_does_not_write(self):
        identifier=self.queue();self.cancel.set();self.writer.process(identifier,'old-thread',self.cancel)
        self.assertEqual(self.fake.calls,[])
    def test_bounded_resume_one(self):
        for n in range(3):self.queue(dict(self.args,content='synthetic '+str(n)),call=str(n))
        self.writer.resume_one('old-thread',self.cancel);self.assertEqual(self.fake.write_count,1)
    def test_native_callback_requires_actual_permit(self):
        runtime=CodexRuntime(self.store,self.temp.name)
        try:
            runtime.memory_writer=self.writer
            runtime.active={'conversation':'old','message':'m1','thread':'old-thread','turn':'turn1','cancel':self.cancel}
            with patch('runtime.MCP_EVENT_WAIT',0.01):
                with self.assertRaises(APIError):runtime.mcp_file_call('old','cove_remember',self.args)
            runtime.file_permits=[{'conversation':'old','turn':'turn1','tool':'cove_remember','arguments':self.args,'call':'actual-event','used':False}]
            result=runtime.mcp_file_call('old','cove_remember',self.args)
            self.assertEqual(result['items'][0]['state'],'confirmed')
            with self.assertRaises(APIError):runtime.mcp_file_call('wrong','cove_remember',self.args)
        finally:runtime.close()


class HandoffTests(unittest.TestCase):
    setUp=MemoryTests.setUp
    tearDown=MemoryTests.tearDown
    def prepare(self,identifier='handoff'):
        self.store.stream('m1','合成测试回复');self.store.finish('m1','complete')
        value=self.store.start_handoff('old',identifier);job=self.store.claim()
        local=LocalHandoff(self.fake,job,'old-thread',self.cancel)
        return value,job,local
    def capsule(self,memories=None):
        return json.dumps({'summary':'合成测试交接','unfinished':['继续这次改造'],'memories':memories or []},ensure_ascii=False)
    def test_local_save_restore_without_ob_or_pulse(self):
        value,job,local=self.prepare();self.fake.available=False
        local.save(self.capsule([self.args]));self.store.finish(job['message'],'complete')
        self.assertEqual(self.store.handoff('old','handoff')['status'],'restoring')
        restore=self.store.claim();read=LocalHandoff(self.fake,restore,'new-thread',self.cancel)
        with patch('memory_context.opening_context',return_value='reviewed-event'):
            context=read.read_context()
        self.assertIn('合成测试交接',context);self.assertIn('reviewed-event',context);self.assertIn('queued',context)
        self.store.stream(restore['message'],'接着聊');self.store.finish(restore['message'],'complete')
        self.assertEqual(self.store.handoff('old','handoff')['status'],'complete')
        self.assertEqual(self.store.conversations()['activeConversationID'],value['targetConversationID'])
        self.assertEqual(self.store.conversation('old')['thread'],'old-thread');self.assertEqual(self.fake.calls,[])
    def test_handoff_no_memory_is_valid(self):
        value,job,local=self.prepare();local.save(self.capsule());self.store.finish(job['message'],'complete')
        self.assertEqual(self.store.handoff('old','handoff')['status'],'restoring')
        self.assertEqual(self.store.memory_status()['items'],[])
    def test_handoff_failed_save_never_switches(self):
        value,job,local=self.prepare()
        with self.assertRaises(RuntimeError):local.save('{}')
        self.store.finish(job['message'],'failed','invalid')
        self.assertEqual(self.store.conversations()['activeConversationID'],'old')
    def test_handoff_invalid_evidence_atomic_rollback(self):
        value,job,local=self.prepare()
        with self.assertRaises(APIError):local.save(self.capsule([self.args,dict(self.args,sourceQuote='不存在')]))
        self.assertEqual(self.store.memory_status()['items'],[])
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM handoff_capsules').fetchone()[0],0)
    def test_handoff_cannot_complete_by_self_report(self):
        value,job,local=self.prepare();self.store.stream(job['message'],'已经保存');self.store.finish(job['message'],'complete')
        self.assertEqual(self.store.handoff('old','handoff')['status'],'failed')
    def test_handoff_restart_no_replay(self):
        value,job,local=self.prepare();local.save(self.capsule());self.store.close();self.store=Store(self.temp.name)
        self.assertEqual(self.store.handoff('old','handoff')['status'],'failed');self.assertIsNone(self.store.claim())
    def test_handoff_restore_failure_preserves_old(self):
        value,job,local=self.prepare();local.save(self.capsule());self.store.finish(job['message'],'complete')
        restore=self.store.claim();self.store.finish(restore['message'],'failed','test error')
        self.assertEqual(self.store.conversations()['activeConversationID'],'old')
    def test_handoff_idempotent_and_model_preserved(self):
        self.store.set_terminal_model('old','test-model','high')
        value,job,local=self.prepare();local.save(self.capsule());local.save(self.capsule())
        self.store.finish(job['message'],'complete')
        self.assertEqual(self.store.terminal_settings(value['targetConversationID']),{'model':'test-model','effort':'high'})
        self.assertEqual(self.store.start_handoff('old','handoff')['targetConversationID'],value['targetConversationID'])
    def test_missing_ob_tools_does_not_disable_local_handoff(self):
        with patch.dict(os.environ,{'COVE_HANDOFF_OB_WRITE_TOOLS':''}):
            self.assertTrue(self.store.context_usage('old')['handoffAvailable'])
            value,job,local=self.prepare()
            local.save(self.capsule())
            self.store.finish(job['message'],'complete')
            self.assertEqual(self.store.handoff('old','handoff')['status'],'restoring')

    def test_handoff_disabled(self):
        with patch.dict(os.environ,{'COVE_HANDOFF_ENABLED':'0'}):
            self.assertFalse(self.store.context_usage('old')['handoffAvailable'])
            with self.assertRaises(APIError):self.store.start_handoff('old','disabled')
    def test_runtime_local_handoff_selects_new_path(self):
        self.store.finish('m1','complete');calls=[];owner=self
        class Runtime(CodexRuntime):
            def ensure_started(inner):pass
            def file_config(inner,conversation):return {}
            def request(inner,method,params=None,timeout=30):
                calls.append((method,params))
                if method in ('thread/start','thread/resume'):return {'thread':{'id':params.get('threadId','new-thread')}}
                if method=='turn/start':
                    thread=params['threadId'];turn='t-'+thread
                    answer=owner.capsule() if thread=='old-thread' else '接着聊'
                    if thread=='new-thread':owner.assertIn('Cove 已保存的本地交接',params['input'][0]['text'])
                    inner.streams[thread].put({'method':'turn/completed','params':{'threadId':thread,'turn':{'id':turn,'status':'completed','items':[{'type':'agentMessage','id':'a','phase':'final_answer','text':answer}],'error':None}}})
                    return {'turn':{'id':turn}}
                raise AssertionError('OB/Pulse RPC forbidden in local handoff: '+method)
        runtime=Runtime(self.store,self.temp.name)
        try:
            self.store.start_handoff('old','runtime')
            for phase in ('saving','restoring'):
                job=self.store.claim();status,error=runtime.run(job,self.cancel)
                self.assertEqual(status,'complete');self.store.finish(job['message'],status,error)
            self.assertEqual(self.store.handoff('old','runtime')['status'],'complete')
        finally:runtime.close()

if __name__=='__main__':unittest.main()
