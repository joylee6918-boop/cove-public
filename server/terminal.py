"""Conversation console: real app-server events and single-turn approvals only."""
import json
import os
import re
import threading
import time
import uuid
from datetime import datetime, timezone, timedelta

from storage import APIError, now


def redact(value):
    text = str(value)
    for key, secret in os.environ.items():
        if len(secret) >= 8 and any(word in key.upper() for word in ('TOKEN', 'SECRET', 'PASSWORD', 'API_KEY')):
            text = text.replace(secret, '[redacted]')
    text = re.sub(r'(?i)(Bearer\s+)[^\s\"\'<>]+', r'\1[redacted]', text)
    text = re.sub(r'(?i)([\"\']?(?:access_token|refresh_token|id_token|api_key|password|secret|authorization)[\"\']?\s*[:=]\s*)(\"[^\"]*\"|\'[^\']*\'|[^\s,;]+)', r'\1[redacted]', text)
    text = re.sub(r'\b(?:sk-[A-Za-z0-9_-]{12,}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)\b', '[redacted]', text)
    # Strip terminal controls, retaining ordinary line breaks/tabs.
    text = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', text)
    return ''.join(c for c in text if c in '\n\t' or ord(c) >= 32)[:16000]


class TerminalRuntime:
    def init_terminal(self):
        self.approvals = {}
        self.approval_timeout = min(600, max(1, float(os.getenv('COVE_APPROVAL_TIMEOUT', '120'))))
        self.effort = os.getenv('COVE_EFFORT', 'high')
        self.terminal_budget = 0
        self.command_output = {}
        self.terminal_items = {}

    def models(self):
        self.ensure_started()
        models, seen, cursor = [], set(), None
        for _ in range(20):
            result = self.request('model/list', {'limit': 100, 'includeHidden': False, **({'cursor': cursor} if cursor else {})})
            for m in result.get('data', []):
                if m.get('hidden') or not isinstance(m.get('model'), str) or m['model'] in seen:
                    continue
                seen.add(m['model'])
                models.append({'id': m['id'], 'model': m['model'], 'displayName': m['displayName'],
                               'supportedEfforts': [e['reasoningEffort'] for e in m['supportedReasoningEfforts']],
                               'defaultEffort': m['defaultReasoningEffort']})
            next_cursor = result.get('nextCursor')
            if not next_cursor:
                return {'models': models, 'updatedAt': now()}
            if next_cursor == cursor:
                break
            cursor = next_cursor
        raise RuntimeError('Codex 模型列表分页未完成')

    def validate_model(self, model, effort=None):
        catalog = self.models()['models']
        selected = next((m for m in catalog if model in (m['model'], m['id'])), None)
        if not selected:
            raise APIError(400, '模型不在当前 Codex 实际列表中')
        effort = effort or selected['defaultEffort']
        if effort not in selected['supportedEfforts']:
            raise APIError(400, '该模型不支持此推理强度')
        return selected['model'], effort

    def terminal_state(self, conversation):
        with self.state_lock:
            active = self.active if self.active and self.active['conversation'] == conversation else None
            pending = [dict(a['public']) for a in self.approvals.values() if a['public']['conversationID'] == conversation]
            connected = bool(self.process and self.process.poll() is None and not self.closed)
            return {'connected': connected, 'turnID': active['turn'] if active else None,
                    'pendingApprovals': pending}

    def _console(self, kind, text, item=None):
        active = self.active
        if not active or self.terminal_budget >= 1_000_000:
            return
        self.terminal_budget += len(str(text)) + 100
        self.store.terminal_event(active['conversation'], kind, text, active['thread'], active['turn'], item)

    def _terminal_notification(self, message):
        p, method = message.get('params', {}), message.get('method')
        with self.state_lock:
            a = self.active
            if a and p.get('threadId') == a['thread'] and method == 'serverRequest/resolved':
                for key, value in list(self.approvals.items()):
                    if value['requestID'] == p.get('requestId'):
                        self._remove_approval(key, '审批已由运行时结束')
                return
            if not a or p.get('threadId') != a['thread'] or p.get('turnId', p.get('turn', {}).get('id')) != a['turn']:
                return
            if method == 'turn/started':
                self._console('turn', '回合开始')
            elif method == 'turn/completed':
                self._console('turn', '回合结束：' + str(p['turn'].get('status')))
                self._clear_approvals('回合结束', send=False)
            elif method == 'turn/plan/updated':
                lines = []
                if p.get('explanation'):
                    lines.append(str(p['explanation']))
                for step in p.get('plan', [])[:30]:
                    if isinstance(step, dict) and step.get('step'):
                        marker = {'completed': '✓', 'inProgress': '▶', 'pending': '·'}.get(step.get('status'), '·')
                        lines.append(marker + ' ' + str(step['step']))
                if lines:
                    self._console('plan', '\n'.join(lines))
            elif method == 'item/commandExecution/outputDelta':
                # Buffer whole lines so credential redaction cannot be bypassed by chunk boundaries.
                key = p.get('itemId'); record = self.command_output.setdefault(key, {'tail': '', 'bytes': 0, 'discard': False})
                if record['bytes'] >= 64000:
                    return
                record['tail'] += p.get('delta', '')
                while '\n' in record['tail']:
                    line, record['tail'] = record['tail'].split('\n', 1)
                    if not record['discard'] and len(line) <= 16000:
                        self._console('output', line, key); record['bytes'] += len(line)
                    record['discard'] = False
                if len(record['tail']) > 16000:
                    record['tail'] = ''; record['discard'] = True
            elif method == 'item/commandExecution/terminalInteraction':
                # Do not persist stdin text: it can contain passwords or tokens.
                self._console('command', '已向运行中的命令发送输入', p.get('itemId'))
            elif method == 'item/mcpToolCall/progress':
                if p.get('message'):
                    self._console('tool', p['message'], p.get('itemId'))
            elif method in ('item/started', 'item/completed'):
                item = p.get('item', {}); key = item.get('id'); done = method == 'item/completed'
                if not done and item.get('type') in ('commandExecution', 'fileChange'):
                    self.terminal_items[key] = {k: redact(json.dumps(item[k], ensure_ascii=False) if k == 'changes' else item[k]) for k in ('command', 'cwd', 'changes') if item.get(k) is not None}
                if item.get('type') == 'commandExecution':
                    self._console('command', ('完成：' if done else '$ ') + item.get('command', '') + ('\nexitCode=' + str(item.get('exitCode')) if done else '') + '\ncwd=' + str(item.get('cwd', '')), key)
                    if done:
                        output = self.command_output.pop(key, None)
                        if output:
                            if output['tail'] and not output['discard'] and output['bytes'] < 64000:
                                self._console('output', output['tail'], key)
                        elif item.get('aggregatedOutput'):
                            self._console('output', item['aggregatedOutput'], key)
                elif item.get('type') == 'fileChange':
                    self._console('fileChange', ('完成：' if done else '文件更改：') + json.dumps(item.get('changes', []), ensure_ascii=False), key)
                elif item.get('type') in ('mcpToolCall', 'dynamicToolCall'):
                    # Never serialize tool arguments/results: may contain health, bytes or credentials.
                    suffix = ' · 开始'
                    if done:
                        result = item.get('result')
                        failed = bool(item.get('error')) or str(item.get('status', '')).casefold() in ('failed', 'error') or (isinstance(result, dict) and result.get('isError') is True)
                        succeeded = isinstance(result, dict) and result.get('isError') is False
                        suffix = ' · 失败' if failed else (' · 成功' if succeeded else ' · 已结束（结果未记录）')
                    self._console('tool', str(item.get('server', '')) + ' ' + str(item.get('tool', '')) + suffix, key)
                elif item.get('type') == 'agentMessage' and done:
                    self._console('message', item.get('text', ''), key)
                elif item.get('type') == 'reasoning':
                    # Never expose private reasoning or summaries. The lifecycle
                    # is still useful execution telemetry, like the CLI spinner.
                    self._console('status', '思考完成' if done else '正在思考…', key)
                elif item.get('type') == 'plan':
                    self._console('plan', item.get('text', '') if done else '正在整理执行计划…', key)
                elif item.get('type') == 'webSearch':
                    self._console('status', '网络搜索完成' if done else '正在搜索网络…', key)
                elif item.get('type') == 'imageView':
                    self._console('status', '图片读取完成' if done else '正在读取图片…', key)
                elif item.get('type') == 'imageGeneration':
                    self._console('status', '图片生成完成' if done else '正在生成图片…', key)
                elif item.get('type') == 'contextCompaction':
                    self._console('status', '上下文整理完成' if done else '正在整理上下文…', key)
                elif item.get('type') in ('collabAgentToolCall', 'subAgentActivity'):
                    self._console('status', '协作任务完成' if done else '正在处理协作任务…', key)
                elif item.get('type') == 'sleep':
                    self._console('status', '等待结束' if done else '正在等待…', key)
                elif item.get('type') == 'agentMessage' and not done:
                    self._console('status', '正在组织回复…', key)
            elif method == 'error':
                self._console('error', 'Codex 执行出错' + ('，正在重试' if p.get('willRetry') else ''))

    def _queue_approval(self, message):
        p, method = message.get('params', {}), message['method']
        kind = {'item/commandExecution/requestApproval': 'command', 'item/fileChange/requestApproval': 'fileChange',
                'item/permissions/requestApproval': 'permissions'}.get(method)
        if not kind:
            return False
        with self.state_lock:
            a = self.active
            if not a or a['cancel'].is_set() or a['thread'] != p.get('threadId') or not a['turn'] or a['turn'] != p.get('turnId'):
                return False
            key = str(uuid.uuid4()); created = now()
            details = {k: p[k] for k in ('additionalPermissions', 'networkApprovalContext', 'permissions', 'grantRoot') if p.get(k) is not None}
            cached = self.terminal_items.get(p.get('itemId'), {})
            detail_text = redact(json.dumps(details, ensure_ascii=False)) if details else ''
            if cached.get('changes'):
                detail_text += '\n'+cached['changes']
            choices = ['accept', 'decline']
            if kind == 'command' and p.get('availableDecisions') is not None:
                choices = [d for d in choices if d in p['availableDecisions']]
                if 'decline' not in choices:
                    # Unsupported amendment-only decisions are safely denied, never fabricated.
                    return False
            public = {'id': key, 'conversationID': a['conversation'], 'kind': kind, 'threadID': a['thread'], 'turnID': a['turn'],
                      'itemID': p.get('itemId', ''), 'command': redact(p.get('command') or cached.get('command')) if p.get('command') or cached.get('command') else None,
                      'cwd': redact(p.get('cwd') or cached.get('cwd')) if p.get('cwd') or cached.get('cwd') else None, 'reason': redact(p['reason']) if p.get('reason') else None,
                      'details': redact(detail_text) if detail_text else None, 'decisions': choices,
                      'createdAt': created, 'expiresAt': (datetime.now(timezone.utc)+timedelta(seconds=self.approval_timeout)).isoformat().replace('+00:00', 'Z')}
            timer = threading.Timer(self.approval_timeout, self._expire_approval, args=(key,)); timer.daemon = True
            self.approvals[key] = {'public': public, 'requestID': message['id'], 'method': method, 'params': p,
                                   'deadline': time.monotonic()+self.approval_timeout, 'timer': timer}
            self._console('approval', '待审批：'+kind+' '+(public['command'] or public['reason'] or ''), p.get('itemId'))
            timer.start()
            return True

    def _remove_approval(self, key, reason):
        entry = self.approvals.pop(key, None)
        if entry:
            entry['timer'].cancel()
            self._console('approval', reason, entry['public']['itemID'])

    @staticmethod
    def _approval_result(entry, decision):
        if entry['method'] == 'item/permissions/requestApproval':
            return {'permissions': entry['params'].get('permissions', {}) if decision == 'accept' else {}, 'scope': 'turn'}
        return {'decision': decision}

    def resolve_approval(self, conversation, approval, thread, turn, decision):
        with self.state_lock:
            entry = self.approvals.get(approval); a = self.active
            if not entry or not a or a['cancel'].is_set() or entry['deadline'] <= time.monotonic() or a['conversation'] != conversation or a['thread'] != thread or a['turn'] != turn or entry['public']['threadID'] != thread or entry['public']['turnID'] != turn:
                raise APIError(409, '审批已失效或不属于当前 Cove 回合')
            if decision not in entry['public']['decisions']:
                raise APIError(400, '审批决定无效')
            try:
                self._send({'id': entry['requestID'], 'result': self._approval_result(entry, decision)})
            except Exception:
                self._remove_approval(approval, '审批发送失败')
                if self.process and self.process.poll() is None:
                    self.process.terminate()
                raise APIError(503, '审批响应发送失败；执行状态未知')
            self._remove_approval(approval, '审批：'+decision)
        return {'ok': True}

    def _expire_approval(self, key):
        with self.state_lock:
            entry = self.approvals.get(key)
            if not entry:
                return
            try:
                self._send({'id': entry['requestID'], 'result': self._approval_result(entry, 'decline')})
            except Exception:
                if self.process and self.process.poll() is None:
                    self.process.terminate()
            self._remove_approval(key, '审批超时，已拒绝')

    def _clear_approvals(self, reason, send=False):
        with self.state_lock:
            for key, entry in list(self.approvals.items()):
                if send:
                    try:
                        self._send({'id': entry['requestID'], 'result': self._approval_result(entry, 'decline')})
                    except Exception:
                        pass
                self._remove_approval(key, reason)
