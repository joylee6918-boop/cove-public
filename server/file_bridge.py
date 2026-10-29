"""Thread-scoped local MCP callback. Never uses the phone's global bearer token."""
import hmac
import json
import os
import secrets
import stat
import sys
import hashlib
import threading
from contextlib import nullcontext
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from files import MAX_BODY
from storage import APIError, encode


class FileBridge:
    def __init__(self, runtime, persistence_path=None):
        self.runtime = runtime
        self.tokens = {}
        self.lock = threading.Lock()
        self.persistence_path = self._private_path(persistence_path) if persistence_path else None
        previous = self._load_state() if self.persistence_path else None
        bridge = self
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def setup(self):
                # Voice synthesis has a separately bounded 60s upstream timeout.
                super().setup(); self.connection.settimeout(115)

            def do_POST(self):
                status, result = 200, None
                try:
                    if self.path != '/call':
                        raise APIError(404, 'Unknown local callback')
                    supplied = self.headers.get('Authorization', '')
                    with bridge.lock:
                        conversation = next((value for token, value in bridge.tokens.items() if hmac.compare_digest(supplied.encode(), ('Bearer '+token).encode())), None)
                    if conversation is None:
                        raise APIError(401, 'Invalid local capability')
                    if self.headers.get('Transfer-Encoding'):
                        raise APIError(400, 'Chunked callback unsupported')
                    try:
                        size = int(self.headers.get('Content-Length', '0'))
                    except ValueError:
                        raise APIError(400, 'Invalid callback size')
                    if size <= 0 or size > MAX_BODY:
                        raise APIError(413, 'Local callback too large')
                    try:
                        body = json.loads(self.rfile.read(size))
                    except (ValueError, UnicodeError):
                        raise APIError(400, 'Invalid callback JSON')
                    if not isinstance(body, dict):
                        raise APIError(400, 'Invalid callback JSON')
                    if callable(getattr(runtime, 'mcp_file_call_native', None)):
                        result = runtime.mcp_file_call_native(conversation, body.get('tool'),
                                                              body.get('arguments'), body.get('metadata'),
                                                              body.get('rpcID'))
                    else:
                        result = runtime.mcp_file_call(conversation, body.get('tool'), body.get('arguments'))
                except APIError as error:
                    status, result = error.status, {'error': error.message}
                except Exception:
                    status, result = 500, {'error': 'Local file callback failed'}
                self.close_connection = True
                def write_result(status, result):
                    data = encode(result).encode()
                    self.send_response(status); self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', str(len(data))); self.send_header('Cache-Control', 'no-store')
                    self.end_headers(); self.wfile.write(data); self.wfile.flush()
                try:
                    guard = nullcontext()
                    if status == 200 and body.get('tool', '').startswith('cove_collar_'):
                        from collar import delivery_guard
                        guard = delivery_guard(runtime, conversation, body['tool'], body['arguments'], result)
                    if status == 200 and body.get('tool') in ('cove_read_health', 'cove_read_app_activity'):
                        from data_access import delivery_guard
                        guard = delivery_guard(runtime, conversation, body['tool'], body['arguments'], result)
                    if status == 200 and body.get('tool') in ('cove_read_personal_ledger', 'cove_record_personal_ledger'):
                        from personal_ledger import delivery_guard
                        guard = delivery_guard(runtime, conversation, body['tool'], body['arguments'], result)
                    if status == 200 and body.get('tool') == 'cove_read_device_action':
                        from device_actions import delivery_guard
                        guard = delivery_guard(runtime, conversation, body['tool'], body['arguments'], result)
                    with guard:
                        write_result(status, result)
                except APIError as error:
                    write_result(error.status, {'error': error.message})
                if status == 200 and body.get('tool') == 'cove_read_health_request' and result.get('request', {}).get('status') in ('allowed', 'denied', 'expired'):
                    runtime.store.mark_health_request_delivered(conversation, result['request']['id'])
        try:
            self.server = ThreadingHTTPServer(('127.0.0.1', previous['port'] if previous else 0), Handler)
        except OSError as exc:
            raise RuntimeError('已保存的 Cove MCP 回调端口不可用；拒绝更换端口') from exc
        # Drain already-started bounded callbacks before the owning Store closes.
        # Cancellation revokes future commits; it cannot undo an upstream call.
        self.server.daemon_threads = False
        self.server.block_on_close = True
        if previous:
            self.tokens = previous['tokens']
        elif self.persistence_path:
            try:
                self._save_state()
            except Exception:
                self.server.server_close()
                raise
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True); self.thread.start()

    @staticmethod
    def _private_path(path):
        path = Path(path).expanduser()
        if not path.is_absolute() or '..' in path.parts or path.parent != path.parent.resolve(strict=True):
            raise ValueError('MCP callback state path is not an explicit private path')
        parent = path.parent.stat()
        if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.getuid() or parent.st_mode & 0o077:
            raise ValueError('MCP callback state directory is not private')
        if path.exists() or path.is_symlink():
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise ValueError('MCP callback state file is unsafe')
        return path

    def _load_state(self):
        if not self.persistence_path.exists():
            return None
        fd = os.open(self.persistence_path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_size > 65536:
                raise ValueError('unsafe MCP callback state')
            with os.fdopen(fd, 'r', encoding='utf-8') as stream:
                fd = None
                value = json.load(stream)
        finally:
            if fd is not None:
                os.close(fd)
        if (not isinstance(value, dict) or set(value) != {'version', 'port', 'tokens'} or
                value['version'] != 1 or type(value['port']) is not int or not 1 <= value['port'] <= 65535 or
                not isinstance(value['tokens'], dict) or len(value['tokens']) > 1000 or
                any(not isinstance(token, str) or len(token) < 32 or
                    not isinstance(conversation, str) or not conversation
                    for token, conversation in value['tokens'].items())):
            raise ValueError('invalid MCP callback state')
        return value

    def _save_state(self):
        if not self.persistence_path:
            return
        payload = encode({'version': 1, 'port': self.server.server_port, 'tokens': self.tokens}).encode()
        if len(payload) > 65536:
            raise ValueError('MCP callback state is full')
        path = self.persistence_path
        temporary = path.with_name(path.name + '.' + secrets.token_hex(8) + '.tmp')
        fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        try:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(payload); stream.flush(); os.fsync(stream.fileno())
            os.replace(temporary, path)
            directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            if temporary.exists():
                temporary.unlink()

    def config(self, conversation):
        with self.lock:
            token = next((token for token, value in self.tokens.items() if value == conversation), None)
            if token is None:
                token = secrets.token_urlsafe(32); self.tokens[token] = conversation
                try:
                    self._save_state()
                except Exception:
                    self.tokens.pop(token, None)
                    raise
        return {'mcp_servers.cove_files': {'command': sys.executable, 'args': [str(Path(__file__).with_name('files_mcp.py'))],
                                          'env': {'COVE_FILE_CALLBACK_URL': 'http://127.0.0.1:'+str(self.server.server_port)+'/call', 'COVE_FILE_CALLBACK_TOKEN': token},
                                          'enabled': True, 'required': True, 'tool_timeout_sec': 120}}

    def cli_config(self, conversation):
        """Private capability file lets native -c overrides contain no token.

        Does not alter CODEX_HOME/config.toml, shared profiles, or other services.
        An existing file must match byte-for-byte; never overwrite an unknown
        launch credential while a persistent native process may still use it.
        """
        if self.persistence_path is None:
            raise RuntimeError('CLI capability requires persistent callback identity')
        config = self.config(conversation)
        server = dict(config['mcp_servers.cove_files'])
        env = server['env']
        data = encode({'callback': env['COVE_FILE_CALLBACK_URL'],
                       'token': env['COVE_FILE_CALLBACK_TOKEN']}).encode()
        name = 'tmux-mcp-' + hashlib.sha256(conversation.encode()).hexdigest() + '.json'
        path = self._private_path(self.persistence_path.parent / name)
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        except FileExistsError:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, 'rb') as stream:
                if stream.read(8193) != data:
                    raise RuntimeError('existing native MCP capability changed; no overwrite')
        else:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
        server['env'] = {'COVE_FILE_CAPABILITY_PATH': str(path)}
        return {'mcp_servers.cove_files': server}

    def close(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(timeout=2)
