"""Synthetic notification tests; no Apple calls, real credentials or messages."""
import json
import os
import sqlite3
import sys
import tempfile
import threading
import time
import types
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import Mock, patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from cove import Application
from notifications import GENERIC_BODY, configured_push, notification_payload
from storage import Store


class NotificationPayloadTests(unittest.TestCase):
    def test_generic_and_unknown_modes_never_include_content(self):
        message = {'id': 'reply', 'text': 'PRIVATE BODY', 'attachments': [
            {'filename': 'PRIVATE FILE', 'mime': 'text/plain', 'url': '/PRIVATE/PATH'}]}
        for mode in ('generic', 'unknown', None):
            payload = notification_payload('conversation', message, mode)
            self.assertNotIn('PRIVATE', json.dumps(payload))
            self.assertEqual(payload['aps']['alert']['body'], GENERIC_BODY)
            self.assertEqual(payload['messageID'], 'reply')

    def test_opted_in_content_is_bounded_and_flattened(self):
        payload = notification_payload('c' * 160, {'id': 'm' * 160, 'text': '\x00\n你好\t世界\u202e ' + '😀' * 3000}, 'content')
        body = payload['aps']['alert']['body']
        self.assertTrue(body.startswith('你好 世界 '))
        self.assertTrue(body.endswith('…'))
        self.assertEqual(len(body), 240)
        self.assertNotIn('\u202e', body)
        self.assertLessEqual(len(json.dumps(payload).encode('utf-8')), 4096)
        self.assertLessEqual(len(json.dumps(payload, ensure_ascii=False).encode('utf-8')), 4096)

    def test_attachments_and_legacy_ids_have_honest_fallback(self):
        cases = [({'attachments': [{'mime': 'image/png'}]}, 'Assistant 发来图片'),
                 ({'attachments': [{'mime': 'application/pdf'}]}, 'Assistant 发来文件'),
                 ({'stickerID': 'sticker'}, 'Assistant 发来一个表情'),
                 ({'attachmentURL': '/legacy'}, 'Assistant 发来文件'),
                 ({}, GENERIC_BODY)]
        for fields, expected in cases:
            self.assertEqual(notification_payload('c', {'id': 'm', **fields}, 'content')['aps']['alert']['body'], expected)
        self.assertEqual(notification_payload('c', 'legacy-id', 'content')['aps']['alert']['body'], GENERIC_BODY)

    def test_provider_builds_separate_payload_for_each_device(self):
        client = Mock()
        client.post.return_value.status_code = 200
        httpx = types.SimpleNamespace(Client=Mock(return_value=client), HTTPError=RuntimeError)
        jwt = types.SimpleNamespace(encode=Mock(return_value='synthetic-signed-token'))
        env = {'COVE_APNS_TEAM_ID': 'test', 'COVE_APNS_KEY_ID': 'test',
               'COVE_APNS_KEY_PATH': '/not-a-real-key', 'COVE_APNS_BUNDLE_ID': 'test.cove',
               'COVE_APNS_SANDBOX': '1'}
        with patch.dict(os.environ, env, clear=True), patch.dict(sys.modules, {'httpx': httpx, 'jwt': jwt}), \
                patch.object(Path, 'read_text', return_value='synthetic-private-key'):
            push = configured_push()
            push('c', {'id': 'm', 'text': 'PRIVATE BODY'}, [
                {'token': 'content-device', 'previewMode': 'content'},
                {'token': 'private-device', 'previewMode': 'generic'}, 'legacy-device'])
        calls = client.post.call_args_list
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[0].kwargs['json']['aps']['alert']['body'], 'PRIVATE BODY')
        for call in calls[1:]:
            self.assertNotIn('PRIVATE BODY', json.dumps(call.kwargs['json']))
        self.assertTrue(calls[0].args[0].startswith('https://api.sandbox.push.apple.com/'))


class NotificationStorageTests(unittest.TestCase):
    def test_old_database_migration_defaults_private_and_persists_choice(self):
        with tempfile.TemporaryDirectory() as directory:
            db = sqlite3.connect(Path(directory) / 'cove.sqlite3')
            db.execute('CREATE TABLE devices(token TEXT PRIMARY KEY, registered TEXT NOT NULL)')
            db.execute('INSERT INTO devices VALUES(?,?)', ('a' * 64, '2026-09-16T00:00:00Z'))
            db.commit(); db.close()
            store = Store(directory)
            try:
                self.assertEqual(store.notification_devices(), [{'token': 'a' * 64, 'previewMode': 'generic'}])
                store.register_device('a' * 64, 'content')
                self.assertEqual(store.device_tokens(), ['a' * 64])
            finally:
                store.close()
            store = Store(directory)
            try:
                self.assertEqual(store.notification_devices()[0]['previewMode'], 'content')
                store.register_device('a' * 64)
                self.assertEqual(store.notification_devices()[0]['previewMode'], 'generic')
                store.unregister_device('a' * 64)
                self.assertEqual(store.notification_devices(), [])
            finally:
                store.close()


class NotificationHTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(self.temp.name)
        self.pushed = []
        store = self.store

        class FakeRuntime:
            def run(self, job, cancelled):
                store.stream(job['message'], 'Synthetic completed reply')
                return 'complete', None

            def close(self):
                pass

        self.app = Application(self.store, 'synthetic-notification-auth-token', FakeRuntime(), push=lambda *args: self.pushed.append(args))
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), self.app.handler())
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown(); self.server.server_close()
        self.app.close(); self.store.close(); self.temp.cleanup()

    def post(self, path, body, auth=True):
        headers = {'Content-Type': 'application/json'}
        if auth:
            headers['Authorization'] = 'Bearer synthetic-notification-auth-token'
        req = Request('http://127.0.0.1:' + str(self.server.server_port) + path,
                      data=json.dumps(body).encode(), headers=headers, method='POST')
        try:
            with urlopen(req, timeout=3) as response:
                return response.status, json.loads(response.read())
        except HTTPError as error:
            return error.code, json.loads(error.read())

    def test_registration_validates_and_updates_preference(self):
        device = 'A' * 64
        self.assertEqual(self.post('/v1/devices', {'token': device, 'previewMode': 'content'}, auth=False)[0], 401)
        self.assertEqual(self.post('/v1/devices', {'token': device, 'previewMode': 'content'})[0], 200)
        self.assertEqual(self.store.notification_devices(), [{'token': device.lower(), 'previewMode': 'content'}])
        for invalid in (None, True, 'bad', {}, []):
            self.assertEqual(self.post('/v1/devices', {'token': device, 'previewMode': invalid})[0], 400)
        self.assertEqual(self.store.notification_devices()[0]['previewMode'], 'content')
        self.assertEqual(self.post('/v1/devices', {'token': device})[0], 200)
        self.assertEqual(self.store.notification_devices()[0]['previewMode'], 'generic')

    def test_worker_passes_only_completed_reply_and_per_device_choices(self):
        self.assertEqual(self.post('/v1/devices', {'token': 'a' * 64, 'previewMode': 'content'})[0], 200)
        self.assertEqual(self.post('/v1/conversations', {'id': 'synthetic-conversation'})[0], 200)
        self.assertEqual(self.post('/v1/messages', {'id': 'synthetic-message', 'conversationID': 'synthetic-conversation', 'text': 'Synthetic input'})[0], 200)
        deadline = time.monotonic() + 3
        while not self.pushed and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertEqual(len(self.pushed), 1)
        conversation, message, devices = self.pushed[0]
        self.assertEqual(conversation, 'synthetic-conversation')
        self.assertEqual(message['status'], 'complete')
        self.assertEqual(message['text'], 'Synthetic completed reply')
        self.assertEqual(devices, [{'token': 'a' * 64, 'previewMode': 'content'}])


if __name__ == '__main__':
    unittest.main()
