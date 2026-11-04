"""Synthetic queued-event regressions; no production data or model requests."""
from datetime import datetime, timedelta, timezone
import tempfile
import unittest
from uuid import uuid4

from app_events import AppEvents, iso
from storage import APIError
import test_app_events


class QueuedStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.now = datetime(2026, 10, 20, tzinfo=timezone.utc)
        self.store = AppEvents(self.temp.name, True, lambda: self.now)
        self.addCleanup(self.store.close)
        self.now += timedelta(days=10)

    def event(self, age=0, **changes):
        return dict(dict(id=str(uuid4()), app='Safari', action='open',
                         timestamp=iso(self.now - timedelta(seconds=age))), **changes)

    def rejected(self, body, status=400, queued=True):
        with self.assertRaises(APIError) as caught:
            self.store.ingest(body, queued=queued)
        self.assertEqual(caught.exception.status, status)

    def test_queued_and_legacy_time_boundaries(self):
        for age in [0, 601, 86400, 604800, -60]:
            event = self.event(age)
            self.assertEqual(self.store.ingest(event, queued=True),
                             dict(ok=True, id=event['id'], duplicate=False))
        self.rejected(self.event(604800.001))
        self.rejected(self.event(-60.001))
        self.rejected(self.event(601), queued=False)
        self.store.ingest(self.event(600))

    def test_lost_ack_keeps_original_id_even_after_window(self):
        body = self.event(86400)
        self.store.ingest(body, queued=True)
        self.now += timedelta(days=20)
        self.assertTrue(self.store.ingest(body, queued=True)['duplicate'])
        self.rejected(dict(body, action='close'), 409)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM events').fetchone()[0], 1)

    def test_pre_setup_import_rejected(self):
        self.now -= timedelta(days=9)
        self.rejected(self.event(86400.001))
        self.store.ingest(self.event(86400), queued=True)

    def test_aliases_and_strict_schema(self):
        for alias, canonical in [('WeChat', '微信'), ('rednote', '小红书')]:
            body = self.event(app=alias)
            self.store.ingest(body, queued=True)
            self.assertEqual(self.store.db.execute('SELECT app FROM events WHERE id=?', (body['id'],)).fetchone()[0], canonical)
        for body in [[], self.event(extra=True), self.event(id=True), self.event(action={}), self.event(timestamp='2026-10-30')]:
            self.rejected(body)


class QueuedRouteTests(test_app_events.AppEventRouteTests):
    def test_write_only_auth_and_queued_route(self):
        body = dict(id=str(uuid4()), app='Safari', action='open', timestamp=iso(datetime.now(timezone.utc)))
        path = '/v1/app-events/queued'
        for token in [None, self.owner, 'invalid']:
            self.assertEqual(self.call('POST', path, token, body)[0], 401)
        self.assertEqual(self.call('POST', path, self.shortcut, body),
                         (200, dict(ok=True, id=body['id'], duplicate=False)))
        self.assertTrue(self.call('POST', path, self.shortcut, body)[1]['duplicate'])
        self.assertEqual(self.call('POST', path+'?x=1', self.shortcut, body)[0], 400)
        self.assertFalse(self.app.wake.is_set())
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0], 0)


if __name__ == '__main__':
    unittest.main()
