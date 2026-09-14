"""Cove-only stdio MCP file tools; implementation runs in the parent callback."""
import json
import os
import sys
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from files import FILE_TOOLS


def reply(id, result=None, error=None):
    payload = {'jsonrpc': '2.0', 'id': id}
    payload['error' if error is not None else 'result'] = error if error is not None else result
    print(json.dumps(payload, ensure_ascii=False, separators=(',', ':')), flush=True)


def main():
    callback, capability = os.environ['COVE_FILE_CALLBACK_URL'], os.environ['COVE_FILE_CALLBACK_TOKEN']
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
            reply(id, {'tools': [dict(tool, annotations={'readOnlyHint': tool['name'] == 'cove_list_stickers', 'destructiveHint': False, 'openWorldHint': False}) for tool in FILE_TOOLS]})
        elif method == 'tools/call':
            try:
                data = json.dumps({'tool': params.get('name'), 'arguments': params.get('arguments')}, ensure_ascii=False, allow_nan=False).encode()
                request = Request(callback, data=data, headers={'Content-Type': 'application/json', 'Authorization': 'Bearer '+capability}, method='POST')
                with urlopen(request, timeout=25) as response:
                    result = json.loads(response.read())
                reply(id, {'content': [{'type': 'text', 'text': json.dumps(result, ensure_ascii=False)}], 'isError': False})
            except HTTPError as error:
                try:
                    reason = json.loads(error.read()).get('error', 'File callback rejected')
                except (ValueError, UnicodeError):
                    reason = 'File callback rejected'
                reply(id, {'content': [{'type': 'text', 'text': reason}], 'isError': True})
            except Exception:
                reply(id, {'content': [{'type': 'text', 'text': 'Cove file callback unavailable; no file delivery confirmed'}], 'isError': True})
        elif method in ('ping', 'resources/list', 'prompts/list'):
            reply(id, {} if method == 'ping' else {'resources' if method == 'resources/list' else 'prompts': []})
        else:
            reply(id, error={'code': -32601, 'message': 'Unknown Cove MCP method'})


if __name__ == '__main__':
    main()
