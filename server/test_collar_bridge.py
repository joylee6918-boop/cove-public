import copy
from datetime import datetime, timedelta, timezone
import http.client
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
import uuid

from collar_bridge import BridgeError, CollarBridge, iso, make_server


class FakeStore:
    _STATUS_EXCLUDED_SOURCES = {'manual', 'chat'}

    def __init__(self):
        self.samples, self.state, self.writes, self.queries = [], {}, [], []
        self.crash_before = self.crash_after = self.race = False

    def _samples_between(self, start, end, **kwargs):
        self.queries.append((start, end, kwargs))
        return copy.deepcopy(self.samples)  # Deliberately ignores scope.

    def get_command_state(self):
        return copy.deepcopy(self.state)

    def _write_command(self, command):
        if self.crash_before:
            raise RuntimeError('SECRET upstream error')
        self.writes.append(copy.deepcopy(command))
        self.state = copy.deepcopy(command)
        if self.race:
            self.state['command_id'] = 'unrelated'
        if self.crash_after:
            raise RuntimeError('SECRET after write')

    def create_command(self, *_args, **_kwargs):
        raise AssertionError('Must never create command with automatic watch alert')

    def send_watch_alert(self, *_args, **_kwargs):
        raise AssertionError('Must never push')


class FakePush:
    def __init__(self):
        self.calls = []
        self.fail = False

    def send_measurement(self, identifier):
        self.calls.append(identifier)
        if self.fail:
            raise RuntimeError('SECRET push failure')
        return {'status': 'accepted', 'httpStatus': 200, 'apnsID': identifier}


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.now = datetime(2026, 9, 15, 12, tzinfo=timezone.utc)
        self.hs = FakeStore()
        self.bridge = CollarBridge(self.hs, 'x'*40, self.directory.name, lambda: self.now)
        self.body = {'metrics': ['sleep', 'restingHeartRate', 'heartRate', 'steps', 'hrv'],
                     'startAt': iso(self.now-timedelta(hours=24)), 'endAt': iso(self.now)}

    def sample(self, kind, value=60, unit='count/min', hours=1, **extra):
        row = dict(type=kind, value=value, unit=unit, at=iso(self.now-timedelta(hours=hours)), source='watch')
        row.update(extra)
        return row

    def test_token_and_permissions(self):
        for token in ('', 'short', ' '+('x'*40)):
            with self.assertRaises(ValueError):
                CollarBridge(self.hs, token, self.directory.name)
        self.assertTrue(self.bridge.authorized('Bearer '+'x'*40))
        self.assertFalse(self.bridge.authorized('Bearer bad'))
        self.assertEqual(os.stat(self.directory.name).st_mode & 0o777, 0o700)
        self.assertEqual(os.stat(Path(self.directory.name)/'measurements.sqlite3').st_mode & 0o777, 0o600)
        for host in ('0.0.0.0', 'localhost', '192.168.1.1'):
            with self.assertRaises(ValueError):
                make_server(self.bridge, host=host, port=0)

    def test_exact_projection_and_empty(self):
        empty = self.bridge.summary(self.body)
        self.assertEqual(empty['snapshot']['metrics'], [])
        self.assertEqual(empty['missingMetricIDs'], self.body['metrics'])
        self.hs.samples = [self.sample('heart_rate', 70, secret='never', extra={'secret': 'never'}),
                           self.sample('heart_rate', 80, hours=0.5),
                           self.sample('heart_rate', 999, source='manual', hours=0.1),
                           self.sample('heart_rate', 999, source='watch', hours=-1),
                           self.sample('heart_rate', 999, hours=30),
                           self.sample('resting_heart_rate', 55),
                           self.sample('heart_rate_variability', 28, 'ms'),
                           self.sample('step_count', 100, 'count'),
                           self.sample('step_count', 100, 'count'),
                           self.sample('step_count', 200, 'count', hours=2),
                           self.sample('blood_pressure', 120)]
        result = self.bridge.summary(self.body)
        values = {m['id']: m for m in result['snapshot']['metrics']}
        self.assertEqual(values['heartRate']['value'], 80)
        self.assertEqual(values['steps']['value'], 300)
        self.assertEqual(values['restingHeartRate']['value'], 55)
        self.assertEqual(values['hrv']['value'], 28)
        self.assertNotIn('secret', json.dumps(result))
        self.assertEqual(set(values['heartRate']), {'id','title','value','unit','sampledAt','source'})
        self.assertEqual(self.hs.queries[-1][2]['exclude_sources'], {'manual', 'chat'})
        self.body['metrics'] = ['heartRate']
        result = self.bridge.summary(self.body)
        self.assertEqual([m['id'] for m in result['snapshot']['metrics']], ['heartRate'])
        self.assertEqual(self.hs.queries[-1][2]['types'], {'heart_rate'})

    def test_invalid_values_not_zero(self):
        self.hs.samples = [self.sample('heart_rate', value=value) for value in (True, -1, float('nan'), float('inf'), '65')]
        self.hs.samples += [self.sample('step_count', 1, 'count'), self.sample('step_count', 2, 'count')]
        self.assertEqual(self.bridge.summary(self.body)['snapshot']['metrics'], [])

    def test_bounds_and_schema(self):
        variants = [dict(self.body, surprise=True), dict(self.body, metrics=[]),
                    dict(self.body, metrics=['heartRate','heartRate']), dict(self.body, metrics=['secret']),
                    dict(self.body, metrics=[{}]), dict(self.body, startAt='2026-09-14T12:00:00'),
                    dict(self.body, startAt=iso(self.now-timedelta(hours=49))),
                    dict(self.body, endAt=iso(self.now+timedelta(seconds=61))),
                    dict(self.body, startAt=self.body['endAt'])]
        for body in variants:
            with self.subTest(body=body), self.assertRaises(BridgeError) as caught:
                self.bridge.summary(body)
            self.assertEqual(caught.exception.status, 400)
        self.assertEqual(self.hs.queries, [])

    def test_sleep_union_clips_and_ignores_awake(self):
        def seg(stage, lo, hi):
            return dict(stage=stage, start=iso(self.now-timedelta(hours=lo)), end=iso(self.now-timedelta(hours=hi)))
        extra = dict(totalSleep=99, segments=[seg('core', 26, 20), seg('deep', 22, 18),
                    seg('asleep', 22, 18), seg('awake', 18, 17), seg('rem', 17, 16)])
        self.hs.samples = [self.sample('sleep_analysis', extra=extra), self.sample('sleep_analysis', extra=extra)]
        value = self.bridge.summary(self.body)['snapshot']['metrics'][0]
        self.assertEqual(value['value'], 7)
        self.assertEqual(value['sampledAt'], iso(self.now-timedelta(hours=16)))
        self.assertEqual(value['source'], 'Collar · Apple Watch')

    def test_sleep_totals_complete_dedup_nonoverlap_only(self):
        def session(lo, hi, total):
            return self.sample('sleep_analysis', extra=dict(totalSleep=total,
                sleepStart=iso(self.now-timedelta(hours=lo)), sleepEnd=iso(self.now-timedelta(hours=hi))))
        first, second = session(12, 8, 3), session(7, 5, 1)
        self.hs.samples = [first, first, second]
        self.assertEqual(self.bridge.summary(self.body)['snapshot']['metrics'][0]['value'], 4)
        self.hs.samples.append(session(9, 6, 2))
        self.assertEqual(self.bridge.summary(self.body)['snapshot']['metrics'], [])
        self.hs.samples = [session(25, 20, 4)]
        self.assertEqual(self.bridge.summary(self.body)['snapshot']['metrics'], [])
        self.hs.samples = [self.sample('sleep_analysis', extra={'totalSleep': 8})]
        self.assertEqual(self.bridge.summary(self.body)['snapshot']['metrics'], [])

    def test_measure_idempotence_restart_no_push(self):
        identifier = str(uuid.uuid4())
        result = self.bridge.create_measurement({'requestID': identifier})
        self.assertEqual(result['measurement']['status'], 'pending')
        self.assertEqual(len(self.hs.writes), 1)
        self.assertEqual(set(self.hs.writes[0]), {'command_id','command','status','requested_at','duration_seconds','result'})
        self.assertEqual(self.hs.writes[0]['duration_seconds'], 30)
        self.assertEqual(self.bridge.create_measurement({'requestID': identifier}), result)
        restarted = CollarBridge(self.hs, 'x'*40, self.directory.name, lambda: self.now)
        self.assertEqual(restarted.create_measurement({'requestID': identifier}), result)
        self.assertEqual(len(self.hs.writes), 1)
        with self.assertRaises(BridgeError) as caught:
            self.bridge.create_measurement({'requestID':str(uuid.uuid4())})
        self.assertEqual(caught.exception.status, 429)
        self.now += timedelta(seconds=61)
        with self.assertRaises(BridgeError) as caught:
            self.bridge.create_measurement({'requestID':str(uuid.uuid4())})
        self.assertEqual(caught.exception.status, 409)

    def test_measure_no_clobber_or_leak(self):
        self.hs.state = {'status':'seen', 'command_id':'other', 'result':{'private':'secret'}}
        with self.assertRaises(BridgeError) as caught:
            self.bridge.create_measurement({'requestID':str(uuid.uuid4())})
        self.assertEqual(caught.exception.status, 409)
        self.assertEqual(self.hs.writes, [])
        with self.assertRaises(BridgeError) as caught:
            self.bridge.measurement(str(uuid.uuid4()))
        self.assertEqual(caught.exception.status, 404)
        self.hs.state = {}
        identifier = str(uuid.uuid4())
        self.bridge.create_measurement({'requestID':identifier})
        self.hs.state = {'status':'done','command_id':'other','result':{'private':'secret'}}
        result = self.bridge.measurement(identifier)
        self.assertEqual(result['measurement']['status'], 'unknown')
        self.assertNotIn('secret', json.dumps(result))

    def test_measure_crash_intent_never_replayed(self):
        identifier = str(uuid.uuid4())
        self.hs.crash_before = True
        self.assertEqual(self.bridge.create_measurement({'requestID':identifier})['measurement']['status'], 'unknown')
        self.hs.crash_before = False
        restarted = CollarBridge(self.hs, 'x'*40, self.directory.name, lambda: self.now)
        self.assertEqual(restarted.create_measurement({'requestID':identifier})['measurement']['status'], 'unknown')
        self.assertEqual(self.hs.writes, [])

    def test_measure_crash_after_reconciles_no_replay(self):
        identifier = str(uuid.uuid4())
        self.hs.crash_after = True
        self.assertEqual(self.bridge.create_measurement({'requestID':identifier})['measurement']['status'], 'unknown')
        self.assertEqual(self.bridge.create_measurement({'requestID':identifier})['measurement']['status'], 'pending')
        self.assertEqual(len(self.hs.writes), 1)

    def test_measure_race_is_unknown(self):
        self.hs.race = True
        result = self.bridge.create_measurement({'requestID':str(uuid.uuid4())})
        self.assertEqual(result['measurement']['status'], 'unknown')

    def test_new_measurement_alert_is_claimed_once(self):
        push = FakePush()
        bridge = CollarBridge(self.hs, 'x'*40, self.directory.name, lambda: self.now, push)
        identifier = str(uuid.uuid4())
        self.assertEqual(bridge.create_measurement({'requestID':identifier})['measurement']['status'], 'pending')
        self.assertEqual(push.calls, [identifier])
        restarted = CollarBridge(self.hs, 'x'*40, self.directory.name, lambda: self.now, push)
        restarted.create_measurement({'requestID':identifier})
        self.assertEqual(push.calls, [identifier])

    def test_alert_only_after_matching_command_and_never_retries_uncertain(self):
        push = FakePush()
        push.fail = True
        bridge = CollarBridge(self.hs, 'x'*40, self.directory.name, lambda: self.now, push)
        identifier = str(uuid.uuid4())
        self.assertEqual(bridge.create_measurement({'requestID':identifier})['measurement']['status'], 'unknown')
        push.fail = False
        self.assertEqual(bridge.create_measurement({'requestID':identifier})['measurement']['status'], 'pending')
        self.assertEqual(push.calls, [identifier])

        self.now += timedelta(seconds=61)
        self.hs.state = {}
        self.hs.race = True
        other = str(uuid.uuid4())
        self.assertEqual(bridge.create_measurement({'requestID':other})['measurement']['status'], 'unknown')
        self.assertEqual(push.calls, [identifier])

    def test_crash_after_command_reconciles_one_alert_without_command_replay(self):
        push = FakePush()
        bridge = CollarBridge(self.hs, 'x'*40, self.directory.name, lambda: self.now, push)
        identifier = str(uuid.uuid4())
        self.hs.crash_after = True
        self.assertEqual(bridge.create_measurement({'requestID':identifier})['measurement']['status'], 'unknown')
        self.assertEqual(push.calls, [])
        self.hs.crash_after = False
        self.assertEqual(bridge.create_measurement({'requestID':identifier})['measurement']['status'], 'pending')
        self.assertEqual(push.calls, [identifier])
        self.assertEqual(len(self.hs.writes), 1)

    def test_two_bridge_instances_serialize_duplicate(self):
        second = CollarBridge(self.hs, 'x'*40, self.directory.name, lambda: self.now)
        identifier, barrier, results = str(uuid.uuid4()), threading.Barrier(2), []
        def run(bridge):
            barrier.wait(timeout=2)
            results.append(bridge.create_measurement({'requestID':identifier}))
        threads = [threading.Thread(target=run, args=(bridge,)) for bridge in (self.bridge, second)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=3)
            self.assertFalse(thread.is_alive())
        self.assertEqual(len(results), 2)
        self.assertEqual(results[0], results[1])
        self.assertEqual(len(self.hs.writes), 1)

    def test_busy_appearing_after_intent_is_not_overwritten(self):
        calls = []
        def state():
            calls.append(1)
            return {} if len(calls) == 1 else {'status':'pending','command_id':'other'}
        self.hs.get_command_state = state
        identifier = str(uuid.uuid4())
        self.assertEqual(self.bridge.create_measurement({'requestID':identifier})['measurement']['status'], 'unknown')
        self.assertEqual(self.hs.writes, [])
        self.hs.get_command_state = lambda: {}
        self.assertEqual(self.bridge.create_measurement({'requestID':identifier})['measurement']['status'], 'unknown')
        self.assertEqual(self.hs.writes, [])

    def test_measure_results_require_valid_samples(self):
        identifier = str(uuid.uuid4())
        self.bridge.create_measurement({'requestID':identifier})
        for status in ('seen', 'expired'):
            self.hs.state['status'] = status
            self.assertEqual(self.bridge.measurement(identifier)['measurement']['status'], status)
        self.hs.state.update(status='done', completed_at=iso(self.now+timedelta(seconds=30)),
                             result={'heart_rate_average':70,'heart_rate_minimum':60,'heart_rate_maximum':80,
                                     'sample_count':0, 'readings':[], 'private':'never'})
        self.assertEqual(self.bridge.measurement(identifier)['measurement']['status'], 'done')
        self.assertIsNone(self.bridge.measurement(identifier)['measurement']['result'])
        self.hs.state['result']['sample_count'] = 5
        result = self.bridge.measurement(identifier)['measurement']
        self.assertEqual(result['status'], 'done')
        self.assertEqual(result['result']['sampleCount'], 5)
        self.assertNotIn('readings', json.dumps(result))
        self.assertNotIn('never', json.dumps(result))
        self.hs.state['result']['heart_rate_minimum'] = 90
        self.assertEqual(self.bridge.measurement(identifier)['measurement']['status'], 'unknown')

    def test_http_auth_and_validation(self):
        server = make_server(self.bridge, port=0)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        def call(method, path, body=None, auth=True, raw=False):
            client = http.client.HTTPConnection(*server.server_address, timeout=3)
            headers = {'Authorization':'Bearer '+'x'*40} if auth else {}
            encoded = body if raw else (json.dumps(body) if body is not None else None)
            client.request(method, path, encoded, headers)
            response = client.getresponse()
            status, data = response.status, json.loads(response.read())
            self.assertEqual(response.getheader('Cache-Control'), 'no-store')
            client.close()
            return status, data
        self.assertEqual(call('GET','/health',auth=False)[0],401)
        self.assertEqual(call('GET','/health'),(200,{'ok':True,'service':'collar-cove','protocol':1}))
        self.assertEqual(call('POST','/summary',self.body,auth=False)[0],401)
        self.assertEqual(self.hs.queries,[])
        self.assertEqual(call('POST','/summary',self.body)[0],200)
        self.assertEqual(call('POST','/measurements', {'requestID':str(uuid.uuid4()),'durationSeconds':60})[0],400)
        self.assertEqual(call('POST','/summary','{"metrics":[],"metrics":[]}',raw=True)[0],400)
        self.assertEqual(call('GET','/measurements/not-a-uuid')[0],400)
        self.assertEqual(call('GET','/measurements/'+str(uuid.uuid4()))[0],404)
        self.assertEqual(call('GET','/raw')[0],404)
        self.assertEqual(call('POST','/summary','x'*5000,raw=True)[0],413)
        identifier = str(uuid.uuid4())
        self.assertEqual(call('POST','/measurements',{'requestID':identifier},auth=False)[0],401)
        self.assertEqual(self.hs.writes, [])
        self.assertEqual(call('POST','/measurements',{'requestID':identifier})[1]['measurement']['status'],'pending')
        self.assertEqual(call('GET','/measurements/'+identifier)[1]['measurement']['status'],'pending')


if __name__ == '__main__':
    unittest.main()
