"""Synthetic-only SQLite tests; never touch a real calendar or alarm."""
import json
import tempfile
import threading
import unittest
from datetime import datetime, timezone, timedelta
from types import SimpleNamespace

from storage import Store, APIError, encode
from device_actions import DeviceActionStore, delivery_guard

# Keep independently runnable before root integration lands.
TestStore = Store if issubclass(Store, DeviceActionStore) else type('TestStore', (DeviceActionStore, Store), {})


class DeviceActionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = TestStore(self.temp.name)
        self.store.init_device_actions()
        self.store.create_conversation('a'); self.store.create_conversation('b')
        self.store.accept({'id': 'incoming', 'conversationID': 'a', 'text': 'Synthetic fixture'})
        self.store.claim(); self.store.bind_turn('incoming', 'turn')
        self.store.set_data_access({'enabled': True})
        self.heartbeat()
        self.count = 0

    def tearDown(self):
        self.store.close(); self.temp.cleanup()

    def heartbeat(self, **overrides):
        states = dict(calendar='authorized', reminders='authorized', alarms='authorized'); states.update(overrides)
        return self.store.register_device_actions({'deviceID': 'PHONE', 'statuses': states})

    def call(self, tool='cove_request_device_action', args=None, call=None, conversation='a', message='incoming', turn='turn'):
        self.count += 1
        return self.store.assistant_device_tool(message, turn, call or str(self.count), tool, args if args is not None else {'operation': 'listAlarms'}, conversation)

    def request(self, args=None):
        return self.call(args=args)['request']

    def claim(self, request, **body):
        return self.store.claim_device_action('a', request['id'], body or {'deviceID': 'PHONE'})

    def success(self, request):
        return {'deviceID': 'phone', 'status': 'succeeded', 'result': {'actionID': request['id'].upper(), 'records': [{'id': 'synthetic', 'title': 'Fixture'}], 'message': 'Synthetic only'}}

    def response(self, request, body=None, conversation='a'):
        return self.store.respond_device_action(conversation, request['id'].upper(), self.success(request) if body is None else body)

    def assertError(self, status, fn, *args, **kwargs):
        with self.assertRaises(APIError) as caught: fn(*args, **kwargs)
        self.assertEqual(caught.exception.status, status)

    def test_request_claim_result_receipt_and_exact_response_replay(self):
        request = self.request(); self.assertEqual(request['id'], request['action']['id'])
        self.assertEqual(request['status'], 'pending'); self.assertNotIn('result', request)
        self.assertEqual(self.store.device_actions('a', 'PHONE')['requests'], [request])
        self.assertError(409, self.response, request)
        self.assertEqual(self.claim(request)['request']['status'], 'claimed')
        self.assertError(409, self.claim, request)
        response = self.response(request)
        self.assertEqual(response['request']['status'], 'succeeded')
        self.assertEqual(self.response(request), response)
        self.assertEqual(self.store.db.execute("SELECT count(*) FROM jobs WHERE message LIKE 'device-result-%'").fetchone()[0], 1)
        self.assertError(409, self.response, request, {'deviceID': 'phone', 'status': 'failed', 'error': 'Changed'})
        read = self.call('cove_read_device_action', {'requestID': request['id']})
        self.assertEqual(read['request']['result']['records'][0]['title'], 'Fixture')
        self.assertIsNone(read['request']['readAt'])
        self.store.mark_device_action_delivered('a', request['id'], 'incoming')
        self.assertEqual(self.store.device_action_continuation_state('a', request['id'], 'other'), 'wait')
        self.store.finish('incoming', 'complete')
        self.assertEqual(self.store.device_action_continuation_state('a', request['id'], 'other'), 'skipped')

    def test_offline_permissions_and_wrong_device_scope(self):
        self.heartbeat(calendar='denied')
        args = {'operation': 'listEvents', 'start': '2026-10-01T00:00:00+08:00', 'end': '2026-10-02T00:00:00+08:00'}
        self.assertError(409, self.request, args)
        request = self.request()
        self.assertError(403, self.claim, request, deviceID='other')
        self.assertEqual(self.store.device_actions('a', 'other'), {'requests': []})
        self.assertError(404, self.store.claim_device_action, 'b', request['id'], {'deviceID': 'phone'})
        self.assertError(403, self.response, request, {'deviceID': 'other', 'status': 'denied'})
        self.assertError(404, self.response, request, {'deviceID': 'phone', 'status': 'denied'}, 'b')
        self.assertError(409, self.call, conversation='b')
        with self.store.db:
            self.store.db.execute("UPDATE device_action_devices SET body=json_set(body,'$.reportedAt','2000-01-01T00:00:00Z')")
        self.assertFalse(self.call('cove_device_capabilities', {})['online'])
        self.assertError(409, self.request, {'operation': 'listReminders'})
        self.assertError(409, self.claim, request)

    def test_duplicate_call_changed_args_duplicate_pending_and_claimed(self):
        args = {'operation': 'createReminder', 'title': 'Synthetic'}
        first = self.call(args=args, call='same')
        self.assertEqual(self.call(args=args, call='same'), first)
        self.assertError(409, self.call, args={'operation': 'listReminders'}, call='same')
        self.assertError(409, self.call, args={'title': 'Synthetic', 'operation': 'createReminder'})
        self.claim(first['request'])
        self.assertError(409, self.request, args)
        self.assertError(409, self.claim, first['request'])
        self.store.finish('incoming', 'complete'); self.store.close()
        self.store = TestStore(self.temp.name); self.store.init_device_actions()
        self.assertError(409, self.claim, first['request'])
        self.assertEqual(self.response(first['request'])['request']['status'], 'succeeded')

    def test_expiry_no_claim_replay_and_late_claimed_response(self):
        request = self.request()
        with self.store.db:
            self.store.db.execute("UPDATE device_actions SET body=json_set(body,'$.action.expiresAt','2000-01-01T00:00:00Z') WHERE id=?", (request['id'],))
        self.assertError(409, self.claim, request)
        self.assertEqual(self.store.device_actions('a', 'phone')['requests'][0]['status'], 'expired')
        self.assertError(409, self.response, request, {'deviceID': 'phone', 'status': 'denied'})
        second = self.request(); self.claim(second)
        with self.store.db:
            self.store.db.execute("UPDATE device_actions SET body=json_set(body,'$.action.expiresAt','2000-01-01T00:00:00Z') WHERE id=?", (second['id'],))
        self.assertError(409, self.claim, second)
        self.assertEqual(self.response(second)['request']['status'], 'succeeded')

    def test_standing_revoke_blocks_read_create_claim_upload_and_cached_delivery(self):
        request = self.request(); self.claim(request); self.response(request)
        read = self.call('cove_read_device_action', {'requestID': request['id']}, call='read')
        pending = self.request({'operation': 'listReminders'})
        self.store.set_data_access({'enabled': False})
        self.assertError(403, self.call, 'cove_read_device_action', {'requestID': request['id']}, 'read')
        self.assertError(403, self.request, {'operation': 'listReminders'})
        self.assertError(403, self.claim, pending)
        self.assertError(403, self.response, request)
        self.assertError(403, self.store.mark_device_action_delivered, 'a', request['id'])
        # Mutation still requires local user confirmation, not standing read grant.
        mutation = self.request({'operation': 'createReminder', 'title': 'Synthetic'})
        self.claim(mutation); self.response(mutation)
        self.assertEqual(self.call('cove_read_device_action', {'requestID': mutation['id']})['request']['status'], 'succeeded')

    def test_validation_and_bounded_result(self):
        invalid = [{'operation': []}, {'operation': 'shell'}, {'operation': 'listAlarms', 'title': 'extra'},
                   {'operation': 'createReminder', 'title': ''}, {'operation': 'createReminder', 'title': 'x'*201},
                   {'operation': 'cancelAlarm', 'targetID': 'bad'}, {'operation': 'deleteEvent'},
                   {'operation': 'scheduleAlarm', 'title': 'Fixture', 'start': '2020-01-01T00:00:00Z'},
                   {'operation': 'listEvents', 'start': '2026-10-01', 'end': '2026-10-02'},
                   {'operation': 'listEvents', 'start': '2026-10-01T00:00:00Z', 'end': '2026-12-01T00:00:00Z'}]
        for args in invalid:
            with self.subTest(args=args): self.assertError(400, self.request, args)
        request = self.request(); self.claim(request)
        for value in ({'actionID': 'wrong', 'records': [], 'message': 'Fixture'}, {'actionID': request['id'], 'records': [{}], 'message': 'Fixture'}, {'actionID': request['id'], 'records': [], 'message': 'x'*1001}):
            self.assertError(400, self.response, request, {'deviceID': 'phone', 'status': 'succeeded', 'result': value})
        self.assertError(400, self.response, request, dict(self.success(request), error='not success'))
        self.assertError(400, self.response, request, dict(self.success(request), status='failed'))

    def test_denial_before_claim_and_no_writes_from_system_turns(self):
        request = self.request()
        result = self.response(request, {'deviceID': 'phone', 'status': 'denied'})
        self.assertEqual(result['request']['status'], 'denied')
        self.assertError(409, self.claim, request)
        self.store.finish('incoming', 'complete')
        job = self.store.claim(); self.store.bind_turn(job['message'], 'system-turn')
        self.assertError(403, self.call, args={'operation': 'createReminder', 'title': 'Forbidden'}, message=job['message'], turn='system-turn')
        self.assertEqual(self.call('cove_read_device_action', {'requestID': request['id']}, message=job['message'], turn='system-turn')['request']['status'], 'denied')

    def test_cancel_original_turn_prevents_late_execution(self):
        request = self.request()
        self.store.finish('incoming', 'interrupted')
        self.assertError(409, self.claim, request)
        self.assertEqual(self.store.device_actions('a', 'phone')['requests'][0]['status'], 'failed')

    def test_recurring_calendar_occurrences_may_share_identifier(self):
        request = self.request({'operation': 'listEvents', 'start': '2026-10-01T00:00:00Z', 'end': '2026-10-04T00:00:00Z'})
        self.claim(request)
        body = self.success(request)
        body['result']['records'] = [
            {'id': 'series', 'title': 'Synthetic occurrence', 'start': '2026-10-01T09:00:00Z', 'end': '2026-10-01T10:00:00Z'},
            {'id': 'series', 'title': 'Synthetic occurrence', 'start': '2026-10-02T09:00:00Z', 'end': '2026-10-02T10:00:00Z'}]
        self.assertEqual(len(self.response(request, body)['request']['result']['records']), 2)

    def test_reconnection_and_permission_loss_never_revive_pending_requests(self):
        request = self.request()
        with self.store.db:
            self.store.db.execute("UPDATE device_action_devices SET body=json_set(body,'$.reportedAt','2000-01-01T00:00:00Z')")
        self.heartbeat()
        self.assertError(409, self.claim, request)
        self.assertEqual(self.store._device_request('a', request['id'])['status'], 'failed')
        another = self.request()
        self.heartbeat(alarms='denied')
        self.heartbeat()
        self.assertError(409, self.claim, another)

    def test_delivery_guard_permission_revalidation_and_receipt(self):
        request = self.request(); self.claim(request); self.response(request)
        args = {'requestID': request['id']}
        result = self.call('cove_read_device_action', args, call='delivery')
        runtime = SimpleNamespace(store=self.store, state_lock=threading.RLock(), active={'conversation': 'a', 'turn': 'turn', 'message': 'incoming', 'cancel': threading.Event()}, file_permits=[{'conversation': 'a', 'turn': 'turn', 'call': 'delivery', 'tool': 'cove_read_device_action', 'arguments': args, 'used': True}])
        with delivery_guard(runtime, 'a', 'cove_read_device_action', args, result):
            self.assertIsNone(self.store._device_request('a', request['id'])['readAt'])
        self.assertIsNotNone(self.store._device_request('a', request['id'])['readAt'])
        self.store.set_data_access({'enabled': False})
        with self.assertRaises(APIError), delivery_guard(runtime, 'a', 'cove_read_device_action', args, result):
            self.fail('revoked result must never flush')
        self.store.set_data_access({'enabled': True})
        with self.assertRaises(APIError), delivery_guard(runtime, 'a', 'cove_read_device_action', args, result):
            self.fail('regrant must not revive the old result')
        self.assertError(403, self.call, 'cove_read_device_action', args, call='delivery')


if __name__ == '__main__':
    unittest.main()
