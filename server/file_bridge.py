"""Thread-scoped local MCP callback. Never uses the phone's global bearer token."""
import hmac
import json
import secrets
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from files import MAX_BODY
from storage import APIError, encode


class FileBridge:
    def __init__(self, runtime):
        self.runtime = runtime
        self.tokens = {}
        self.lock = threading.Lock()
        bridge = self
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def setup(self):
                super().setup(); self.connection.settimeout(20)

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
                    result = runtime.mcp_file_call(conversation, body.get('tool'), body.get('arguments'))
                except APIError as error:
                    status, result = error.status, {'error': error.message}
                except Exception:
                    status, result = 500, {'error': 'Local file callback failed'}
                self.close_connection = True
                data = encode(result).encode()
                self.send_response(status); self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data))); self.send_header('Cache-Control', 'no-store')
                self.end_headers(); self.wfile.write(data)
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True); self.thread.start()

    def config(self, conversation):
        with self.lock:
            token = next((token for token, value in self.tokens.items() if value == conversation), None)
            if token is None:
                token = secrets.token_urlsafe(32); self.tokens[token] = conversation
        return {'mcp_servers.cove_files': {'command': sys.executable, 'args': [str(Path(__file__).with_name('files_mcp.py'))],
                                          'env': {'COVE_FILE_CALLBACK_URL': 'http://127.0.0.1:'+str(self.server.server_port)+'/call', 'COVE_FILE_CALLBACK_TOKEN': token},
                                          'enabled': True, 'required': True}}

    def close(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(timeout=2)
