"""Actual HTTP bytes/headers, persistent multi-file storage and isolated stdio MCP checks."""
import base64
import json
import os
import shlex
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from urllib.request import Request, urlopen
from unittest.mock import patch

import test_server as support
from files import MAX_ATTACHMENT, MAX_BODY, export_file, open_export_roots
from runtime import CodexRuntime
from storage import APIError, Store


class FileHTTPTests(unittest.TestCase):
    setUp = support.HTTPTests.setUp
    tearDown = support.HTTPTests.tearDown
    request = support.HTTPTests.request
    poll = support.HTTPTests.poll
    wait_done = support.HTTPTests.wait_done

    def upload(self, filename, mime, data):
        status, result = self.request('POST', '/v1/attachments', {'filename': filename, 'mime': mime, 'dataBase64': base64.b64encode(data).decode()})
        self.assertEqual(status, 200, result)
        return result

    def test_binary_html_metadata_roundtrip_and_inert_download(self):
        binary = b'PK\x03\x04\x00\xff\xfe\x01binary document\x00'
        attachment = self.upload('report.zip', 'application/zip', binary)
        self.assertEqual(attachment['filename'], 'report.zip'); self.assertEqual(attachment['mime'], 'application/zip'); self.assertEqual(attachment['size'], len(binary))
        self.assertEqual(self.request('GET', attachment['url'])[1], binary)
        html = b'<!doctype html><script>window.location="https://example.test"</script><h1>Cove</h1>'
        attachment = self.upload('用户 的页面.html', 'text/html', html)
        request = Request(self.base+attachment['url'], headers={'Authorization': 'Bearer '+support.TOKEN})
        with urlopen(request, timeout=3) as response:
            self.assertEqual(response.read(), html)
            self.assertEqual(response.headers['X-Content-Type-Options'], 'nosniff')
            self.assertEqual(response.headers['Content-Type'], 'text/html')
            self.assertTrue(response.headers['Content-Disposition'].startswith('attachment;'))
            self.assertIn('filename*=UTF-8\'\'%E7%94%A8%E6%88%B7', response.headers['Content-Disposition'])
        self.assertEqual(self.request('GET', attachment['url'], auth=False)[0], 401)
        self.assertEqual(self.request('POST', '/v1/attachments', {'filename': 'bad\r\nX-Foo: unsafe', 'mime': 'text/html', 'dataBase64': 'eA=='})[0], 400)
        self.assertEqual(self.request('POST', '/v1/attachments', {'filename': 'ok', 'mime': 'text/html\r\nX-Foo: unsafe', 'dataBase64': 'eA=='})[0], 400)

    def test_real_twenty_mib_boundary_and_body_rejection(self):
        data = b'z' * MAX_ATTACHMENT
        attachment = self.upload('large.bin', 'application/octet-stream', data)
        self.assertEqual(attachment['size'], MAX_ATTACHMENT)
        self.assertEqual(self.request('GET', attachment['url'])[1], data)
        too_large = {'filename': 'over.bin', 'mime': 'application/octet-stream', 'dataBase64': base64.b64encode(data+b'z').decode()}
        self.assertEqual(self.request('POST', '/v1/attachments', too_large)[0], 413)
        self.assertEqual(self.request('POST', '/v1/attachments', {'filename': 'empty.txt', 'mime': 'text/plain', 'dataBase64': ''})[0], 200)
        import http.client
        connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)
        connection.request('POST', '/v1/attachments', body=None, headers={'Authorization': 'Bearer '+support.TOKEN, 'Content-Length': str(MAX_BODY+1)})
        self.assertEqual(connection.getresponse().status, 413); connection.close()

    def test_multiple_attachments_order_conflicts_and_legacy_fingerprint_retry(self):
        one = self.upload('one.pdf', 'application/pdf', b'%PDF-1.7\x00binary')
        two = self.upload('two.md', 'text/markdown', '# 标题'.encode())
        body = {'id': 'multi', 'conversationID': 'a', 'text': '', 'attachmentIDs': [one['id'], two['id']]}
        status, ack = self.request('POST', '/v1/messages', body)
        self.assertEqual(status, 200); self.assertEqual(ack['message']['attachments'], [one, two]); self.assertEqual(ack['message']['attachmentURL'], one['url'])
        self.assertEqual(self.request('POST', '/v1/messages', body)[1]['message']['id'], ack['message']['id'])
        self.assertEqual(self.request('POST', '/v1/messages', dict(body, attachmentIDs=[two['id'], one['id']]))[0], 409)
        self.assertEqual(self.request('POST', '/v1/messages', dict(body, id='repeat', attachmentIDs=[one['id']]*2))[0], 400)
        self.assertEqual(self.request('POST', '/v1/messages', dict(body, id='too-many', attachmentIDs=[str(i) for i in range(11)]))[0], 400)
        legacy = {'id': 'old', 'conversationID': 'a', 'text': 'legacy', 'attachmentID': one['id']}
        self.request('POST', '/v1/messages', legacy)
        with self.store.lock, self.store.db:
            self.store.db.execute('UPDATE messages SET fingerprint=? WHERE id=?', (json.dumps({k:legacy.get(k) for k in ('id','conversationID','text','replyTo','attachmentID')}), 'old'))
        retry = dict(legacy); retry.pop('attachmentID'); retry['attachmentIDs'] = [one['id']]
        self.assertEqual(self.request('POST', '/v1/messages', retry)[0], 200)
        self.assertEqual(self.request('POST', '/v1/messages', dict(retry, attachmentIDs=[two['id']]))[0], 409)
        self.wait_done(); self.assertEqual(self.runtime.calls, ['multi', 'old'])


class FileRuntimeTests(unittest.TestCase):
    def command(self):
        return shlex.quote(sys.executable)+' '+shlex.quote(str(Path(__file__).with_name('fake_app_server.py')))

    def test_new_and_original_resumed_thread_create_downloadable_mcp_file(self):
        with tempfile.TemporaryDirectory() as temp:
            store = Store(temp); store.create_conversation('new'); store.create_conversation('old'); store.bind_thread('old', 'original-old-thread')
            # Child environment must not inherit the phone bearer even when parent has one.
            with patch.dict(os.environ, {'COVE_TOKEN': 'phone-secret-not-for-model'}):
                runtime = CodexRuntime(store, temp, self.command(), timeout=5)
                try:
                    for conversation, message in [('new', 'first'), ('old', 'second')]:
                        store.accept({'id': message, 'conversationID': conversation, 'text': 'COVE_TEST_FILES'})
                        job = store.claim(); status, error = runtime.run(job, threading.Event()); store.finish(message, status, error)
                        self.assertEqual(status, 'complete')
                        assistant = store._message(job['assistant'])
                        self.assertEqual(len(assistant['attachments']), 1)
                        attachment = assistant['attachments'][0]
                        self.assertEqual(attachment['filename'], 'reply.html'); self.assertEqual(attachment['mime'], 'text/html')
                        self.assertEqual(store.attachment(attachment['id'])['data'], b'<!doctype html><p>Cove file</p>')
                        self.assertEqual(assistant['attachmentURL'], attachment['url'])
                    self.assertEqual(store.conversation('old')['thread'], 'original-old-thread')
                    self.assertIsNone(store.health()['readAt'])
                finally:
                    runtime.close(); store.close()

    def test_text_html_source_json_bounded_context_vision_and_binary_honesty(self):
        class CaptureRuntime(CodexRuntime):
            def request(self, method, params=None, timeout=30):
                if method == 'turn/start': self.inputs = params['input']
                return super().request(method, params, timeout)
        with tempfile.TemporaryDirectory() as temp:
            store = Store(temp); store.create_conversation('a')
            files = [('view.html','text/html', b'<script>testOnly()</script>'), ('notes.md','text/markdown',b'# Heading'), ('data.json','application/json',b'{"real":true}'),
                     ('code.py','application/octet-stream',b'print("SOURCE_CODE")'), ('large.txt','text/plain',('甲'*100_000).encode()), ('paper.pdf','application/pdf',b'%PDF-1.7 BINARY_MUST_NOT_LEAK'),
                     ('pixel.png','image/png',b'\x89PNG\r\n\x1a\nsynthetic signature only')]
            ids = [store.add_attachment(*file)['id'] for file in files]
            store.accept({'id':'inputs','conversationID':'a','text':'test','attachmentIDs':ids}); job=store.claim()
            runtime=CaptureRuntime(store,temp,self.command(),timeout=5)
            try:
                status,error=runtime.run(job,threading.Event());self.assertEqual(status,'complete')
                text=runtime.inputs[0]['text'];self.assertIn('<script>testOnly()</script>',text);self.assertIn('# Heading',text);self.assertIn('SOURCE_CODE',text);self.assertIn('{"real":true}',text)
                self.assertIn('内容已截断',text);self.assertNotIn('BINARY_MUST_NOT_LEAK',text);self.assertIn('没有读取内容',text)
                self.assertLess(len(text.encode()), 210_000)
                images=[item for item in runtime.inputs if item['type']=='image'];self.assertEqual(len(images),1);self.assertTrue(images[0]['url'].startswith('data:image/png;base64,'))
            finally:runtime.close();store.close()

    def test_export_roots_reject_outside_hidden_symlink_hardlink_and_special_file(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)/'exports';root.mkdir();outside=Path(temp)/'private.txt';outside.write_text('NOT FOR EXPORT')
            allowed=root/'page.html';allowed.write_text('<h1>Safe file</h1>')
            roots=open_export_roots(str(root))
            try:
                filename,mime,data=export_file({'path':str(allowed.resolve())},roots)
                self.assertEqual(filename,'page.html');self.assertEqual(mime,'text/html');self.assertEqual(data,b'<h1>Safe file</h1>')
                (root/'link').symlink_to(outside);(root/'.env').write_text('SECRET')
                os.link(outside,root/'hardlink');os.mkfifo(root/'fifo')
                for file in (outside,root/'link',root/'.env',root/'hardlink',root/'fifo'):
                    with self.assertRaises(APIError):export_file({'path':str(file.absolute())},roots)
                with self.assertRaises(APIError):export_file({'path':'relative.txt'},roots)
                with self.assertRaises(APIError):export_file({'path':str(allowed.resolve())},[])
            finally:
                for _,fd in roots:os.close(fd)

    def test_callback_auth_current_turn_tool_event_and_assistant_boundaries(self):
        from urllib.error import HTTPError
        with tempfile.TemporaryDirectory() as temp:
            store=Store(temp);store.create_conversation('a');store.accept({'id':'m','conversationID':'a','text':'test'});job=store.claim();store.bind_turn('m','turn')
            runtime=CodexRuntime(store,temp,self.command());config=runtime.file_config('a')['mcp_servers.cove_files']
            env=config['env'];arguments={'filename':'ok.md','mime':'text/markdown','text':'# Safe'}
            runtime.active={'conversation':'a','thread':'thread','turn':'turn','message':'m','cancel':threading.Event()}
            body=json.dumps({'tool':'cove_create_file','arguments':arguments}).encode()
            bad=Request(env['COVE_FILE_CALLBACK_URL'],data=body,headers={'Authorization':'Bearer '+support.TOKEN},method='POST')
            try:
                with self.assertRaises(HTTPError) as error:urlopen(bad,timeout=3)
                self.assertEqual(error.exception.code,401)
                runtime.file_permits=[{'conversation':'a','turn':'old-turn','call':'stale','tool':'cove_create_file','arguments':arguments,'used':False}]
                with patch('runtime.MCP_EVENT_WAIT', .05):
                    with self.assertRaises(APIError):runtime.mcp_file_call('a','cove_create_file',arguments)
                self.assertEqual(store._message(job['assistant'])['attachments'], [])
                # Wrong conversation is rejected immediately, no capability to another chat.
                with self.assertRaises(APIError):runtime.mcp_file_call('b','cove_create_file',arguments)
                runtime.active['cancel'].set()
                with self.assertRaises(APIError):runtime.mcp_file_call('a','cove_create_file',arguments)
                runtime.active['cancel'].clear()
                runtime.file_permits=[{'conversation':'a','turn':'turn','call':'current','tool':'cove_create_file','arguments':arguments,'used':False}]
                first=runtime.mcp_file_call('a','cove_create_file',arguments);second=runtime.mcp_file_call('a','cove_create_file',arguments)
                self.assertEqual(first,second);self.assertEqual(len(store._message(job['assistant'])['attachments']),1)
                binary=b'PK\x00\xff\xfe model-created binary'
                binary_arguments={'filename':'model.zip','mime':'application/zip','dataBase64':base64.b64encode(binary).decode()}
                runtime.file_permits.append({'conversation':'a','turn':'turn','call':'binary','tool':'cove_create_file','arguments':binary_arguments,'used':False})
                generated=runtime.mcp_file_call('a','cove_create_file',binary_arguments)
                self.assertEqual(store.attachment(generated['id'])['data'],binary)
                private=Path(temp)/'private.txt';private.write_text('SECRET NOT TO TRANSFER')
                path_arguments={'path':str(private.resolve())}
                runtime.file_permits.append({'conversation':'a','turn':'turn','call':'outside','tool':'cove_send_file','arguments':path_arguments,'used':False})
                with self.assertRaises(APIError):runtime.mcp_file_call('a','cove_send_file',path_arguments)
                self.assertEqual(len(store._message(job['assistant'])['attachments']),2)
                for index in range(8):store.create_assistant_file('m','turn','extra-'+str(index),'extra.txt','text/plain',b'x')
                with self.assertRaises(APIError):store.create_assistant_file('m','turn','over-limit','extra.txt','text/plain',b'x')
                self.assertEqual(len(store._message(job['assistant'])['attachments']),10)
                store.finish('m','complete')
                with self.assertRaises(APIError):runtime.mcp_file_call('a','cove_create_file',arguments)
                with self.assertRaises(APIError):store.create_assistant_file('m','other-turn','x','bad.txt','text/plain',b'x')
            finally:runtime.close();store.close()


if __name__ == '__main__':unittest.main()
