"""TEST ONLY: deterministic stdio app-server fixture, no network/model/account access."""
import json
import sys
import os
import subprocess

count = 0
configs = {}
thread_modes = {}


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
        assert 'dynamicTools' not in params  # legacy global health tool is retired
        count += 1
        configs['thread-' + str(count)] = params['config']['mcp_servers.cove_files']
        thread_modes['thread-' + str(count)] = 'start'
        send({'id': id, 'result': {'thread': {'id': 'thread-' + str(count)}, 'modelProvider': params.get('modelProvider', 'openai')}})
    elif method == 'thread/resume':
        configs[params['threadId']] = params['config']['mcp_servers.cove_files']
        thread_modes[params['threadId']] = 'resume'
        send({'id': id, 'result': {'thread': {'id': params['threadId']}, 'modelProvider': params.get('modelProvider', 'openai')}})
    elif method == 'turn/start':
        count += 1; thread = params['threadId']; turn = 'turn-' + str(count)
        if params['input'][0].get('text', '').split('\n', 1)[0] == 'COVE_TEST_PRESTART_FAILURE':
            send({'id': id, 'error': {'code': -32001, 'message': 'synthetic pre-start dispatch failure'}})
            continue
        if params['input'][0].get('text', '').split('\n', 1)[0] == 'COVE_TEST_APPROVAL':
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
        if params['input'][0].get('text', '').split('\n', 1)[0] == 'COVE_TEST_UNCERTAIN':
            # Accept/start a turn but withhold its RPC acknowledgment, staying alive.
            send({'method': 'turn/started', 'params': {'threadId': thread, 'turn': {'id': turn, 'status': 'inProgress'}}})
            continue
        # App-server can emit notifications and tool requests before the turn/start response.
        send({'method': 'turn/started', 'params': {'threadId': thread, 'turn': {'id': turn, 'status': 'inProgress'}}})
        first_line = params['input'][0].get('text', '').split('\n', 1)[0]
        if first_line.startswith('[Cove health consent event] '):
            first_line = 'COVE_TEST_HEALTH_READ ' + first_line.removeprefix('[Cove health consent event] ')
        if first_line.startswith(('COVE_TEST_HEALTH_REQUEST ', 'COVE_TEST_HEALTH_READ ', 'COVE_TEST_DATA_HEALTH ', 'COVE_TEST_DATA_APPS ', 'COVE_TEST_COLLAR_SUMMARY ', 'COVE_TEST_COLLAR_MEASURE ')):
            marker, payload = first_line.split(' ', 1)
            arguments = json.loads(payload)
            name = {'COVE_TEST_HEALTH_REQUEST': 'cove_request_health', 'COVE_TEST_HEALTH_READ': 'cove_read_health_request', 'COVE_TEST_DATA_HEALTH': 'cove_read_health', 'COVE_TEST_DATA_APPS': 'cove_read_app_activity', 'COVE_TEST_COLLAR_SUMMARY': 'cove_collar_summary', 'COVE_TEST_COLLAR_MEASURE': 'cove_collar_measure'}[marker]
            item = {'type': 'mcpToolCall', 'id': 'health-'+turn, 'server': 'cove_files', 'tool': name, 'arguments': arguments, 'status': 'inProgress'}
            # No parent-test permit injection: actual app-server notifications must
            # reach CodexRuntime._read before the callback can be accepted.
            send({'method': 'item/started', 'params': {'threadId': thread, 'turnId': turn, 'item': item}})
            config = configs[thread]
            child_env = dict(os.environ, **config['env'])
            assert 'COVE_TOKEN' not in child_env
            assert not any(key.startswith(('COVE_COLLAR_', 'COLLAR_COVE_')) for key in child_env)
            child = subprocess.Popen([config['command'], *config['args']], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=child_env)
            try:
                child.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call', 'params': {'name': name, 'arguments': arguments}})+'\n'); child.stdin.flush()
                result = json.loads(child.stdout.readline())['result']
                assert result['isError'] is False, result
                delivered = json.loads(result['content'][0]['text'])
                if marker == 'COVE_TEST_DATA_HEALTH':
                    assert delivered['source'] == 'cove-health'
                    assert delivered['entries'][0]['snapshot']['metrics'][0]['value'] == 42
                elif marker == 'COVE_TEST_DATA_APPS':
                    assert delivered['source'] == 'cove-shortcuts'
                    assert delivered['eventCount'] == 0
                elif marker == 'COVE_TEST_COLLAR_SUMMARY':
                    assert delivered['source'] == 'collar'
                    assert delivered['snapshot']['metrics'][0]['value'] == 42
                elif marker == 'COVE_TEST_COLLAR_MEASURE':
                    assert delivered['measurement']['status'] == 'pending'
                    assert delivered['measurement']['result'] is None
                elif marker == 'COVE_TEST_HEALTH_REQUEST':
                    assert delivered['request']['status'] == 'pending'
                    assert 'snapshot' not in delivered
                else:
                    assert delivered['request']['status'] == 'allowed'
                    assert delivered['snapshot']['metrics'][0]['id'] == 'steps'
                    assert delivered['snapshot']['metrics'][0]['value'] == 42
                    assert delivered['missingMetricIDs'] == ['hrv']
                item.update(status='completed', result=result)
                send({'method': 'item/completed', 'params': {'threadId': thread, 'turnId': turn, 'item': item}})
            finally:
                child.terminate(); child.wait(timeout=3); child.stdin.close(); child.stdout.close()
            send({'id': id, 'result': {'turn': {'id': turn, 'status': 'inProgress', 'items': []}}})
            text = ('data fixture' if marker.startswith('COVE_TEST_DATA_') else 'collar fixture' if marker.startswith('COVE_TEST_COLLAR_') else 'health '+delivered['request']['status'])+' '+thread_modes[thread]+' '+thread
            send({'method': 'item/completed', 'params': {'threadId': thread, 'turnId': turn, 'item': {'type': 'agentMessage', 'id': 'answer', 'text': text, 'phase': 'final_answer'}}})
            send({'method': 'turn/completed', 'params': {'threadId': thread, 'turn': {'id': turn, 'status': 'completed', 'items': [], 'error': None}}})
            continue
        if first_line.startswith('COVE_TEST_LEDGER '):
            config = configs[thread]
            child_env = dict(os.environ, **config['env'])
            assert 'COVE_TOKEN' not in child_env
            child = subprocess.Popen([config['command'], *config['args']], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=child_env)
            try:
                for ordinal, (tool, args) in enumerate((('cove_read_personal_ledger', {}), ('cove_record_personal_ledger', json.loads(first_line.split(' ', 1)[1])))):
                    item = {'type': 'mcpToolCall', 'id': 'ledger-'+turn+'-'+str(ordinal), 'server': 'cove_files', 'tool': tool, 'arguments': args, 'status': 'inProgress'}
                    send({'method': 'item/started', 'params': {'threadId': thread, 'turnId': turn, 'item': item}})
                    results = []
                    for rpc in (1, 2):
                        child.stdin.write(json.dumps({'id': rpc, 'method': 'tools/call', 'params': {'name': tool, 'arguments': args}})+'\n'); child.stdin.flush()
                        response = json.loads(child.stdout.readline())['result']
                        assert not response['isError'], response
                        results.append(json.loads(response['content'][0]['text']))
                    assert results[0] == results[1]
                    if ordinal == 1:
                        assert results[0]['command']['status'] == 'pending'
                        assert results[0]['paymentExecution'] is False
            finally:
                child.stdin.close(); child.wait(timeout=10); child.stdout.close()
            send({'id': id, 'result': {'turn': {'id': turn, 'status': 'inProgress', 'items': []}}})
            send({'method': 'item/completed', 'params': {'threadId': thread, 'turnId': turn, 'item': {'type': 'agentMessage', 'id': 'answer', 'text': 'synthetic ledger pending '+thread_modes[thread], 'phase': 'final_answer'}}})
            send({'method': 'turn/completed', 'params': {'threadId': thread, 'turn': {'id': turn, 'status': 'completed', 'items': [], 'error': None}}})
            continue
        if first_line == 'COVE_TEST_WALLET':
            config = configs[thread]
            child_env = dict(os.environ, **config['env'])
            assert 'COVE_TOKEN' not in child_env
            child = subprocess.Popen([config['command'], *config['args']], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=child_env)
            try:
                for ordinal, (tool, args) in enumerate((('cove_read_wallet', {}), ('cove_request_purchase', {'amountFen': 100, 'reason': '测试购买 '+thread}))):
                    item = {'type': 'mcpToolCall', 'id': 'wallet-'+turn+'-'+str(ordinal), 'server': 'cove_files', 'tool': tool, 'arguments': args, 'status': 'inProgress'}
                    send({'method': 'item/started', 'params': {'threadId': thread, 'turnId': turn, 'item': item}})
                    results = []
                    for rpc_id in (ordinal*2+1, ordinal*2+2):
                        child.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': rpc_id, 'method': 'tools/call', 'params': {'name': tool, 'arguments': args}})+'\n'); child.stdin.flush()
                        result = json.loads(child.stdout.readline())['result']
                        assert not result['isError'], result
                        results.append(json.loads(result['content'][0]['text']))
                    if ordinal == 0:
                        assert results[0]['wallet'] == 'assistant'
                    else:
                        assert results[0] == results[1] and results[0]['operation'] == 'request'
                    item.update(status='completed', result=result)
                    send({'method': 'item/completed', 'params': {'threadId': thread, 'turnId': turn, 'item': item}})
            finally:
                child.stdin.close(); child.wait(timeout=10); child.stdout.close()
            send({'id': id, 'result': {'turn': {'id': turn, 'status': 'inProgress', 'items': []}}})
            send({'method': 'item/completed', 'params': {'threadId': thread, 'turnId': turn, 'item': {'type': 'agentMessage', 'id': 'answer', 'text': 'synthetic wallet '+thread_modes[thread], 'phase': 'final_answer'}}})
            send({'method': 'turn/completed', 'params': {'threadId': thread, 'turn': {'id': turn, 'status': 'completed', 'items': [], 'error': None}}})
            continue
        if params['input'][0].get('text', '').startswith('COVE_TEST_WEATHER'):
            tool = 'cove_read_weather'
            item = {'type': 'mcpToolCall', 'id': 'weather-'+turn, 'server': 'cove_files', 'tool': tool, 'arguments': {}, 'status': 'inProgress'}
            send({'method': 'item/started', 'params': {'threadId': thread, 'turnId': turn, 'item': item}})
            config = configs[thread]
            child_env = dict(os.environ, **config['env'])
            assert not any(key.startswith('COVE_WEATHERKIT_') for key in child_env)
            child = subprocess.Popen([config['command'], *config['args']], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=child_env)
            try:
                child.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call', 'params': {'name': tool, 'arguments': {}}})+'\n'); child.stdin.flush()
                result = json.loads(child.stdout.readline())['result']
                assert not result['isError'], result
                weather = json.loads(result['content'][0]['text'])
                assert weather['available'] and weather['source']['name'] == 'Apple Weather'
                item.update(status='completed', result=result)
                send({'method': 'item/completed', 'params': {'threadId': thread, 'turnId': turn, 'item': item}})
            finally:
                child.stdin.close(); child.wait(timeout=10); child.stdout.close()
            send({'id': id, 'result': {'turn': {'id': turn, 'status': 'inProgress', 'items': []}}})
            send({'method': 'item/completed', 'params': {'threadId': thread, 'turnId': turn, 'item': {'type': 'agentMessage', 'id': 'answer', 'text': 'synthetic weather '+thread_modes[thread], 'phase': 'final_answer'}}})
            send({'method': 'turn/completed', 'params': {'threadId': thread, 'turn': {'id': turn, 'status': 'completed', 'items': [], 'error': None}}})
            continue
        sticker_test = params['input'][0].get('text', '').startswith('COVE_TEST_STICKERS')
        if params['input'][0].get('text', '').split('\n', 1)[0] == 'COVE_TEST_FILES' or sticker_test:
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
                assert {t['name'] for t in listed['tools']} == {'cove_request_location', 'cove_read_location', 'cove_read_personal_ledger', 'cove_record_personal_ledger', 'cove_read_wallet', 'cove_request_purchase', 'cove_read_weather', 'travel_journey', 'travel_move', 'travel_sense', 'travel_memory', 'cove_device_capabilities', 'cove_request_device_action', 'cove_read_device_action', 'cove_create_file', 'cove_send_file', 'cove_send_voice', 'cove_list_stickers', 'cove_save_sticker', 'cove_send_sticker', 'cove_request_health', 'cove_read_health_request', 'cove_read_health', 'cove_read_app_activity', 'cove_record_pulse_note', 'cove_collar_summary', 'cove_collar_measure', 'cove_collar_measurement', 'cove_bobobei_control', 'cove_bobobei_stop', 'cove_fenxin_control', 'cove_fenxin_stop', 'cove_remember', 'cove_memory_status', 'cove_cancel_pending_memory'}
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
        assert tool['result']['success'] is False  # legacy health access is fail-closed
        assert tool['result']['contentItems'][0]['type'] == 'inputText'
        # Request from an unrelated turn must fail and never read health.
        send({'id': 'stale-' + str(count), 'method': 'item/tool/call', 'params': {'threadId': thread, 'turnId': 'old-turn', 'tool': 'cove_health_read', 'callId': 'old', 'arguments': {}}})
        stale = json.loads(sys.stdin.readline()); assert stale['result']['success'] is False
        send({'id': id, 'result': {'turn': {'id': turn, 'status': 'inProgress', 'items': []}}})
        final_text = 'actual final ' + thread
        if (params['input'][0].get('text', '').split('\n', 1)[0] == 'COVE_TEST_LITTLE_THOUGHTS'
                and '[Cove little thoughts]' in params['input'][0].get('text', '')):
            final_text += '\n\n```cove_little_thoughts\nSynthetic authored aside.\n```'
        for event in [
            {'method': 'item/reasoning/textDelta', 'params': {'threadId': thread, 'turnId': turn, 'itemId': 'reasoning', 'delta': 'PRIVATE REASONING MUST NOT LEAK'}},
            {'method': 'item/completed', 'params': {'threadId': thread, 'turnId': turn, 'item': {'type': 'reasoning', 'id': 'reasoning', 'text': 'PRIVATE REASONING MUST NOT LEAK', 'summary': ['Synthetic public summary']}}},
            {'method': 'item/completed', 'params': {'threadId': 'other-thread', 'turnId': turn, 'item': {'type': 'reasoning', 'id': 'stale-summary', 'summary': ['WRONG THREAD SUMMARY']}}},
            {'method': 'item/completed', 'params': {'threadId': thread, 'turnId': 'other-turn', 'item': {'type': 'reasoning', 'id': 'stale-summary', 'summary': ['WRONG TURN SUMMARY']}}},
            {'method': 'item/agentMessage/delta', 'params': {'threadId': 'other-thread', 'turnId': turn, 'itemId': 'bad', 'delta': 'MUST NOT LEAK'}},
            {'method': 'item/completed', 'params': {'threadId': thread, 'turnId': 'other-turn', 'item': {'type': 'agentMessage', 'id': 'bad2', 'text': 'MUST NOT LEAK'}}},
            {'method': 'item/agentMessage/delta', 'params': {'threadId': thread, 'turnId': turn, 'itemId': 'progress', 'delta': 'working'}},
            {'method': 'item/completed', 'params': {'threadId': thread, 'turnId': turn, 'item': {'type': 'agentMessage', 'id': 'progress', 'phase': 'commentary', 'text': 'working'}}},
            {'method': 'item/agentMessage/delta', 'params': {'threadId': thread, 'turnId': turn, 'itemId': 'answer', 'delta': 'partial'}},
            {'method': 'item/completed', 'params': {'threadId': thread, 'turnId': turn, 'item': {'type': 'agentMessage', 'id': 'answer', 'phase': 'final_answer', 'text': final_text}}},
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
