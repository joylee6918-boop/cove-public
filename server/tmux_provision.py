"""Explicit native Codex tmux provisioning with durable, non-replayable intents.

New TUI sessions have no rollout before their first turn. The only bootstrap
identity accepted here is a unique native /status UUID whose exact writer-lock
is held by the bound pane process. First dispatch is a separate durable intent;
registration waits for one exact, newly created session_meta rollout.
"""
from __future__ import annotations

import errno
import fcntl
import hashlib
import os
import re
import secrets
import sqlite3
import stat
import subprocess
import threading
import time
import uuid
from pathlib import Path

from tmux_session import TmuxSession, TmuxSessionError
from tmux_registry import TmuxRegistryError


class ProvisionError(RuntimeError):
    pass


_UUID = r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
_STATUS = re.compile(r'(?m)\bSession:\s*(' + _UUID + r')\b')
_PROFILE = re.compile(r'cove_[a-z0-9_-]{1,59}\Z')
_EMPTY_EDITOR = re.compile(r'(?m)^› Ask Codex to do anything\s*$')


def native_ready_probe(transport, thread, *, timeout=8):
    """Fail closed unless the pinned native pane has a stable empty editor.

    This is a narrow 0.155.1 TUI integration probe, not a generic idle-turn
    guarantee. The transport's capture revalidates private socket, exact
    session, pinned pane and expected executable on every read. Never submit
    a turn just because this returns true; runtime still needs its ledger.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        screen = transport.capture(max_lines=120)
        context = 'OpenAI Codex' in screen if thread is None else transport.workspace in screen
        if context and _EMPTY_EDITOR.search(screen):
            time.sleep(.15)
            second = transport.capture(max_lines=120)
            second_context = 'OpenAI Codex' in second if thread is None else transport.workspace in second
            if second_context and _EMPTY_EDITOR.search(second):
                return True
        time.sleep(.05)
    return False


class TmuxProvisioner:
    def __init__(self, *, registry, socket_dir, workspace, launch_config,
                 ready_probe=native_ready_probe, lock_verifier=None, transport_factory=TmuxSession):
        directory = Path(socket_dir)
        if not directory.is_absolute() or directory != directory.resolve(strict=True):
            raise ValueError('private socket directory must be canonical')
        info = directory.stat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError('private socket directory must be owned and 0700')
        work = Path(workspace)
        if not work.is_absolute() or work != work.resolve(strict=True) or not work.is_dir():
            raise ValueError('workspace must be an existing canonical directory')
        if not callable(launch_config):
            raise ValueError('launch_config callback is required')
        self.registry, self.socket_dir, self.workspace = registry, directory, str(work)
        self.launch_config = launch_config
        self.ready_probe = ready_probe
        self.lock_verifier = lock_verifier or self._verify_native_lock
        self.transport_factory = transport_factory
        self.lock = threading.RLock()
        self.db = sqlite3.connect(str(directory / 'provisions.sqlite3'), isolation_level=None,
                                  check_same_thread=False)
        os.chmod(directory / 'provisions.sqlite3', 0o600)
        self.db.row_factory = sqlite3.Row
        self.db.execute('PRAGMA journal_mode=DELETE')
        self.db.execute('PRAGMA synchronous=FULL')
        self.db.execute('''CREATE TABLE IF NOT EXISTS provisions (
            operation_id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL,
            thread_id TEXT, session_id TEXT NOT NULL, owner_token TEXT NOT NULL,
            socket_path TEXT NOT NULL, pane_id TEXT, rollout_path TEXT, first_message TEXT,
            launched_at REAL NOT NULL, state TEXT NOT NULL)
        ''')
        if 'pane_id' not in {row['name'] for row in self.db.execute('PRAGMA table_info(provisions)')}:
            self.db.execute('ALTER TABLE provisions ADD COLUMN pane_id TEXT')
        self._live = {}
        self._closed = False

    def _config_fingerprint(self, conversation):
        # Root prepares an additive, private native CLI profile for Cove. The
        # shared CODEX_HOME base config/auth/rollouts are never overwritten.
        # No bearer/capability value may go in argv; the profile can refer to
        # a private capability file that the MCP process reads itself.
        spec = self.launch_config(conversation)
        allowed = ({'config_sha256'}, {'config_sha256', 'profile_name', 'profile_sha256'})
        if not isinstance(spec, dict) or set(spec) not in allowed or not isinstance(spec['config_sha256'], str):
            raise ProvisionError('launch configuration fingerprint missing')
        def verify(path, fingerprint):
            try:
                if path != path.resolve(strict=True) or path.is_symlink():
                    raise ValueError
                info = path.stat()
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or
                        info.st_mode & 0o077 or info.st_size > 256 * 1024):
                    raise ValueError
                if hashlib.sha256(path.read_bytes()).hexdigest() != fingerprint:
                    raise ValueError
            except (OSError, ValueError) as error:
                raise ProvisionError('native Codex config is not privately verified') from error
        verify(Path(self.registry.codex_home) / 'config.toml', spec['config_sha256'])
        if 'profile_name' not in spec:
            return []
        name = spec['profile_name']
        if not isinstance(name, str) or not _PROFILE.fullmatch(name):
            raise ProvisionError('Cove native profile name is invalid')
        verify(Path(self.registry.codex_home) / (name + '.config.toml'), spec['profile_sha256'])
        return ['-p', name]

    @staticmethod
    def _op(value):
        try:
            if not isinstance(value, str) or str(uuid.UUID(value)) != value:
                raise ValueError
        except (ValueError, AttributeError) as error:
            raise ValueError('operation ID must be a canonical UUID') from error
        return value

    def _reserve(self, operation_id, conversation_id, thread_id, state):
        operation_id = self._op(operation_id)
        session_id = str(uuid.uuid4())
        owner = secrets.token_urlsafe(32)
        socket_path = str(self.socket_dir / (session_id + '.sock'))
        launched_at = time.time()
        with self.lock:
            if self._closed:
                raise ProvisionError('provisioner is closed')
            self.db.execute('BEGIN IMMEDIATE')
            try:
                active = self.db.execute('''SELECT 1 FROM provisions WHERE conversation_id=?
                    AND state IN ('launch-intent','bootstrap-intent','awaiting-first-message',
                                  'first-intent','bound-first-intent','ready') LIMIT 1''',
                    (conversation_id,)).fetchone()
                if active:
                    raise ProvisionError('conversation already has an active provision operation')
                self.db.execute('''INSERT INTO provisions
                    (operation_id,conversation_id,thread_id,session_id,owner_token,
                     socket_path,rollout_path,first_message,launched_at,state)
                     VALUES (?,?,?,?,?,?,?,?,?,?)''',
                                (operation_id, conversation_id, thread_id, session_id, owner,
                                 socket_path, None, None, launched_at, state))
                row = self.db.execute('SELECT * FROM provisions WHERE operation_id=?',
                                      (operation_id,)).fetchone()
                self.db.execute('COMMIT')
            except sqlite3.IntegrityError as error:
                self.db.execute('ROLLBACK')
                raise ProvisionError('provision operation already used; no automatic retry') from error
            except BaseException:
                self.db.execute('ROLLBACK')
                raise
            return row

    def _transport(self, row, thread):
        kwargs = dict(socket_path=row['socket_path'], session_name=row['session_id'],
                      conversation_id=row['conversation_id'], thread_id=thread,
                      workspace=self.workspace, owner_token=row['owner_token'],
                      child_env={'CODEX_HOME': self.registry.codex_home},
                      tmux_binary=self.registry.tmux_binary)
        if self.registry.runner is not None:
            kwargs['runner'] = self.registry.runner
        return self.transport_factory(**kwargs)

    def _start(self, row, argv, rows, cols):
        with self.lock:
            if self._closed:
                raise ProvisionError('provisioner is closed')
            transport = self._transport(row, row['thread_id'] or ('bootstrap-' + row['operation_id']))
            transport.start(argv, rows=rows, cols=cols)
            self.db.execute('UPDATE provisions SET pane_id=? WHERE operation_id=?',
                            (transport.pane_id, row['operation_id']))
            self._live[row['operation_id']] = transport
            return transport

    def _rollouts_for(self, thread):
        # UUID-specific candidate search, never “latest file”. Each candidate
        # must pass the registry's exact native session_meta validation.
        base = Path(self.registry.codex_home) / 'sessions'
        candidates = []
        if base.exists():
            for path in base.rglob('*' + thread + '*.jsonl'):
                try:
                    self.registry._rollout_identity(path, thread)
                except TmuxRegistryError:
                    continue
                candidates.append(path)
                if len(candidates) > 1:
                    break
        return candidates

    def resume_existing(self, conversation, *, operation_id, rollout_path,
                        rows=30, cols=100):
        """Explicitly resume one known native thread; never use --last/picker."""
        conversation_id, thread = self.registry._identity(conversation)
        profile_args = self._config_fingerprint(conversation)
        path, _, _ = self.registry._rollout_identity(rollout_path, thread)
        with self.registry.lock:
            previous = self.registry.db.execute('SELECT state FROM bindings WHERE conversation_id=?',
                                                (conversation_id,)).fetchone()
            if previous and previous['state'] in ('ready', 'busy', 'console'):
                raise ProvisionError('existing binding must not be replaced')
        row = self._reserve(operation_id, conversation_id, thread, 'launch-intent')
        argv = [self.registry.codex_binary, *profile_args, '--no-alt-screen', '-C', self.workspace,
                'resume', thread]
        try:
            transport = self._start(row, argv, rows, cols)
            if self.ready_probe is None or self.ready_probe(transport, thread) is not True:
                raise ProvisionError('native resumed TUI readiness not verified')
            binding = self.registry.register_existing(conversation, transport, path)
            with self.lock:
                self.db.execute('UPDATE provisions SET state=?,rollout_path=? WHERE operation_id=?',
                                ('ready', path, operation_id))
            return binding
        except Exception:
            with self.lock:
                self.db.execute('UPDATE provisions SET state=? WHERE operation_id=?', ('quarantine', operation_id))
            self.registry.quarantine(conversation_id, 'provision outcome unknown')
            raise

    def create_new(self, conversation_id, *, operation_id, rows=30, cols=100,
                   status_timeout=8):
        """Start an empty TUI and prove its native UUID without model input.

        Returns pending bootstrap, NOT a dispatch-ready registry binding.
        The caller must durably reserve its first message, then bind the exact
        newly created native rollout before declaring the turn complete.
        """
        if not isinstance(conversation_id, str) or not conversation_id:
            raise ValueError('conversation ID required')
        with self.registry.lock:
            previous = self.registry.db.execute('SELECT session_id FROM bindings WHERE conversation_id=?',
                                                (conversation_id,)).fetchone()
            if previous and previous['session_id']:
                raise ProvisionError('known binding must not be silently replaced with a new thread')
        profile_args = self._config_fingerprint({'id': conversation_id, 'thread': None})
        row = self._reserve(operation_id, conversation_id, None, 'bootstrap-intent')
        argv = [self.registry.codex_binary, *profile_args, '--no-alt-screen', '-C', self.workspace]
        try:
            transport = self._start(row, argv, rows, cols)
            if self.ready_probe is None or self.ready_probe(transport, None) is not True:
                raise ProvisionError('native empty TUI readiness not verified')
            transport.send_text('/status')
            # tmux has delivered bytes, not proof that the native editor has
            # consumed them. Never press Enter until the exact slash command is
            # visibly staged in the bound pane; otherwise startup races can
            # drop /status or, worse, submit into a different prompt.
            staged_deadline = time.monotonic() + min(status_timeout, 4)
            while time.monotonic() < staged_deadline:
                screen = transport.capture(max_lines=100)
                if re.search(r'(?m)^\s*[›>]\s*/status\s*$', screen):
                    break
                time.sleep(.05)
            else:
                raise ProvisionError('native /status was not staged in the editor')
            # The visible editor frame may precede installation of its current
            # slash-command handler by one render tick on native TUI startup.
            time.sleep(.15)
            if not re.search(r'(?m)^\s*[›>]\s*/status\s*$',
                             transport.capture(max_lines=100)):
                raise ProvisionError('native /status editor staging changed')
            transport.send_special('Enter')
            deadline = time.monotonic() + status_timeout
            ids = set()
            while time.monotonic() < deadline:
                ids = set(_STATUS.findall(transport.capture(max_lines=500)))
                if len(ids) > 1:
                    raise ProvisionError('multiple native session IDs on screen')
                if ids:
                    break
                time.sleep(.05)
            if len(ids) != 1:
                raise ProvisionError('native /status session ID not verified')
            thread = next(iter(ids))
            pane_pid = transport._run('display-message', '-p', '-t', transport.pane_id,
                                      '#{pane_pid}').stdout.strip()
            if not pane_pid.isdecimal() or not self.lock_verifier(int(pane_pid), thread):
                raise ProvisionError('native writer lock is not held by bound pane')
            if self._rollouts_for(thread):
                raise ProvisionError('empty TUI unexpectedly has an existing rollout')
            # /status itself must not have sent a model turn or created a
            # rollout. The one-shot first intent below is the only send path.
            # A native /status panel is an overlay, not the composer. Explicitly
            # dismiss it and prove a fresh empty editor before exposing the
            # pending session for first-message dispatch.
            transport.send_special('Escape')
            if self.ready_probe(transport, None) is not True:
                raise ProvisionError('native editor not ready after /status')
            # One-way transition from a private bootstrap placeholder to the
            # authoritative /status UUID. No existing thread may be rebound.
            transport._verify_binding()
            transport._run('set-option', '-t', transport.session_name, '@cove_thread', thread)
            transport.thread_id = thread
            transport._verify_binding()
            with self.lock:
                self.db.execute('UPDATE provisions SET thread_id=?,state=? WHERE operation_id=?',
                                (thread, 'awaiting-first-message', operation_id))
            return {'sessionID': transport.session_name, 'threadID': thread,
                    'rolloutPath': None, 'transport': transport,
                    'state': 'awaiting-first-message'}
        except Exception:
            with self.lock:
                self.db.execute('UPDATE provisions SET state=? WHERE operation_id=?', ('quarantine', operation_id))
            raise

    def begin_first_dispatch(self, operation_id, message_id):
        """Durable one-shot first-message intent; does not send it."""
        self._op(operation_id)
        if not isinstance(message_id, str) or not message_id:
            raise ValueError('message ID required')
        with self.lock:
            self.db.execute('BEGIN IMMEDIATE')
            try:
                row = self.db.execute('SELECT state FROM provisions WHERE operation_id=?',
                                      (operation_id,)).fetchone()
                if not row or row['state'] != 'awaiting-first-message':
                    raise ProvisionError('bootstrap intent unavailable; no replay')
                if self.db.execute('SELECT 1 FROM provisions WHERE first_message=?',
                                   (message_id,)).fetchone():
                    raise ProvisionError('first message already dispatched')
                self.db.execute('UPDATE provisions SET first_message=?,state=? WHERE operation_id=?',
                                (message_id, 'first-intent', operation_id))
                self.db.execute('COMMIT')
            except BaseException:
                self.db.execute('ROLLBACK')
                raise

    def bind_first_rollout(self, operation_id, conversation, *, message_id):
        """Bind only the one fresh native file for the proven UUID after dispatch."""
        self._op(operation_id)
        with self.lock:
            row = self.db.execute('SELECT * FROM provisions WHERE operation_id=?',
                                  (operation_id,)).fetchone()
            if not row or row['state'] != 'first-intent' or row['first_message'] != message_id:
                raise ProvisionError('first-message intent does not match')
            conversation_id, thread = self.registry._identity(conversation)
            if conversation_id != row['conversation_id'] or thread != row['thread_id']:
                raise ProvisionError('native bootstrap conversation/thread mismatch')
            candidates = self._rollouts_for(thread)
            if len(candidates) != 1:
                raise ProvisionError('native first rollout is absent or ambiguous')
            path = candidates[0]
            if path.stat().st_mtime < row['launched_at'] - 2:
                raise ProvisionError('native first rollout predates bootstrap')
            transport = self._live.get(operation_id)
            if transport is None:
                transport = self._transport(row, thread)
                transport.attach_existing()
            binding = self.registry.register_existing(conversation, transport, path)
            try:
                self.registry.begin_dispatch(conversation_id, message_id)
            except BaseException:
                self.registry.quarantine(conversation_id, 'first dispatch binding incomplete')
                self.db.execute('UPDATE provisions SET state=? WHERE operation_id=?',
                                ('quarantine', operation_id))
                raise
            self.db.execute('UPDATE provisions SET rollout_path=?,state=? WHERE operation_id=?',
                            (str(path), 'bound-first-intent', operation_id))
            return binding

    def finish_first_dispatch(self, operation_id, conversation_id, message_id):
        with self.lock:
            row = self.db.execute('SELECT * FROM provisions WHERE operation_id=?',
                                  (operation_id,)).fetchone()
            if not row or row['state'] != 'bound-first-intent' or row['first_message'] != message_id:
                raise ProvisionError('first turn is not bound to this intent')
            self.registry.finish_dispatch(conversation_id, message_id)
            self.db.execute('UPDATE provisions SET state=? WHERE operation_id=?',
                            ('ready', operation_id))

    def recover_after_force(self, conversation, *, operation_id, rows=30, cols=100):
        """Explicit owner recovery: kill only the verified old session, then resume."""
        binding = self.registry.inspect(conversation)
        binding['transport'].terminate_bound()
        self.registry.quarantine(conversation['id'], 'owner forced recovery')
        with self.lock:
            self.db.execute('''UPDATE provisions SET state='terminated'
                WHERE conversation_id=? AND session_id=? AND state IN
                  ('launch-intent','bootstrap-intent','awaiting-first-message',
                   'first-intent','bound-first-intent','ready')''',
                (conversation['id'], binding['sessionID']))
        return self.resume_existing(conversation, operation_id=operation_id,
                                    rollout_path=binding['rolloutPath'], rows=rows, cols=cols)

    def terminate_pending(self, operation_id):
        """Explicitly force-stop a still-unbound bootstrap, including after restart.

        The operation/pane/owner metadata must all match. This does not create
        a new thread, adopt any rollout, or replay the uncertain first message.
        """
        self._op(operation_id)
        with self.lock:
            row = self.db.execute('SELECT * FROM provisions WHERE operation_id=?',
                                  (operation_id,)).fetchone()
            if not row or row['state'] not in ('bootstrap-intent', 'awaiting-first-message',
                                               'first-intent', 'quarantine'):
                raise ProvisionError('pending bootstrap is unavailable for scoped force')
            if not row['pane_id']:
                raise ProvisionError('bootstrap pane identity was not durably recorded')
            thread = row['thread_id'] or ('bootstrap-' + operation_id)
            transport = self._transport(row, thread)
            transport.pane_id = row['pane_id']
            transport.terminate_bound()
            self.db.execute('UPDATE provisions SET state=? WHERE operation_id=?',
                            ('terminated', operation_id))
            self._live.pop(operation_id, None)
            return {'conversationID': row['conversation_id'], 'threadID': row['thread_id'],
                    'firstMessageID': row['first_message'], 'state': 'terminated'}

    def inspect_pending(self, conversation_id):
        """Recover exactly one unbound bootstrap handle for diagnostic/force UI.

        No dispatch right is granted, and an unavailable native process is not
        silently recreated. The exact original pane/session owner must remain.
        """
        if not isinstance(conversation_id, str) or not conversation_id:
            raise ValueError('conversation ID required')
        with self.lock:
            rows = self.db.execute('''SELECT * FROM provisions WHERE conversation_id=?
                AND state IN ('bootstrap-intent','awaiting-first-message','first-intent','quarantine')''',
                (conversation_id,)).fetchall()
            if len(rows) != 1 or not rows[0]['pane_id']:
                raise ProvisionError('unique pending bootstrap identity unavailable')
            row = rows[0]
            thread = row['thread_id'] or ('bootstrap-' + row['operation_id'])
            transport = self._transport(row, thread)
            transport.pane_id = row['pane_id']
            transport._verify_identity()
            try:
                transport.attach_existing()
            except TmuxSessionError:
                pass  # explicit terminate_bound still uses exact identity
            return {'operationID': row['operation_id'], 'conversationID': conversation_id,
                    'bootstrapID': row['operation_id'], 'paneID': row['pane_id'],
                    'launchedAt': row['launched_at'],
                    'sessionID': row['session_id'], 'threadID': row['thread_id'],
                    'rolloutPath': None, 'transport': transport,
                    'state': row['state'], 'firstMessageID': row['first_message']}

    def close(self):
        with self.lock:
            if self._closed:
                return
            self._closed = True
            for transport in self._live.values():
                transport.detach()
            self._live.clear()
            self.db.close()

    def _verify_native_lock(self, pane_pid, thread):
        path = Path(self.registry.codex_home) / 'thread-writer-locks' / (thread + '.lock')
        try:
            if path.is_symlink():
                return False
            info = path.stat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                return False
            fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
            try:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except OSError as error:
                    if error.errno not in (errno.EAGAIN, errno.EACCES):
                        return False
                else:
                    fcntl.flock(fd, fcntl.LOCK_UN)
                    return False
            finally:
                os.close(fd)
            proc_fd = Path('/proc') / str(pane_pid) / 'fd'
            if proc_fd.is_dir():
                return any(Path(os.readlink(entry)).resolve(strict=False) == path
                           for entry in proc_fd.iterdir() if entry.is_symlink())
            result = subprocess.run(['lsof', '-p', str(pane_pid), '-Fn'],
                                    capture_output=True, text=True, timeout=3, check=False)
            return result.returncode == 0 and ('n' + str(path)) in result.stdout.splitlines()
        except (OSError, subprocess.TimeoutExpired):
            return False
