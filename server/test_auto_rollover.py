import os
import tempfile
import unittest
from unittest.mock import patch

from auto_rollover import threshold, token_limits, estimated_turn_tokens
from memory_context import same_conversation_context
from runtime import CodexRuntime
from storage import Store


class AutoRolloverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(self.temp.name)
        self.store.create_conversation('same-chat')
        self.store.bind_thread('same-chat', 'old-thread')
        self.store.accept({'id': 'owner-one', 'conversationID': 'same-chat',
                           'text': '记住我喜欢雨天散步'})

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def usage(self, tokens):
        self.store.record_context_usage({
            'threadId': 'old-thread',
            'tokenUsage': {'last': {'totalTokens': tokens},
                           'modelContextWindow': 258400},
        })

    def complete_owner(self):
        job = self.store.claim()
        self.store.bind_turn(job['message'], 'owner-turn', 'old-thread')
        self.store.complete_reply(job['message'], 'owner-turn', '正常回复', None)
        self.store.finish(job['message'], 'complete')
        return job

    def test_runtime_rolls_over_at_190k_without_hidden_model_turn(self):
        job = self.complete_owner()
        self.usage(190000)
        runtime = CodexRuntime(self.store, self.temp.name)
        with patch('compaction_status.compaction_status', return_value={
                'compactionCount': 0, 'lastCompactedAt': None, 'compactionError': None}):
            runtime.after_job(job, 'complete')
        status = self.store.auto_rollover_status('same-chat')
        self.assertEqual((status['state'], status['used_tokens'], status['trigger_kind']),
                         ('complete', 190000, 'token-soft'))
        self.assertIsNone(self.store.conversation('same-chat')['thread'])
        self.assertEqual(self.store.db.execute("SELECT count(*) FROM jobs").fetchone()[0], 1)
        runtime.close()

    def test_one_canonical_compaction_rolls_over_immediately(self):
        job = self.complete_owner()
        self.usage(120000)
        runtime = CodexRuntime(self.store, self.temp.name)
        with patch('compaction_status.compaction_status', return_value={
                'compactionCount': 1, 'lastCompactedAt': '2026-10-28T15:00:00Z',
                'compactionError': None}):
            runtime.after_job(job, 'complete')
        status = self.store.auto_rollover_status('same-chat')
        self.assertEqual((status['compaction_count'], status['trigger_kind']),
                         (1, 'canonical-compaction'))
        self.assertIsNone(self.store.conversation('same-chat')['thread'])
        runtime.close()

    def test_limits_are_190k_soft_210k_hard_and_invalid_env_is_ignored(self):
        self.assertEqual((threshold(), token_limits()), (1, (190000, 210000)))
        with patch.dict(os.environ, {
                'COVE_AUTO_ROLLOVER_COMPACTIONS': 'nope',
                'COVE_AUTO_ROLLOVER_SOFT_TOKENS': '249999',
                'COVE_AUTO_ROLLOVER_HARD_TOKENS': '190000'}):
            self.assertEqual((threshold(), token_limits()), (1, (190000, 210000)))

    def test_projected_hard_limit_detaches_before_claiming_owner_turn(self):
        self.usage(181000)
        runtime = CodexRuntime(self.store, self.temp.name)
        job = runtime.claim_job()
        self.assertEqual(job['message'], 'owner-one')
        self.assertIsNone(job['conversation']['thread'])
        status = self.store.auto_rollover_status('same-chat')
        self.assertEqual((status['trigger_kind'], status['used_tokens']),
                         ('projected-hard', 181000))
        runtime.close()

    def test_below_projected_hard_limit_keeps_thread(self):
        self.usage(170000)
        runtime = CodexRuntime(self.store, self.temp.name)
        job = runtime.claim_job()
        self.assertEqual(job['conversation']['thread'], 'old-thread')
        self.assertIsNone(self.store.auto_rollover_status('same-chat'))
        runtime.close()

    def test_turn_estimate_reserves_output_and_counts_large_attachments(self):
        plain = estimated_turn_tokens({'text': '继续'})
        attached = estimated_turn_tokens({'text': '继续', 'attachments': [
            {'mime': 'text/plain', 'size': 120000}, {'mime': 'image/png', 'size': 4},
        ]})
        self.assertGreaterEqual(plain, 30000)
        self.assertGreater(attached, plain + 40000)

    def test_authorized_current_repair_carries_a_continuity_anchor(self):
        note = '今天她身体不舒服；地铁口走不动时，希望我主动背她。'
        op = self.store.schedule_auto_rollover(
            'same-chat', 'old-thread', 2, 175996,
            'authorized-current-repair', note)
        self.assertEqual(op['state'], 'complete')
        marker = self.store.consume_window_reset('same-chat')
        self.assertEqual((marker['previousThread'], marker['compactionCount'],
                          marker['trigger']),
                         ('old-thread', 2, 'authorized-current-repair'))
        with patch.dict(os.environ, {'COVE_CHAT_DB': str(self.store.directory / 'cove.sqlite3')}):
            value = same_conversation_context('same-chat', None, marker)
        self.assertIn('身体不舒服', value)
        self.assertIn('我喜欢雨天散步', value)

    def test_restart_keeps_completed_detach_without_model_replay(self):
        self.store.schedule_auto_rollover('same-chat', 'old-thread', 1, 120000,
                                          'canonical-compaction')
        self.store.close()
        self.store = Store(self.temp.name)
        self.assertIsNone(self.store.conversation('same-chat')['thread'])
        self.assertEqual(self.store.auto_rollover_status('same-chat')['state'], 'complete')
        self.assertEqual(self.store.db.execute("SELECT count(*) FROM jobs").fetchone()[0], 1)


if __name__ == '__main__':
    unittest.main()
