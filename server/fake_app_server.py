"""TEST ONLY: deterministic stdio app-server fixture, no network/model/account access."""
import json
import sys
import os
import subprocess

count = 0
configs = {}


def send(value):
    print(json.dumps(value), flush=True)


def models(id):
    send({'id': id, 'result': {'data': [{'id': 'fixture-sol', 'model': 'fixture-sol', 'displayName': 'TEST ONLY Sol', 'hidden': False,
                                      'defaultReasoningEffort': 'low', 'supportedReasoningEfforts': [{'reasoningEffort': e} for e in ('low', 'high')]},
                                     {'id': 'fixture-other', 'model': 'fixture-other', 'displayName': 'TEST ONLY Other', 'hidden': False,
                                      'defaultReasoningEffort': 'medium', 'supportedReasoningEfforts': [{'reasoningEffort': 'medium'}]}], 'nextCursor': None}})


for line in sys.stdin:
    message = json.loads(line)
    if 'method' not in message:
        continue  # Host response to dynamic tool.
    method = message['method']; params = message.get('params', {}); id = message.get('id')
    if method == 'initialized':
        continue
    if method == 'initialize':
        assert params['capabilities']['experimentalApi'] is True
        send({'id': id, 'result': {'userAgent': 'fake'}})
    elif method == 'thread/start':
        assert params['dynamicTools'][0]['type'] == 'function'
        assert params['dynamicTools'][0]['name'] == 'cove_health_read'
        count += 1
        configs['thread-' + str(count)] = params['config']['mcp_servers.cove_files']
        send({'id': id, 'result': {'thread': {'id': 'thread-' + str(count)}}})
    elif method == 'thread/resume':
        configs[params['threadId']] = params['config']['mcp_servers.cove_files']
        send({'id': id, 'result': {'thread': {'id': params['threadId']}}})
    elif method == 'turn/start':
        count += 1; thread = params['threadId']; turn = 'turn-' + str(count)
        if params['input'][0].get('text') == 'COVE_TEST_PRESTART_FAILURE':
            send({'id': id, 'error': {'code': -32001, 'message': 'synthetic pre-start dispatch failure'}})
            continue
        if params['input'][0].get('text') == 'COVE_TEST_APPROVAL':
            send({'method': 'turn/started', 'params': {'threadId': thread, 'turn': {'id': turn, 'status': 'inProgress'}}})
            item = {'type': 'commandExecution', 'id': 'cmd-'+turn, 'command': 'printf COVE_CONSOLE_PROOF', 'cwd': '/synthetic', 'status': 'inProgress'}
            send({'method': 'item/started', 'params': {'threadId': thread, 'turnId': turn, 'item': item}})
            approval = 'approval-'+turn
            send({'id': approval, 'method': 'item/commandExecution/requestApproval', 'params': {'threadId': thread, 'turnId': turn, 'itemId': item['id'], 'command': item['command'], 'cwd': '/synthetic', 'reason': 'Synthetic regression only', 'availableDecisions': ['accept', 'decline']}})
            send({'id': id, 'result': {'turn': {'id': turn, 'status': 'inProgress'}}})
            while True:
                answer = json.loads(sys.stdin.readline())
                if answer.get('method') == 'model/list':
                    models(answer['id']); continue
                assert answer['id'] == approval and answer['result']['decision'] in ('accept', 'decline'), answer
                decision = answer['result']['decision']; break
            send({'method': 'item/commandExecution/outputDelta', 'params': {'threadId': thread, 'turnId': turn, 'itemId': item['id'], 'delta': 'Authorization: Bear'}})
            send({'method': 'item/commandExecution/outputDelta', 'params': {'threadId': thread, 'turnId': turn, 'itemId': item['id'], 'delta': 'er fixture-private-secret\nCOVE_CONSOLE_PROOF\n'}})
            item.update(status='completed', exitCode=0, aggregatedOutput='COVE_CONSOLE_PROOF')
            send({'method': 'item/completed', 'params': {'threadId': thread, 'turnId': turn, 'item': item}})
            text = 'console '+decision+' '+str(params.get('model'))+' '+str(params.get('effort'))+' '+thread
            send({'method': 'item/completed', 'params': {'threadId': thread, 'turnId': turn, 'item': {'type': 'agentMessage', 'id': 'answer', 'text': text, 'phase': 'final_answer'}}})
            send({'method': 'turn/completed', 'params': {'threadId': thread, 'turn': {'id': turn, 'status': 'completed', 'items': [], 'error': None}}})
            continue
        if params['input'][0].get('text') == 'COVE_TEST_UNCERTAIN':
            # Accept/start a turn but withhold its RPC acknowledgment, staying alive.
            send({'method': 'turn/started', 'params': {'threadId': thread, 'turn': {'id': turn, 'status': 'inProgress'}}})
            continue
        # App-server can emit notifications and tool requests before the turn/start response.
        send({'method': 'turn/started', 'params': {'threadId': thread, 'turn': {'id': turn, 'status': 'inProgress'}}})
        sticker_test = params['input'][0].get('text', '').startswith('COVE_TEST_STICKERS')
        if params['input'][0].get('text') == 'COVE_TEST_FILES' or sticker_test:
            arguments = {'filename': 'reply.html', 'mime': 'text/html', 'text': '<!doctype html><p>Cove file</p>'}
            item = {'type': 'mcpToolCall', 'id': 'file-'+str(count), 'server': 'cove_files', 'tool': 'cove_create_file', 'arguments': arguments, 'status': 'inProgress'}
            send({'method': 'item/started', 'params': {'threadId': thread, 'turnId': turn, 'item': item}})
            config = configs[thread]
            child_env = dict(os.environ, **config['env'])
            assert 'COVE_TOKEN' not in child_env
            child = subprocess.Popen([config['command'], *config['args']], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=child_env)
            try:
                def mcp(method, params, id):
                    child.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params})+'\n'); child.stdin.flush()
                    return json.loads(child.stdout.readline())['result']
                mcp('initialize', {'protocolVersion': '2024-11-05', 'capabilities': {}, 'clientInfo': {'name': 'fake-cli', 'version': '1'}}, 1)
                listed = mcp('tools/list', {}, 2)
                assert {t['name'] for t in listed['tools']} == {'cove_create_file', 'cove_send_file', 'cove_list_stickers', 'cove_save_sticker', 'cove_send_sticker'}
                if sticker_test:
                    def sticker_call(name, args, ordinal):
                        tool_item = {'type': 'mcpToolCall', 'id': 'sticker-'+turn+'-'+str(ordinal), 'server': 'cove_files', 'tool': name, 'arguments': args, 'status': 'inProgress'}
                        send({'method': 'item/started', 'params': {'threadId': thread, 'turnId': turn, 'item': tool_item}})
                        result = mcp('tools/call', {'name': name, 'arguments': args}, ordinal)
                        assert not result['isError'], result
                        assert mcp('tools/call', {'name': name, 'arguments': args}, ordinal+100) == result
                        tool_item.update(status='completed', result=result)
                        send({'method': 'item/completed', 'params': {'threadId': thread, 'turnId': turn, 'item': tool_item}})
                        return json.loads(result['content'][0]['text'])
                    attachment_id = params['input'][0]['text'].split('attachmentID=', 1)[1].split('；', 1)[0]
                    sticker = sticker_call('cove_save_sticker', {'attachmentID': attachment_id, 'label': 'synthetic greeting'}, 3)['sticker']
                    assert sticker in sticker_call('cove_list_stickers', {}, 4)['stickers']
                    assert sticker_call('cove_send_sticker', {'stickerID': sticker['id']}, 5)['sticker'] == sticker
                else:
                    result = mcp('tools/call', {'name': 'cove_create_file', 'arguments': arguments}, 3)
                    assert result['isError'] is False, result
                    repeated = mcp('tools/call', {'name': 'cove_create_file', 'arguments': arguments}, 4)
                    assert result == repeated
                    item.update(status='completed', result=result)
                    send({'method': 'item/completed', 'params': {'threadId': thread, 'turnId': turn, 'item': item}})
            finally:
                child.terminate(); child.wait(timeout=3); child.stdin.close(); child.stdout.close()
        send({'id': 'tool-' + str(count), 'method': 'item/tool/call', 'params': {'threadId': thread, 'turnId': turn, 'tool': 'cove_health_read', 'callId': 'call', 'arguments': {}}})
        tool = json.loads(sys.stdin.readline())
        assert tool['result']['success'] is True
        assert tool['result']['contentItems'][0]['type'] == 'inputText'
        # Request from an unrelated turn must fail and never read health.
        send({'id': 'stale-' + str(count), 'method': 'item/tool/call', 'params': {'threadId': thread, 'turnId': 'old-turn', 'tool': 'cove_health_read', 'callId': 'old', 'arguments': {}}})
        stale = json.loads(sys.stdin.readline()); assert stale['result']['success'] is False
        send({'id': id, 'result': {'turn': {'id': turn, 'status': 'inProgress', 'items': []}}})
        for event in [
            {'method': 'item/reasoning/textDelta', 'params': {'threadId': thread, 'turnId': turn, 'itemId': 'reasoning', 'delta': 'PRIVATE REASONING MUST NOT LEAK'}},
            {'method': 'item/completed', 'params': {'threadId': thread, 'turnId': turn, 'item': {'type': 'reasoning', 'id': 'reasoning', 'text': 'PRIVATE REASONING MUST NOT LEAK', 'summary': ['private']}}},
            {'method': 'item/agentMessage/delta', 'params': {'threadId': 'other-thread', 'turnId': turn, 'itemId': 'bad', 'delta': 'MUST NOT LEAK'}},
            {'method': 'item/completed', 'params': {'threadId': thread, 'turnId': 'other-turn', 'item': {'type': 'agentMessage', 'id': 'bad2', 'text': 'MUST NOT LEAK'}}},
            {'method': 'item/agentMessage/delta', 'params': {'threadId': thread, 'turnId': turn, 'itemId': 'progress', 'delta': 'working'}},
            {'method': 'item/completed', 'params': {'threadId': thread, 'turnId': turn, 'item': {'type': 'agentMessage', 'id': 'progress', 'phase': 'commentary', 'text': 'working'}}},
            {'method': 'item/agentMessage/delta', 'params': {'threadId': thread, 'turnId': turn, 'itemId': 'answer', 'delta': 'partial'}},
            {'method': 'item/completed', 'params': {'threadId': thread, 'turnId': turn, 'item': {'type': 'agentMessage', 'id': 'answer', 'phase': 'final_answer', 'text': 'actual final ' + thread}}},
            {'method': 'turn/completed', 'params': {'threadId': thread, 'turn': {'id': turn, 'status': 'completed', 'items': [], 'error': None}}}
        ]:
            send(event)
    elif method == 'turn/interrupt':
        send({'id': id, 'result': {}})
    elif method == 'model/list':
        models(id)
    elif method == 'account/rateLimits/read':
        send({'id': id, 'result': {'rateLimitsByLimitId': {'codex': {'planType': 'plus', 'primary': {'usedPercent': 17, 'windowDurationMins': 300, 'resetsAt': 1700000000}, 'secondary': None}}}})
    else:
        send({'id': id, 'error': {'code': -32601, 'message': 'unknown fake method'}})
