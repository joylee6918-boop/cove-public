"""Owner console for runtime-owned tmux panes; never creates a shell.

The chat runtime must register its actual pane and share its dispatch lock here.
The persistent command journal prevents network retries or service restarts from
replaying a possibly executed input. This is not a chat runtime or MCP permit.
"""
from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import stat
import uuid
from pathlib import Path

from storage import APIError
from tmux_session import TmuxSessionError


class TmuxConsole:
    def __init__(self, directory, *, lock, before_control, after_control=None):
        # before_control is required: the runtime fences dispatch/cancellation
        # and old MCP capabilities before allowing any terminal mutation.
        if not callable(before_control):
            raise ValueError('runtime control gate is required')
        directory = Path(directory)
        if directory != directory.resolve(strict=True):
            raise ValueError('console journal directory must not cross symlinks')
        info = directory.stat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError('console journal directory must be private and owned')
        path = directory / 'tmux-controls.sqlite3'
        fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise ValueError('unsafe console journal')
        finally:
            os.close(fd)
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.execute('PRAGMA synchronous=FULL')
        self.db.execute('''CREATE TABLE IF NOT EXISTS controls (
            request TEXT PRIMARY KEY, session TEXT NOT NULL, digest TEXT NOT NULL,
            state TEXT NOT NULL CHECK(state IN ('dispatched','complete')))''')
        self.db.execute('''CREATE TABLE IF NOT EXISTS terminations (
            session TEXT PRIMARY KEY, conversation TEXT NOT NULL, thread TEXT NOT NULL)''')
        self.db.commit()
        self.lock = lock
        self.before_control = before_control
        self.after_control = after_control
        self.bindings = {}

    @staticmethod
    def _id(value):
        try:
            if not isinstance(value, str) or str(uuid.UUID(value)) != value:
                raise ValueError()
        except (ValueError, AttributeError):
            raise APIError(400, 'tmux 标识无效')
        return value

    def register(self, session_id, transport, *, allow_unavailable=False, input_available=True):
        """Called only by the owning chat runtime, never from an HTTP request."""
        self._id(session_id)
        with self.lock:
            if session_id in self.bindings:
                raise ValueError('tmux session identity must not be reused')
            if any(b['transport'].conversation_id == transport.conversation_id and
                   b['state'] != 'terminated' for b in self.bindings.values()):
                raise ValueError('conversation already has a bound pane')
            state = 'running'
            try:
                transport.attach_existing()
            except TmuxSessionError:
                if not allow_unavailable:
                    raise
                # Recovery must still prove the original pane/session identity.
                # No permission to send to a replacement shell is granted.
                transport._verify_identity()
                state = 'unavailable'
            self.bindings[session_id] = {'transport': transport, 'state': state,
                                         'revision': 0, 'output': '', 'inputAvailable': input_available}

    def _bound(self, conversation, session_id):
        binding = self.bindings.get(session_id)
        if not binding or binding['transport'].conversation_id != conversation:
            raise APIError(404, '这个对话没有对应的 tmux 会话')
        return binding

    def termination_recorded(self, conversation, session_id, thread):
        with self.lock:
            row = self.db.execute('SELECT conversation,thread FROM terminations WHERE session=?',
                                  (session_id,)).fetchone()
            return row == (conversation, thread)

    def restore_terminated(self, session_id, transport):
        """Rehydrate only a durable kill ACK, without touching a dead/live pane.

        The caller must additionally verify the registry's original thread and
        rollout inode. This handle has no input rights and cannot kill anything.
        """
        self._id(session_id)
        with self.lock:
            if not self.termination_recorded(transport.conversation_id, session_id, transport.thread_id):
                raise APIError(409, '没有已确认的终止回执，未猜测会话已停止')
            if session_id in self.bindings or any(
                    b['transport'].conversation_id == transport.conversation_id and b['state'] != 'terminated'
                    for b in self.bindings.values()):
                raise APIError(409, '当前会话已有终端绑定')
            self.bindings[session_id] = {'transport': transport, 'state': 'terminated',
                                         'revision': 0, 'output': '', 'inputAvailable': False}

    def bound_thread(self, conversation, session_id):
        with self.lock:
            return self._bound(conversation, session_id)['transport'].thread_id

    def attach(self, conversation):
        # Attach is a read of a registered runtime session, not permission to
        # start Codex, resume an arbitrary thread, or fall back to /bin/sh.
        with self.lock:
            candidates = [(key, b) for key, b in self.bindings.items()
                          if b['transport'].conversation_id == conversation and b['state'] != 'terminated']
            if not candidates:
                # Keep the most recently ACKed terminated session visible so
                # leaving/reopening the sheet does not lose explicit recovery.
                candidates = [(key, b) for key, b in self.bindings.items()
                              if b['transport'].conversation_id == conversation and b['state'] == 'terminated'][-1:]
            if len(candidates) != 1:
                raise APIError(409, '当前对话没有可附着的 tmux 会话；不会另开 Shell')
            return self.capture(conversation, candidates[0][0])

    def capture(self, conversation, session_id):
        with self.lock:
            binding = self._bound(conversation, session_id)
            transport = binding['transport']
            if binding['state'] != 'terminated':
                previous_state = binding['state']
                try:
                    output = transport.capture(max_lines=500, max_bytes=256 * 1024)
                    if output != binding['output']:
                        binding['revision'] += 1
                        binding['output'] = output
                    binding['state'] = 'running'
                except TmuxSessionError:
                    # Preserve the session ID, so force-exit remains available
                    # when ordinary capture/input cannot verify a live process.
                    binding['state'] = 'unavailable'
                if binding['state'] != previous_state:
                    binding['revision'] += 1
            return {'sessionID': session_id, 'conversationID': conversation,
                    'threadID': transport.thread_id, 'state': binding['state'],
                    'output': binding['output'], 'revision': binding['revision'],
                    'inputAvailable': binding['inputAvailable'],
                    'allowedKeys': ['Enter', 'C-c', 'Escape', 'BS', 'Tab', 'Up', 'Down', 'Left', 'Right']
                                   if binding['inputAvailable'] else ['C-c']}

    def control(self, conversation, session_id, request_id, operation, value=None):
        self._id(request_id)
        if operation == 'input':
            if not isinstance(value, str) or not value or len(value.encode('utf-8')) > 64 * 1024:
                raise APIError(400, 'tmux 输入为空或超过 64 KiB')
            # Literal input must not smuggle Enter / control bytes. The explicit
            # key operation is separately gated by the chat runtime.
            if any(ord(c) < 32 or ord(c) == 127 for c in value):
                raise APIError(400, '请用终端按键发送回车或控制字符')
        elif operation == 'key':
            if not isinstance(value, str) or value not in ('Enter', 'C-c', 'Escape', 'BS', 'Tab', 'Up', 'Down', 'Left', 'Right'):
                raise APIError(400, 'tmux 按键无效')
        elif operation != 'terminate' or value is not None:
            raise APIError(400, 'tmux 操作无效')
        digest = hashlib.sha256(json.dumps([conversation, session_id, operation, value],
                                           ensure_ascii=False).encode()).hexdigest()
        with self.lock:
            binding = self._bound(conversation, session_id)
            old = self.db.execute('SELECT session,digest,state FROM controls WHERE request=?', (request_id,)).fetchone()
            if old:
                if old[:2] != (session_id, digest):
                    raise APIError(409, 'tmux 请求标识已用于另一操作')
                if old[2] == 'complete':
                    return {'ok': True, 'duplicate': True}
                raise APIError(409, '上次操作结果未知，未自动重发；请先查看终端')
            if binding['state'] == 'terminated':
                raise APIError(409, 'tmux 会话已结束')
            # Persist intent BEFORE any gate with possible side effects. Unknown
            # outcomes consume the request ID even if the connection times out.
            with self.db:
                self.db.execute('INSERT INTO controls VALUES (?,?,?,?)',
                                (request_id, session_id, digest, 'dispatched'))
            try:
                self.before_control(conversation, session_id, operation, value)
                transport = binding['transport']
                if operation == 'input':
                    transport.send_text(value)
                elif operation == 'key':
                    transport.send_special(value)
                else:
                    transport.terminate_bound()
                    # Record only after the exact transport ACK. A crash before
                    # this commit stays unknown; never infer success from absence.
                    with self.db:
                        self.db.execute('INSERT INTO terminations VALUES(?,?,?)',
                                        (session_id, conversation, transport.thread_id))
                    binding['state'] = 'terminated'
                    binding['revision'] += 1
                if self.after_control:
                    self.after_control(conversation, session_id, operation, value)
                with self.db:
                    self.db.execute("UPDATE controls SET state='complete' WHERE request=?", (request_id,))
            except Exception:
                raise APIError(503, '终端操作未确认，执行状态可能已改变；不会自动重发') from None
            return {'ok': True, 'duplicate': False}

    def close(self):
        # Service shutdown does not kill persistent sessions.
        with self.lock:
            for binding in self.bindings.values():
                binding['transport'].detach()
            self.db.close()
