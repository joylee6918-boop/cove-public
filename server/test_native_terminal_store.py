"""Synthetic native terminal projection: records only, never model dispatch."""
import tempfile
import unittest
from pathlib import Path

from storage import Store, APIError


class NativeTerminalStoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.tmp.name) / 'data')
        self.store.create_conversation('c')
        self.store.bind_thread('c', 'thread')

    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()

    def test_adoption_does_not_enqueue_and_duplicate_does_not_replay(self):
        job = self.store.adopt_native_turn('c', 'thread', 'turn', 'owner typed this')
        self.assertEqual(job['state'], 'running')
        self.assertIsNone(self.store.claim())
        self.assertEqual(self.store.poll('c', 0)['messages'][0]['source'], 'native-terminal')
        again = self.store.adopt_native_turn('c', 'thread', 'turn', 'owner typed this')
        self.assertTrue(again['duplicate'])
        self.assertEqual(again['message'], job['message'])
        self.store.stream(job['message'], 'native final')
        self.store.finish(job['message'], 'complete')
        again = self.store.adopt_native_turn('c', 'thread', 'turn', 'owner typed this')
        self.assertEqual(again['state'], 'complete')
        self.assertEqual(len(self.store.poll('c', 0)['messages']), 2)

    def test_wrong_thread_changed_body_and_overlap_rejected(self):
        with self.assertRaises(APIError):
            self.store.adopt_native_turn('c', 'other', 'turn', 'text')
        self.store.adopt_native_turn('c', 'thread', 'turn', 'text')
        for turn, text in [('turn', 'changed'), ('second', 'second text')]:
            with self.assertRaises(APIError):
                self.store.adopt_native_turn('c', 'thread', turn, text)

    def test_app_turn_cannot_be_reinterpreted_as_terminal_turn(self):
        self.store.accept({'id': 'u', 'conversationID': 'c', 'text': 'app input'})
        job = self.store.claim()
        self.assertTrue(self.store.bind_turn(job['message'], 'turn', 'thread'))
        with self.assertRaises(APIError):
            self.store.adopt_native_turn('c', 'thread', 'turn', 'app input')

    def test_restart_does_not_reactivate_terminal_turn(self):
        job = self.store.adopt_native_turn('c', 'thread', 'turn', 'text')
        self.store.close()
        self.store = Store(Path(self.tmp.name) / 'data')
        repeated = self.store.adopt_native_turn('c', 'thread', 'turn', 'text')
        self.assertEqual(repeated['state'], 'failed')
        self.assertTrue(repeated['duplicate'])
        self.assertIsNone(self.store.claim())
        self.assertEqual(repeated['message'], job['message'])


if __name__ == '__main__':
    unittest.main()
