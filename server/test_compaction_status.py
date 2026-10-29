import json,sqlite3,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
import compaction_status as cs

class CompactionTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.home=Path(self.tmp.name);(self.home/'sessions').mkdir()
        self.path=self.home/'sessions'/'thread.jsonl';self.path.write_text('')
        with sqlite3.connect(self.home/'state_5.sqlite') as db:
            db.execute('CREATE TABLE threads(id TEXT, rollout_path TEXT)')
            db.execute('INSERT INTO threads VALUES(?,?)',('thread',str(self.path)))
        cs._CACHE.clear()
    def add(self,kind='compacted',stamp='2026-10-10T02:00:00Z'):
        with self.path.open('a') as f:f.write(json.dumps({'type':kind,'timestamp':stamp,'payload':{'type':'context_compacted'}})+'\n')
    def read(self):return cs.compaction_status(self.home,'thread')
    def test_zero_is_verified(self):self.assertEqual(self.read()['compactionCount'],0)
    def test_count_and_last_canonical_only(self):
        for _ in range(12):self.add()
        self.add('event_msg');self.add('compacted','2026-10-10T03:00:00Z')
        self.assertEqual(self.read()['compactionCount'],13)
        self.assertEqual(self.read()['lastCompactedAt'],'2026-10-10T03:00:00Z')
        self.assertNotIn('payload',str(self.read()))
    def test_cached_refresh_does_not_double_count(self):
        self.add();self.read();self.add();self.assertEqual(self.read()['compactionCount'],2)
        self.assertEqual(self.read()['compactionCount'],2)
    def test_truncate_rescans(self):
        self.add();self.add();self.read();self.path.write_text('');self.assertEqual(self.read()['compactionCount'],0)
    def test_replacement_rescans(self):
        self.add();self.read();other=self.path.with_suffix('.new');other.write_text('');other.replace(self.path)
        self.assertEqual(self.read()['compactionCount'],0)
    def test_missing_is_unknown_not_zero(self):self.assertIsNone(cs.compaction_status(self.home,'other')['compactionCount'])
    def test_outside_history_rejected(self):
        with sqlite3.connect(self.home/'state_5.sqlite') as db:db.execute('UPDATE threads SET rollout_path=?',(str(self.home/'outside.jsonl'),))
        self.assertIsNone(self.read()['compactionCount'])
    def test_partial_line_waits_then_counts(self):
        self.path.write_text('{"type":"compacted",')
        self.assertIsNone(self.read()['compactionCount'])
        with self.path.open('a') as f:f.write('"timestamp":"2026-10-10T00:00:00Z"}\n')
        self.assertEqual(self.read()['compactionCount'],1)
    def test_corrupt_record_not_silent_zero(self):
        self.path.write_text('broken\n');self.assertIsNone(self.read()['compactionCount'])
    def test_legitimate_nine_megabyte_tool_result_does_not_hide_compactions(self):
        with self.path.open('w') as f:
            f.write(json.dumps({'type':'response_item','timestamp':'2026-10-10T01:00:00Z',
                                'payload':{'type':'custom_tool_call_output','output':'x'*(9*1024*1024)}})+'\n')
        self.add()
        self.assertEqual(self.read()['compactionCount'],1)
    def test_budget_returns_unknown_until_complete(self):
        self.add();self.add()
        with patch.object(cs,'SCAN_BYTES',1):
            self.assertIsNone(self.read()['compactionCount'])
            self.assertEqual(self.read()['compactionCount'],2)
    def test_no_timestamp_is_unknown(self):
        self.add(stamp=None);self.assertIsNone(self.read()['compactionCount'])
if __name__=='__main__':unittest.main()
