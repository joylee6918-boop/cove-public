"""Codex app-server JSON-lines stdio. Host-local login; only Cove thread IDs."""
import json
import codecs
import os
import queue
import shlex
import subprocess
import threading
import time
from pathlib import Path

from storage import APIError, encode, now
from files import decode_file, export_file, open_export_roots, text_file, vision_image, FILE_TOOLS, STICKER_TOOLS, TEXT_PER_FILE, TEXT_TOTAL, VISION_TOTAL
from terminal import TerminalRuntime

MCP_EVENT_WAIT = 10

HEALTH_TOOL = {'type': 'function', 'name': 'cove_health_read',
               'description': 'Read the latest health snapshot voluntarily shared by the user with Cove. Returns actual sample/capture/sync dates and missing metrics. Read only; never diagnose or write to memory automatically.',
               'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': False}}


class CodexRuntime(TerminalRuntime):
    def __init__(self, store, workspace, command='codex app-server', model=None, timeout=1800):
        self.store, self.workspace = store, str(Path(workspace).expanduser().resolve())
        self.command, self.model, self.timeout = shlex.split(command), model, timeout
        self.process = None
        self.reader = None
        self.closed = False
        self.start_lock = threading.Lock()
        self.write_lock = threading.Lock()
        self.state_lock = threading.RLock()
        self.pending, self.streams, self.loaded = {}, {}, set()
        self.next_id = 0
        self.active = None
        self.file_bridge = None
        self.file_permits = []
        self.file_signal = threading.Event()
        self.export_roots = open_export_roots(os.environ.get('COVE_EXPORT_ROOTS', ''))
        self.init_terminal()

    def _send(self, payload):
        with self.write_lock:
            self.process.stdin.write(encode(payload) + '\n'); self.process.stdin.flush()

    def request(self, method, params=None, timeout=30):
        with self.state_lock:
            self.next_id += 1; id = self.next_id
            response = queue.Queue(maxsize=1); self.pending[id] = response
        try:
            self._send({'id': id, 'method': method, 'params': params or {}})
            try:
                value = response.get(timeout=timeout)
            except queue.Empty:
                raise RuntimeError(f'Codex {method} 请求超时；执行状态未知')
            if 'error' in value:
                # Don't expose arbitrary provider messages (may contain private host paths/tokens).
                raise RuntimeError(f'Codex {method} 失败 ({value["error"].get("code", "unknown")})')
            return value['result']
        finally:
            with self.state_lock:
                self.pending.pop(id, None)

    def ensure_started(self):
        with self.start_lock:
            if self.closed:
                raise RuntimeError('Codex 运行时已关闭')
            if self.process and self.process.poll() is None:
                return
            self._stop_process()
            if not Path(self.workspace).is_dir():
                raise RuntimeError('COVE_WORKSPACE 身份目录不存在')
            # Inherit existing host-local Codex login/config; no login or credential HTTP endpoint.
            runtime_env = {key: value for key, value in os.environ.items() if key != 'COVE_TOKEN' and not key.startswith('COVE_APNS_')}
            self.process = subprocess.Popen(self.command, cwd=self.workspace, stdin=subprocess.PIPE,
                                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1, env=runtime_env)
            self.loaded.clear()
            self.reader = threading.Thread(target=self._read, args=(self.process,), daemon=True)
            self.reader.start()
            try:
                self.request('initialize', {'clientInfo': {'name': 'cove_private_ios', 'title': 'Cove', 'version': '0.1.0'},
                                            'capabilities': {'experimentalApi': True}})
                self._send({'method': 'initialized', 'params': {}})
            except Exception:
                self._stop_process()
                raise

    def _read(self, process):
        try:
            for line in process.stdout:
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if 'id' in message and 'method' not in message:
                    with self.state_lock:
                        target = self.pending.get(message['id'])
                    if target:
                        target.put_nowait(message)
                elif 'id' in message:
                    self._server_request(message)
                else:
                    p = message.get('params', {})
                    with self.state_lock:
                        if message.get('method') == 'turn/started' and self.active and self.active['thread'] == p.get('threadId'):
                            turn = p.get('turn', {}).get('id')
                            if self.active['turn'] is None and turn and self.store.bind_turn(self.active['message'], turn, self.active['thread']):
                                self.active['turn'] = turn
                        item = p.get('item', {})
                        if message.get('method') == 'item/started' and item.get('type') == 'mcpToolCall' and item.get('server') == 'cove_files' and self.active and self.active['thread'] == p.get('threadId') and self.active['turn'] == p.get('turnId'):
                            self.file_permits.append({'conversation': self.active['conversation'], 'turn': p['turnId'], 'call': item['id'], 'tool': item['tool'], 'arguments': item['arguments'], 'used': False})
                            self.file_signal.set()
                        target = self.streams.get(p.get('threadId'))
                    self._terminal_notification(message)
                    if target:
                        target.put(message)
        finally:
            self._clear_approvals('Codex 连接断开', send=False)
            with self.state_lock:
                for target in self.pending.values():
                    if target.empty():
                        target.put({'error': {'code': 'disconnected'}})
                for target in self.streams.values():
                    target.put({'method': 'cove/disconnected', 'params': {}})

    def _server_request(self, message):
        p, method = message.get('params', {}), message['method']
        with self.state_lock:
            active = self.active
        if method == 'item/tool/call' and p.get('tool') == HEALTH_TOOL['name'] and active and p.get('threadId') == active['thread']:
            # turn/start notifications can precede its response, but must carry the active turn.
            turn = active.get('turn')
            health = None
            if turn is None or p.get('turnId') != turn:
                result = {'success': False, 'contentItems': [{'type': 'inputText', 'text': 'Inactive Cove turn'}]}
            elif p.get('arguments') not in ({}, None):
                result = {'success': False, 'contentItems': [{'type': 'inputText', 'text': 'Expected empty arguments'}]}
            else:
                health, version = self.store.health_for_tool()
                present = {m['id'] for m in health['snapshot']['metrics']} if health['snapshot'] else set()
                health['missingMetricIDs'] = [id for id in ('sleep', 'steps', 'heartRate', 'restingHeartRate', 'hrv', 'activeEnergy', 'exercise') if id not in present]
                result = {'success': True, 'contentItems': [{'type': 'inputText', 'text': encode(health)}]}
            self._send({'id': message['id'], 'result': result})
            if health is not None:
                self.store.mark_health_read(health, version)
            return
        # The owner explicitly authorizes automatic MCP approval in bypass mode.
        # Ordinary questions still use the existing client flow.
        if os.getenv('COVE_APPROVAL_POLICY') == 'never' and method in ('tool/requestUserInput', 'item/tool/requestUserInput'):
            answers = {}
            questions = p.get('questions') or []
            for question in questions:
                consent = (str(question.get('header', '')) + ' ' + str(question.get('question', ''))).casefold()
                if not any(word in consent for word in ('tool', 'mcp', 'connector', '工具', '连接器')):
                    break
                labels = [option.get('label', '') for option in question.get('options') or []]
                accepted = next((label for label in labels if label.casefold() in ('accept', 'approve', 'allow', 'yes', '允许', '批准', '同意')), None)
                if not question.get('id') or accepted is None:
                    break
                answers[question['id']] = {'answers': [accepted]}
            if questions and len(answers) == len(questions):
                self._send({'id': message['id'], 'result': {'answers': answers}})
                return
        if self._queue_approval(message):
            return
        # Unsupported requests and stale approvals stay denied.
        if method in ('item/commandExecution/requestApproval', 'item/fileChange/requestApproval'):
            result = {'decision': 'decline'}
        elif method == 'item/permissions/requestApproval':
            result = {'permissions': {}, 'scope': 'turn'}
        elif method == 'mcpServer/elicitation/request':
            schema = p.get('requestedSchema') or {}
            if os.getenv('COVE_APPROVAL_POLICY') == 'never' and p.get('mode') in ('form', 'openai/form', 'openaiForm') and not schema.get('required'):
                result = {'action': 'accept', 'content': {}}
            else:
                result = {'action': 'cancel', 'content': None}
        elif method == 'item/tool/requestUserInput':
            result = {'answers': {}}
        elif method == 'item/tool/call':
            result = {'success': False, 'contentItems': [{'type': 'inputText', 'text': 'Tool unavailable in Cove'}]}
        else:
            self._send({'id': message['id'], 'error': {'code': -32601, 'message': 'Unsupported Cove client request'}})
            return
        self._send({'id': message['id'], 'result': result})

    def file_config(self, conversation):
        if self.file_bridge is None:
            from file_bridge import FileBridge
            self.file_bridge = FileBridge(self)
        return self.file_bridge.config(conversation)

    def mcp_file_call(self, conversation, tool, arguments):
        if tool not in {entry['name'] for entry in FILE_TOOLS} or not isinstance(arguments, dict):
            raise APIError(400, '文件工具参数无效')
        # Accept only an actual MCP item/started from this current thread+turn.
        # This also prevents stale MCP subprocesses from attaching to another turn.
        deadline = time.monotonic() + MCP_EVENT_WAIT
        while time.monotonic() < deadline:
            with self.state_lock:
                active = self.active
                if not active or active['conversation'] != conversation or active['cancel'].is_set():
                    raise APIError(409, '没有对应的活跃 Cove 回合')
                matches = [p for p in self.file_permits if p['conversation'] == conversation and p['turn'] == active['turn'] and p['tool'] == tool and p['arguments'] == arguments]
                permit = next((p for p in matches if not p['used']), matches[-1] if matches else None)
                if permit:
                    permit['used'] = True
                    message, turn, call = active['message'], active['turn'], permit['call']
                    break
                self.file_signal.clear()
            self.file_signal.wait(min(.1, deadline-time.monotonic()))
        else:
            raise APIError(409, '文件请求没有对应的当前回合工具事件')
        # Recheck under the runtime lock through the commit, so cancellation or a
        # turn switch cannot race a callback after its matching permit was found.
        with self.state_lock:
            active = self.active
            if not active or active['conversation'] != conversation or active['message'] != message or active['turn'] != turn or active['cancel'].is_set():
                raise APIError(409, '没有对应的活跃 Cove 回合')
            if tool in {entry['name'] for entry in STICKER_TOOLS}:
                return self.store.assistant_sticker_tool(message, turn, call, tool, arguments)
            filename, mime, data = decode_file(arguments) if tool == 'cove_create_file' else export_file(arguments, self.export_roots)
            return self.store.create_assistant_file(message, turn, call, filename, mime, data)

    def usage(self):
        self.ensure_started()
        result = self.request('account/rateLimits/read')
        # limitName labels quota buckets, not the selected conversation model.
        # Never substitute a model-specific bucket (e.g. Spark) for total Codex.
        buckets = result.get('rateLimitsByLimitId') or {}
        bucket = buckets.get('codex')
        if bucket is None:
            legacy = result.get('rateLimits')
            if legacy and legacy.get('limitId') in (None, 'codex'):
                bucket = legacy
        bucket = bucket or {}
        windows, plan = [], bucket.get('planType')
        from datetime import datetime, timezone
        import math
        seen = set()
        for name in ('primary', 'secondary'):
            window = bucket.get(name)
            if not isinstance(window, dict):
                continue
            duration, percent = window.get('windowDurationMins'), window.get('usedPercent')
            if duration not in (300, 10080) or duration in seen:
                continue
            if isinstance(percent, bool) or not isinstance(percent, (float, int)) or not math.isfinite(percent) or not 0 <= percent <= 100:
                continue
            resets = window.get('resetsAt')
            try:
                reset_date = datetime.fromtimestamp(resets, timezone.utc).isoformat().replace('+00:00', 'Z') if resets is not None else None
            except (TypeError, ValueError, OverflowError, OSError):
                reset_date = None
            seen.add(duration)
            windows.append({'id': 'codex-5h' if duration == 300 else 'codex-weekly',
                            'title': '5 小时窗口' if duration == 300 else '周额度',
                            'usedPercent': percent, 'resetsAt': reset_date})
        windows.sort(key=lambda window: window['id'] != 'codex-5h')
        if plan is None:
            account = self.request('account/read', {'refreshToken': False}).get('account')
            plan = account.get('planType') if account else None
        return {'plan': plan, 'updatedAt': now(), 'windows': windows, 'error': None if windows else '账号未返回额度窗口'}

    def interrupt(self, conversation, cancelled=None):
        with self.state_lock:
            active = self.active
            if not active or active['conversation'] != conversation or (cancelled is not None and active['cancel'] is not cancelled):
                return
            active['cancel'].set()
            thread, turn = active['thread'], active.get('turn')
            self._clear_approvals('回合已停止', send=True)
        if turn:
            self.request('turn/interrupt', {'threadId': thread, 'turnId': turn})

    def run(self, job, cancelled):
        try:
            return self._run(job, cancelled)
        except Exception:
            # A dispatch/stream failure can leave a turn alive. Never let the next
            # message steer that uncertain turn; stop only our own subprocess.
            with self.start_lock:
                self._stop_process()
            raise

    def _run(self, job, cancelled):
        self.ensure_started()
        conversation = job['conversation']; thread = conversation['thread']
        if not thread:
            params = {'cwd': self.workspace, 'approvalPolicy': os.getenv('COVE_APPROVAL_POLICY', 'on-request'), 'sandbox': os.getenv('COVE_SANDBOX', 'read-only'),
                      'dynamicTools': [HEALTH_TOOL], 'ephemeral': False,
                      'config': self.file_config(conversation['id']),
                      'developerInstructions': 'This is Cove, a self-hosted personal assistant app. Continue the identity and memory instructions in the configured workspace. cove_health_read is the only way to mark uploaded health as read. Read health only when relevant; never pretend a sync means you read it. No autonomous wakes. Do not claim unavailable tool actions succeeded.'}
            if self.model:
                params['model'] = self.model
            result = self.request('thread/start', params, timeout=90)
            thread = result['thread']['id']; self.store.bind_thread(conversation['id'], thread); self.loaded.add(thread)
        elif thread not in self.loaded:
            self.request('thread/resume', {'threadId': thread, 'cwd': self.workspace, 'approvalPolicy': os.getenv('COVE_APPROVAL_POLICY', 'on-request'), 'sandbox': os.getenv('COVE_SANDBOX', 'read-only'), 'config': self.file_config(conversation['id'])}, timeout=90); self.loaded.add(thread)
        events = queue.Queue()
        with self.state_lock:
            self.streams[thread] = events
            self.active = {'conversation': conversation['id'], 'thread': thread, 'turn': None, 'cancel': cancelled, 'message': job['message']}
            self.file_permits.clear()
            self.terminal_budget = 0; self.command_output.clear(); self.terminal_items.clear()
        try:
            if cancelled.is_set():
                return 'interrupted', None
            text = job['user']['text']
            if job['user'].get('replyTo'):
                with self.store.lock:
                    quoted = self.store._message(job['user']['replyTo'])
                text = '[引用 ' + quoted['role'] + '：' + quoted['text'][:4000] + ']\n' + text
            health = self.store.health()
            if health['snapshot'] and not health['readAt']:
                text += '\n[Cove：有尚未读取的健康快照；如与对话相关，可调用 cove_health_read。]'
            inputs = [{'type': 'text', 'text': text}]
            text_budget, vision_budget = TEXT_TOTAL, VISION_TOTAL
            for file_meta in job['user'].get('attachments', []):
                attachment = self.store.attachment(file_meta['id'])
                label = '\n[Cove附件：'+attachment['filename']+'；attachmentID='+attachment['id']+'；'+attachment['mime']+'；'+str(len(attachment['data']))+' bytes]\n'
                if vision_image(attachment) and len(attachment['data']) <= vision_budget:
                    import base64
                    inputs.append({'type': 'image', 'url': 'data:' + attachment['mime'] + ';base64,' + base64.b64encode(attachment['data']).decode()})
                    vision_budget -= len(attachment['data'])
                    inputs[0]['text'] += label + '图片已作为视觉输入。'
                elif text_file(attachment) and text_budget > 0:
                    limit = min(TEXT_PER_FILE, text_budget)
                    try:
                        content = codecs.getincrementaldecoder('utf-8')().decode(attachment['data'][:limit], final=False)
                    except UnicodeError:
                        inputs[0]['text'] += label+'仅完成文件传输；没有可确认的UTF-8文本，不要声称已读文件内容。'; continue
                    if '\x00' in content:
                        inputs[0]['text'] += label+'仅完成二进制文件传输，未读取内容。'; continue
                    inputs[0]['text'] += label+content
                    text_budget -= len(content.encode('utf-8'))
                    if len(attachment['data']) > limit:
                        inputs[0]['text'] += '\n[内容已截断，不能声称读取整个文件。]'
                else:
                    inputs[0]['text'] += label+'仅完成文件传输（PDF/Office/压缩包/二进制或超出本轮读取预算），没有读取内容，不要声称已读。'
            settings = self.store.terminal_settings(conversation['id'], self.model, self.effort)
            turn_params = {'threadId': thread, 'input': inputs, 'approvalPolicy': os.getenv('COVE_APPROVAL_POLICY', 'on-request')}
            for key in ('model', 'effort'):
                if settings.get(key):
                    turn_params[key] = settings[key]
            result = self.request('turn/start', turn_params, timeout=90)
            turn = result['turn']['id']
            if not self.store.bind_turn(job['message'], turn, thread):
                raise RuntimeError('Codex 回合绑定冲突；执行状态未知，未自动重发')
            with self.state_lock:
                self.active['turn'] = turn
            if cancelled.is_set():
                self.request('turn/interrupt', {'threadId': thread, 'turnId': turn})
            items = {}; phases = {}; deadline = time.monotonic() + self.timeout
            while time.monotonic() < deadline:
                try:
                    event = events.get(timeout=min(1, max(.01, deadline-time.monotonic())))
                except queue.Empty:
                    continue
                method, p = event['method'], event.get('params', {})
                if method == 'cove/disconnected':
                    raise RuntimeError('Codex 连接断开；执行状态未知，未自动重发')
                if p.get('threadId') != thread or p.get('turnId', p.get('turn', {}).get('id')) != turn:
                    continue
                if method == 'item/agentMessage/delta':
                    id = p['itemId']; items[id] = items.get(id, '') + p['delta']
                elif method in ('item/started', 'item/completed') and p.get('item', {}).get('type') == 'agentMessage':
                    item = p['item']; id = item['id']; phases[id] = item.get('phase')
                    if method == 'item/completed':
                        items[id] = item['text']
                elif method == 'turn/completed':
                    for item in p['turn'].get('items', []):
                        if item.get('type') == 'agentMessage':
                            items[item['id']] = item['text']; phases[item['id']] = item.get('phase')
                    self.store.stream(job['message'], self._text(items, phases))
                    status = p['turn']['status']; error = p['turn'].get('error')
                    return {'completed': 'complete', 'interrupted': 'interrupted', 'failed': 'failed'}.get(status, 'failed'), ('Codex 回合失败' if error or status not in ('completed', 'interrupted') else None)
                elif method == 'error' and not p.get('willRetry'):
                    # Wait for authoritative turn/completed when possible; keep error visible on timeout.
                    continue
                content = self._text(items, phases)
                if len(content) > 2_000_000:
                    raise RuntimeError('回复超出 Cove 大小限制')
                if method in ('item/agentMessage/delta', 'item/completed'):
                    self.store.stream(job['message'], content)
            self.request('turn/interrupt', {'threadId': thread, 'turnId': turn})
            raise RuntimeError('回复超时，已请求中断；未自动重发')
        finally:
            with self.state_lock:
                self._clear_approvals('回合已结束', send=True)
                self.streams.pop(thread, None); self.active = None
                self.file_permits.clear(); self.file_signal.set()

    @staticmethod
    def _text(items, phases):
        final = [text for id, text in items.items() if phases.get(id) == 'final_answer']
        return '\n\n'.join(final or items.values())

    def _stop_process(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill(); self.process.wait(timeout=5)
        if self.reader:
            self.reader.join(timeout=5)
        if self.process:
            self.process.stdin.close(); self.process.stdout.close()
        self.process = None
        self.reader = None
        self.loaded.clear()

    def close(self):
        with self.start_lock:
            self.closed = True
            self._stop_process()
        if self.file_bridge:
            self.file_bridge.close(); self.file_bridge = None
        for _, descriptor in self.export_roots:
            os.close(descriptor)
        self.export_roots.clear()
