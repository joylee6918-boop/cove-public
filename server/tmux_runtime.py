"""Codex CLI turn adapter for explicitly registered persistent tmux sessions.

No app-server subprocess or RPC is used. Provisioning must independently verify
the native session, rollout and launch configuration before registration.
Uncertain dispatches are quarantined, never silently re-sent on reconnection.
"""
from __future__ import annotations

import json
import threading
import time
import os
import uuid
from pathlib import Path

from runtime import CodexRuntime
from storage import APIError
from tmux_console import TmuxConsole
from tmux_rollout import RolloutTailer


class TmuxRuntime(CodexRuntime):
    def __init__(self, store, workspace, *, session_provider, codex_home,
                 model=None, timeout=1800, tailer_factory=RolloutTailer,
                 enable_terminal_input=False, provisioner=None):
        # Reuse only bounded input preparation and authorized tool executors.
        # Every app-server launch/RPC/lifecycle method is overridden below.
        super().__init__(store, workspace, command='codex', model=model, timeout=timeout)
        self.session_provider = session_provider
        self.codex_home = str(Path(codex_home).resolve(strict=True))
        self.tailer_factory = tailer_factory
        self.native_signal = threading.Event()
        self.run_done = threading.Event()
        self.run_done.set()
        self.bindings = {}
        self.provisioner = provisioner
        self.interactive = None
        if enable_terminal_input:
            from tmux_interactive import InteractiveTurns
            self.interactive = InteractiveTurns(self)
        self.tmux_console = TmuxConsole(store.directory, lock=self.state_lock,
                                        before_control=self._before_control,
                                        after_control=self._after_control)

    def request(self, *args, **kwargs):
        raise APIError(503, 'tmux 运行时不使用 app-server RPC；该适配尚不可用')

    def _send(self, *args, **kwargs):
        raise APIError(503, 'tmux 运行时没有 app-server 连接')

    def ensure_started(self):
        if self.closed:
            raise APIError(503, 'tmux 运行时已关闭')

    def file_config(self, conversation):
        with self.state_lock:
            self.ensure_started()
            if self.file_bridge is None:
                from file_bridge import FileBridge
                self.file_bridge = FileBridge(self, persistence_path=self.store.directory / 'tmux-mcp-bridge.json')
            return self.file_bridge.config(conversation)

    def launch_config(self, conversation):
        # Native additive profile, not an edit of shared CODEX_HOME/config.toml.
        self.file_config(conversation['id'])
        from tmux_profile import launch_profile
        settings = self.store.terminal_settings(conversation['id'], self.model, self.effort)
        return launch_profile(self.codex_home, self.file_bridge.cli_config(conversation['id']),
                              model=settings['model'], effort=settings['effort'],
                              model_provider=self.model_provider,
                              approval_policy=os.getenv('COVE_APPROVAL_POLICY', 'on-request'),
                              sandbox=os.getenv('COVE_SANDBOX', 'read-only'))

    def mcp_file_call(self, *args, **kwargs):
        # A missing native envelope must never fall through to legacy permits.
        raise APIError(409, 'CLI 工具缺少原生回合元数据')

    def mcp_file_call_native(self, conversation, tool, arguments, metadata, rpc_id):
        from tmux_mcp import bind_native_call
        # The MCP callback may beat the disk watcher by a few milliseconds.
        # Wait only for the pending turn's authoritative task_started binding.
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            with self.state_lock:
                active = self.active
                state = self.interactive.states.get(conversation) if self.interactive else None
                envelope = metadata.get('x-codex-turn-metadata') if isinstance(metadata, dict) else None
                pending_owner_turn = bool(state and state['credits'] > 0 and not state['error'] and
                                          not state['stop'].is_set() and isinstance(envelope, dict) and
                                          envelope.get('thread_id') == state['binding']['threadID'] and
                                          isinstance(envelope.get('turn_id'), str))
                if not active and pending_owner_turn:
                    self.native_signal.clear()
                elif not active or active['conversation'] != conversation or active['cancel'].is_set():
                    raise APIError(409, '没有对应的活跃 Cove 回合')
                elif (pending_owner_turn and active['turn'] is not None and
                      envelope.get('turn_id') != active['turn']):
                    self.native_signal.clear()
                elif active['turn'] is not None and active.get('message') is not None:
                    call = bind_native_call(self, conversation, tool, arguments, metadata, rpc_id)
                    message = active['message']
                    break
                self.native_signal.clear()
            self.native_signal.wait(.05)
        else:
            raise APIError(409, '尚未确认原生 CLI 回合，未执行工具')
        return self.execute_bound_file_call(conversation, tool, arguments, message, call.turn, call.call_id)

    def _session(self, conversation):
        with self.state_lock:
            self.ensure_started()
            binding = None
            if self.provisioner:
                with self.session_provider.lock:
                    row = self.session_provider.db.execute('SELECT * FROM bindings WHERE conversation_id=?',
                                                          (conversation['id'],)).fetchone()
                if row is None:
                    operation = str(uuid.uuid4())
                    if conversation['thread']:
                        candidates = self.provisioner._rollouts_for(conversation['thread'])
                        if len(candidates) != 1:
                            raise APIError(409, '无法唯一确认原会话记录，未新建替代会话')
                        binding = self.provisioner.resume_existing(conversation, operation_id=operation,
                                                                  rollout_path=candidates[0])
                    else:
                        binding = self.provisioner.create_new(conversation['id'], operation_id=operation)
                        with self.store.lock:
                            if self.store.conversation(conversation['id'])['thread'] is not None:
                                raise APIError(409, '聊天线程已经变化，未覆盖')
                            self.store.bind_thread(conversation['id'], binding['threadID'])
                            conversation['thread'] = binding['threadID']
                        binding['bootstrapID'] = operation
            if binding is None:
                binding = self.session_provider.ensure(conversation)
            if binding['threadID'] != conversation['thread'] or not conversation['thread']:
                raise APIError(409, 'tmux 与聊天线程不一致')
            if binding['sessionID'] not in self.tmux_console.bindings:
                self.tmux_console.register(binding['sessionID'], binding['transport'],
                                           input_available=self.interactive is not None and not binding.get('bootstrapID'))
            self.bindings[conversation['id']] = binding
        return binding

    def attach_console(self, conversation):
        self.ensure_started()
        with self.store.lock:
            record = self.store.conversation(conversation)
        binding = self.bindings.get(conversation)
        if binding and self.tmux_console.bindings.get(binding['sessionID'], {}).get('state') == 'terminated':
            return
        # A stopped pane cannot pass a live tmux identity probe after restart.
        # Rehydrate its diagnostic handle only from a durable exact kill ACK
        # plus the unchanged registry/thread/rollout identity, never a missing PID.
        if not binding and hasattr(self.session_provider, 'db'):
            with self.state_lock, self.session_provider.lock:
                row = self.session_provider.db.execute('SELECT * FROM bindings WHERE conversation_id=?',
                                                       (conversation,)).fetchone()
                if (row and row['thread_id'] == record['thread'] and
                        self.tmux_console.termination_recorded(conversation, row['session_id'], record['thread'])):
                    path = self.session_provider._check_rollout(row)
                    transport = self.session_provider._transport(row)
                    transport.pane_id, transport.expected_command = row['pane_id'], row['expected_command']
                    self.tmux_console.restore_terminated(row['session_id'], transport)
                    self.bindings[conversation] = self.session_provider._binding(transport, path)
                    # The console ACK is authoritative if a crash preceded the
                    # secondary provision ledger update. This performs no I/O.
                    self._after_control(conversation, row['session_id'], 'terminate', None)
                    return
        if not binding or not binding.get('bootstrapID'):
            try:
                binding = self.session_provider.inspect(record)
            except RuntimeError:
                if not self.provisioner:
                    raise
                binding = self.provisioner.inspect_pending(conversation)
                if binding['threadID'] != record['thread']:
                    raise APIError(409, '启动线程尚未与聊天确认绑定，未授予终端操作权')
        with self.state_lock:
            self.ensure_started()
            if binding['sessionID'] not in self.tmux_console.bindings:
                self.tmux_console.register(binding['sessionID'], binding['transport'],
                                           allow_unavailable=True, input_available=self.interactive is not None)
            self.bindings[conversation] = binding

    def _after_control(self, conversation, session, operation, value):
        if operation != 'terminate' or not self.provisioner:
            return
        # Called only after the exact bound transport has ACKed kill-session.
        # Persist it so a later explicit recovery need not try to kill again.
        with self.provisioner.lock:
            self.provisioner.db.execute("UPDATE provisions SET state='terminated' WHERE conversation_id=? AND session_id=?",
                                       (conversation, session))

    def recover_console(self, conversation, session, request_id):
        """Explicit owner recovery of an ACKed terminated pane, never a replay."""
        console = self.tmux_console
        console._id(request_id)
        with self.state_lock:
            self.ensure_started()
            if not self.provisioner:
                raise APIError(503, '当前运行时没有原生恢复器')
            console.db.execute('''CREATE TABLE IF NOT EXISTS recoveries (
                request TEXT PRIMARY KEY, conversation TEXT NOT NULL, old_session TEXT NOT NULL,
                state TEXT NOT NULL, new_session TEXT)''')
            old = console.db.execute('SELECT conversation,old_session,state,new_session FROM recoveries WHERE request=?',
                                     (request_id,)).fetchone()
            if old:
                if old[:2] != (conversation, session):
                    raise APIError(409, '恢复请求标识已用于其他会话')
                if old[2] == 'complete':
                    if old[3] not in console.bindings:
                        self.attach_console(conversation)
                    return console.capture(conversation, old[3])
                raise APIError(409, '上次恢复结果未知，未自动重启；请重新附着查看')
            previous = console._bound(conversation, session)
            if previous['state'] != 'terminated':
                raise APIError(409, '请先明确强制退出当前会话，再恢复；不会暗中停止任务')
            with self.store.lock:
                record = self.store.conversation(conversation)
                if record['thread'] != previous['transport'].thread_id:
                    raise APIError(409, '当前聊天线程已变化，未恢复旧终端')
                if self.store.db.execute("SELECT 1 FROM jobs WHERE state='running' LIMIT 1").fetchone():
                    raise APIError(409, '旧任务正在停止，请稍后恢复')
            if not self.run_done.is_set() or self.active:
                raise APIError(409, '旧任务正在停止，请稍后恢复')
            state = self.interactive.states.get(conversation) if self.interactive else None
            if state and state['worker'].is_alive():
                raise APIError(409, '终端观察器正在停止，请稍后恢复')
            with self.session_provider.lock:
                row = self.session_provider.db.execute('SELECT * FROM bindings WHERE conversation_id=?', (conversation,)).fetchone()
                if not row or row['session_id'] != session or row['thread_id'] != record['thread']:
                    raise APIError(409, '没有可核验的原生历史；保留记录，请新建对话')
                path = self.session_provider._check_rollout(row)
            with console.db:
                console.db.execute('INSERT INTO recoveries VALUES(?,?,?,?,NULL)',
                                   (request_id, conversation, session, 'intent'))
            # The provision ledger uses the same operation ID and also refuses
            # uncertain restarts. No previous message is passed to resume.
            binding = self.provisioner.resume_existing(record, operation_id=request_id, rollout_path=path)
            self.session_provider.clear_console_pending(conversation)
            if self.interactive:
                self.interactive.states.pop(conversation, None)
            console.register(binding['sessionID'], binding['transport'], input_available=self.interactive is not None)
            self.bindings[conversation] = binding
            with console.db:
                console.db.execute("UPDATE recoveries SET state='complete',new_session=? WHERE request=?",
                                   (binding['sessionID'], request_id))
            return console.capture(conversation, binding['sessionID'])

    def _before_control(self, conversation, session, operation, value):
        # Called under the same lock used by dispatch and native tool commit.
        binding = self.bindings.get(conversation)
        if not binding or binding['sessionID'] != session:
            raise APIError(409, '终端会话已变化')
        active = self.active
        if operation == 'terminate' or (operation == 'key' and value == 'C-c'):
            if self.interactive:
                self.interactive.revoke(conversation)
            if active and active['conversation'] == conversation:
                active['cancel'].set()
                active['interrupt_attempted'] = True
                self.native_signal.set()
            self.session_provider.quarantine(conversation, 'owner-interrupted')
            return
        if self.interactive:
            self.interactive.before_control(conversation, operation, value)
            return
        # An active model turn does NOT prove the TUI is awaiting approval.
        # Enter might queue an untracked second model turn. Until native prompt
        # receipts / idle-turn adoption are implemented, only stop controls are
        # permitted by this candidate's real runtime (transport itself supports keys).
        raise APIError(409, '自由终端输入尚未完成回合同步；当前可中断或强退，新任务请从聊天框发送')

    def interrupt(self, conversation, cancelled=None):
        with self.state_lock:
            active = self.active
            if not active or active['conversation'] != conversation or (
                    cancelled is not None and active['cancel'] is not cancelled):
                return
            active['cancel'].set()
            self.native_signal.set()
            binding = self.bindings[conversation]
            self.session_provider.quarantine(conversation, 'interrupted')
            if not active.get('interrupt_attempted'):
                active['interrupt_attempted'] = True
                binding['transport'].send_special('C-c')

    def _cli_text(self, inputs):
        text = inputs[0]['text']
        images = [value for value in inputs[1:] if value.get('type') == 'image']
        if images:
            # Native interactive CLI image injection still requires a verified
            # attachment adapter; do not replace a vision input with guessed text.
            raise APIError(503, 'tmux 图片输入适配尚未验收，未向模型发送这条消息')
        if any(item.get('type') != 'text' for item in inputs):
            raise APIError(503, 'tmux 输入类型尚未适配')
        # A single-line JSON envelope preserves newlines in the original input
        # without injecting Enter/control bytes or relying on unverified terminal
        # bracketed-paste state. Only the separate Enter submits the prompt.
        encoded = 'Cove input JSON (use the text field as this turn input): ' + json.dumps(
            {'text': text}, ensure_ascii=False, separators=(',', ':'), allow_nan=False)
        if len(encoded.encode('utf-8')) > 64 * 1024:
            raise APIError(413, '本轮内容超过安全终端输入上限，未发送到模型')
        return encoded

    def run(self, job, cancelled):
        with self.state_lock:
            self.ensure_started()
            if not self.run_done.is_set():
                raise APIError(409, '已有正在准备或执行的 tmux 任务')
            if self.interactive and self.interactive.busy():
                raise APIError(409, '终端仍有输入或任务待确认，聊天任务暂不能写入同一输入框')
            self.run_done.clear()
        try:
            return self._run_tmux(job, cancelled)
        finally:
            self.run_done.set()

    def claim_job(self):
        with self.state_lock:
            if self.closed or (self.interactive and self.interactive.busy()):
                return None
            return self.store.claim()

    def after_job(self, job, status):
        if self.interactive:
            with self.state_lock:
                conversation = job['conversation']['id']
                try:
                    if status == 'complete':
                        self.interactive.after_app_complete(conversation)
                    elif conversation in self.interactive.states:
                        self.interactive.revoke(conversation)
                except Exception:
                    # A failed hand-over must not silently kill the Application
                    # worker, nor allow another app send into a pending editor.
                    self.interactive.revoke(conversation)
                    self.session_provider.quarantine(conversation, 'terminal handover uncertain')

    def _run_tmux(self, job, cancelled):
        if job['user'].get('handoffID'):
            raise APIError(503, 'tmux 换窗工具回执适配尚未验收；保留原会话')
        # Retains real offline audio transcription, exact health continuation,
        # quoted messages, supported text files and standing-access context.
        inputs, settings = self.prepare_inputs(job, cancelled)
        if inputs is None:
            return 'interrupted', '这次健康分享已撤回，未读取'
        if settings != {'model': self.model, 'effort': self.effort}:
            raise APIError(503, '此会话模型设置与已验证的 CLI 启动设置不同；未静默忽略模型选择')
        # Keep the independently validated image channel separate from the
        # plain-text envelope; a filename in the prompt is not a vision input.
        text = self._cli_text([item for item in inputs if item.get('type') != 'image'])
        from tmux_inputs import stage_images
        image_root = self.store.directory / 'tmux-inputs'
        image_paths = stage_images(inputs, image_root)
        if cancelled.is_set():
            return 'interrupted', None
        binding = self._session(job['conversation'])
        self.file_config(job['conversation']['id'])
        conversation = job['conversation']['id']
        transport = binding['transport']
        reader = None
        dispatched = False
        complete = False
        chunks = []
        observed_images = 0
        bootstrap = binding.get('bootstrapID')
        try:
            with self.state_lock:
                self.ensure_started()
                if cancelled.is_set():
                    return 'interrupted', None
                if self.active:
                    raise APIError(409, '已有活跃 tmux 回合')
                if not bootstrap:
                    reader = self.tailer_factory(self.codex_home, binding['rolloutPath'], binding['threadID'], arm_next=True)
                if image_paths and reader:
                    # Native user image records contain base64. Still bounded:
                    # 20 MiB vision bytes + encoding and prepared text < 32 MiB.
                    reader.MAX_LINE_BYTES = 32 * 1024 * 1024
                if bootstrap:
                    self.provisioner.begin_first_dispatch(bootstrap, job['message'])
                else:
                    self.session_provider.begin_dispatch(conversation, job['message'])
                dispatched = True
                self.active = {'conversation': conversation, 'thread': binding['threadID'],
                               'turn': None, 'cancel': cancelled, 'message': job['message'],
                               'interrupt_attempted': False}
                self._native_mcp_calls = {}
                if image_paths:
                    from tmux_images import paste_image, paste_text
                    for path in image_paths:
                        if cancelled.is_set():
                            return 'interrupted', '图片输入已停止，未自动重发'
                        paste_image(transport, path, allowed_root=image_root)
                    paste_text(transport, text)
                else:
                    transport.send_text(text)
                if cancelled.is_set():
                    return 'interrupted', '输入已写入但未提交；已请求清除，未自动重发'
                transport.send_special('Enter')
            deadline = time.monotonic() + self.timeout
            while time.monotonic() < deadline:
                if cancelled.is_set():
                    return 'interrupted', '已停止本次回复；终端执行状态需确认，未自动重发'
                if reader is None:
                    if not self.provisioner._rollouts_for(binding['threadID']):
                        time.sleep(.05)
                        continue
                    binding = self.provisioner.bind_first_rollout(bootstrap, job['conversation'], message_id=job['message'])
                    from tmux_rollout import RolloutObserver
                    reader = RolloutObserver(self.codex_home, binding['rolloutPath'], binding['threadID'], from_start=True)
                    # First session_meta may include long native instructions.
                    reader.MAX_LINE_BYTES = 32 * 1024 * 1024
                    with self.state_lock:
                        self.bindings[conversation] = binding
                for event in reader.poll():
                    with self.state_lock:
                        if cancelled.is_set():
                            return 'interrupted', None
                        active = self.active
                        if event.kind == 'turn_started':
                            if not self.store.bind_turn(job['message'], event.turn_id, binding['threadID']):
                                raise APIError(409, '原生 CLI 回合绑定冲突')
                            active['turn'] = event.turn_id
                            self.native_signal.set()
                        elif not active['turn'] or event.turn_id != active['turn']:
                            raise APIError(409, 'CLI 回合事件与当前任务不一致')
                        elif event.kind == 'message':
                            chunks.append(event.text or '')
                            if sum(map(len, chunks)) > 2_000_000:
                                raise APIError(413, '回复超出 Cove 大小限制')
                            self.store.stream(job['message'], '\n'.join(chunks))
                        elif event.kind == 'image_input':
                            observed_images += int(event.label)
                        elif event.kind == 'turn_completed':
                            if not event.projection_complete:
                                raise APIError(409, 'CLI 回复投影不完整，未标记成功')
                            if observed_images < len(image_paths):
                                raise APIError(409, '未确认全部图片进入原生视觉输入，未标记成功')
                            if not chunks and event.text:
                                chunks.append(event.text)
                            if not chunks and not self.store._message(job['assistant']).get('attachments'):
                                raise APIError(409, 'CLI 未返回可确认的回复内容，未标记成功')
                            self.store.stream(job['message'], '\n'.join(chunks))
                            if bootstrap:
                                self.provisioner.finish_first_dispatch(bootstrap, conversation, job['message'])
                                self.tmux_console.bindings[binding['sessionID']]['inputAvailable'] = self.interactive is not None
                            else:
                                self.session_provider.finish_dispatch(conversation, job['message'])
                            complete = True
                            self.active = None
                            self.native_signal.set()
                            return 'complete', None
                time.sleep(.05)
            raise APIError(504, 'tmux 回复超时，执行状态未知；请检查终端，未自动重发')
        finally:
            if reader is not None:
                reader.close()
            with self.state_lock:
                try:
                    if dispatched and not complete:
                        active = self.active
                        if active and not active.get('interrupt_attempted'):
                            active['interrupt_attempted'] = True
                            active['cancel'].set()
                            try:
                                transport.send_special('C-c')
                            except Exception:
                                # Unknown interrupt outcome is not permission
                                # to retry it or dispatch another user message.
                                pass
                        self.session_provider.quarantine(conversation, 'uncertain-turn')
                finally:
                    if self.active and self.active['message'] == job['message']:
                        self.active = None
                    self.native_signal.set()

    def terminal_state(self, conversation):
        with self.state_lock:
            binding = self.bindings.get(conversation)
            active = self.active if self.active and self.active['conversation'] == conversation else None
            return {'connected': bool(binding and not self.closed),
                    'turnID': active['turn'] if active else None, 'pendingApprovals': []}

    def context_usage(self, conversation):
        from continuity import seed_rollout_usage
        seed_rollout_usage(self.store, conversation, self.codex_home)
        result = self.store.context_usage(conversation)
        result.update(handoffAvailable=False, handoffError='tmux 换窗工具回执适配尚未验收')
        return result

    def models(self):
        raise APIError(503, 'tmux 模型目录适配尚未验收，不返回伪造列表')

    def validate_model(self, *args, **kwargs):
        raise APIError(503, 'tmux 模型切换尚未验收')

    def usage(self):
        raise APIError(503, 'tmux 额度适配尚未验收，不返回估算额度')

    def start_voice_conversation(self, *args, **kwargs):
        raise APIError(503, 'tmux 实时通话尚未适配；消息语音条是独立能力')

    def realtime_busy(self):
        return False

    def realtime_requires_reconnect(self):
        return False

    def close(self):
        with self.state_lock:
            if self.closed:
                return
            self.closed = True
            if self.active:
                self.active['cancel'].set()
            self.native_signal.set()
        if not self.run_done.wait(6):
            # Don't close a DB/transport while the worker is still unwinding.
            # Its durable busy marker prevents any restart from replaying it.
            return
        if self.file_bridge:
            self.file_bridge.close()
        if self.interactive:
            self.interactive.close()
        self.tmux_console.close()
        if self.provisioner:
            self.provisioner.close()
        self.session_provider.close()
