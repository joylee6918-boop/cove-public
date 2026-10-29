import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
import uuid

from collar_push import WatchPush


class PushTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.key = self.root / 'fake.p8'
        self.key.write_text('SYNTHETIC_NOT_A_KEY')
        self.key.chmod(0o600)
        (self.root / 'watch_tokens.json').write_text(json.dumps([{'token': 'a'*64}]))
        self.env = dict(COLLAR_COVE_APNS_TEAM_ID='ABCDE12345', COLLAR_COVE_APNS_KEY_ID='KEY1234567',
                        COLLAR_COVE_APNS_KEY_PATH=str(self.key), HEALTH_DATA_DIR=str(self.root),
                        COLLAR_COVE_DATA_DIR=str(self.root))
        self.calls = []
        self.response = SimpleNamespace(returncode=0, stdout='\n200')
        self.push = self.new_push()
        self.identifier = str(uuid.uuid4())

    def run_curl(self, args, **kwargs):
        self.calls.append((args, kwargs))
        return self.response

    def new_push(self):
        return WatchPush(self.env, self.run_curl, lambda: 'SECRET_JWT')

    def test_accept_once_across_restart_private_transport(self):
        receipt = self.push.send_test_once(self.identifier)
        self.assertEqual(receipt['status'], 'accepted')
        self.assertTrue(self.new_push().send_test_once(self.identifier)['duplicate'])
        self.assertEqual(len(self.calls), 1)
        args, kwargs = self.calls[0]
        self.assertNotIn('SECRET_JWT', str(args))
        self.assertNotIn('a'*64, str(args))
        self.assertIn('api.sandbox.push.apple.com', kwargs['input'])
        self.assertIn('Collar 推送测试', kwargs['input'])
        self.assertNotIn('measure_heart_rate', kwargs['input'])
        self.assertEqual(os.stat(self.root/'push-tests.sqlite3').st_mode & 0o777, 0o600)

    def test_rejection_no_retry(self):
        self.response.stdout = '{"reason":"DeviceTokenNotForTopic"}\n400'
        result = self.push.send_test_once(self.identifier)
        self.assertEqual(result['reason'], 'DeviceTokenNotForTopic')
        self.push.send_test_once(self.identifier)
        self.assertEqual(len(self.calls), 1)

    def test_uncertain_timeout_no_retry(self):
        def timeout(*args, **kwargs):
            self.calls.append(1)
            raise subprocess.TimeoutExpired('SECRET', 6)
        self.push.runner = timeout
        self.assertEqual(self.push.send_test_once(self.identifier)['status'], 'unknown')
        self.assertTrue(self.push.send_test_once(self.identifier)['duplicate'])
        self.assertEqual(len(self.calls), 1)

    def test_crash_intent_never_replayed(self):
        def crash(*args, **kwargs):
            raise KeyboardInterrupt()
        self.push.runner = crash
        with self.assertRaises(KeyboardInterrupt):
            self.push.send_test_once(self.identifier)
        result = self.new_push().send_test_once(self.identifier)
        self.assertEqual(result['status'], 'unknown')
        self.assertTrue(result['duplicate'])
        self.assertEqual(self.calls, [])

    def test_private_key_and_recipient_fail_closed(self):
        self.key.chmod(0o644)
        self.assertEqual(self.push.send_test_once(self.identifier)['status'], 'not_configured')
        self.key.chmod(0o600)
        for rows in ([], [{'token': 'a'*64}, {'token': 'b'*64}], [{'token': 'bad\nheader'}]):
            (self.root/'watch_tokens.json').write_text(json.dumps(rows))
            self.assertEqual(self.push.send_test_once(self.identifier)['status'], 'recipient_not_unique')
        self.assertEqual(self.calls, [])

    def test_status_read_only_no_secrets(self):
        result = self.push.status()
        self.assertTrue(result['configured'])
        self.assertTrue(result['automaticMeasurementAlerts'])
        self.assertEqual(result['registeredTokens'], 1)
        self.assertNotIn('a'*64, str(result))
        self.assertFalse((self.root/'push-tests.sqlite3').exists())
        self.assertEqual(self.calls, [])

    def test_measurement_sender_has_no_test_or_measurement_side_effect(self):
        result = self.push.send_measurement(self.identifier)
        self.assertEqual(result['status'], 'accepted')
        self.assertEqual(len(self.calls), 1)
        stdin = self.calls[0][1]['input']
        self.assertIn('收到测量请求', stdin)
        self.assertNotIn('推送测试', stdin)
        self.assertNotIn('measure_heart_rate', stdin)


if __name__ == '__main__':
    unittest.main()
