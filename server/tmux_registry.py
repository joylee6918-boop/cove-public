"""Durable, private bindings for already-known Cove Codex tmux sessions.

This registry never discovers a thread from terminal text, starts a model,
replays a task, or silently replaces a failed session. Launching a new native
Codex thread is a separate, explicitly verified integration step.
"""
from __future__ import annotations

import os
import json
import sqlite3
import stat
import threading
import uuid
from contextlib import contextmanager
from functools import wraps
from pathlib import Path

from tmux_session import TmuxSession, TmuxSessionError


class TmuxRegistryError(RuntimeError):
    pass


def synchronized(method):
    @wraps(method)
    def wrapper(self, *args, **kwargs):
        with self.lock:
            return method(self, *args, **kwargs)
    return wrapper


class TmuxRegistry:
    def __init__(self, *, db_path, codex_binary, codex_home, launch_config=None,
                 transport_factory=TmuxSession, runner=None, tmux_binary='tmux'):
        path = Path(db_path)
        if not path.is_absolute() or path != path.resolve(strict=False):
            raise ValueError('registry path must be explicit, absolute, and symlink-free')
        parent = path.parent
        try:
            for ancestor in (parent, *parent.parents):
                if ancestor.is_symlink():
                    raise TmuxRegistryError('registry path crosses a symlink')
            info = parent.lstat()
        except OSError as error:
            raise TmuxRegistryError('private registry parent is unavailable') from error
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise TmuxRegistryError('registry parent must be private and owned (0700)')
        if path.is_symlink():
            raise TmuxRegistryError('registry path is a symlink')
        if path.exists():
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise TmuxRegistryError('registry file must be private and owned (0600)')
        binary = Path(codex_binary)
        home = Path(codex_home)
        if not binary.is_absolute() or not binary.is_file() or not home.is_absolute() or not home.is_dir():
            raise ValueError('native Codex binary and CODEX_HOME must be explicit existing paths')
        if home != home.resolve(strict=True):
            raise ValueError('CODEX_HOME must be a canonical path without symlinks')
        self.codex_binary, self.codex_home = str(binary), str(home)
        self.launch_config = launch_config  # reserved for explicit future native resume
        self.transport_factory, self.runner, self.tmux_binary = transport_factory, runner, tmux_binary
        self.db_path = path
        self.lock = threading.RLock()
        self.db = sqlite3.connect(str(path), isolation_level=None, check_same_thread=False)
        os.chmod(path, 0o600)
        self.db.row_factory = sqlite3.Row
        self.db.execute('PRAGMA journal_mode=DELETE')
        self.db.execute('PRAGMA synchronous=FULL')
        self.db.execute('''CREATE TABLE IF NOT EXISTS bindings (
            conversation_id TEXT PRIMARY KEY, thread_id TEXT, session_id TEXT,
            socket_path TEXT, workspace TEXT, owner_token TEXT, pane_id TEXT,
            expected_command TEXT, rollout_path TEXT, rollout_dev INTEGER, rollout_ino INTEGER,
            state TEXT NOT NULL,
            dispatch_message TEXT,
            quarantine_reason TEXT NOT NULL DEFAULT ''
        )''')
        self.db.execute('''CREATE TABLE IF NOT EXISTS dispatches (
            message_id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL,
            state TEXT NOT NULL CHECK(state IN ('intent','complete'))
        )''')
        self.db.execute('''CREATE TABLE IF NOT EXISTS console_pending (
            conversation_id TEXT PRIMARY KEY, intent_id TEXT NOT NULL)''')
        self._attached = {}

    @contextmanager
    def _transaction(self):
        # isolation_level=None means `with self.db:` alone is NOT a transaction.
        # All callers hold self.lock, and this ledger must commit atomically with
        # the binding state or leave neither mutation behind.
        self.db.execute('BEGIN IMMEDIATE')
        try:
            yield
            self.db.execute('COMMIT')
        except BaseException:
            self.db.execute('ROLLBACK')
            raise

    @staticmethod
    def _identity(conversation):
        if not isinstance(conversation, dict):
            raise ValueError('conversation must be a dict')
        conversation_id, thread = conversation.get('id'), conversation.get('thread')
        if not isinstance(conversation_id, str) or not conversation_id or not isinstance(thread, str) or not thread:
            raise ValueError('an existing conversation and verified thread are required')
        return conversation_id, thread

    def _transport(self, row):
        kwargs = dict(socket_path=row['socket_path'], session_name=row['session_id'],
                      conversation_id=row['conversation_id'], thread_id=row['thread_id'],
                      workspace=row['workspace'], owner_token=row['owner_token'],
                      child_env={'CODEX_HOME': self.codex_home}, tmux_binary=self.tmux_binary)
        if self.runner is not None:
            kwargs['runner'] = self.runner
        return self.transport_factory(**kwargs)

    def _rollout_identity(self, rollout_path, thread):
        path = Path(rollout_path)
        try:
            resolved = path.resolve(strict=True)
            if not path.is_absolute() or path != resolved or not path.is_file():
                raise ValueError
            allowed = [Path(self.codex_home) / 'sessions', Path(self.codex_home) / 'archived_sessions']
            if not any(path == base or base in path.parents for base in allowed):
                raise ValueError
            with path.open('rb') as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode):
                    raise ValueError
                line = stream.readline(1024 * 1024 + 1)
            if not line or len(line) > 1024 * 1024 or not line.endswith(b'\n'):
                raise ValueError
            metadata = json.loads(line)
            if metadata.get('type') != 'session_meta' or not isinstance(metadata.get('payload'), dict) or metadata['payload'].get('id') != thread:
                raise ValueError
            return str(path), info.st_dev, info.st_ino
        except (OSError, ValueError, TypeError, UnicodeError) as error:
            raise TmuxRegistryError('rollout identity cannot be verified') from error

    def _check_rollout(self, row):
        path, dev, ino = self._rollout_identity(row['rollout_path'], row['thread_id'])
        if dev != row['rollout_dev'] or ino != row['rollout_ino']:
            raise TmuxRegistryError('rollout file was replaced')
        return path

    @synchronized
    def register_existing(self, conversation, transport: TmuxSession, rollout_path) -> dict:
        """Explicitly bind an already-running, verified native thread and pane."""
        conversation_id, thread = self._identity(conversation)
        if transport.conversation_id != conversation_id or transport.thread_id != thread:
            raise TmuxRegistryError('transport and existing thread do not match')
        try:
            if str(uuid.UUID(transport.session_name)) != transport.session_name:
                raise ValueError
        except (ValueError, AttributeError) as error:
            raise ValueError('registry session ID must be a canonical UUID') from error
        path, device, inode = self._rollout_identity(rollout_path, thread)
        transport.attach_existing()  # checks socket owner, session, pane, command and liveness
        values = (conversation_id, thread, transport.session_name, str(transport.socket_path),
                  transport.workspace, transport.owner_token, transport.pane_id,
                  transport.expected_command, path, device, inode)
        previous = self.db.execute('SELECT * FROM bindings WHERE conversation_id=?', (conversation_id,)).fetchone()
        if previous and previous['state'] in ('ready', 'busy', 'console') and tuple(previous[k] for k in
                ('conversation_id', 'thread_id', 'session_id', 'socket_path', 'workspace',
                 'owner_token', 'pane_id', 'expected_command', 'rollout_path', 'rollout_dev', 'rollout_ino')) != values:
            raise TmuxRegistryError('existing active binding differs; explicit quarantine required')
        if previous and previous['state'] in ('busy', 'console'):
            raise TmuxRegistryError('busy binding cannot be registered or replayed')
        with self.db:
            self.db.execute('''INSERT INTO bindings VALUES (?,?,?,?,?,?,?,?,?,?,?,'ready',NULL,'')
                ON CONFLICT(conversation_id) DO UPDATE SET
                thread_id=excluded.thread_id, session_id=excluded.session_id,
                socket_path=excluded.socket_path, workspace=excluded.workspace,
                owner_token=excluded.owner_token, pane_id=excluded.pane_id,
                expected_command=excluded.expected_command, rollout_path=excluded.rollout_path,
                rollout_dev=excluded.rollout_dev, rollout_ino=excluded.rollout_ino,
                state='ready', dispatch_message=NULL, quarantine_reason='' ''', values)
        self._attached[conversation_id] = transport
        return self._binding(transport, path)

    @staticmethod
    def _binding(transport, rollout_path):
        return {'sessionID': transport.session_name, 'threadID': transport.thread_id,
                'rolloutPath': rollout_path, 'transport': transport}

    @synchronized
    def ensure(self, conversation) -> dict:
        conversation_id, thread = self._identity(conversation)
        row = self.db.execute('SELECT * FROM bindings WHERE conversation_id=?', (conversation_id,)).fetchone()
        if row is None:
            self.quarantine(conversation_id, 'unknown binding')
            raise TmuxRegistryError('unknown conversation binding; no task dispatched')
        if self.db.execute('SELECT 1 FROM console_pending WHERE conversation_id=?', (conversation_id,)).fetchone():
            self.quarantine(conversation_id, 'unconfirmed terminal input')
            raise TmuxRegistryError('terminal input state unknown; no task dispatched')
        if row['state'] in ('busy', 'console'):
            self.quarantine(conversation_id, 'uncertain prior dispatch')
            raise TmuxRegistryError('prior dispatch outcome unknown; no task dispatched')
        if row['state'] != 'ready':
            raise TmuxRegistryError('conversation binding is quarantined')
        if row['thread_id'] != thread:
            self.quarantine(conversation_id, 'thread mismatch')
            raise TmuxRegistryError('thread mismatch; no task dispatched')
        try:
            self._check_rollout(row)
            transport = self._attached.get(conversation_id)
            if transport is None:
                transport = self._transport(row)
                transport.attach_existing()
                self._attached[conversation_id] = transport
            else:
                transport._require_attached()
            if transport.pane_id != row['pane_id'] or transport.expected_command != row['expected_command']:
                raise TmuxRegistryError('pane metadata mismatch')
            return self._binding(transport, row['rollout_path'])
        except (OSError, ValueError, TmuxSessionError, TmuxRegistryError):
            self.quarantine(conversation_id, 'reattach verification failed')
            raise TmuxRegistryError('bound session unavailable; no task dispatched') from None

    @synchronized
    def inspect(self, conversation) -> dict:
        """Read an existing binding for diagnostics/force-stop, even when busy.

        This proves persistent identity and original pane, but deliberately does
        not assert the current executable is healthy or grant dispatch rights.
        """
        conversation_id, thread = self._identity(conversation)
        row = self.db.execute('SELECT * FROM bindings WHERE conversation_id=?', (conversation_id,)).fetchone()
        if row is None or not row['session_id']:
            raise TmuxRegistryError('unknown bound session')
        if row['thread_id'] != thread:
            raise TmuxRegistryError('thread mismatch')
        try:
            self._check_rollout(row)
            transport = self._transport(row)
            transport.pane_id = row['pane_id']
            transport.expected_command = row['expected_command']
            transport._verify_identity()
            return self._binding(transport, row['rollout_path'])
        except (OSError, ValueError, TmuxSessionError):
            raise TmuxRegistryError('bound session identity unavailable') from None

    @synchronized
    def quarantine(self, conversation_id, reason) -> None:
        if not isinstance(conversation_id, str) or not conversation_id:
            raise ValueError('conversation ID required')
        if not isinstance(reason, str) or not reason or len(reason) > 80 or any(ord(c) < 32 for c in reason):
            raise ValueError('short non-sensitive reason required')
        with self.db:
            self.db.execute('''INSERT INTO bindings(conversation_id,state,quarantine_reason)
                VALUES (?, 'quarantine', ?)
                ON CONFLICT(conversation_id) DO UPDATE SET state='quarantine', quarantine_reason=excluded.quarantine_reason''',
                (conversation_id, reason))

    @synchronized
    def note_console_pending(self, conversation_id, intent_id):
        """Mark editor/queued input even while an app turn owns the dispatch."""
        with self._transaction():
            if not self.db.execute('SELECT 1 FROM bindings WHERE conversation_id=?', (conversation_id,)).fetchone():
                raise TmuxRegistryError('unknown terminal binding')
            self.db.execute('INSERT OR IGNORE INTO console_pending VALUES (?,?)', (conversation_id, intent_id))

    @synchronized
    def clear_console_pending(self, conversation_id):
        # Runtime calls this only at a verified native completion with no
        # unconsumed Enter/editor state. Never clear it on detach or timeout.
        with self._transaction():
            self.db.execute('DELETE FROM console_pending WHERE conversation_id=?', (conversation_id,))

    @synchronized
    def begin_console(self, conversation_id, intent_id) -> None:
        """Reserve native input ownership before sending any terminal bytes.

        A pending editor/submission is not an idle pane. On service restart this
        state fails ensure(), just like a busy dispatch; it is never auto-replayed.
        """
        if not isinstance(intent_id, str) or not intent_id or len(intent_id) > 200:
            raise ValueError('console intent ID required')
        with self._transaction():
            changed = self.db.execute('''UPDATE bindings SET state='console', dispatch_message=?
                WHERE conversation_id=? AND state='ready' AND dispatch_message IS NULL''',
                (intent_id, conversation_id)).rowcount
            if changed != 1:
                raise TmuxRegistryError('binding is not ready for terminal ownership')

    @synchronized
    def adopt_console_dispatch(self, conversation_id, intent_id, message_id) -> None:
        """Bind a genuinely observed owner input; this does not send anything."""
        if not isinstance(message_id, str) or not message_id or len(message_id) > 200:
            raise ValueError('message ID required')
        with self._transaction():
            if self.db.execute('SELECT 1 FROM dispatches WHERE message_id=?', (message_id,)).fetchone():
                raise TmuxRegistryError('native message was already adopted')
            changed = self.db.execute('''UPDATE bindings SET state='busy', dispatch_message=?
                WHERE conversation_id=? AND state='console' AND dispatch_message=?''',
                (message_id, conversation_id, intent_id)).rowcount
            if changed != 1:
                raise TmuxRegistryError('console ownership mismatch')
            self.db.execute('INSERT INTO dispatches VALUES (?,?,?)',
                            (message_id, conversation_id, 'intent'))

    @synchronized
    def finish_console(self, conversation_id, intent_id) -> None:
        """Release a non-chat native command only after its real completion."""
        with self._transaction():
            changed = self.db.execute('''UPDATE bindings SET state='ready', dispatch_message=NULL
                WHERE conversation_id=? AND state='console' AND dispatch_message=?''',
                (conversation_id, intent_id)).rowcount
            if changed != 1:
                raise TmuxRegistryError('console ownership mismatch; idle not granted')

    @synchronized
    def begin_dispatch(self, conversation_id, message_id) -> None:
        """Durably reserve a known ready binding before any text reaches tmux."""
        if not isinstance(message_id, str) or not message_id or len(message_id) > 200:
            raise ValueError('message ID required')
        with self._transaction():
            if self.db.execute('SELECT 1 FROM dispatches WHERE message_id=?', (message_id,)).fetchone():
                raise TmuxRegistryError('message was already dispatched; replay refused')
            changed = self.db.execute('''UPDATE bindings SET state='busy', dispatch_message=?
                WHERE conversation_id=? AND state='ready' AND dispatch_message IS NULL''',
                (message_id, conversation_id)).rowcount
            if changed != 1:
                raise TmuxRegistryError('binding is not ready; dispatch refused')
            self.db.execute('INSERT INTO dispatches VALUES (?, ?, ?)',
                            (message_id, conversation_id, 'intent'))

    @synchronized
    def finish_dispatch(self, conversation_id, message_id) -> None:
        """Only a verified native complete for this exact message may release busy."""
        with self._transaction():
            changed = self.db.execute('''UPDATE bindings SET state='ready', dispatch_message=NULL
                WHERE conversation_id=? AND state='busy' AND dispatch_message=?''',
                (conversation_id, message_id)).rowcount
            if changed != 1:
                raise TmuxRegistryError('dispatch owner mismatch; ready state not granted')
            changed = self.db.execute('''UPDATE dispatches SET state='complete'
                WHERE message_id=? AND conversation_id=? AND state='intent' ''',
                (message_id, conversation_id)).rowcount
            if changed != 1:
                raise TmuxRegistryError('dispatch intent missing; ready state not granted')

    @synchronized
    def close(self) -> None:
        for transport in self._attached.values():
            transport.detach()
        self._attached.clear()
        self.db.close()
