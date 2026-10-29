import base64, os, sys, threading, time, unittest
from types import SimpleNamespace
sys.path.insert(0, os.path.dirname(__file__))
from shell_console import ShellConsole, MAX_OUTPUT, MAX_FINISHED_SESSIONS
from storage import APIError


class Process:
    def __init__(self, alive=True): self.alive=alive
    def poll(self): return None if self.alive else 1


class Runtime:
    def __init__(self): self.process=Process(); self.calls=[]; self.done=threading.Event()
    def request(self, method, params, timeout=0):
        self.calls.append((method,params,timeout))
        if method == 'command/exec': self.done.wait(2); return {'exitCode':0,'stdout':'','stderr':''}
        if method == 'command/exec/terminate': self.done.set()
        return {}


class RestartRuntime:
    def __init__(self): self.process=Process(); self.calls=[]; self.events={}; self.lock=threading.Lock(); self.terminateSeen=threading.Event()
    def request(self, method, params, timeout=0):
        self.calls.append((method,params,timeout)); pid=params.get('processId')
        if method == 'command/exec':
            with self.lock: event=self.events.setdefault(pid,threading.Event())
            event.wait(2); return {'exitCode':130,'stdout':'','stderr':''}
        if method == 'command/exec/terminate':
            with self.lock: event=self.events.get(pid)
            if not event: raise RuntimeError('unknown process')
            self.terminateSeen.set(); event.set(); time.sleep(.02); return {}
        if method in ('command/exec/resize','command/exec/write'):
            with self.lock:
                if pid not in self.events: raise RuntimeError('not ready')
            return {}
        return {}


class DelayedReadyRuntime:
    def __init__(self):
        self.process=Process(); self.ready=threading.Event(); self.entered=threading.Event()
        self.done=threading.Event(); self.calls=[]
    def request(self, method, params, timeout=0):
        self.calls.append((method,params,timeout))
        if method == 'command/exec':
            self.entered.set(); self.done.wait(3); return {'exitCode': 0}
        if method == 'command/exec/resize':
            if not self.ready.is_set(): raise RuntimeError('process not yet ready')
            return {}
        if method == 'command/exec/terminate':
            self.done.set(); return {}
        if method == 'command/exec/write':
            if not self.ready.is_set(): raise RuntimeError('process not yet ready')
            return {}
        return {}


class ShellConsoleTests(unittest.TestCase):
    def test_start_waits_for_exact_process_readiness_before_returning_running(self):
        runtime=DelayedReadyRuntime(); shell=ShellConsole(runtime,'/safe',idle_timeout=30)
        result=[]
        worker=threading.Thread(target=lambda: result.append(shell.start()))
        worker.start(); self.assertTrue(runtime.entered.wait(1)); time.sleep(.12)
        self.assertTrue(worker.is_alive()); self.assertEqual(result, [])
        runtime.ready.set(); worker.join(2)
        self.assertFalse(worker.is_alive()); self.assertEqual(result[0]['state'], 'running')
        methods=[method for method,_,_ in runtime.calls]
        self.assertIn('command/exec/resize', methods)
        self.assertNotIn('command/exec/write', methods)
        shell.terminate(result[0]['id']); shell.close()

    def test_start_readiness_failure_never_returns_running_or_replays_input(self):
        runtime=DelayedReadyRuntime(); shell=ShellConsole(runtime,'/safe',idle_timeout=30)
        with self.assertRaises(APIError) as raised:
            shell.start()
        self.assertEqual(raised.exception.status, 503)
        self.assertEqual(len(shell.sessions), 1)
        self.assertEqual(next(iter(shell.sessions.values()))['state'], 'failed')
        self.assertFalse(any(method == 'command/exec/write' for method,_,_ in runtime.calls))
        shell.close()

    def test_route_start_reattaches_only_its_own_running_session(self):
        from cove import Application
        runtime=RestartRuntime(); runtime.ensure_started=lambda: None
        runtime.workspace='/safe'; runtime.shell_console=None
        store=SimpleNamespace(lock=threading.RLock(), conversation=lambda name: {'id': name})
        app=object.__new__(Application)
        app.runtime=runtime; app.store=store; app.shell_lock=threading.Lock(); app.shell_owners={}
        app_shell=app.shell_request('start', {'conversationID': 'a'})
        same=app.shell_request('start', {'conversationID': 'a'})
        self.assertEqual(same['id'], app_shell['id'])
        self.assertEqual(len([method for method,_,_ in runtime.calls if method=='command/exec']),1)
        with self.assertRaises(APIError) as bad_size:
            app.shell_request('start', {'conversationID': 'a', 'rows': True})
        self.assertEqual(bad_size.exception.status,400)
        with self.assertRaises(APIError) as other:
            app.shell_request('start', {'conversationID': 'b'})
        self.assertEqual(other.exception.status,409)
        runtime.shell_console.terminate(app_shell['id']); runtime.shell_console.close()

    def test_start_exact_safe_schema_and_real_byte_controls(self):
        runtime=Runtime(); shell=ShellConsole(runtime,'/safe/work',idle_timeout=30)
        started=shell.start(24,80); time.sleep(.02)
        method,p,_=runtime.calls[0]
        self.assertEqual(method,'command/exec'); self.assertEqual(
            p['command'], ['/usr/bin/script','-qec','/bin/sh','/dev/null'])
        self.assertTrue(p['tty']); self.assertEqual(p['cwd'],'/safe/work')
        self.assertEqual(p['sandboxPolicy'],{'type':'readOnly','networkAccess':False})
        self.assertNotIn('env',p); self.assertNotIn('disableTimeout',p)
        shell.write(started['id'],base64.b64encode(b'echo ok\n').decode())
        shell.terminate(started['id'])
        shell.close()

    def test_ctrl_c_rotates_only_pty_and_next_write_targets_ready_process(self):
        runtime=RestartRuntime(); shell=ShellConsole(runtime,'/safe',idle_timeout=30)
        sid=shell.start()['id']; time.sleep(.02)
        old_pid=next(params['processId'] for method,params,_ in runtime.calls if method=='command/exec')
        result=shell.write(sid,base64.b64encode(b'\x03').decode())
        self.assertTrue(result['restarted']); self.assertEqual(shell.status(sid)['state'],'running')
        with shell.lock: new_pid=shell.sessions[sid]['processId']
        self.assertNotEqual(old_pid,new_pid)
        execs=[params for method,params,_ in runtime.calls if method=='command/exec']
        self.assertEqual(execs[-1]['command'],['/usr/bin/script','-qec','/bin/sh','/dev/null'])
        notice=b''.join(base64.b64decode(event['dataBase64']) for event in shell.status(sid)['events'])
        self.assertIn('已中止命令并重建 Shell；当前目录和环境已重置'.encode(),notice)
        shell.write(sid,base64.b64encode(b"printf 'AFTER\\n'\n").decode())
        writes=[params for method,params,_ in runtime.calls if method=='command/exec/write']
        self.assertEqual(writes[-1]['processId'],new_pid)
        self.assertFalse(any(params.get('deltaBase64')==base64.b64encode(b'\x03').decode() for params in writes))
        shell.terminate(sid); shell.close()

    def test_write_resize_and_terminate_serialize_with_interrupt_generation(self):
        runtime=RestartRuntime(); shell=ShellConsole(runtime,'/safe',idle_timeout=30); sid=shell.start()['id']; time.sleep(.02)
        errors=[]
        interrupt=threading.Thread(target=lambda: shell.write(sid,base64.b64encode(b'\x03').decode()))
        interrupt.start(); self.assertTrue(runtime.terminateSeen.wait(1))
        writer=threading.Thread(target=lambda: shell.write(sid,base64.b64encode(b'echo new\n').decode()))
        resizer=threading.Thread(target=lambda: shell.resize(sid,40,120))
        writer.start();resizer.start();interrupt.join();writer.join();resizer.join()
        with shell.lock: new_pid=shell.sessions[sid]['processId']
        writes=[p for m,p,_ in runtime.calls if m=='command/exec/write']
        self.assertEqual(writes[-1]['processId'],new_pid)
        self.assertEqual(next(p for m,p,_ in reversed(runtime.calls) if m=='command/exec/resize')['processId'],new_pid)
        shell.terminate(sid); self.assertEqual(shell.status(sid)['state'],'terminated'); shell.close()

    def test_close_during_interrupt_never_spawns_replacement(self):
        runtime=RestartRuntime(); shell=ShellConsole(runtime,'/safe',idle_timeout=30); sid=shell.start()['id']; time.sleep(.02)
        interrupt=threading.Thread(target=lambda: shell.write(sid,base64.b64encode(b'\x03').decode()))
        interrupt.start(); self.assertTrue(runtime.terminateSeen.wait(1)); shell.close(); interrupt.join()
        execs=[p for m,p,_ in runtime.calls if m=='command/exec']
        self.assertEqual(len(execs),1)

    def test_output_is_bounded_and_stale_process_ignored(self):
        runtime=Runtime(); shell=ShellConsole(runtime,'/safe'); sid=shell.start()['id']; time.sleep(.01)
        pid=runtime.calls[0][1]['processId']
        self.assertFalse(shell.output_delta({'processId':'stale','stream':'stdout','deltaBase64':'eA==','capReached':False}))
        chunk=b'x'*(MAX_OUTPUT//2+1)
        for _ in range(2): self.assertTrue(shell.output_delta({'processId':pid,'stream':'stdout','deltaBase64':base64.b64encode(chunk).decode(),'capReached':False}))
        status=shell.status(sid); self.assertEqual(len(status['events']),1)
        shell.terminate(sid)
        shell.close()

    def test_session_gate_validation_idle_and_unsupported_sandbox(self):
        runtime=Runtime(); now=[0]; shell=ShellConsole(runtime,'/safe',idle_timeout=30,clock=lambda:now[0]); sid=shell.start()['id']; time.sleep(.01)
        with self.assertRaises(APIError): shell.write('wrong','Aw==')
        with self.assertRaises(APIError): shell.write(sid,'not base64')
        with self.assertRaises(APIError): shell.resize(sid,1,1)
        self.assertEqual(ShellConsole.sandbox_policy({'COVE_SANDBOX':'workspace-write'})['type'],'readOnly')
        self.assertEqual(ShellConsole.sandbox_policy({'COVE_SANDBOX':'danger-full-access'}), {'type':'readOnly','networkAccess':False})
        with self.assertRaises(APIError): ShellConsole.sandbox_policy({'COVE_SANDBOX':'unknown'})
        now[0]=31; self.assertEqual(shell.reap_idle(),1); self.assertEqual(shell.status(sid)['state'],'terminated')
        shell.close()

    def test_one_live_strict_bool_disconnect_close_and_finished_cap(self):
        runtime=Runtime(); shell=ShellConsole(runtime,'/safe'); first=shell.start()['id']; time.sleep(.01)
        with self.assertRaises(APIError): shell.start()
        with self.assertRaises(APIError): shell.write(first,'Aw==',close_stdin=1)
        # Reader-finally path is local state only: it must not issue an RPC.
        before=len(runtime.calls); shell.disconnect(); self.assertEqual(len(runtime.calls),before)
        self.assertEqual(shell.status(first)['state'],'failed')
        with shell.lock:
            for index in range(MAX_FINISHED_SESSIONS+5):
                shell.sessions[str(index)]={'id':str(index),'processId':str(index),'created':index,'last':index,'state':'exited','exitCode':0,'next':1,'events':__import__('collections').deque(),'bytes':0}
            shell._trim_finished_locked()
            self.assertLessEqual(len([s for s in shell.sessions.values() if s['state']!='running']),MAX_FINISHED_SESSIONS)
        shell.close()
        with self.assertRaises(APIError): shell.start()

    def test_requires_existing_app_server(self):
        runtime=Runtime();runtime.process=Process(False)
        shell=ShellConsole(runtime,'/safe')
        with self.assertRaises(APIError):shell.start()
        shell.close()

    def test_broader_host_policy_is_narrowed_per_command_without_env_change(self):
        from unittest.mock import patch
        with patch.dict(os.environ, {'COVE_SANDBOX':'danger-full-access'}):
            runtime=Runtime(); shell=ShellConsole(runtime,'/safe')
            try:
                sid=shell.start()['id']; time.sleep(.02)
                self.assertEqual(runtime.calls[0][1]['sandboxPolicy'], {'type':'readOnly','networkAccess':False})
                self.assertEqual(os.environ['COVE_SANDBOX'], 'danger-full-access')
                shell.terminate(sid)
            finally:
                shell.close()

if __name__=='__main__':unittest.main()
