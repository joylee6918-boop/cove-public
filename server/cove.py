#!/usr/bin/env python3
"""Run: COVE_TOKEN=... COVE_WORKSPACE=/identity python3 server/cove.py"""
import hmac
import json
import os
import re
import threading
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from runtime import CodexRuntime
from storage import APIError, Store, encode, now
from files import MAX_ATTACHMENT, MAX_BODY, decode_file, disposition
from pulse_read import dashboard as pulse_dashboard, snapshot as read_pulse_snapshot, PulseReadError
from memory_calendar import snapshot as read_memory_calendar, CalendarError as MemoryCalendarError
from app_events import AppEvents, MAX_BODY as APP_EVENT_MAX_BODY
from travel_bridge import TravelBridge
from wallet import Wallet
ID = re.compile(r'^[A-Za-z0-9_.-]{1,160}$')


def string(value, label, maximum=160):
    if not isinstance(value, str) or not value or len(value) > maximum:
        raise APIError(400, label + ' 无效')
    return value


def identifier(value):
    if not isinstance(value, str) or not ID.fullmatch(value):
        raise APIError(400, 'ID 无效')
    return value


def date(value):
    if not isinstance(value, str) or len(value) > 64:
        raise APIError(400, '日期无效')
    try:
        parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
        if parsed.tzinfo is None:
            raise ValueError()
    except ValueError:
        raise APIError(400, '日期必须是带时区的 ISO8601')
    return value


def health_snapshot(snapshot):
    from data_access import upload_snapshot
    return upload_snapshot(snapshot)


def pulse_snapshot(path):
    try:
        return read_pulse_snapshot(path)
    except PulseReadError as exc:
        raise APIError(503, str(exc))


class Application:
    def __init__(self, store, token, runtime=None, pulse_path=None, push=None, shortcuts_token=''):
        if not token or len(token) < 24:
            raise ValueError('COVE_TOKEN must contain at least 24 characters')
        if shortcuts_token and (len(shortcuts_token) < 32 or len(shortcuts_token) > 256
                                or not shortcuts_token.isascii() or not shortcuts_token.isprintable()
                                or any(c.isspace() for c in shortcuts_token)
                                or hmac.compare_digest(shortcuts_token, token)):
            raise ValueError('COVE_SHORTCUTS_TOKEN must be a separate 32–256 character ASCII secret')
        self.shortcuts_token = shortcuts_token
        self.app_events = AppEvents(store.directory, configured=bool(shortcuts_token))
        self.store, self.token, self.runtime = store, token, runtime
        self.travel = TravelBridge(store)
        self.wallet = Wallet(store.directory)
        from cove_location import CoveLocation
        self.location = CoveLocation(store)
        if runtime is not None:
            runtime.location = self.location
            runtime.app_events = self.app_events
            runtime.travel = self.travel
            runtime.wallet = self.wallet
        self.pulse_path, self.push = pulse_path, push
        self.wake = threading.Event(); self.stop = threading.Event()
        self.active_lock = threading.Lock(); self.active = None
        self.terminal_lock = threading.Lock()
        self.shell_lock = threading.Lock()
        self.shell_owners = {}
        self.worker = threading.Thread(target=self._work, daemon=True)
        self.worker.start()

    def _work(self):
        while not self.stop.is_set():
            self.location.drain()
            for request, scope in self.location.data.pending_notifications():
                if self.push:
                    try:
                        self.push(scope['conversationID'], {'locationRequest': True}, self.store.notification_devices())
                    except Exception:
                        pass  # notification is a hint; foreground polling is authoritative
            # Claim + active publication is atomic relative to interruption of queued turns.
            with self.active_lock:
                if self.runtime and getattr(self.runtime, 'realtime_requires_reconnect', lambda: False)():
                    self.runtime.recover_voice_transport()
                voice_busy = self.runtime and getattr(self.runtime, 'realtime_busy', lambda: False)()
                claim = getattr(self.runtime, 'claim_job', self.store.claim)
                job = None if voice_busy else claim()
                if job:
                    cancelled = threading.Event(); self.active = (job['user']['conversationID'], cancelled)
            if not job:
                self.wake.wait(1); self.wake.clear(); continue
            status = 'failed'; error = None
            try:
                if not self.runtime:
                    raise RuntimeError('Codex 运行时未配置')
                status, error = self.runtime.run(job, cancelled)
            except Exception as exc:
                error = exc.message if isinstance(exc, APIError) else str(exc) if isinstance(exc, RuntimeError) else '回复处理失败；执行状态未知，未自动重发'
            finally:
                self.store.finish(job['message'], status, error)
                after_job = getattr(self.runtime, 'after_job', None)
                if after_job:
                    try:
                        after_job(job, status)
                    except Exception as hook_error:
                        print('Cove after-job hook failed: '+type(hook_error).__name__, flush=True)
                with self.active_lock:
                    self.active = None
            # Reply durable before push. Push is optional and never the delivery source.
            if status == 'complete' and self.push:
                try:
                    assistant = self.store._message(job['assistant'])
                    if assistant and not assistant.get('hidden'):
                        self.push(job['user']['conversationID'], assistant, self.store.notification_devices())
                except Exception:
                    pass

    def interrupt(self, conversation):
        cancelled = None
        with self.active_lock:
            with self.store.lock:
                handoff = self.store.db.execute("SELECT target FROM handoffs WHERE source=? AND json_extract(body,'$.status')='restoring' ORDER BY rowid DESC LIMIT 1", (conversation,)).fetchone()
                if handoff:
                    conversation = handoff[0]
            self.store.cancel_queued(conversation)
            if self.active and self.active[0] == conversation:
                cancelled = self.active[1]; cancelled.set()
        if self.runtime and cancelled is not None:
            self.runtime.interrupt(conversation, cancelled)

    def terminal_input(self, body):
        identifier(body.get('id')); conversation = identifier(body.get('conversationID'))
        text = body.get('text')
        if not isinstance(text, str) or not text.strip() or len(text) > 100_000:
            raise APIError(400, '指令为空或过长')
        with self.terminal_lock:
            old, _ = self.store.terminal_control(body)
            if old:
                return old
            if not text.lstrip().startswith('/'):
                message = self.store.accept({k: body[k] for k in ('id', 'conversationID', 'text')})
                self.wake.set()
                return {'ok': True, 'kind': 'message', 'message': message}
            parts = text.strip().split()
            command = parts[0]
            if command == '/stop' and len(parts) == 1:
                result, fresh = self.store.terminal_control(body, {'ok': True, 'kind': 'stop'})
                if fresh:
                    self.interrupt(conversation)
                return result
            if command == '/help' and len(parts) == 1:
                return self.store.terminal_control(body, {'ok': True, 'kind': 'help', 'text': '普通指令进入当前会话队列；/stop 停止当前会话并取消其排队消息；/model <模型> [推理强度] 设置下一回合；/help 查看帮助。'})[0]
            if command == '/model':
                if len(parts) == 1:
                    settings = self.store.terminal_settings(conversation, getattr(self.runtime, 'model', None), getattr(self.runtime, 'effort', None))
                    return self.store.terminal_control(body, dict(settings, ok=True, kind='model'))[0]
                if len(parts) in (2, 3):
                    if not self.runtime:
                        raise APIError(503, 'Codex 运行时未配置')
                    model, effort = self.runtime.validate_model(parts[1], parts[2] if len(parts) == 3 else None)
                    return self.store.terminal_control(body, {'ok': True, 'kind': 'model', 'model': model, 'effort': effort}, model, effort)[0]
            raise APIError(400, '未知控制指令；使用 /help')

    def tmux_request(self, operation, body):
        console = getattr(self.runtime, 'tmux_console', None)
        if console is None:
            raise APIError(503, '当前聊天运行时尚未切换 tmux；不会另开 Shell')
        fields = {'attach': {'conversationID'},
                  'capture': {'conversationID', 'sessionID'},
                  'input': {'conversationID', 'sessionID', 'requestID', 'text'},
                  'key': {'conversationID', 'sessionID', 'requestID', 'key'},
                  'terminate': {'conversationID', 'sessionID', 'requestID'},
                  'recover': {'conversationID', 'sessionID', 'requestID'}}
        if operation not in fields or set(body) != fields[operation]:
            raise APIError(400, 'tmux 参数无效')
        conversation = identifier(body.get('conversationID'))
        if operation == 'attach' and callable(getattr(self.runtime, 'attach_console', None)):
            self.runtime.attach_console(conversation)
        with console.lock:
            with self.store.lock:
                thread = self.store.conversation(conversation)['thread']
            if operation == 'attach':
                snapshot = console.attach(conversation)
                bound_thread = snapshot['threadID']
            else:
                session = identifier(body.get('sessionID'))
                bound_thread = console.bound_thread(conversation, session)
            if not thread or bound_thread != thread:
                raise APIError(409, 'tmux 与当前聊天线程不一致，未执行操作')
            if operation == 'attach':
                return snapshot
            if operation == 'capture':
                return console.capture(conversation, session)
            if operation == 'recover':
                recover = getattr(self.runtime, 'recover_console', None)
                if not callable(recover):
                    raise APIError(503, '当前运行时不支持原生恢复')
                return recover(conversation, session, identifier(body.get('requestID')))
            return console.control(conversation, session, body.get('requestID'), operation,
                                   body.get('text') if operation == 'input' else body.get('key'))

    def shell_request(self, operation, body):
        if not self.runtime or not hasattr(self.runtime, 'shell_console'):
            raise APIError(503, '当前服务尚未启用 Shell')
        conversation = identifier(body.get('conversationID'))
        with self.store.lock:
            self.store.conversation(conversation)
        if operation == 'start':
            if set(body) - {'conversationID', 'rows', 'cols'}:
                raise APIError(400, 'Shell 启动参数无效')
            rows, cols = body.get('rows', 30), body.get('cols', 100)
            if (type(rows) is not int or not 4 <= rows <= 300 or
                    type(cols) is not int or not 20 <= cols <= 500):
                raise APIError(400, 'Shell 尺寸无效')
            self.runtime.ensure_started()
            with self.shell_lock:
                if self.runtime.shell_console is None:
                    from shell_console import ShellConsole
                    self.runtime.shell_console = ShellConsole(self.runtime, self.runtime.workspace)
                # Re-entering the same conversation's Shell view must attach
                # to its existing PTY, not create a second shell or return 409.
                # Never attach a PTY owned by a different conversation.
                shell = self.runtime.shell_console
                with shell.lock:
                    for existing_id, owner in self.shell_owners.items():
                        if owner != conversation or existing_id not in shell.sessions:
                            continue
                        snapshot = shell.status(existing_id)
                        if snapshot['state'] == 'running':
                            return snapshot
                result = shell.start(rows, cols)
                self.shell_owners[result['id']] = conversation
                # Ownership only retained for sessions the bounded manager knows.
                self.shell_owners = {key: owner for key, owner in self.shell_owners.items()
                                     if key in self.runtime.shell_console.sessions}
                return result
        session = identifier(body.get('sessionID'))
        with self.shell_lock:
            if self.shell_owners.get(session) != conversation or not self.runtime.shell_console:
                raise APIError(404, '这个对话没有对应 Shell')
            shell = self.runtime.shell_console
        if operation == 'events':
            if set(body) - {'conversationID','sessionID','after'}:
                raise APIError(400, 'Shell 日志参数无效')
            try:
                after = int(body.get('after', 0))
            except (TypeError, ValueError):
                raise APIError(400, 'Shell 游标无效')
            return shell.status(session, after)
        if operation == 'write':
            if set(body) - {'conversationID','sessionID','dataBase64','closeStdin'}:
                raise APIError(400, 'Shell 输入参数无效')
            return shell.write(session, body.get('dataBase64'), body.get('closeStdin', False))
        if operation == 'resize':
            if set(body) != {'conversationID','sessionID','rows','cols'}:
                raise APIError(400, 'Shell 尺寸参数无效')
            return shell.resize(session, body.get('rows'), body.get('cols'))
        if operation == 'terminate':
            if set(body) != {'conversationID','sessionID'}:
                raise APIError(400, 'Shell 结束参数无效')
            return shell.terminate(session)
        raise APIError(404, 'Shell 操作不存在')

    def realtime_request(self, operation, body):
        if not self.runtime or not hasattr(self.runtime, 'start_voice_conversation'):
            raise APIError(503, '当前服务尚未启用 Codex 实时语音。')
        conversation = identifier(body.get('conversationID'))
        with self.store.lock:
            thread = self.store.conversation(conversation)['thread']
        if operation == 'start':
            if set(body) - {'conversationID', 'voice', 'sdp'}:
                raise APIError(400, '通话参数无效')
            # Serialize against the job worker publishing a new active turn.
            with self.active_lock:
                with self.store.lock:
                    busy = self.store.db.execute("SELECT 1 FROM jobs WHERE state IN ('queued','running') LIMIT 1").fetchone()
                if busy or self.active or self.runtime.realtime_busy():
                    raise APIError(409, '请先等当前回复结束或停止回复，再开始通话。')
                transport = {'type': 'webrtc', 'sdp': body['sdp']} if 'sdp' in body else None
                return self.runtime.start_voice_conversation(conversation, body.get('voice'), transport)
        session = identifier(body.get('sessionID'))
        if not thread:
            raise APIError(409, '这个对话尚未建立 Codex 会话。')
        if operation == 'audio':
            if set(body) != {'conversationID', 'sessionID', 'audio'} or not isinstance(body.get('audio'), dict):
                raise APIError(400, '语音分片参数无效')
            audio = body['audio']
            if set(audio) - {'data','sampleRate','numChannels','samplesPerChannel'}:
                raise APIError(400, '语音格式参数无效')
            return self.runtime.realtime_append_audio(thread, session, audio.get('data'), audio.get('sampleRate'), audio.get('numChannels'), audio.get('samplesPerChannel'))
        if operation == 'stop':
            if set(body) != {'conversationID', 'sessionID'}:
                raise APIError(400, '停止通话参数无效')
            result = self.runtime.realtime_stop(thread, session)
            self.wake.set()
            return result
        if operation == 'events':
            if set(body) - {'conversationID','sessionID','after'}:
                raise APIError(400, '通话日志参数无效')
            try:
                after = int(body.get('after', 0))
            except (ValueError, TypeError):
                raise APIError(400, '通话日志游标无效')
            if after < 0 or after > 2**63 - 1:
                raise APIError(400, '通话日志游标无效')
            return self.runtime.realtime_poll(thread, session, after)
        raise APIError(404, '通话操作不存在')

    def close(self):
        self.stop.set(); self.wake.set()
        with self.active_lock:
            if self.active:
                self.active[1].set()
        if self.runtime:
            self.runtime.close()
        self.worker.join(timeout=6)
        if self.worker.is_alive():
            # main must not close Store while a worker can still commit. Durable
            # job/dispatch intent will fence recovery if the process is stopped.
            raise RuntimeError('Cove worker 尚未退出，未关闭仍可能被使用的存储')
        self.app_events.close()
        self.wallet.close()
        self.location.data.close()

    def handler(self):
        app = self
        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def log_message(self, *_):
                pass  # No chat, health, tokens, or URLs in ordinary access logs.

            def setup(self):
                # Raw attachment uploads may legitimately spend longer than an
                # ordinary JSON request on a mobile/iCloud connection.
                super().setup(); self.connection.settimeout(180)

            def output(self, status, value, mime='application/json; charset=utf-8', headers=None):
                data = value if isinstance(value, bytes) else encode(value).encode()
                self.send_response(status)
                self.send_header('Content-Type', mime); self.send_header('Content-Length', str(len(data)))
                self.send_header('Cache-Control', 'no-store'); self.send_header('X-Content-Type-Options', 'nosniff')
                for name, value in (headers or {}).items():
                    self.send_header(name, value)
                self.end_headers(); self.wfile.write(data)

            def body(self, maximum=MAX_BODY):
                if self.headers.get('Transfer-Encoding'):
                    raise APIError(400, '不支持分块请求')
                try:
                    length = int(self.headers.get('Content-Length', '0'))
                except ValueError:
                    raise APIError(400, 'Content-Length 无效')
                if length <= 0 or length > maximum:
                    raise APIError(413, '请求大小超出限制')
                try:
                    raw = self.rfile.read(length)
                    if len(raw) != length:
                        raise ValueError()
                    value = json.loads(raw, parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
                    if not isinstance(value, dict):
                        raise ValueError()
                    return value
                except (ValueError, UnicodeError):
                    raise APIError(400, 'JSON 请求无效')

            def raw_body(self, maximum):
                if self.headers.get('Transfer-Encoding'):
                    raise APIError(400, '不支持分块请求')
                supplied = self.headers.get('Content-Length')
                if supplied is None:
                    raise APIError(400, 'Content-Length 缺失')
                try:
                    length = int(supplied)
                except ValueError:
                    raise APIError(400, 'Content-Length 无效')
                if length < 0 or length > maximum:
                    raise APIError(413, '请求大小超出限制')
                data = self.rfile.read(length)
                if len(data) != length:
                    raise APIError(400, '文件上传未完成')
                return data

            def route(self):
                url = urlsplit(self.path); path = url.path; method = self.command
                if method == 'GET' and path == '/health':
                    return {'ok': True, 'service': 'cove'}
                authorization = self.headers.get('Authorization', '')
                # The shortcut credential is intentionally not added to owner auth.
                if method == 'POST' and path == '/v1/app-events':
                    if not app.shortcuts_token or not hmac.compare_digest(
                            authorization.encode(), ('Bearer ' + app.shortcuts_token).encode()):
                        raise APIError(401, '快捷指令专用密钥无效或尚未配置')
                    if url.query:
                        raise APIError(400, 'App 事件接口不接受查询参数')
                    return app.app_events.ingest(self.body(APP_EVENT_MAX_BODY))
                if not hmac.compare_digest(authorization.encode(), ('Bearer ' + app.token).encode()):
                    raise APIError(401, '连接密钥无效')
                if path == '/v1/personal-ledger' or path.startswith('/v1/personal-ledger/'):
                    from personal_ledger import MAX_UPLOAD
                    if url.query:
                        raise APIError(400, '个人账本接口不接受查询参数')
                    body = self.body(MAX_UPLOAD if path == '/v1/personal-ledger' else 16384) if method == 'POST' else None
                    # Serialize the actual response flush with revocation, not just the read.
                    with app.store.lock:
                        if path == '/v1/personal-ledger' and method == 'DELETE':
                            result = app.store.delete_personal_ledger()
                        else:
                            app.store._require_data_access()
                            if path == '/v1/personal-ledger' and method == 'POST':
                                result = app.store.upload_personal_ledger(body)
                            elif path == '/v1/personal-ledger' and method == 'GET':
                                result = app.store.personal_ledger()
                            elif path == '/v1/personal-ledger/commands' and method == 'GET':
                                result = app.store.personal_ledger(pending_only=True)
                            else:
                                ledger_parts = path.strip('/').split('/')
                                if method != 'POST' or len(ledger_parts) != 5 or ledger_parts[:3] != ['v1', 'personal-ledger', 'commands'] or ledger_parts[4] != 'ack':
                                    raise APIError(404, '个人账本接口不存在')
                                result = app.store.acknowledge_personal_ledger(ledger_parts[3], body)
                        self.output(200, result)
                    return None
                if path == '/v1/wallet' or path.startswith('/v1/wallet/'):
                    if url.query:
                        raise APIError(400, '钱包接口不接受查询参数')
                    if method == 'GET' and path == '/v1/wallet':
                        return app.wallet.snapshot()
                    operations = {'/v1/wallet/credit': 'credit', '/v1/wallet/request': 'request',
                                  '/v1/wallet/review': 'review'}
                    if method == 'POST' and path in operations:
                        return app.wallet.mutate(operations[path], self.body(2048))
                    raise APIError(404, '钱包接口不存在')
                if method == 'POST' and path == '/v1/aisay-wake':
                    if self.client_address[0] not in ('127.0.0.1', '::1'):
                        raise APIError(403, 'AISay ingress is local only')
                    from cove_aisay import handle as handle_aisay
                    return handle_aisay(app, self.body(4096))
                if path == '/v1/data-access' and method in ('GET', 'POST'):
                    if url.query:
                        raise APIError(400, '持续读取接口不接受查询参数')
                    return app.store.data_access() if method == 'GET' else app.store.set_data_access(self.body(1024))
                if method == 'GET' and path == '/v1/app-events':
                    query = parse_qs(url.query, keep_blank_values=True)
                    if set(query) != {'day', 'timeZone'} or any(len(v) != 1 for v in query.values()):
                        raise APIError(400, '请各提供一个 day 和 timeZone')
                    return app.app_events.summary(query['day'][0], query['timeZone'][0])
                if method == 'GET' and path == '/v1/memory/calendar':
                    query = parse_qs(url.query, keep_blank_values=True)
                    if set(query) != {'month'} or len(query['month']) != 1:
                        raise APIError(400, '请只提供一个 YYYY-MM 格式的 month')
                    try:
                        return read_memory_calendar(query['month'][0])
                    except MemoryCalendarError as exc:
                        raise APIError(exc.status, exc.message) from None
                if path == '/v1/toy/session' and method in ('GET', 'POST'):
                    if url.query:
                        raise APIError(400, '玩具授权接口不接受查询参数')
                    return app.store.toy_status() if method == 'GET' else app.store.grant_toy_session(self.body(1024))
                if method == 'DELETE' and path.startswith('/v1/toy/session/'):
                    if url.query:
                        raise APIError(400, '收回玩具授权不接受查询参数')
                    return app.store.revoke_toy_session(identifier(path.rsplit('/', 1)[1]))
                if method == 'GET' and path == '/v1/toy/commands':
                    query = parse_qs(url.query, keep_blank_values=True)
                    if set(query) != {'sessionID', 'after'} or any(len(value) != 1 for value in query.values()):
                        raise APIError(400, '玩具指令查询参数无效')
                    try:
                        after = int(query['after'][0])
                    except ValueError:
                        raise APIError(400, '玩具指令游标无效')
                    return app.store.poll_toy_commands(identifier(query['sessionID'][0]), after)
                if method == 'POST' and path.startswith('/v1/toy/commands/') and path.endswith('/ack'):
                    parts = path.strip('/').split('/')
                    if len(parts) != 5:
                        raise APIError(404, '玩具指令接口不存在')
                    body = self.body(4096)
                    session = identifier(body.pop('sessionID', None))
                    return app.store.acknowledge_toy_command(session, identifier(parts[3]), body)
                if method == 'GET' and path == '/v1/conversations':
                    return app.store.conversations()
                if method == 'POST' and path == '/v1/conversations':
                    body = self.body(); id = body.get('id')
                    return {'conversation': app.store.create_conversation(identifier(id) if id is not None else None)}
                parts = path.strip('/').split('/')
                if method == 'GET' and path == '/v1/travel':
                    query = parse_qs(url.query, keep_blank_values=True)
                    if set(query) != {'conversationID'} or len(query['conversationID']) != 1:
                        raise APIError(400, '旅行会话参数无效')
                    result = app.travel.snapshot(identifier(query['conversationID'][0]))
                    app.wake.set()
                    return result
                if method == 'POST' and len(parts) == 5 and parts[:3] == ['v1','travel','invitations'] and parts[4] == 'respond':
                    body = self.body()
                    if not isinstance(body, dict) or set(body) != {'conversationID','decision','requestID'}:
                        raise APIError(400, '旅行邀请参数无效')
                    result = app.travel.respond(identifier(body['conversationID']), identifier(parts[3]), body['decision'], identifier(body['requestID']))
                    app.wake.set()
                    return result
                if method == 'GET' and len(parts)==4 and parts[:3]==['v1','travel','journeys']:
                    query=parse_qs(url.query,keep_blank_values=True)
                    if set(query)-{'conversationID','after'} or 'conversationID' not in query or any(len(v)!=1 for v in query.values()):
                        raise APIError(400,'旅行详情参数无效')
                    try:after=int(query.get('after',['0'])[0])
                    except ValueError:raise APIError(400,'旅行分页参数无效')
                    return app.travel.journal(identifier(query['conversationID'][0]),identifier(parts[3]),after)
                if method == 'POST' and path == '/v1/travel/cover':
                    return app.travel.cover(self.body())
                if method == 'POST' and path == '/v1/travel/control':
                    return app.travel.control(self.body())
                if len(parts) == 4 and parts[:2] == ['v1', 'conversations'] and parts[3] in ('context', 'handoff'):
                    conversation = identifier(parts[2])
                    if method == 'GET' and parts[3] == 'context':
                        return app.runtime.context_usage(conversation) if app.runtime and hasattr(app.runtime, 'context_usage') else app.store.context_usage(conversation)
                    if method == 'GET' and parts[3] == 'handoff':
                        query = parse_qs(url.query)
                        request_id = query.get('id', [None])[0]
                        value = app.store.handoff(conversation, identifier(request_id) if request_id is not None else None)
                        if value is None:
                            self.output(200, None); return None
                        return value
                    if method == 'POST' and parts[3] == 'handoff':
                        result = app.store.start_handoff(conversation, identifier(self.body().get('id')))
                        app.wake.set()
                        return result
                if len(parts) == 4 and parts[:2] == ['v1', 'conversations'] and parts[3] == 'collar':
                    conversation = identifier(parts[2])
                    client = getattr(app.runtime, 'collar_client', None)
                    configured = bool(client and client.configured)
                    if method == 'GET':
                        return app.store.collar_permissions(conversation, configured)
                    if method == 'POST':
                        return app.store.set_collar_permissions(conversation, self.body(), configured)
                if path.startswith('/v1/location/'):
                    if url.query:
                        raise APIError(400, '位置接口不接受查询参数')
                    result = app.location.route(path[len('/v1/location/'):], method, self.body(8192) if method == 'POST' else None)
                    app.wake.set()
                    return result
                if method == 'POST' and path == '/v1/device-actions/device':
                    return app.store.register_device_actions(self.body(4096))
                if len(parts) >= 4 and parts[:2] == ['v1', 'conversations'] and parts[3] == 'device-actions':
                    conversation = identifier(parts[2])
                    if method == 'GET' and len(parts) == 4:
                        query = parse_qs(url.query)
                        if set(query) != {'deviceID'} or len(query['deviceID']) != 1:
                            raise APIError(400, '需要指定手机 deviceID')
                        return app.store.device_actions(conversation, identifier(query['deviceID'][0]))
                    if method == 'POST' and len(parts) == 6 and parts[5] == 'claim':
                        return app.store.claim_device_action(conversation, identifier(parts[4]), self.body(4096))
                    if method == 'POST' and len(parts) == 6 and parts[5] == 'response':
                        result = app.store.respond_device_action(conversation, identifier(parts[4]), self.body(128 * 1024))
                        app.wake.set()
                        return result
                if len(parts) >= 4 and parts[:2] == ['v1', 'conversations'] and parts[3] == 'health-requests':
                    conversation = identifier(parts[2])
                    if method == 'GET' and len(parts) == 4:
                        return app.store.health_requests(conversation)
                    if method == 'POST' and len(parts) == 6 and parts[5] == 'response':
                        result = app.store.respond_health_request(conversation, identifier(parts[4]), self.body())
                        app.wake.set()
                        return result
                if method == 'GET' and path == '/v1/terminal':
                    query = parse_qs(url.query); conversation = identifier(query.get('conversationID', [''])[0])
                    try:
                        after = int(query.get('after', ['0'])[0])
                        if after < 0 or after > 2**63-1:
                            raise ValueError()
                    except ValueError:
                        raise APIError(400, '终端游标无效')
                    tail = query.get('tail', ['0'])[0]
                    if tail not in ('0', '1') or (tail == '1' and after != 0):
                        raise APIError(400, 'tail=1 仅用于 after=0 的最新日志')
                    result = app.store.terminal_poll(conversation, after, tail=tail == '1')
                    result.update(app.store.terminal_settings(conversation, getattr(app.runtime, 'model', None), getattr(app.runtime, 'effort', None)))
                    result.update(app.runtime.terminal_state(conversation) if app.runtime else {'connected': False, 'turnID': None, 'pendingApprovals': []})
                    return result
                if path.startswith('/v1/tmux/'):
                    operation = path.rsplit('/', 1)[-1]
                    if path != '/v1/tmux/' + operation:
                        raise APIError(404, 'tmux 操作不存在')
                    if method == 'GET' and operation == 'capture':
                        query = parse_qs(url.query, keep_blank_values=True)
                        if any(len(values) != 1 for values in query.values()):
                            raise APIError(400, '重复的 tmux 参数')
                        return app.tmux_request(operation, {key: values[0] for key, values in query.items()})
                    if method == 'POST' and operation in ('attach', 'input', 'key', 'terminate', 'recover'):
                        if url.query:
                            raise APIError(400, 'tmux 写操作不接受查询参数')
                        return app.tmux_request(operation, self.body())
                    raise APIError(404, 'tmux 操作不存在')
                if path.startswith('/v1/shell/'):
                    operation = path.rsplit('/', 1)[-1]
                    if method == 'GET' and operation == 'events':
                        query = parse_qs(url.query, keep_blank_values=True)
                        if any(len(values) != 1 for values in query.values()):
                            raise APIError(400, '重复的 Shell 参数')
                        return app.shell_request(operation, {key: values[0] for key, values in query.items()})
                    if method == 'POST' and operation in ('start', 'write', 'resize', 'terminate'):
                        return app.shell_request(operation, self.body())
                    raise APIError(404, 'Shell 操作不存在')
                if path.startswith('/v1/realtime/'):
                    operation = path.rsplit('/', 1)[-1]
                    if method == 'GET' and operation == 'events':
                        query = parse_qs(url.query, keep_blank_values=True)
                        if any(len(values) != 1 for values in query.values()):
                            raise APIError(400, '重复的通话参数')
                        return app.realtime_request(operation, {key: values[0] for key, values in query.items()})
                    if method == 'POST' and operation in ('start', 'audio', 'stop'):
                        return app.realtime_request(operation, self.body())
                    raise APIError(404, '通话操作不存在')
                if method == 'GET' and path == '/v1/terminal/models':
                    if not app.runtime:
                        raise APIError(503, 'Codex 运行时未配置')
                    return app.runtime.models()
                if method == 'POST' and path == '/v1/terminal/input':
                    return app.terminal_input(self.body())
                if method == 'POST' and path == '/v1/terminal/model':
                    body = self.body(); conversation = identifier(body.get('conversationID'))
                    with app.store.lock:
                        app.store.conversation(conversation)
                    if not app.runtime:
                        raise APIError(503, 'Codex 运行时未配置')
                    model, effort = app.runtime.validate_model(string(body.get('model'), '模型'), string(body.get('effort'), '推理强度', 40))
                    app.store.set_terminal_model(conversation, model, effort)
                    return {'ok': True, 'model': model, 'effort': effort}
                if method == 'POST' and path == '/v1/terminal/approval':
                    body = self.body()
                    if not app.runtime:
                        raise APIError(503, 'Codex 运行时未配置')
                    return app.runtime.resolve_approval(identifier(body.get('conversationID')), identifier(body.get('approvalID')), identifier(body.get('threadID')), identifier(body.get('turnID')), body.get('decision'))
                if method == 'GET' and path == '/v1/messages/search':
                    query = parse_qs(url.query, keep_blank_values=True)
                    if 'q' not in query or set(query)-{'q','before','limit','date','timeZone'} or any(len(v)!=1 for v in query.values()):
                        raise APIError(400, '搜索参数无效')
                    return app.store.search_messages(query['q'][0], query.get('before',[None])[0], query.get('limit',[20])[0],
                                                     query.get('date',[None])[0], query.get('timeZone',[None])[0])
                if method == 'GET' and path == '/v1/messages/calendar':
                    query = parse_qs(url.query, keep_blank_values=True)
                    if set(query)-{'month','timeZone','q'} or 'month' not in query or 'timeZone' not in query or any(len(v)!=1 for v in query.values()):
                        raise APIError(400, '日历参数无效')
                    return app.store.message_calendar(query['month'][0], query['timeZone'][0], query.get('q',[''])[0])
                if method == 'GET' and path == '/v1/messages':
                    query = parse_qs(url.query)
                    conversation = identifier(query.get('conversationID', [''])[0])
                    try:
                        after = int(query.get('after', ['0'])[0])
                        if after < 0 or after > 2**63 - 1:
                            raise ValueError()
                    except ValueError:
                        raise APIError(400, '同步游标无效')
                    return app.store.poll(conversation, after)
                if method == 'POST' and path == '/v1/messages':
                    body = self.body(); identifier(body.get('id')); identifier(body.get('conversationID'))
                    text = body.get('text')
                    if not isinstance(text, str) or len(text) > 100_000 or (not text.strip() and not app.store.attachment_ids(body)):
                        raise APIError(400, '消息为空或过长')
                    for key in ('replyTo', 'attachmentID', 'stickerID'):
                        if body.get(key) is not None:
                            identifier(body[key])
                    for attachment_id in app.store.attachment_ids(body):
                        identifier(attachment_id)
                    message = app.store.accept(body); app.wake.set()
                    return {'message': message}
                if method == 'POST' and path == '/v1/messages/reaction':
                    body = self.body()
                    return {'message': app.store.set_reaction(identifier(body.get('conversationID')), identifier(body.get('messageID')), body.get('isLiked'))}
                if method == 'POST' and path == '/v1/interrupt':
                    body = self.body(); app.interrupt(identifier(body.get('conversationID')))
                    return {'ok': True}
                if method == 'POST' and path == '/v1/attachments':
                    content_type = self.headers.get('Content-Type', '').split(';', 1)[0].strip().lower()
                    if content_type == 'application/octet-stream':
                        query = parse_qs(url.query, keep_blank_values=True)
                        if set(query) != {'filename', 'mime'} or any(len(value) != 1 for value in query.values()):
                            raise APIError(400, '附件元数据无效')
                        filename, mime = query['filename'][0], query['mime'][0]
                        data = self.raw_body(MAX_ATTACHMENT)
                    else:
                        filename, mime, data = decode_file(self.body())
                    return app.store.add_attachment(filename, mime, data)
                if method == 'GET' and path == '/v1/stickers':
                    return app.store.stickers()
                if method == 'POST' and path == '/v1/stickers':
                    body = self.body()
                    if set(body) != {'attachmentID', 'label'}:
                        raise APIError(400, '保存表情包需 attachmentID 和 label')
                    return {'sticker': app.store.save_user_sticker(identifier(body.get('attachmentID')), body.get('label'))}
                if method == 'GET' and path.startswith('/v1/attachments/'):
                    attachment = app.store.attachment(identifier(path.rsplit('/', 1)[1]))
                    self.output(200, attachment['data'], attachment['mime'], {'Content-Disposition': disposition(attachment['filename'])}); return None
                if method == 'GET' and path == '/v1/pulse':
                    return pulse_snapshot(app.pulse_path)
                if method == 'GET' and path == '/v1/pulse/dashboard':
                    try:
                        return pulse_dashboard(app.pulse_path, str(app.store.directory / 'cove.sqlite3'))
                    except PulseReadError as exc:
                        raise APIError(503, str(exc))
                if method == 'GET' and path == '/v1/usage':
                    try:
                        if not app.runtime:
                            raise RuntimeError('Codex 运行时未配置')
                        return app.runtime.usage()
                    except Exception:
                        return {'plan': None, 'updatedAt': now(), 'windows': [], 'error': '暂时无法读取 Codex 真实订阅额度'}
                if method == 'POST' and path == '/v1/health':
                    body = self.body(2 * 1024 * 1024)
                    if set(body)-{'snapshot', 'standingAccess'} or ('standingAccess' in body and type(body['standingAccess']) is not bool):
                        raise APIError(400, '健康上传参数无效')
                    snapshot = health_snapshot(body.get('snapshot'))
                    return {'ok': True, 'syncedAt': app.store.upload_health(snapshot, standing=body.get('standingAccess', False))}
                if method == 'GET' and path == '/v1/health':
                    return app.store.health()
                if method == 'GET' and path == '/v1/health/uploads':
                    query = parse_qs(url.query, keep_blank_values=True)
                    if set(query) != {'capturedAt'} or len(query['capturedAt']) != 1:
                        raise APIError(400, '健康上传查询参数无效')
                    return app.store.health_upload(query['capturedAt'][0])
                if method == 'GET' and path == '/v1/health/history':
                    try:
                        days = int(parse_qs(url.query).get('days', ['7'])[0])
                        if days < 1 or days > 31:
                            raise ValueError()
                    except ValueError:
                        raise APIError(400, '历史天数必须为 1 至 31')
                    return app.store.health_history(days)
                if method == 'DELETE' and path == '/v1/health':
                    app.store.delete_health(); return {'ok': True}
                if method in ('POST', 'DELETE') and path == '/v1/devices':
                    body = self.body(); token = body.get('token')
                    if not isinstance(token, str) or not re.fullmatch(r'[a-fA-F0-9]{64,200}', token):
                        raise APIError(400, 'APNs 设备 token 无效')
                    if method == 'POST':
                        preview_mode = body.get('previewMode', 'generic')
                        if not isinstance(preview_mode, str) or preview_mode not in ('generic', 'content'):
                            raise APIError(400, '通知预览设置无效')
                        app.store.register_device(token.lower(), preview_mode)
                    else:
                        app.store.unregister_device(token.lower())
                    return {'ok': True}
                raise APIError(404, '接口不存在')

            def handle_request(self):
                try:
                    result = self.route()
                    if result is not None:
                        self.output(200, result)
                except APIError as exc:
                    self.close_connection = True
                    self.output(exc.status, {'error': exc.message})
                except (BrokenPipeError, ConnectionError, TimeoutError):
                    self.close_connection = True
                except Exception:
                    self.close_connection = True
                    self.output(500, {'error': '服务处理失败'})

            do_GET = do_POST = do_DELETE = handle_request
        return Handler


def configured_runtime(store, workspace):
    mode = os.environ.get('COVE_RUNTIME', 'app-server')
    if mode == 'app-server':
        return CodexRuntime(store, workspace, os.environ.get('COVE_CODEX_COMMAND', 'codex app-server'),
                            os.environ.get('COVE_MODEL') or None, int(os.environ.get('COVE_TURN_TIMEOUT', '1800')))
    if mode != 'tmux':
        raise ValueError('COVE_RUNTIME must be app-server or tmux; no automatic fallback')
    from tmux_registry import TmuxRegistry
    from tmux_runtime import TmuxRuntime
    home, binary = os.environ.get('CODEX_HOME'), os.environ.get('COVE_CODEX_BINARY')
    if not home or not binary:
        raise ValueError('tmux requires explicit CODEX_HOME and COVE_CODEX_BINARY')
    registry = TmuxRegistry(db_path=store.directory / 'tmux-registry.sqlite3',
                            codex_binary=binary, codex_home=home)
    runtime = TmuxRuntime(store, workspace, session_provider=registry, codex_home=home,
                       model=os.environ.get('COVE_MODEL') or None,
                       timeout=int(os.environ.get('COVE_TURN_TIMEOUT', '1800')),
                       enable_terminal_input=True)
    from tmux_provision import TmuxProvisioner
    socket_dir = store.directory / 'tmux-sockets'
    socket_dir.mkdir(mode=0o700, exist_ok=True)
    runtime.provisioner = TmuxProvisioner(registry=registry, socket_dir=socket_dir,
                                        workspace=Path(workspace).resolve(), launch_config=runtime.launch_config)
    return runtime


def main():
    os.umask(0o077)
    token = os.environ.get('COVE_TOKEN', '')
    # Do not inherit this ingest-only credential into Codex/MCP subprocesses.
    shortcuts_token = os.environ.pop('COVE_SHORTCUTS_TOKEN', '')
    workspace = os.environ.get('COVE_WORKSPACE')
    if not workspace:
        raise SystemExit('Set COVE_WORKSPACE to the dedicated Assistant identity workspace')
    store = Store(os.environ.get('COVE_DATA_DIR', '~/.local/share/cove'))
    runtime = configured_runtime(store, workspace)
    from notifications import configured_push
    app = Application(store, token, runtime, os.environ.get('COVE_PULSE_PATH'), configured_push(),
                      shortcuts_token=shortcuts_token)
    server = ThreadingHTTPServer((os.environ.get('COVE_HOST', '127.0.0.1'), int(os.environ.get('COVE_PORT', '8796'))), app.handler())
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close(); app.close(); store.close()


if __name__ == '__main__':
    main()
