#!/usr/bin/env python3
"""Run: COVE_TOKEN=... COVE_WORKSPACE=/identity python3 server/cove.py"""
import hmac
import json
import math
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
from files import MAX_BODY, decode_file, disposition
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
    if not isinstance(snapshot, dict):
        raise APIError(400, '健康快照无效')
    date(snapshot.get('capturedAt'))
    metrics = snapshot.get('metrics')
    if not isinstance(metrics, list) or len(metrics) > 64:
        raise APIError(400, '健康指标无效')
    accepted = {'sleep', 'steps', 'heartRate', 'restingHeartRate', 'hrv', 'activeEnergy', 'exercise'}
    seen = set(); normalized = []
    for metric in metrics:
        if not isinstance(metric, dict) or metric.get('id') not in accepted or metric['id'] in seen:
            raise APIError(400, '健康指标 ID 无效或重复')
        seen.add(metric['id'])
        value = metric.get('value')
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
            raise APIError(400, '健康指标数值无效')
        detail = metric.get('detail')
        if detail is not None and (not isinstance(detail, str) or len(detail) > 4000):
            raise APIError(400, '健康详情无效')
        normalized.append({'id': metric['id'], 'title': string(metric.get('title'), '健康标题', 80), 'value': value,
                           'unit': string(metric.get('unit'), '健康单位', 32), 'sampledAt': date(metric.get('sampledAt')), 'detail': detail})
    return {'capturedAt': snapshot['capturedAt'], 'metrics': normalized}


def pulse_snapshot(path):
    if not path:
        raise APIError(503, '尚未配置 Pulse 状态文件')
    try:
        source = Path(path).expanduser()
        if source.stat().st_size > 2 * 1024 * 1024:
            raise ValueError()
        state = json.loads(source.read_text())
        timestamp = state.get('updatedAt', state.get('updated_at'))
        if isinstance(timestamp, (int, float)) and not isinstance(timestamp, bool):
            timestamp = datetime.fromtimestamp(timestamp, timezone.utc).isoformat().replace('+00:00', 'Z')
        date(timestamp)
        labels = {'energy': '精力', 'focus': '专注', 'calm': '平静', 'charge': '蓄能', 'libido': '欲望', 'intimacy': '亲近',
                  'attachment': '依恋', 'curiosity': '好奇', 'reflection': '反思', 'touch': '触觉', 'smell': '嗅觉', 'taste': '味觉', 'sound': '听觉'}
        result = {'updatedAt': timestamp, 'summary': state.get('summary') or (state.get('last_signal') or {}).get('label') or ''}
        for section in ('desires', 'physical', 'senses'):
            entries = state.get(section) or {}
            if isinstance(entries, list):
                entries = {m['id']: m for m in entries}
            metrics = []
            for key, metric in entries.items():
                value = metric.get('value') if isinstance(metric, dict) else metric
                if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
                    continue
                detail = metric.get('detail', metric.get('label', '')) if isinstance(metric, dict) else ''
                metrics.append({'id': key, 'label': labels.get(key, key), 'value': min(1., max(0., value)), 'detail': str(detail)})
            result[section] = metrics
        return result
    except (OSError, ValueError, TypeError, KeyError, AttributeError, APIError):
        raise APIError(503, 'Pulse 状态文件不可读取或缺少真实记录时间')


class Application:
    def __init__(self, store, token, runtime=None, pulse_path=None, push=None):
        if not token or len(token) < 24:
            raise ValueError('COVE_TOKEN must contain at least 24 characters')
        self.store, self.token, self.runtime = store, token, runtime
        self.pulse_path, self.push = pulse_path, push
        self.wake = threading.Event(); self.stop = threading.Event()
        self.active_lock = threading.Lock(); self.active = None
        self.terminal_lock = threading.Lock()
        self.worker = threading.Thread(target=self._work, daemon=True)
        self.worker.start()

    def _work(self):
        while not self.stop.is_set():
            # Claim + active publication is atomic relative to interruption of queued turns.
            with self.active_lock:
                job = self.store.claim()
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
                error = str(exc) if isinstance(exc, RuntimeError) else '回复处理失败；执行状态未知，未自动重发'
            finally:
                self.store.finish(job['message'], status, error)
                with self.active_lock:
                    self.active = None
            # Reply durable before push. Push is optional and never the delivery source.
            if status == 'complete' and self.push:
                try:
                    self.push(job['user']['conversationID'], job['assistant'], self.store.device_tokens())
                except Exception:
                    pass

    def interrupt(self, conversation):
        cancelled = None
        with self.active_lock:
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

    def close(self):
        self.stop.set(); self.wake.set()
        with self.active_lock:
            if self.active:
                self.active[1].set()
        if self.runtime:
            self.runtime.close()
        self.worker.join(timeout=6)

    def handler(self):
        app = self
        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def log_message(self, *_):
                pass  # No chat, health, tokens, or URLs in ordinary access logs.

            def setup(self):
                super().setup(); self.connection.settimeout(20)

            def output(self, status, value, mime='application/json; charset=utf-8', headers=None):
                data = value if isinstance(value, bytes) else encode(value).encode()
                self.send_response(status)
                self.send_header('Content-Type', mime); self.send_header('Content-Length', str(len(data)))
                self.send_header('Cache-Control', 'no-store'); self.send_header('X-Content-Type-Options', 'nosniff')
                for name, value in (headers or {}).items():
                    self.send_header(name, value)
                self.end_headers(); self.wfile.write(data)

            def body(self):
                if self.headers.get('Transfer-Encoding'):
                    raise APIError(400, '不支持分块请求')
                try:
                    length = int(self.headers.get('Content-Length', '0'))
                except ValueError:
                    raise APIError(400, 'Content-Length 无效')
                if length <= 0 or length > MAX_BODY:
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

            def route(self):
                url = urlsplit(self.path); path = url.path; method = self.command
                if method == 'GET' and path == '/health':
                    return {'ok': True, 'service': 'cove'}
                authorization = self.headers.get('Authorization', '')
                if not hmac.compare_digest(authorization.encode(), ('Bearer ' + app.token).encode()):
                    raise APIError(401, '连接密钥无效')
                if method == 'GET' and path == '/v1/conversations':
                    return app.store.conversations()
                if method == 'POST' and path == '/v1/conversations':
                    body = self.body(); id = body.get('id')
                    return {'conversation': app.store.create_conversation(identifier(id) if id is not None else None)}
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
                if method == 'GET' and path == '/v1/usage':
                    try:
                        if not app.runtime:
                            raise RuntimeError('Codex 运行时未配置')
                        return app.runtime.usage()
                    except Exception:
                        return {'plan': None, 'updatedAt': now(), 'windows': [], 'error': '暂时无法读取 Codex 真实订阅额度'}
                if method == 'POST' and path == '/v1/health':
                    snapshot = health_snapshot(self.body().get('snapshot'))
                    return {'ok': True, 'syncedAt': app.store.upload_health(snapshot)}
                if method == 'GET' and path == '/v1/health':
                    return app.store.health()
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
                    token = self.body().get('token')
                    if not isinstance(token, str) or not re.fullmatch(r'[a-fA-F0-9]{64,200}', token):
                        raise APIError(400, 'APNs 设备 token 无效')
                    if method == 'POST':
                        app.store.register_device(token.lower())
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


def main():
    os.umask(0o077)
    token = os.environ.get('COVE_TOKEN', '')
    workspace = os.environ.get('COVE_WORKSPACE')
    if not workspace:
        raise SystemExit('Set COVE_WORKSPACE to the dedicated assistant identity workspace')
    store = Store(os.environ.get('COVE_DATA_DIR', '~/.local/share/cove'))
    runtime = CodexRuntime(store, workspace, os.environ.get('COVE_CODEX_COMMAND', 'codex app-server'),
                           os.environ.get('COVE_MODEL') or None, int(os.environ.get('COVE_TURN_TIMEOUT', '1800')))
    from notifications import configured_push
    app = Application(store, token, runtime, os.environ.get('COVE_PULSE_PATH'), configured_push())
    server = ThreadingHTTPServer((os.environ.get('COVE_HOST', '127.0.0.1'), int(os.environ.get('COVE_PORT', '8796'))), app.handler())
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close(); app.close(); store.close()


if __name__ == '__main__':
    main()
