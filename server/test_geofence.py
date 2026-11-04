"""Isolated synthetic region events; no real coordinates, phone, model or network."""
import json
import tempfile
import unittest
from pathlib import Path
from geofence import Geofences
from location_share import LocationError, iso


class GeofenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.now = 1800000000.0
        self.path = Path(self.temp.name) / 'fences.sqlite'
        self.fences = Geofences(self.path, clock=lambda: self.now)

    def tearDown(self):
        self.fences.close(); self.temp.cleanup()

    def config(self, enabled=True, revision='config-1'):
        return dict(expectedRevision=self.fences.access()['revision'], revision=revision, deviceID='fixture-phone',
                    enabled=enabled, places=[{'id': 'home', 'radiusMeters': 300}, {'id': 'work', 'radiusMeters': 200}])

    def enable(self):
        self.fences.configure(self.config())

    def event(self, **changes):
        return dict(dict(id='event-1', revision='config-1', deviceID='fixture-phone', sequence=1,
                         placeID='home', state='inside', kind='transition', observedAt=iso(self.now)), **changes)

    def test_default_off_no_context(self):
        self.assertEqual(self.fences.context(), '')
        with self.assertRaises(LocationError): self.fences.accept(self.event())

    def test_config_idempotency_cas_no_coordinate_ingress(self):
        body = self.config(); first = self.fences.configure(body)
        self.assertEqual(first, self.fences.configure(body))
        with self.assertRaises(LocationError): self.fences.configure(dict(body, revision='new'))
        invalid = self.config(revision='new'); invalid['places'][0]['latitude'] = 1
        with self.assertRaises(LocationError): self.fences.configure(invalid)

    def test_event_ack_is_immutable_and_replay_safe(self):
        self.enable(); event = self.event()
        self.assertEqual(self.fences.accept(event), self.fences.accept(event))
        self.assertEqual(len(self.fences.status()['events']), 1)
        with self.assertRaises(LocationError): self.fences.accept(dict(event, state='outside'))
        with self.assertRaises(LocationError): self.fences.accept(dict(event, id='different'))

    def test_revoke_clears_and_rejects_pending_events(self):
        self.enable(); self.fences.accept(self.event())
        self.fences.configure(self.config(enabled=False, revision='off'))
        self.assertEqual(self.fences.context(), '')
        self.assertEqual(self.fences.status()['events'], [])
        with self.assertRaises(LocationError): self.fences.accept(self.event())

    def test_edit_revision_rejects_old_queue_and_other_device(self):
        self.enable(); self.fences.configure(self.config(revision='edited'))
        with self.assertRaises(LocationError): self.fences.accept(self.event())
        with self.assertRaises(LocationError): self.fences.accept(self.event(revision='edited', deviceID='other'))

    def test_late_sequence_cannot_overwrite_newer_state(self):
        self.enable()
        self.fences.accept(self.event(id='new', sequence=3, state='outside'))
        self.fences.accept(self.event(id='old', sequence=2, observedAt=iso(self.now - 300)))
        self.assertEqual(self.fences.status()['latest'][0]['state'], 'outside')

    def test_original_time_delayed_and_stale_explicit(self):
        self.enable(); self.fences.accept(self.event(observedAt=iso(self.now - 7*3600)))
        value = self.fences.status()['latest'][0]
        self.assertTrue(value['stale']); self.assertTrue(value['delayed'])
        self.assertNotEqual(value['observedAt'], value['receivedAt'])

    def test_initial_reconcile_not_arrival_and_no_model_jobs(self):
        self.enable(); self.fences.accept(self.event(kind='initial'))
        self.assertEqual(self.fences.status()['latest'][0]['kind'], 'initial')
        self.assertIn('不是刚刚到达', self.fences.context())
        self.assertNotIn('latitude', self.fences.context())
        tables = [r[0] for r in self.fences.db.execute("SELECT name FROM sqlite_master WHERE type='table'")]
        self.assertEqual(set(tables), {'fence_access', 'fence_events'})

    def test_boundary_jitter_retains_latest_with_uncertainty(self):
        self.enable(); self.fences.accept(self.event())
        self.now += 20
        self.fences.accept(self.event(id='exit', sequence=2, state='outside'))
        latest = self.fences.status()['latest'][0]
        self.assertEqual(latest['state'], 'outside'); self.assertTrue(latest['boundaryUncertain'])

    def test_timestamp_and_schema_validation(self):
        self.enable()
        for changes in ({'observedAt': iso(self.now+120)}, {'observedAt': iso(self.now-8*86400)},
                        {'sequence': True}, {'kind': 'fake'}, {'placeID': 'arbitrary'}, {'latitude': 1}):
            with self.subTest(changes=changes), self.assertRaises(LocationError): self.fences.accept(self.event(**changes))

    def test_reopen_and_separate_companions(self):
        self.enable(); self.fences.accept(self.event())
        self.fences.close(); self.fences = Geofences(self.path, clock=lambda: self.now)
        self.assertEqual(self.fences.status()['latest'][0]['state'], 'inside')
        other = Geofences(Path(self.temp.name)/'other.sqlite')
        self.assertFalse(other.access()['enabled']); other.close()

    def test_retention_expires_without_new_upload(self):
        self.enable(); self.fences.accept(self.event()); self.now += 8*86400
        self.assertEqual(self.fences.status()['latest'], [])

    def test_empty_config_cannot_enable_and_bad_radius_rejected(self):
        for places in ([], [{'id':'home','radiusMeters':float('nan')}], [{'id':'home','radiusMeters':99}]):
            with self.assertRaises(LocationError): self.fences.configure(dict(self.config(), places=places))

    def test_backward_clock_does_not_claim_a_new_current_state(self):
        self.enable(); self.fences.accept(self.event())
        with self.assertRaises(LocationError): self.fences.accept(self.event(id='backward', sequence=2, observedAt=iso(self.now-120)))


if __name__ == '__main__': unittest.main()
