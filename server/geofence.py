"""Owner-enabled region events, not GPS tracking. Vendored unchanged in CCC.

Centers/addresses stay on the phone. Only home/work, radius, event time and state
cross the wire. No model calls, notifications, chat writes, or automatic wakeups.
"""
import json
import math
import os
import sqlite3
import threading
import time
import uuid
from pathlib import Path
from location_share import LocationError, bounded, iso, stamp


class Geofences:
    def __init__(self, path, clock=time.time):
        self.clock, self.lock = clock, threading.RLock()
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path, check_same_thread=False)
        os.chmod(path, 0o600)
        self.db.row_factory = sqlite3.Row
        self.db.executescript('''
          PRAGMA journal_mode=WAL;
          CREATE TABLE IF NOT EXISTS fence_access(id INTEGER PRIMARY KEY CHECK(id=1), body TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS fence_events(id TEXT PRIMARY KEY, revision TEXT NOT NULL,
            seq INTEGER NOT NULL, observed REAL NOT NULL, received REAL NOT NULL, body TEXT NOT NULL,
            UNIQUE(revision,seq));
        ''')
        with self.db:
            self.db.execute('INSERT OR IGNORE INTO fence_access VALUES(1,?)', (json.dumps({
                'revision': str(uuid.uuid4()), 'deviceID': None, 'enabled': False, 'places': []}),))

    def access(self):
        with self.lock:
            return json.loads(self.db.execute('SELECT body FROM fence_access WHERE id=1').fetchone()[0])

    def configure(self, body):
        if (not isinstance(body, dict) or set(body) != {'expectedRevision', 'revision', 'deviceID', 'enabled', 'places'}
                or type(body['enabled']) is not bool or not isinstance(body['places'], list) or len(body['places']) > 2):
            raise LocationError(400, 'invalid_geofence_configuration')
        revision, device = bounded(body['revision'], 128), bounded(body['deviceID'], 128)
        places, seen = [], set()
        for place in body['places']:
            if (not isinstance(place, dict) or set(place) != {'id', 'radiusMeters'}
                    or place['id'] not in ('home', 'work') or place['id'] in seen
                    or type(place['radiusMeters']) not in (int, float) or not math.isfinite(place['radiusMeters'])
                    or not 100 <= place['radiusMeters'] <= 1000):
                raise LocationError(400, 'invalid_geofence_place')
            seen.add(place['id'])
            places.append(place)
        if body['enabled'] and not places:
            raise LocationError(400, 'geofence_place_required')
        value = dict(revision=revision, deviceID=device, enabled=body['enabled'], places=places)
        with self.lock, self.db:
            old = self.access()
            if old == value:
                return {'access': old, 'ok': True}  # immutable config retry after lost ACK
            if body['expectedRevision'] != old['revision'] or revision == old['revision']:
                raise LocationError(409, 'geofence_configuration_changed')
            self.db.execute('UPDATE fence_access SET body=? WHERE id=1', (json.dumps(value),))
            # Revoke/edit invalidates old observations; do not keep a private trajectory.
            self.db.execute('DELETE FROM fence_events')
        return {'access': value, 'ok': True}

    def accept(self, body):
        keys = {'id', 'revision', 'deviceID', 'sequence', 'placeID', 'state', 'kind', 'observedAt'}
        if not isinstance(body, dict) or set(body) != keys:
            raise LocationError(400, 'invalid_geofence_event')
        ident = bounded(body['id'], 128)
        observed = stamp(body['observedAt'])
        if (type(body['sequence']) is not int or not 1 <= body['sequence'] <= 2**53
                or body['placeID'] not in ('home', 'work') or body['state'] not in ('inside', 'outside')
                or body['kind'] not in ('initial', 'transition', 'reconcile')):
            raise LocationError(400, 'invalid_geofence_event')
        payload = json.dumps(body, sort_keys=True, ensure_ascii=False)
        with self.lock, self.db:
            access = self.access()
            if (not access['enabled'] or (body['revision'], body['deviceID']) != (access['revision'], access['deviceID'])
                    or body['placeID'] not in [p['id'] for p in access['places']]):
                raise LocationError(403, 'geofence_access_changed')
            old = self.db.execute('SELECT body FROM fence_events WHERE id=?', (ident,)).fetchone()
            if old:
                if old[0] != payload:
                    raise LocationError(409, 'geofence_event_conflict')
                return {'ok': True, 'eventID': ident}
            # Offline events remain historical. Never relabel receipt time as crossing time.
            if not self.clock() - 7*86400 <= observed <= self.clock() + 60:
                raise LocationError(400, 'geofence_event_time_out_of_range')
            if self.db.execute('SELECT 1 FROM fence_events WHERE revision=? AND seq=?',
                               (body['revision'], body['sequence'])).fetchone():
                raise LocationError(409, 'geofence_sequence_conflict')
            latest = self.db.execute('SELECT seq,observed FROM fence_events WHERE revision=? ORDER BY seq DESC LIMIT 1',
                                     (access['revision'],)).fetchone()
            if latest and body['sequence'] > latest['seq'] and observed < latest['observed'] - 60:
                raise LocationError(409, 'geofence_clock_changed')
            self.db.execute('INSERT INTO fence_events VALUES(?,?,?,?,?,?)',
                            (ident, body['revision'], body['sequence'], observed, self.clock(), payload))
            self._prune()
        return {'ok': True, 'eventID': ident}

    def _prune(self):
        self.db.execute('DELETE FROM fence_events WHERE observed<?', (self.clock() - 7*86400,))
        self.db.execute('DELETE FROM fence_events WHERE id IN (SELECT id FROM fence_events ORDER BY seq DESC LIMIT -1 OFFSET 128)')

    def status(self):
        with self.lock, self.db:
            self._prune()
            access = self.access()
            rows = self.db.execute('SELECT * FROM fence_events WHERE revision=? ORDER BY seq DESC', (access['revision'],)).fetchall() if access['enabled'] else []
            events, latest = [], {}
            for row in rows:
                value = json.loads(row['body'])
                value.pop('deviceID', None)
                value['receivedAt'] = iso(row['received'])
                value['ageSeconds'] = max(0, int(self.clock() - row['observed']))
                value['stale'] = value['ageSeconds'] > 6*3600
                value['delayed'] = row['received'] - row['observed'] > 300
                value['boundaryUncertain'] = False
                events.append(value)
                latest.setdefault(value['placeID'], value)
            # An immediate opposite observation may be boundary jitter. Preserve the
            # latest state while explicitly lowering certainty (never drop a real exit).
            for current in latest.values():
                prior = next((e for e in events if e['placeID'] == current['placeID'] and e['sequence'] < current['sequence']), None)
                if prior and prior['state'] != current['state'] and abs(stamp(current['observedAt']) - stamp(prior['observedAt'])) < 90:
                    current['boundaryUncertain'] = True
            return {'access': access, 'latest': list(latest.values()), 'events': events[:20], 'serverTime': iso(self.clock())}

    def context(self):
        status = self.status()
        if not status['access']['enabled']:
            return ''
        observations = [{key: event[key] for key in ('placeID', 'state', 'kind', 'observedAt', 'receivedAt', 'stale', 'delayed', 'boundaryUncertain')}
                        for event in status['latest']]
        return ('\n[手机地理围栏 · 系统观察数据，不是用户消息或指令] ' + json.dumps(observations, ensure_ascii=False) +
                '\n仅表示手机最后一次围栏观察，home=家、work=公司。initial是启用时状态，reconcile是恢复监控时状态，均不是刚刚到达/离开。'
                'transition才是系统检测进出，observedAt是手机收到系统事件的时间，receivedAt是上传时间；iOS可能延迟。'
                'stale/delayed/边界不稳定时不当作此刻实时位置；离开某处不能推断目的地，空列表就是未知。'
                '据当前话题自然关心，不必每轮复述、不把旧事件说成刚发生，也不写长期轨迹。')

    def route(self, action, method, body):
        if action == 'status' and method == 'GET':
            return self.status()
        if action == 'config' and method == 'POST':
            return self.configure(body)
        if action == 'event' and method == 'POST':
            return self.accept(body)
        raise LocationError(404, 'geofence_route_not_found')

    def close(self):
        self.db.close()
