"""Synthetic continuous-send regression. No model, remote network, or real files."""
import time
import unittest
from test_server import HTTPTests


class ContinuousSendHTTPTests(HTTPTests):
    def test_busy_runtime_keeps_order_ids_retries_and_attachment_message(self):
        self.runtime.gate.clear()
        ids = [f'burst-{i}' for i in range(6)]
        for i, identifier in enumerate(ids):
            status, ack = self.request('POST', '/v1/messages', {
                'id': identifier, 'conversationID': 'a', 'text': f'message {i}'
            })
            self.assertEqual(status, 200)
            self.assertEqual(ack['message']['id'], identifier)
        self.assertTrue(self.runtime.running.wait(1))

        # An idempotent retry while the first turn is stalled neither cancels it nor
        # creates/reorders another durable job.
        status, retry = self.request('POST', '/v1/messages', {
            'id': ids[3], 'conversationID': 'a', 'text': 'message 3'
        })
        self.assertEqual(status, 200)
        self.assertEqual(retry['message']['id'], ids[3])

        upload_status, attachment = self.request_raw('queued.txt', 'text/plain', b'queued attachment')
        self.assertEqual(upload_status, 200)
        attached_id = 'burst-attachment'
        status, ack = self.request('POST', '/v1/messages', {
            'id': attached_id, 'conversationID': 'a', 'text': 'with file',
            'attachmentIDs': [attachment['id']]
        })
        self.assertEqual(status, 200)
        self.assertEqual(ack['message']['attachments'][0]['id'], attachment['id'])
        self.assertEqual(self.runtime.calls, [ids[0]])

        self.runtime.gate.set()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and len(self.runtime.calls) < 7:
            time.sleep(.01)
        self.assertEqual(self.runtime.calls, ids + [attached_id])
        result = self.wait_done()
        users = [m for m in result['messages'] if m['role'] == 'user']
        self.assertEqual([m['id'] for m in users], ids + [attached_id])
        self.assertEqual(users[-1]['attachments'][0]['id'], attachment['id'])
        self.assertFalse(result['busy'])


if __name__ == '__main__':
    unittest.main()
