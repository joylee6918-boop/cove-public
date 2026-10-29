"""Synthetic continuity tests: no actual model, OB, Pulse or production calls."""
import io
import json
import os
import tempfile
import unittest
from unittest.mock import patch
from storage import APIError, Store
from runtime import CodexRuntime
from continuity import PHASES, DEFAULT_TOOLS, NativeHandoff


class ContinuityTests(unittest.TestCase):
    # Preserve the v1 contract for already persisted legacy handoffs. New defaults
    # are covered by test_memory_outbox.HandoffTests, not these compatibility cases.
    def start_legacy(self, source, identifier):
        value=self.store.start_handoff(source,identifier)
        if value.get('memoryMode')=='local-v2':
            value.pop('memoryMode')
            with self.store.lock,self.store.db:
                self.store.db.execute('UPDATE handoffs SET body=? WHERE id=?',(json.dumps(value),identifier))
        return value

    def setUp(self):
        self.receipt_env = patch.dict(os.environ, {'COVE_HANDOFF_ENABLED': '1'}); self.receipt_env.start()
        self.temp = tempfile.TemporaryDirectory(); self.store = Store(self.temp.name)
        self.store.create_conversation('old'); self.store.bind_thread('old', 'original-thread')

    def tearDown(self):
        self.store.close(); self.temp.cleanup(); self.receipt_env.stop()

    def receipt(self, job, kind):
        with self.store.lock,self.store.db:
            self.store.db.execute('INSERT OR IGNORE INTO handoff_receipts VALUES(?,?,?)',(job['message'],kind,'synthetic-native'))

    def finish_phase(self, job):
        for kind in PHASES[job['user']['handoffPhase']]: self.receipt(job, kind)
        self.store.finish(job['message'], 'complete')

    def test_context_latest_not_cumulative_persistent_and_compaction(self):
        self.assertIsNone(self.store.context_usage('old')['usedTokens'])
        for count in (201000, 85000):
            self.store.record_context_usage({'threadId': 'original-thread', 'tokenUsage': {'last': {'totalTokens': count}, 'total': {'totalTokens': 9999999}, 'modelContextWindow': 400000}})
            self.assertEqual(self.store.context_usage('old')['usedTokens'], count)
        self.store.record_context_usage({'threadId':'original-thread', 'tokenUsage': {'last': {'totalTokens': True}}})
        self.store.record_context_usage({'threadId':'other', 'tokenUsage': {'last': {'totalTokens': 1}}})
        self.store.close(); self.store = Store(self.temp.name)
        self.assertEqual(self.store.context_usage('old')['usedTokens'], 85000)
        self.assertEqual(self.store.context_usage('old')['switchAtTokens'], 190000)
        self.assertEqual(self.store.context_usage('old')['hardSwitchAtTokens'], 210000)

    def test_rollout_seed_latest_not_cumulative_path_bound_and_event_precedence(self):
        from pathlib import Path
        import sqlite3
        from continuity import seed_rollout_usage
        home = Path(self.temp.name) / 'codex'; (home / 'sessions').mkdir(parents=True)
        rollout = home / 'sessions' / 'own.jsonl'
        rollout.write_text(json.dumps({'type':'event_msg','timestamp':'2026-09-16T00:00:00Z','payload':{'type':'token_count','info':{'last_token_usage':{'total_tokens':175996},'total_token_usage':{'total_tokens':49784949},'model_context_window':258400}}})+'\n', encoding='utf-8')
        db = sqlite3.connect(home / 'state_5.sqlite'); db.execute('CREATE TABLE threads(id TEXT,rollout_path TEXT)'); db.execute('INSERT INTO threads VALUES(?,?)', ('original-thread',str(rollout))); db.commit(); db.close()
        seed_rollout_usage(self.store, 'old', str(home))
        value = self.store.context_usage('old'); self.assertEqual(value['usedTokens'],175996); self.assertEqual(value['updatedAt'],'2026-09-16T00:00:00Z')
        self.store.record_context_usage({'threadId':'original-thread','tokenUsage':{'last':{'totalTokens':42}}})
        seed_rollout_usage(self.store, 'old', str(home)); self.assertEqual(self.store.context_usage('old')['usedTokens'],42)
        with self.store.lock,self.store.db:self.store.db.execute('DELETE FROM context_usage')
        db=sqlite3.connect(home / 'state_5.sqlite'); db.execute('UPDATE threads SET rollout_path=?', (str(Path(self.temp.name) / 'outside.jsonl'),)); db.commit(); db.close()
        seed_rollout_usage(self.store, 'old', str(home)); self.assertIsNone(self.store.context_usage('old')['usedTokens'])

    def test_disabled_handoff_cannot_send(self):
        with patch.dict(os.environ,{'COVE_HANDOFF_ENABLED':'0'}):
            self.assertFalse(self.store.context_usage('old')['handoffAvailable'])
            with self.assertRaises(APIError) as e:self.start_legacy('old','blocked')
            self.assertEqual(e.exception.status,409)
            self.assertIsNone(self.store.claim())

    def test_actual_notification_capture(self):
        runtime = CodexRuntime(self.store, self.temp.name)
        event = {'method':'thread/tokenUsage/updated','params':{'threadId':'original-thread','turnId':'t','tokenUsage':{'last':{'totalTokens':1234},'total':{'totalTokens':9000}}}}
        class Process: stdout = io.StringIO(json.dumps(event)+'\n')
        runtime._read(Process()); self.assertEqual(self.store.context_usage('old')['usedTokens'],1234)
        runtime.close()

    def test_handoff_order_preserves_original_and_model_last_20_rounds(self):
        self.store.set_terminal_model('old', 'fixture-sol', 'high')
        for i in range(55):
            self.store.accept({'id':f'm{i}', 'conversationID':'old','text':f'user-{i}'})
            j=self.store.claim(); self.store.stream(j['message'],f'assistant-{i}'); self.store.finish(j['message'],'complete')
        value = self.start_legacy('old','request')
        self.assertEqual(value['status'],'saving'); self.assertEqual(self.store.conversations()['activeConversationID'],'old')
        save = self.store.claim(); self.assertEqual(save['conversation']['thread'],'original-thread')
        with self.assertRaises(APIError): self.store.accept({'id':'blocked','conversationID':'old','text':'x'})
        self.assertEqual(self.start_legacy('old','request'),value)
        self.finish_phase(save)
        value = self.store.handoff('old','request'); self.assertEqual(value['status'],'restoring')
        self.assertEqual(self.store.conversations()['activeConversationID'],'old')
        restore=self.store.claim(); self.assertIsNone(restore['conversation']['thread'])
        self.assertEqual(self.store.terminal_settings(value['targetConversationID']),{'model':'fixture-sol','effort':'high'})
        history=json.loads(restore['user']['text'].split('[Cove 引用历史；附件仅有元数据，不代表已经读取文件]\n',1)[1])
        self.assertEqual(len(history),40); self.assertEqual(history[0]['text'],'user-35'); self.assertEqual(history[-1]['text'],'assistant-54')
        self.assertEqual(sum(m['role']=='user' for m in history),20)
        self.assertEqual(sum(m['role']=='assistant' for m in history),20)
        self.finish_phase(restore)
        value=self.store.handoff('old','request'); self.assertEqual(value['status'],'complete')
        self.assertEqual(self.store.conversations()['activeConversationID'],value['targetConversationID'])
        self.assertEqual(self.store.conversation('old')['thread'],'original-thread')
        self.assertIsNone(self.store.claim())
        self.assertEqual(self.start_legacy('old','request'),value)
        self.assertFalse(any(m.get('handoffID') for m in self.store.poll('old',0,1000)['messages']))

    def test_handoff_fewer_than_20_rounds_preserves_all(self):
        for index in range(12):
            self.store.accept({'id':f'few-{index}','conversationID':'old','text':f'user-{index}'})
            job=self.store.claim();self.store.stream(job['message'],f'assistant-{index}');self.store.finish(job['message'],'complete')
        self.start_legacy('old','fewer');self.finish_phase(self.store.claim());restore=self.store.claim()
        history=json.loads(restore['user']['text'].split('[Cove 引用历史；附件仅有元数据，不代表已经读取文件]\n',1)[1])
        self.assertEqual(len(history),24)
        self.assertEqual([m['text'] for m in history if m['role']=='user'],[f'user-{i}' for i in range(12)])
        self.assertEqual([m['text'] for m in history if m['role']=='assistant'],[f'assistant-{i}' for i in range(12)])
        self.assertIn('最近 20 轮（不足 20 轮则全部）',restore['user']['text'])

    def test_no_model_self_report_or_failed_receipt_can_complete(self):
        self.start_legacy('old','bad'); job=self.store.claim()
        self.store.stream(job['message'],'OB 和 Pulse 都写好了')
        self.store.finish(job['message'],'complete')
        self.assertEqual(self.store.handoff('old','bad')['status'],'failed')
        self.assertEqual(self.store.conversations()['activeConversationID'],'old')
        self.assertEqual(len(self.store.conversations()['conversations']),1)
        self.assertIsNone(self.store.claim())

    def test_restart_uncertain_save_never_replays(self):
        self.start_legacy('old','restart'); job=self.store.claim(); self.receipt(job,'obWrite')
        self.store.close(); self.store=Store(self.temp.name)
        self.assertEqual(self.store.handoff('old','restart')['status'],'failed')
        self.assertIsNone(self.store.claim())
        self.assertEqual(self.start_legacy('old','restart')['status'],'failed')

    def test_restore_failure_old_stays_active_queued_restart_can_proceed(self):
        self.start_legacy('old','restore'); self.finish_phase(self.store.claim())
        self.store.close(); self.store=Store(self.temp.name)
        job=self.store.claim(); self.assertEqual(job['user']['handoffPhase'],'restoring')
        self.store.finish(job['message'],'failed','synthetic read failure')
        self.assertEqual(self.store.handoff('old','restore')['status'],'failed')
        self.assertEqual(self.store.conversations()['activeConversationID'],'old')
        self.assertEqual(self.store.conversation('old')['thread'],'original-thread')

    def test_native_rpc_writes_reads_exact_tools_and_durable_no_replay(self):
        import threading
        self.start_legacy('old','native'); job=self.store.claim(); calls=[]
        class Runtime:
            store=self.store
            def request(inner,method,params,timeout=30):
                calls.append((method,params))
                if method=='mcpServerStatus/list':
                    pairs=[value[0].split('/',1) for value in DEFAULT_TOOLS.values()]
                    return {'data':[{'name':'codex_apps','tools':{tool:{'name':tool} for server,tool in pairs if server=='codex_apps'}}]}
                return {'isError':False,'content':[{'type':'text','text':'{"ok":true}'}]}
        native=NativeHandoff(Runtime(),job,'original-thread',threading.Event())
        native.save(json.dumps({'summary':'synthetic continuity facts','pulseNote':'synthetic continuity label'}))
        self.store.finish(job['message'],'complete')
        self.assertEqual(self.store.handoff('old','native')['status'],'restoring')
        sent=[p for m,p in calls if m=='mcpServer/tool/call']; self.assertEqual(len(sent),2)
        self.assertEqual(sent[0]['tool'],'assistant_ombre_brain.hold');self.assertEqual(sent[1]['arguments']['delta'],0)
        native.save(json.dumps({'summary':'synthetic continuity facts','pulseNote':'synthetic continuity label'}))
        self.assertEqual(len([1 for m,p in calls if m=='mcpServer/tool/call']),2)
        restore=self.store.claim(); read=NativeHandoff(Runtime(),restore,'new-thread',threading.Event())
        self.assertIn('OB',read.read_context());self.store.stream(restore['message'],'接上了');self.store.finish(restore['message'],'complete')
        self.assertEqual(self.store.handoff('old','native')['status'],'complete')
        self.assertEqual(self.store.poll(restore['user']['conversationID'],0)['messages'][0]['text'],'接上了')

    def test_real_catalog_dotted_names_preferred_and_legacy_aliases_kept(self):
        import threading
        from continuity import receipt_tools
        defaults=receipt_tools()
        self.assertEqual(defaults['obWrite'][:2],['codex_apps/assistant_ombre_brain.hold','codex_apps/assistant_ombre_brain.grow'])
        self.assertEqual(defaults['obRead'][0],'codex_apps/assistant_ombre_brain.breath')
        self.assertEqual(defaults['pulseWrite'][0],'codex_apps/assistant_pulse.pulse_ingest_signal')
        self.assertEqual(defaults['pulseRead'][:2],['codex_apps/assistant_pulse.pulse_get_snapshot','codex_apps/assistant_pulse.pulse_render_context'])
        # Synthetic fixture of the observed production mcpServerStatus/list catalog (dotted codex_apps names).
        real={'data':[{'name':'codex_apps','tools':{name:{'name':name} for name in (
            'assistant_ombre_brain.hold','assistant_ombre_brain.grow','assistant_ombre_brain.breath',
            'assistant_pulse.pulse_ingest_signal','assistant_pulse.pulse_get_snapshot','assistant_pulse.pulse_render_context')}}]}
        self.start_legacy('old','dots'); job=self.store.claim(); calls=[]
        class Runtime:
            store=self.store
            catalog=real
            def request(inner,method,params,timeout=30):
                calls.append((method,params))
                if method=='mcpServerStatus/list':return inner.catalog
                return {'isError':False,'content':[{'type':'text','text':'{"ok":true}'}]}
        native=NativeHandoff(Runtime(),job,'original-thread',threading.Event())
        native.save(json.dumps({'summary':'synthetic real catalog','pulseNote':'synthetic dot label'}))
        self.store.finish(job['message'],'complete')
        sent=[p for m,p in calls if m=='mcpServer/tool/call']
        self.assertEqual([(p['server'],p['tool']) for p in sent],[('codex_apps','assistant_ombre_brain.hold'),('codex_apps','assistant_pulse.pulse_ingest_signal')])
        restore=self.store.claim(); read=NativeHandoff(Runtime(),restore,'new-thread',threading.Event())
        read.read_context()
        self.assertEqual([p['tool'] for m,p in calls if m=='mcpServer/tool/call'][2:],['assistant_ombre_brain.breath','assistant_pulse.pulse_get_snapshot'])
        # Legacy underscore-only catalog still satisfies the allowlist.
        class Legacy(Runtime):
            catalog={'data':[{'name':'codex_apps','tools':{name:{'name':name} for name in (
                'assistant_ombre_brain_hold','assistant_ombre_brain_grow','assistant_ombre_brain_breath',
                'assistant_pulse_pulse_ingest_signal','assistant_pulse_pulse_get_snapshot','assistant_pulse_pulse_render_context')}}]}
        legacy=NativeHandoff(Legacy(),job,'original-thread',threading.Event())
        legacy.require(('obWrite','pulseWrite','obRead','pulseRead'))
        legacy.call('obRead',{})
        self.assertEqual(calls[-1][1]['tool'],'assistant_ombre_brain_breath')

    def test_runtime_native_handoff_sequence_summary_writes_reads_then_restore(self):
        import threading
        calls=[]; fixture_store=self.store
        class Runtime(CodexRuntime):
            def ensure_started(inner): pass
            def file_config(inner, conversation): return {}
            def request(inner,method,params=None,timeout=30):
                calls.append((method,params))
                if method in ('thread/start','thread/resume'):
                    return {'thread':{'id':params.get('threadId','new-thread')}}
                if method=='mcpServerStatus/list':
                    return {'data':[{'name':'codex_apps','tools':{values[0].split('/',1)[1]:{'name':values[0].split('/',1)[1]} for values in DEFAULT_TOOLS.values()}}]}
                if method=='mcpServer/tool/call':return {'content':[{'type':'text','text':'{"ok":true}'}], 'isError':False}
                if method=='turn/start':
                    thread=params['threadId'];turn='turn-'+thread
                    if thread=='original-thread':
                        answer=json.dumps({'summary':'synthetic continuity','pulseNote':'synthetic short note'})
                        self.assertNotIn('[Cove 当前数字身体',params['input'][0]['text'])
                    else:
                        answer='接上了';self.assertIn('Cove 应用刚实际读取',params['input'][0]['text'])
                    inner.streams[thread].put({'method':'turn/completed','params':{'threadId':thread,'turn':{'id':turn,'status':'completed','items':[{'type':'agentMessage','id':'a','phase':'final_answer','text':answer}],'error':None}}})
                    return {'turn':{'id':turn}}
                raise AssertionError(method)
        runtime=Runtime(self.store,self.temp.name)
        try:
            self.start_legacy('old','runtime')
            for phase in ('saving','restoring'):
                job=self.store.claim();self.assertEqual(job['user']['handoffPhase'],phase)
                status,error=runtime.run(job,threading.Event());self.assertEqual(status,'complete');self.store.finish(job['message'],status,error)
            self.assertEqual(self.store.handoff('old','runtime')['status'],'complete')
            timeline=[m if m!='mcpServer/tool/call' else p['tool'] for m,p in calls]
            self.assertLess(timeline.index('turn/start'),timeline.index('assistant_ombre_brain.hold'))
            self.assertLess(timeline.index('assistant_pulse.pulse_get_snapshot'),len(timeline)-1)
            self.assertEqual(timeline[-1],'turn/start')
        finally:runtime.close()

    def test_restart_after_restore_dispatch_and_interrupt_do_not_activate_target(self):
        self.start_legacy('old','interrupted');self.finish_phase(self.store.claim())
        target=self.store.handoff('old','interrupted')['targetConversationID']
        self.assertNotIn(target,[c['id'] for c in self.store.conversations()['conversations']])
        job=self.store.claim();self.receipt(job,'obRead')
        self.store.close();self.store=Store(self.temp.name)
        self.assertEqual(self.store.handoff('old','interrupted')['status'],'failed')
        self.assertEqual(self.store.conversations()['activeConversationID'],'old')
        self.assertNotIn(target,[c['id'] for c in self.store.conversations()['conversations']])
        self.assertIsNone(self.store.claim())
        self.start_legacy('old','stop');job=self.store.claim();self.receipt(job,'obWrite');self.receipt(job,'pulseWrite')
        self.store.finish(job['message'],'interrupted')
        self.assertEqual(self.store.handoff('old','stop')['status'],'failed');self.assertIsNone(self.store.claim())

    def test_stop_source_also_stops_queued_hidden_restore(self):
        import threading
        from cove import Application
        self.start_legacy('old','stop-source');self.finish_phase(self.store.claim())
        app=Application.__new__(Application);app.store=self.store;app.runtime=None;app.active=None;app.active_lock=threading.Lock()
        app.interrupt('old')
        self.assertIsNone(self.store.claim());self.assertEqual(self.store.handoff('old','stop-source')['status'],'failed')
        self.assertEqual(self.store.conversations()['activeConversationID'],'old')

    def test_native_unknown_dispatch_and_semantic_errors_never_retry(self):
        import threading
        self.start_legacy('old','unknown');job=self.store.claim();calls=[]
        class Runtime:
            store=self.store
            def request(inner,method,params,timeout=30):
                calls.append(method)
                if method=='mcpServerStatus/list':return {'data':[{'name':'codex_apps','tools':{'assistant_ombre_brain_hold':{'name':'assistant_ombre_brain_hold'}}}]}
                raise RuntimeError('synthetic timeout')
        native=NativeHandoff(Runtime(),job,'original-thread',threading.Event())
        for i in range(2):
            with self.assertRaises(RuntimeError):native.call('obWrite',{'content':'synthetic'})
        self.assertEqual(calls.count('mcpServer/tool/call'),1)
        from continuity import mcp_result_ok
        self.assertFalse(mcp_result_ok({'isError':True,'content':[]}))
        self.assertFalse(mcp_result_ok({'isError':False,'content':[]}))
        self.assertFalse(mcp_result_ok({'content':[{'type':'text','text':''}]}))
        self.assertFalse(mcp_result_ok({'content':[{'type':'text','text':'{"result":"{\\"success\\": false}"}'}],'structuredContent':{'ok':False}}))
        self.store.finish(job['message'],'failed','unknown');self.assertEqual(self.store.conversations()['activeConversationID'],'old')

    def test_busy_cross_source_and_unknown_id(self):
        self.store.accept({'id':'busy','conversationID':'old','text':'busy'})
        with self.assertRaises(APIError) as e:self.start_legacy('old','busy')
        self.assertEqual(e.exception.status,409)
        self.store.finish('busy','interrupted')
        self.start_legacy('old','r'); self.store.create_conversation('other')
        with self.assertRaises(APIError) as e:self.start_legacy('other','r')
        self.assertEqual(e.exception.status,409)
        with self.assertRaises(APIError) as e:self.store.handoff('other','r')
        self.assertEqual(e.exception.status,404)
        self.assertIsNone(self.store.handoff('other'))

if __name__ == '__main__': unittest.main()
