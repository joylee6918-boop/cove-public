import tempfile
import threading
import time
import unittest

from storage import Store
import toy_control


class ToyControlTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.store = Store(self.directory.name)
        self.store.create_conversation('a')

    def tearDown(self):
        self.store.db.close()
        self.store.process_lock.close()
        self.directory.cleanup()

    def test_requires_phone_grant(self):
        result = self.store.assistant_toy_tool('m', 't', 'c', 'cove_bobobei_stop', {}, 'a')
        self.assertEqual(result['status'], 'unavailable')
        self.assertFalse(result['executed'])
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM toy_commands').fetchone()[0], 0)

    def test_phone_ack_is_required_before_success(self):
        session = self.store.grant_toy_session({'mode': 'untilRevoked'})['session']['id']
        result = {}

        def invoke():
            result.update(self.store.assistant_toy_tool(
                'm', 't', 'c', 'cove_bobobei_control',
                {'motion': 35, 'vibration': 25, 'rotation': 0}, 'a'))

        worker = threading.Thread(target=invoke)
        worker.start()
        deadline = time.monotonic() + 2
        poll = None
        while time.monotonic() < deadline:
            poll = self.store.poll_toy_commands(session, 0)
            if poll['commands']:
                break
            time.sleep(.01)
        self.assertEqual(poll['commands'][0]['motion'], 35)
        command = poll['commands'][0]['id']
        self.assertTrue(worker.is_alive(), 'tool must wait for the phone write receipt')
        self.store.acknowledge_toy_command(session, command, {
            'status': 'started', 'startedAt': '2026-09-28T10:00:00Z'})
        worker.join(2)
        self.assertFalse(worker.is_alive())
        self.assertTrue(result['executed'])
        self.assertEqual(result['status'], 'started')

    def test_phone_delay_expires_command_instead_of_late_delivery(self):
        session = self.store.grant_toy_session({'mode': 'untilRevoked'})['session']['id']
        old_wait = toy_control.TOY_TOOL_WAIT_SECONDS
        toy_control.TOY_TOOL_WAIT_SECONDS = .02
        try:
            result = self.store.assistant_toy_tool(
                'm', 't', 'late', 'cove_bobobei_control',
                {'motion': 20, 'vibration': 30, 'rotation': 40}, 'a')
        finally:
            toy_control.TOY_TOOL_WAIT_SECONDS = old_wait

        self.assertEqual(result['status'], 'expired')
        self.assertFalse(result['executed'])
        row = self.store.db.execute(
            "SELECT status FROM toy_commands WHERE id=?", (int(result['commandID']),)).fetchone()
        self.assertEqual(row['status'], 'canceled')
        poll = self.store.poll_toy_commands(session, 0)
        self.assertEqual(poll['commands'], [])

    def test_fenxin_requires_matching_owner_grant(self):
        self.store.grant_toy_session({'mode': 'untilRevoked', 'device': 'fenxin'})
        wrong = self.store.assistant_toy_tool(
            'm', 't', 'wrong', 'cove_bobobei_control',
            {'motion': 20, 'vibration': 0, 'rotation': 0}, 'a')
        self.assertEqual(wrong['status'], 'unavailable')
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM toy_commands').fetchone()[0], 0)

    def test_fenxin_command_is_high_level_only(self):
        session = self.store.grant_toy_session(
            {'mode': 'untilRevoked', 'device': 'fenxin'})['session']['id']
        result = {}

        def invoke():
            result.update(self.store.assistant_toy_tool(
                'm', 't', 'fenxin', 'cove_fenxin_control', {'level': 35}, 'a'))

        worker = threading.Thread(target=invoke)
        worker.start()
        deadline = time.monotonic() + 2
        poll = None
        while time.monotonic() < deadline:
            poll = self.store.poll_toy_commands(session, 0)
            if poll['commands']:
                break
            time.sleep(.01)
        command = poll['commands'][0]
        self.assertEqual(command['device'], 'fenxin')
        self.assertEqual(command['level'], 35)
        self.assertNotIn('hex', command)
        self.store.acknowledge_toy_command(session, command['id'], {
            'status': 'started', 'startedAt': '2026-09-29T10:00:00Z'})
        worker.join(2)
        self.assertTrue(result['executed'])


    def test_revoke_cancels_queued_and_restart_invalidates_session(self):
        first = self.store.grant_toy_session({'mode': 'untilRevoked'})['session']['id']
        self.store.db.execute(
            "INSERT INTO toy_commands(request_id,session,body,status,created) VALUES('r',?,'{}','queued','now')", (first,))
        self.store.db.commit()
        self.assertFalse(self.store.revoke_toy_session(first)['active'])
        self.assertEqual(self.store.db.execute("SELECT status FROM toy_commands WHERE request_id='r'").fetchone()[0], 'canceled')

        second = self.store.grant_toy_session({'mode': 'untilRevoked'})['session']['id']
        self.store.init_toy_control()
        self.assertFalse(self.store.toy_status()['active'])
        self.assertFalse(self.store.poll_toy_commands(second, 0)['active'])

    def test_rejects_arbitrary_or_out_of_range_commands(self):
        self.store.grant_toy_session({'mode': 'untilRevoked'})
        with self.assertRaises(Exception):
            self.store.assistant_toy_tool('m', 't', 'c', 'cove_bobobei_control',
                                          {'motion': 101, 'vibration': 0, 'rotation': 0}, 'a')
        with self.assertRaises(Exception):
            self.store.assistant_toy_tool('m', 't', 'c', 'cove_bobobei_control', {'hex': '00'}, 'a')


if __name__ == '__main__':
    unittest.main()
