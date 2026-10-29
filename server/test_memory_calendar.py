"""Synthetic OB frontmatter only. No real memory, service or account access."""
import io
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

import memory_calendar as calendar


class MemoryCalendarTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / 'synthetic-ob'
        (self.root / 'dynamic').mkdir(parents=True)

    def tearDown(self):
        self.temp.cleanup()

    def bucket(self, identifier, created='2026-09-15T20:00:00', folder='dynamic', extra='', name=None, body='PRIVATE BODY MUST NOT BE READ'):
        parent = self.root / folder; parent.mkdir(parents=True,exist_ok=True)
        path = parent / ((name or identifier)+'.md')
        path.write_text("---\nid: '"+identifier+"'\ncreated: '"+created+"'\n"+extra+'---\n'+body,encoding='utf-8')
        return path

    def read(self, month='2026-09', **kwargs):
        return calendar.snapshot(month,buckets_path=self.root,naive_timezone='UTC',**kwargs)

    def unavailable(self, call):
        with self.assertRaises(calendar.CalendarError) as caught: call()
        self.assertEqual(caught.exception.status,503)
        self.assertNotIn(str(self.root),caught.exception.message)
        self.assertNotIn('PRIVATE',caught.exception.message)

    def test_utc_naive_and_explicit_offsets_cross_day_and_month(self):
        self.bucket('naive','2026-08-31T16:00:00')
        self.bucket('z','2026-09-01T15:59:59Z')
        self.bucket('offset','2026-09-01T17:00:00+01:00')
        self.bucket('before','2026-08-31T15:59:59Z')
        self.bucket('next-month','2026-09-30T16:00:00Z')
        response=self.read()
        self.assertEqual(response['days'][0],{'date':'2026-09-01','count':2})
        self.assertEqual(response['days'][1]['count'],1)
        self.assertEqual(response['total'],3)
        self.assertEqual(len(response['days']),30)
        self.assertEqual(response['timezone'],'Asia/Shanghai')
        self.assertEqual(response['metric'],'created');self.assertEqual(response['source'],'ombre')
        self.assertEqual(set(response),{'month','timezone','source','metric','days','updatedAt','total'})

    def test_all_six_categories_archive_and_duplicate_id_once(self):
        for index,folder in enumerate(calendar.DIRECTORIES):self.bucket(str(index),folder=folder+'/nested')
        self.bucket('0',folder='archive',name='duplicate')
        self.bucket('not-a-bucket',folder='_ledger')
        self.bucket('also-not-a-bucket',folder='_media')
        response=self.read();self.assertEqual(response['total'],6)
        self.assertEqual(response['days'][15]['count'],6)

    def test_deleted_excluded_even_if_created_invalid_and_duplicate_active_exists(self):
        self.bucket('deleted','not a date',extra="deleted_at: '2026-09-16T00:00:00'\n")
        self.bucket('duplicate','2026-09-15T20:00:00')
        self.bucket('duplicate','not a date',folder='archive',name='deleted-copy',extra="deleted_at: '2026-09-16T00:00:00'\n")
        self.bucket('null',extra='deleted_at: null\n')
        self.bucket('empty',extra="deleted_at: ''\n")
        self.bucket('false',extra='deleted_at: false\n')
        self.assertEqual(self.read()['total'],3)

    def test_conflicting_duplicate_dates_unavailable(self):
        self.bucket('same','2026-09-10T00:00:00');self.bucket('same','2026-09-11T00:00:00',folder='archive')
        self.unavailable(self.read)

    def test_missing_invalid_dates_and_partial_header_are_unknown(self):
        for header in ('---\nid: x\n---\n','---\nid: x\ncreated: not-a-date\n---\n','---\nid: x\ncreated: 2026-09-15\n','NO FRONTMATTER\n'):
            path=self.root/'dynamic'/'bad.md';path.write_text(header)
            self.unavailable(self.read);path.unlink()
        self.bucket('impossible','2026-02-30')
        self.unavailable(self.read)
        (self.root/'dynamic'/'impossible.md').unlink()
        self.bucket('overflow','9999-12-31T23:59:59Z')
        self.unavailable(self.read)

    def test_date_only_leap_month_and_valid_empty_source(self):
        self.assertEqual(self.read('2024-02')['total'],0)
        self.assertEqual(len(self.read('2024-02')['days']),29)
        self.bucket('date-only','2024-02-29')
        self.assertEqual(self.read('2024-02')['days'][-1]['count'],1)

    def test_strict_month_validation_before_source_access(self):
        for month in ('2026-9','2026-00','2026-13','0000-01','2026-09/',' 2026-09','2026-09\n','２０２６-０９',None,202609):
            with self.assertRaises(calendar.CalendarError) as caught:calendar.snapshot(month)
            self.assertEqual(caught.exception.status,400)

    def test_explicit_configuration_required_unknown_path_timezone_and_no_categories(self):
        with patch.dict(os.environ,{'COVE_OB_BUCKETS_PATH':'','COVE_OB_NAIVE_TIMEZONE':''}):
            self.unavailable(lambda:calendar.snapshot('2026-09'))
            self.unavailable(lambda:calendar.snapshot('2026-09',self.root))
        self.unavailable(lambda:calendar.snapshot('2026-09','relative/source','UTC'))
        self.unavailable(lambda:calendar.snapshot('2026-09',self.root/'missing','UTC'))
        self.unavailable(lambda:calendar.snapshot('2026-09',self.root,'not/a/timezone'))
        self.unavailable(lambda:calendar.snapshot('2026-09',self.temp.name,'UTC'))

    def test_symlink_file_directory_root_and_hardlinks_refused(self):
        target=self.bucket('outside',folder='_media')
        link=self.root/'dynamic'/'link.md';link.symlink_to(target)
        self.unavailable(self.read);link.unlink()
        link=self.root/'dynamic'/'nested';link.symlink_to(target.parent,target_is_directory=True)
        self.unavailable(self.read);link.unlink()
        link=Path(self.temp.name)/'linked-root';link.symlink_to(self.root,target_is_directory=True)
        self.unavailable(lambda:calendar.snapshot('2026-09',link,'UTC'));link.unlink()
        os.link(target,self.root/'dynamic'/'hard.md');self.unavailable(self.read)

    def test_scalar_subset_safe_and_relevant_yaml_objects_refused(self):
        path=self.root/'dynamic'/'quoted.md'
        path.write_text('---\nid: "quoted" # comment\ncreated: 2026-09-15T20:00:00 # comment\nname: !!python/object/apply:os.system ["NEVER EXECUTE"]\nquotes: |\n  created: not-a-real-key\n---\nPRIVATE')
        self.assertEqual(self.read()['total'],1)
        for value in ('!!timestamp 2026-09-15','*alias','&alias 2026-09-15','[2026-09-15]','|','"unterminated'):
            path.write_text('---\nid: x\ncreated: '+value+'\n---\nPRIVATE')
            self.unavailable(self.read)
        path.write_text('---\nid: x\ncreated: 2026-09-15\ncreated: 2026-09-16\n---\n')
        self.unavailable(self.read)

    def test_reader_never_requests_body_bytes(self):
        header=b"---\nid: x\ncreated: '2026-09-15'\n---\n"
        class HeaderOnly(io.BytesIO):
            def readline(inner,limit=-1):
                if inner.tell()>=len(header):raise AssertionError('Attempt to read body')
                value=super().readline(limit)
                if inner.tell()>len(header):raise AssertionError('Read crossed body boundary')
                return value
            def read(inner,*_):raise AssertionError('Unbounded/prefetch body read')
        stream=HeaderOnly(header+b'PRIVATE BODY')
        self.assertEqual(calendar._read_header(stream,[0],time.monotonic()+10)['id'],'x')
        self.assertEqual(stream.tell(),len(header))
        path=self.bucket('actual')
        path.write_bytes(b"---\nid: actual\ncreated: '2026-09-15'\n---\n"+b'\xff\xfePRIVATE BODY')
        self.assertEqual(self.read()['total'],1)

    def test_bounded_file_header_line_total_depth_and_deadline(self):
        self.bucket('a');self.bucket('b')
        for key,value in (('MAX_FILES',1),('MAX_ENTRIES',1),('MAX_HEADER_BYTES',10),('MAX_TOTAL_HEADER_BYTES',10),('MAX_LINE_BYTES',5),('MAX_DEPTH',0),('MAX_SCAN_SECONDS',-1)):
            with patch.object(calendar,key,value):self.unavailable(self.read)

    def test_concurrent_change_is_unavailable_not_partial_zero(self):
        path=self.bucket('racy');original=calendar._read_header
        def mutate(stream,budget,deadline):
            result=original(stream,budget,deadline)
            path.write_text('---\nid: racy\ncreated: 2026-09-16\n---\nPRIVATE CHANGED')
            return result
        with patch.object(calendar,'_read_header',side_effect=mutate):self.unavailable(self.read)
        # A post-read new bucket is caught by the second full metadata inventory.
        original_inventory=calendar._inventory;calls=[0]
        def add_file(fd,deadline):
            calls[0]+=1
            if calls[0]==2:self.bucket('new')
            return original_inventory(fd,deadline)
        with patch.object(calendar,'_inventory',side_effect=add_file):self.unavailable(self.read)

    def test_scan_does_not_modify_source(self):
        path=self.bucket('unchanged');before=path.read_bytes();stat_before=path.stat()
        self.read();after=path.stat()
        self.assertEqual(path.read_bytes(),before)
        self.assertEqual(after.st_mtime_ns,stat_before.st_mtime_ns)
        self.assertEqual(after.st_ctime_ns,stat_before.st_ctime_ns)

if __name__=='__main__':unittest.main()
