"""Synthetic local sticker ownership, exact bytes, MCP capability and quota tests."""
import base64
import json
import shlex
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import test_server as support
from runtime import CodexRuntime
from storage import APIError, Store

# Valid single-pixel GIF fixture; bytes are deliberately never decoded/re-encoded.
GIF = base64.b64decode('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7')


class StickerHTTPTests(unittest.TestCase):
    setUp = support.HTTPTests.setUp
    tearDown = support.HTTPTests.tearDown
    request = support.HTTPTests.request
    poll = support.HTTPTests.poll
    wait_done = support.HTTPTests.wait_done

    def upload(self, data=GIF, mime='image/gif'):
        status, attachment = self.request('POST', '/v1/attachments', {'filename': 'fixture.gif', 'mime': mime, 'dataBase64': base64.b64encode(data).decode()})
        self.assertEqual(status, 200)
        return attachment

    def test_upload_save_send_retry_and_exact_download(self):
        attachment = self.upload()
        args = {'attachmentID': attachment['id'], 'label': ' synthetic wave '}
        status, result = self.request('POST', '/v1/stickers', args)
        self.assertEqual(status, 200)
        sticker = result['sticker']
        self.assertEqual(sticker['owner'], 'user')
        self.assertEqual(sticker['label'], 'synthetic wave')
        self.assertEqual(sticker['attachment'], attachment)
        self.assertEqual(self.request('POST', '/v1/stickers', dict(args, label='do not overwrite'))[1], result)
        self.assertEqual(self.request('GET', '/v1/stickers')[1]['stickers'], [sticker])
        self.assertEqual(self.runtime.calls, [])  # saving never starts a model turn
        self.assertEqual(self.request('GET', attachment['url'])[1], GIF)
        body = {'id': 'sticker-send', 'conversationID': 'a', 'text': '', 'attachmentIDs': [attachment['id']], 'stickerID': sticker['id']}
        status, ack = self.request('POST', '/v1/messages', body)
        self.assertEqual(status, 200)
        self.assertEqual(ack['message']['stickerID'], sticker['id'])
        self.assertEqual(ack['message']['attachments'], [attachment])
        self.assertEqual(self.request('POST', '/v1/messages', body)[0], 200)
        without_marker = dict(body); without_marker.pop('stickerID')
        self.assertEqual(self.request('POST', '/v1/messages', without_marker)[0], 409)
        other = self.upload()
        self.assertEqual(self.request('POST', '/v1/messages', dict(body, id='mismatch', attachmentIDs=[other['id']]))[0], 400)
        self.wait_done()
        self.assertEqual(self.runtime.calls, ['sticker-send'])

    def test_auth_owner_spoof_invalid_image_and_label(self):
        attachment = self.upload()
        args = {'attachmentID': attachment['id'], 'label': 'fixture'}
        self.assertEqual(self.request('GET', '/v1/stickers', auth=False)[0], 401)
        self.assertEqual(self.request('POST', '/v1/stickers', args, auth=False)[0], 401)
        self.assertEqual(self.request('POST', '/v1/stickers', dict(args, owner='assistant'))[0], 400)
        for label in ('', '   ', 'x'*121, 'bad\nlabel', None, 42):
            self.assertEqual(self.request('POST', '/v1/stickers', dict(args, label=label))[0], 400)
        for data, mime in ((b'<svg/>', 'image/svg+xml'), (b'not a GIF', 'image/gif'), (GIF, 'image/png')):
            invalid = self.upload(data, mime)
            self.assertEqual(self.request('POST', '/v1/stickers', dict(args, attachmentID=invalid['id']))[0], 400)
        self.assertEqual(self.request('GET', '/v1/stickers')[1]['stickers'], [])


class StickerRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(self.temp.name)
        for conversation in ('a', 'b'):
            self.store.create_conversation(conversation)
        self.shared = self.store.add_attachment('shared.gif', 'image/gif', GIF)
        self.unshared = self.store.add_attachment('unshared.gif', 'image/gif', GIF)
        self.other = self.store.add_attachment('other.gif', 'image/gif', GIF)
        self.store.accept({'id': 'incoming', 'conversationID': 'a', 'text': '', 'attachmentIDs': [self.shared['id']]})
        self.job = self.store.claim()
        self.store.bind_turn('incoming', 'turn')
        self.store.accept({'id': 'elsewhere', 'conversationID': 'b', 'text': '', 'attachmentIDs': [self.other['id']]})
        self.runtime = CodexRuntime(self.store, self.temp.name)
        self.runtime.active = {'conversation': 'a', 'thread': 'thread', 'turn': 'turn', 'message': 'incoming', 'cancel': threading.Event()}

    def tearDown(self):
        self.runtime.close(); self.store.close(); self.temp.cleanup()

    def call(self, tool, arguments, call):
        self.runtime.file_permits.append({'conversation': 'a', 'turn': 'turn', 'call': call, 'tool': tool, 'arguments': arguments, 'used': False})
        return self.runtime.mcp_file_call('a', tool, arguments)

    def test_assistant_ownership_reuse_persistence_and_message_revision(self):
        user_sticker = self.store.save_user_sticker(self.shared['id'], 'user wave')
        self.assertEqual(self.call('cove_list_stickers', {}, 'empty')['stickers'], [])
        args = {'attachmentID': self.shared['id'], 'label': 'assistant wave'}
        sticker = self.call('cove_save_sticker', args, 'save')['sticker']
        self.assertEqual(sticker['owner'], 'assistant')
        self.assertNotEqual(sticker['id'], user_sticker['id'])
        self.assertEqual(self.runtime.mcp_file_call('a', 'cove_save_sticker', args)['sticker'], sticker)
        self.assertEqual(self.call('cove_list_stickers', {}, 'listed')['stickers'], [sticker])
        before = self.store._message(self.job['assistant'])['revision']
        sent = self.call('cove_send_sticker', {'stickerID': sticker['id']}, 'send')
        self.assertEqual(sent['attachment'], self.shared)
        assistant = self.store._message(self.job['assistant'])
        self.assertGreater(assistant['revision'], before)
        self.assertEqual(assistant['stickerID'], sticker['id'])
        self.assertEqual(assistant['attachments'], [self.shared])
        self.assertEqual(self.runtime.mcp_file_call('a', 'cove_send_sticker', {'stickerID': sticker['id']}), sent)
        self.assertEqual(self.store._message(self.job['assistant'])['revision'], assistant['revision'])
        self.assertEqual(self.store.attachment(self.shared['id'])['data'], GIF)
        # Sending saved files reuses the attachment, rather than copying animation.
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM attachments').fetchone()[0], 3)
        self.store.finish('incoming', 'complete')
        self.store.close(); self.store = Store(self.temp.name); self.runtime.store = self.store
        self.assertEqual(len(self.store.stickers()['stickers']), 2)
        self.assertEqual(self.store._message(self.job['assistant'])['stickerID'], sticker['id'])
        self.assertEqual(self.store.attachment(self.shared['id'])['data'], GIF)
        with self.assertRaises(APIError):
            self.runtime.mcp_file_call('a', 'cove_send_sticker', {'stickerID': sticker['id']})

    def test_mcp_capability_event_current_turn_and_unshared_image_rejection(self):
        config = self.runtime.file_config('a')['mcp_servers.cove_files']['env']
        args = {'attachmentID': self.shared['id'], 'label': 'fixture'}
        payload = json.dumps({'tool': 'cove_save_sticker', 'arguments': args}).encode()
        request = Request(config['COVE_FILE_CALLBACK_URL'], data=payload, headers={'Authorization': 'Bearer '+support.TOKEN}, method='POST')
        with self.assertRaises(HTTPError) as failure:
            urlopen(request, timeout=3)
        self.assertEqual(failure.exception.code, 401)
        with patch('runtime.MCP_EVENT_WAIT', .02):
            with self.assertRaises(APIError): self.runtime.mcp_file_call('a', 'cove_save_sticker', args)
            self.runtime.file_permits.append({'conversation': 'a', 'turn': 'old', 'call': 'stale', 'tool': 'cove_save_sticker', 'arguments': args, 'used': False})
            with self.assertRaises(APIError): self.runtime.mcp_file_call('a', 'cove_save_sticker', args)
        for attachment in (self.unshared, self.other):
            with self.assertRaises(APIError) as failure:
                self.call('cove_save_sticker', dict(args, attachmentID=attachment['id']), attachment['id'])
            self.assertEqual(failure.exception.status, 403)
        user_sticker = self.store.save_user_sticker(self.shared['id'], 'mine')
        with self.assertRaises(APIError): self.call('cove_send_sticker', {'stickerID': user_sticker['id']}, 'wrong-owner')
        self.runtime.active['cancel'].set()
        with self.assertRaises(APIError): self.call('cove_save_sticker', args, 'cancelled')
        self.assertEqual(self.store.stickers('assistant')['stickers'], [])
        self.assertEqual(self.store._message(self.job['assistant'])['attachments'], [])

    def test_sticker_mixed_reply_marker_limit_and_library_bound(self):
        sticker = self.call('cove_save_sticker', {'attachmentID': self.shared['id'], 'label': 'wave'}, 'save')['sticker']
        self.call('cove_send_sticker', {'stickerID': sticker['id']}, 'first')
        self.store.create_assistant_file('incoming', 'turn', 'generated', 'note.txt', 'text/plain', b'fixture')
        self.assertNotIn('stickerID', self.store._message(self.job['assistant']))
        for index in range(8):
            self.call('cove_send_sticker', {'stickerID': sticker['id']}, 'extra-'+str(index))
        with self.assertRaises(APIError) as failure:
            self.call('cove_send_sticker', {'stickerID': sticker['id']}, 'over-limit')
        self.assertEqual(failure.exception.status, 413)
        self.assertEqual(len(self.store._message(self.job['assistant'])['attachments']), 10)
        # Populate small synthetic records directly to exercise the count bound.
        with self.store.lock, self.store.db:
            for index in range(500):
                aid = 'capacity-'+str(index)
                self.store.db.execute('INSERT INTO attachments VALUES(?,?,?,?)', (aid, 'test.gif', 'image/gif', GIF))
                self.store.db.execute('INSERT INTO stickers VALUES(?,?,?,?,?)', ('sticker-'+aid, 'user', 'fixture', '2026-01-01T00:00:00Z', aid))
        with self.assertRaises(APIError) as failure:
            self.store.save_user_sticker(self.unshared['id'], 'over-limit')
        self.assertEqual(failure.exception.status, 413)

    def test_stdio_mcp_save_list_send_on_new_and_resumed_original_threads(self):
        with tempfile.TemporaryDirectory() as temp:
            store = Store(temp)
            store.create_conversation('new'); store.create_conversation('old')
            store.bind_thread('old', 'original-sticker-thread')
            command = shlex.quote(sys.executable)+' '+shlex.quote(str(Path(__file__).with_name('fake_app_server.py')))
            runtime = CodexRuntime(store, temp, command, timeout=5)
            try:
                for conversation in ('new', 'old'):
                    attachment = store.add_attachment('test.gif', 'image/gif', GIF)
                    store.accept({'id': conversation, 'conversationID': conversation, 'text': 'COVE_TEST_STICKERS', 'attachmentIDs': [attachment['id']]})
                    job = store.claim()
                    status, error = runtime.run(job, threading.Event())
                    store.finish(job['message'], status, error)
                    self.assertEqual(status, 'complete', error)
                    assistant = store._message(job['assistant'])
                    self.assertEqual(assistant['attachments'], [attachment])
                    self.assertEqual(store.sticker(assistant['stickerID'])['owner'], 'assistant')
                    self.assertEqual(store.attachment(attachment['id'])['data'], GIF)
                self.assertEqual(store.conversation('old')['thread'], 'original-sticker-thread')
                self.assertEqual(len(store.stickers('assistant')['stickers']), 2)
            finally:
                runtime.close(); store.close()


class UsageBucketTests(unittest.TestCase):
    def usage(self, response, plan='plus'):
        class FixtureRuntime(CodexRuntime):
            def ensure_started(self): pass
            def request(self, method, params=None, timeout=30):
                return response if method == 'account/rateLimits/read' else {'account': {'planType': plan}}
        runtime = FixtureRuntime(None, '/private/tmp')
        try:
            return runtime.usage()
        finally:
            runtime.close()

    def window(self, duration, percent):
        return {'windowDurationMins': duration, 'usedPercent': percent, 'resetsAt': 1700000000}

    def test_pro_weekly_primary_excludes_spark_and_does_not_invent_five_hours(self):
        result = self.usage({'rateLimitsByLimitId': {
            'codex_bengalfox': {'planType': 'prolite', 'limitName': 'GPT-5.3-Codex-Spark', 'primary': self.window(300, 0), 'secondary': self.window(10080, 0)},
            'codex': {'planType': 'prolite', 'primary': self.window(10080, 65), 'secondary': None}}})
        self.assertEqual(result['plan'], 'prolite')
        self.assertEqual([(x['id'], x['title'], x['usedPercent']) for x in result['windows']], [('codex-weekly', '周额度', 65)])

    def test_plus_two_windows_legacy_and_unknown_buckets(self):
        canonical = {'planType': 'plus', 'primary': self.window(300, 20), 'secondary': self.window(10080, 40)}
        for response in ({'rateLimits': canonical}, {'rateLimitsByLimitId': {'codex': canonical}}):
            result = self.usage(response)
            self.assertEqual(result['plan'], 'plus')
            self.assertEqual([x['id'] for x in result['windows']], ['codex-5h', 'codex-weekly'])
        for response in ({'rateLimits': dict(canonical, limitId='codex_bengalfox')}, {'rateLimitsByLimitId': {'codex_bengalfox': canonical}}, {'rateLimits': {'primary': self.window(60, 20)}}):
            result = self.usage(response)
            self.assertEqual(result['windows'], [])
            self.assertTrue(result['error'])
        result = self.usage({'rateLimits': {'primary': self.window(300, float('nan')), 'secondary': self.window(10080, True)}})
        self.assertEqual(result['windows'], [])


if __name__ == '__main__':
    unittest.main()
