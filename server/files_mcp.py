"""Cove-only stdio MCP file tools; implementation runs in the parent callback."""
import json
import os
import sys
import stat
from pathlib import Path
from urllib.parse import urlparse
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from files import FILE_TOOLS


def reply(id, result=None, error=None):
    payload = {'jsonrpc': '2.0', 'id': id}
    payload['error' if error is not None else 'result'] = error if error is not None else result
    print(json.dumps(payload, ensure_ascii=False, separators=(',', ':')), flush=True)


def callback_credentials():
    """CLI launch arguments may contain a capability *path*, never its token."""
    configured = os.environ.get('COVE_FILE_CAPABILITY_PATH')
    if not configured:
        return os.environ['COVE_FILE_CALLBACK_URL'], os.environ['COVE_FILE_CALLBACK_TOKEN']
    path = Path(configured)
    if not path.is_absolute() or path != path.resolve(strict=True):
        raise RuntimeError('unsafe Cove capability path')
    parent = path.parent.stat()
    if parent.st_uid != os.getuid() or parent.st_mode & 0o077:
        raise RuntimeError('Cove capability directory is not private')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'r', encoding='utf-8') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_size > 8192:
            raise RuntimeError('unsafe Cove capability file')
        data = json.load(stream)
    if not isinstance(data, dict) or set(data) != {'callback', 'token'}:
        raise RuntimeError('invalid Cove capability')
    callback, token = data['callback'], data['token']
    parsed = urlparse(callback)
    if (parsed.scheme != 'http' or parsed.hostname != '127.0.0.1' or
            parsed.path != '/call' or not parsed.port or parsed.username or parsed.password or
            parsed.query or parsed.fragment or not isinstance(token, str) or
            not 32 <= len(token) <= 256 or not token.isascii() or
            any(not (c.isalnum() or c in '-_') for c in token)):
        raise RuntimeError('invalid Cove loopback capability')
    return callback, token


def main():
    callback, capability = callback_credentials()
    for line in sys.stdin:
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if 'id' not in message:
            continue
        id, method, params = message['id'], message.get('method'), message.get('params', {})
        if method == 'initialize':
            reply(id, {'protocolVersion': params.get('protocolVersion', '2024-11-05'), 'capabilities': {'tools': {'listChanged': False}}, 'serverInfo': {'name': 'cove_files', 'version': '1.0'}})
        elif method == 'tools/list':
            reply(id, {'tools': [dict(tool, annotations={'readOnlyHint': tool['name'] in ('cove_read_personal_ledger', 'cove_read_wallet', 'cove_read_weather', 'cove_device_capabilities', 'cove_read_device_action', 'cove_memory_status', 'cove_list_stickers', 'cove_read_health_request', 'cove_read_health', 'cove_read_app_activity', 'cove_collar_summary', 'cove_collar_measurement'), 'destructiveHint': False, 'openWorldHint': tool['name'].startswith('cove_collar_') or tool['name'] == 'cove_read_weather'}) for tool in FILE_TOOLS]})
        elif method == 'tools/call':
            try:
                data = json.dumps({'tool': params.get('name'), 'arguments': params.get('arguments'),
                                   'metadata': params.get('_meta'), 'rpcID': id},
                                  ensure_ascii=False, allow_nan=False).encode()
                request = Request(callback, data=data, headers={'Content-Type': 'application/json', 'Authorization': 'Bearer '+capability}, method='POST')
                # cove_send_voice may spend up to 60 seconds in its bounded TTS
                # provider. Other tools normally return much sooner.
                timeout = 110 if str(params.get('name','')).startswith('travel_') else (65 if params.get('name') in ('cove_send_voice', 'cove_remember', 'cove_read_weather') else 25)
                with urlopen(request, timeout=timeout) as response:
                    result = json.loads(response.read())
                reply(id, {'content': [{'type': 'text', 'text': json.dumps(result, ensure_ascii=False)}], 'isError': params.get('name') == 'cove_read_weather' and result.get('available') is not True})
            except HTTPError as error:
                try:
                    reason = json.loads(error.read()).get('error', 'File callback rejected')
                except (ValueError, UnicodeError):
                    reason = 'File callback rejected'
                reply(id, {'content': [{'type': 'text', 'text': reason}], 'isError': True})
            except Exception:
                reason = ('Purchase outcome unknown; do not issue a new purchase call. Read the wallet and ask the owner to reconcile.'
                          if params.get('name') == 'cove_request_purchase' else
                          'Bookkeeping outcome unknown; read personal ledger command statuses before creating another command. No payment was executed.'
                          if params.get('name') == 'cove_record_personal_ledger' else
                          'Cove file callback unavailable; no file delivery confirmed')
                reply(id, {'content': [{'type': 'text', 'text': reason}], 'isError': True})
        elif method in ('ping', 'resources/list', 'prompts/list'):
            reply(id, {} if method == 'ping' else {'resources' if method == 'resources/list' else 'prompts': []})
        else:
            reply(id, error={'code': -32601, 'message': 'Unknown Cove MCP method'})


if __name__ == '__main__':
    main()
