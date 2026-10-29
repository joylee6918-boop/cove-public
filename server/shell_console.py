"""Managed PTY shells backed by the existing Codex app-server connection.

This module never spawns a host process itself.  `command/exec` owns the PTY,
applies an explicit read-only/no-network sandbox, and ties process lifetime to
the already authenticated app-server connection.
"""
from __future__ import annotations

import base64
import binascii
import os
import threading
import time
import uuid
from collections import deque

from storage import APIError

MAX_INPUT = 64 * 1024
MAX_OUTPUT = 1024 * 1024
MAX_EVENTS = 2000
MAX_FINISHED_SESSIONS = 20


class ShellConsole:
    def __init__(self, runtime, workspace, idle_timeout=600, max_lifetime=1800, clock=None):
        self.runtime = runtime
        self.workspace = str(workspace)
        self.idle_timeout = min(1800, max(30, int(idle_timeout)))
        self.max_lifetime = min(3600, max(self.idle_timeout, int(max_lifetime)))
        self.clock = clock or time.monotonic
        self.lock = threading.RLock()
        self.sessions = {}
        self._closed = threading.Event()
        self._reaper = threading.Thread(target=self._reap_loop, daemon=True)
        self._reaper.start()

    def _reap_loop(self):
        interval = min(30, max(5, self.idle_timeout // 4))
        while not self._closed.wait(interval):
            self.reap_idle()

    def close(self):
        self._closed.set()
        with self.lock:
            ids = [value['id'] for value in self.sessions.values() if value['state'] == 'running']
        for session_id in ids:
            try: self.terminate(session_id)
            except Exception: self._finish(session_id, 'failed', None)
        if threading.current_thread() is not self._reaper:
            self._reaper.join(timeout=1)

    @staticmethod
    def sandbox_policy(env=None):
        env = os.environ if env is None else env
        # command/exec accepts a per-command sandboxPolicy (Codex 0.155.0).
        # Always narrow this shell to read-only/no-network, even when ordinary
        # chat turns have a broader host policy. Never inherit dangerFullAccess.
        configured = env.get('COVE_SANDBOX', 'read-only').strip().lower()
        if configured not in ('read-only', 'readonly', 'workspace-write', 'danger-full-access'):
            raise APIError(503, 'Shell 不支持当前 Cove 沙盒配置')
        return {'type': 'readOnly', 'networkAccess': False}

    def _ensure_runtime(self):
        process = getattr(self.runtime, 'process', None)
        if process is None or process.poll() is not None:
            raise APIError(503, 'Codex app-server 尚未连接')

    def start(self, rows=30, cols=100):
        with self.lock:
            if self._closed.is_set(): raise APIError(503, 'Shell 管理器已关闭')
            if any(value['state'] == 'running' for value in self.sessions.values()):
                raise APIError(409, '已有一个正在运行的 Shell session')
        self._ensure_runtime()
        if not isinstance(rows, int) or isinstance(rows, bool) or not 4 <= rows <= 300:
            raise APIError(400, 'Shell rows 无效')
        if not isinstance(cols, int) or isinstance(cols, bool) or not 20 <= cols <= 500:
            raise APIError(400, 'Shell cols 无效')
        policy = self.sandbox_policy()
        session_id, process_id = str(uuid.uuid4()), 'cove-shell-' + uuid.uuid4().hex
        now = self.clock()
        session = {'id': session_id, 'processId': process_id, 'created': now, 'last': now,
                   'state': 'running', 'exitCode': None, 'next': 1, 'events': deque(), 'bytes': 0,
                   'generation': 1, 'rows': rows, 'cols': cols, 'ioLock': threading.RLock()}
        with self.lock:
            if self._closed.is_set(): raise APIError(503, 'Shell 管理器已关闭')
            if any(value['state'] == 'running' for value in self.sessions.values()):
                raise APIError(409, '已有一个正在运行的 Shell session')
            self.sessions[session_id] = session
            self._trim_finished_locked()
        # Codex command/exec exposes PTY-shaped streams but does not make that
        # device the shell's controlling terminal. Running `/bin/sh -i`
        # directly therefore prints a job-control warning. The system `script`
        # utility owns a nested controlling PTY, so the page gets a real prompt,
        # command echo and job control without fabricating terminal output.
        params = {'command': ['/usr/bin/script', '-qec', '/bin/sh', '/dev/null'],
                  'processId': process_id, 'tty': True,
                  'streamStdin': True, 'streamStdoutStderr': True,
                  'outputBytesCap': MAX_OUTPUT, 'timeoutMs': self.max_lifetime * 1000,
                  'cwd': self.workspace, 'size': {'rows': rows, 'cols': cols},
                  'sandboxPolicy': policy}
        threading.Thread(target=self._exec, args=(session_id, 1, params), daemon=True).start()
        # command/exec is a long-lived RPC and has no separate PTY-created
        # response. Do not expose a nominally running session until the native
        # process accepts an operation addressed to its exact process ID.
        deadline = time.monotonic() + 2
        while True:
            with self.lock:
                if session['state'] != 'running' or self._closed.is_set():
                    raise APIError(503, 'Shell 未能就绪')
            try:
                self.runtime.request('command/exec/resize', {'processId': process_id,
                                     'size': {'rows': rows, 'cols': cols}}, timeout=2)
                break
            except Exception:
                if time.monotonic() >= deadline:
                    try: self.runtime.request('command/exec/terminate', {'processId': process_id}, timeout=2)
                    except Exception: pass
                    self._finish(session_id, 'failed', None, 1)
                    raise APIError(503, 'Shell PTY 未能就绪；没有发送任何输入')
                time.sleep(.05)
        return self.status(session_id)

    def _exec(self, session_id, generation, params):
        try:
            result = self.runtime.request('command/exec', params, timeout=self.max_lifetime + 15)
            code = result.get('exitCode') if isinstance(result, dict) else None
            self._finish(session_id, 'exited', code if isinstance(code, int) else None, generation)
        except Exception:
            self._finish(session_id, 'failed', None, generation)

    def _finish(self, session_id, state, exit_code, generation=None):
        with self.lock:
            session = self.sessions.get(session_id)
            if session and session['state'] == 'running' and (generation is None or session['generation'] == generation):
                session['state'], session['exitCode'], session['last'] = state, exit_code, self.clock()
                self._trim_finished_locked()

    def _trim_finished_locked(self):
        finished = sorted((value for value in self.sessions.values() if value['state'] != 'running'), key=lambda value: value['last'])
        for value in finished[:-MAX_FINISHED_SESSIONS]: self.sessions.pop(value['id'], None)

    def disconnect(self):
        """Reader-finally hook: never RPC back into the dead reader connection."""
        with self.lock:
            sessions = list(self.sessions.values())
        for session in sessions:
            with session['ioLock'], self.lock:
                if session['state'] == 'running':
                    session['state'], session['last'] = 'failed', self.clock()
        with self.lock:
            self._trim_finished_locked()

    def output_delta(self, params):
        """Accept only command/exec/outputDelta params from runtime._read."""
        if not isinstance(params, dict): return False
        process_id, encoded = params.get('processId'), params.get('deltaBase64')
        stream = params.get('stream')
        if stream not in ('stdout', 'stderr') or not isinstance(encoded, str): return False
        try:
            raw = base64.b64decode(encoded, validate=True)
        except (ValueError, binascii.Error):
            return False
        if len(raw) > MAX_OUTPUT: return False
        with self.lock:
            session = next((value for value in self.sessions.values() if value['processId'] == process_id and value['state'] == 'running'), None)
            if not session: return False
            event = {'id': session['next'], 'stream': stream, 'dataBase64': encoded,
                     'capReached': params.get('capReached') is True}
            session['next'] += 1; session['events'].append((len(raw), event)); session['bytes'] += len(raw)
            while len(session['events']) > MAX_EVENTS or session['bytes'] > MAX_OUTPUT:
                size, _ = session['events'].popleft(); session['bytes'] -= size
            return True

    def _session(self, session_id):
        with self.lock:
            session = self.sessions.get(session_id)
            if not session: raise APIError(404, 'Shell session 不存在')
            return session

    def _running_locked(self, session, allow_closed=False):
        with self.lock:
            if (self._closed.is_set() and not allow_closed) or session['state'] != 'running': raise APIError(409, 'Shell session 已结束')
            return session['processId']

    def write(self, session_id, delta_base64=None, close_stdin=False):
        session = self._session(session_id)
        if not isinstance(close_stdin, bool): raise APIError(400, 'closeStdin 必须是布尔值')
        if delta_base64 is None and not close_stdin: raise APIError(400, 'Shell 输入为空')
        if delta_base64 is not None:
            if not isinstance(delta_base64, str): raise APIError(400, 'Shell 输入编码无效')
            try: raw = base64.b64decode(delta_base64, validate=True)
            except (ValueError, binascii.Error): raise APIError(400, 'Shell 输入 Base64 无效')
            if not raw or len(raw) > MAX_INPUT: raise APIError(413, 'Shell 单次输入最多 64 KiB')
            # Codex 0.155's command/exec PTY exits when ETX is delivered, even
            # for an interactive /bin/sh. Rotate only the managed PTY process
            # while retaining the authenticated logical Cove shell session.
            if raw == b'\x03' and not close_stdin:
                with session['ioLock']:
                    return self._interrupt_and_restart(session_id, session)
        with session['ioLock']:
            process_id = self._running_locked(session)
            params = {'processId': process_id, 'closeStdin': close_stdin}
            if delta_base64 is not None: params['deltaBase64'] = delta_base64
            self.runtime.request('command/exec/write', params, timeout=10)
            with self.lock:
                if session['state'] == 'running' and session['processId'] == process_id: session['last'] = self.clock()
        return {'ok': True}

    def _interrupt_and_restart(self, session_id, session):
        with session['ioLock']:
            with self.lock:
                if self._closed.is_set() or session['state'] != 'running': raise APIError(409, 'Shell session 已结束')
                old_process = session['processId']
                session['generation'] += 1
                generation = session['generation']
                process_id = 'cove-shell-' + uuid.uuid4().hex
                session['processId'], session['last'] = process_id, self.clock()
                rows, cols = session['rows'], session['cols']
            try:
                self.runtime.request('command/exec/terminate', {'processId': old_process}, timeout=10)
            except Exception:
                self._finish(session_id, 'failed', None, generation)
                raise APIError(503, 'Shell 中断失败，执行状态未知')
            with self.lock:
                if self._closed.is_set() or session['state'] != 'running':
                    if session['state'] == 'running':
                        session['state'], session['last'] = 'terminated', self.clock()
                    return {'ok': True, 'restarted': False}
            params = {'command': ['/usr/bin/script', '-qec', '/bin/sh', '/dev/null'],
                      'processId': process_id, 'tty': True,
                      'streamStdin': True, 'streamStdoutStderr': True,
                      'outputBytesCap': MAX_OUTPUT, 'timeoutMs': self.max_lifetime * 1000,
                      'cwd': self.workspace, 'size': {'rows': rows, 'cols': cols},
                      'sandboxPolicy': self.sandbox_policy()}
            threading.Thread(target=self._exec, args=(session_id, generation, params), daemon=True).start()
            # command/exec has no separate "PTY ready" response. A successful
            # resize is the protocol-level readiness probe before returning to
            # a client that may immediately send its next command.
            deadline = time.monotonic() + 2
            while True:
                try:
                    self.runtime.request('command/exec/resize', {'processId': process_id,
                                         'size': {'rows': rows, 'cols': cols}}, timeout=2)
                    break
                except Exception:
                    if time.monotonic() >= deadline:
                        try: self.runtime.request('command/exec/terminate', {'processId': process_id}, timeout=2)
                        except Exception: pass
                        self._finish(session_id, 'failed', None, generation)
                        raise APIError(503, 'Shell 已中断，但新 PTY 未能就绪')
                    time.sleep(.05)
            notice = '\r\n[Shell] 已中止命令并重建 Shell；当前目录和环境已重置。\r\n'.encode()
            encoded = base64.b64encode(notice).decode()
            with self.lock:
                if session['state'] == 'running' and session['generation'] == generation:
                    event = {'id': session['next'], 'stream': 'stdout', 'dataBase64': encoded, 'capReached': False}
                    session['next'] += 1; session['events'].append((len(notice), event)); session['bytes'] += len(notice)
                    while len(session['events']) > MAX_EVENTS or session['bytes'] > MAX_OUTPUT:
                        size, _ = session['events'].popleft(); session['bytes'] -= size
        return {'ok': True, 'restarted': True}

    def resize(self, session_id, rows, cols):
        session = self._session(session_id)
        if not isinstance(rows, int) or isinstance(rows, bool) or not 4 <= rows <= 300 or not isinstance(cols, int) or isinstance(cols, bool) or not 20 <= cols <= 500:
            raise APIError(400, 'Shell 尺寸无效')
        with session['ioLock']:
            process_id = self._running_locked(session)
            self.runtime.request('command/exec/resize', {'processId': process_id, 'size': {'rows': rows, 'cols': cols}}, timeout=10)
            with self.lock:
                if session['state'] == 'running' and session['processId'] == process_id:
                    session['last'], session['rows'], session['cols'] = self.clock(), rows, cols
        return {'ok': True}

    def terminate(self, session_id):
        session = self._session(session_id)
        with session['ioLock']:
            process_id = self._running_locked(session, allow_closed=True)
            generation = session['generation']
            self.runtime.request('command/exec/terminate', {'processId': process_id}, timeout=10)
            with self.lock:
                if session['generation'] == generation and session['processId'] == process_id:
                    session['state'], session['exitCode'], session['last'] = 'terminated', None, self.clock()
                    self._trim_finished_locked()
        return {'ok': True}

    def status(self, session_id, after=0):
        if not isinstance(after, int) or isinstance(after, bool) or after < 0: raise APIError(400, 'Shell cursor 无效')
        with self.lock:
            session = self.sessions.get(session_id)
            if not session: raise APIError(404, 'Shell session 不存在')
            events = [event for _, event in session['events'] if event['id'] > after]
            if session['state'] == 'running': session['last'] = self.clock()
            return {'id': session['id'], 'state': session['state'], 'exitCode': session['exitCode'],
                    'events': events, 'cursor': events[-1]['id'] if events else after,
                    'ansi': 'basic-uninterpreted'}

    def reap_idle(self):
        now = self.clock()
        with self.lock:
            ids = [s['id'] for s in self.sessions.values() if s['state'] == 'running' and now - s['last'] >= self.idle_timeout]
        for session_id in ids:
            try: self.terminate(session_id)
            except Exception: self._finish(session_id, 'failed', None)
        return len(ids)
