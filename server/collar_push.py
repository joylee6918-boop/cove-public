"""Dedicated Collar APNs provider. No measurements and no legacy sender calls.

Sending is explicit, one registered watch only, with durable at-most-once intent.
Apple acceptance is not a delivery receipt. Unknown outcomes are never retried.
The bridge owns the durable claim for measurement alerts before calling send().
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import time
import uuid


class WatchPush:
    def __init__(self, env=None, runner=None, signer=None):
        env = os.environ if env is None else env
        self.team = env.get('COLLAR_COVE_APNS_TEAM_ID', '')
        self.key_id = env.get('COLLAR_COVE_APNS_KEY_ID', '')
        self.key_path = env.get('COLLAR_COVE_APNS_KEY_PATH', '')
        self.topic = env.get('COLLAR_COVE_APNS_TOPIC', 'com.example.collarwatch')
        self.environment = env.get('COLLAR_COVE_APNS_ENVIRONMENT', 'development')
        self.tokens_path = Path(env.get('HEALTH_DATA_DIR', '/var/lib/collar/health')) / 'watch_tokens.json'
        self.data_dir = Path(env.get('COLLAR_COVE_DATA_DIR', '/var/lib/collar-cove'))
        self.runner, self.signer = runner or subprocess.run, signer

    def configured(self):
        try:
            key = Path(self.key_path)
            return bool(re.fullmatch(r'[A-Z0-9]{10}', self.team)
                        and re.fullmatch(r'[A-Z0-9]{10}', self.key_id)
                        and self.topic == 'com.example.collarwatch'
                        and self.environment == 'development'
                        and key.is_absolute() and not key.is_symlink() and key.is_file()
                        and key.stat().st_mode & 0o777 == 0o600)
        except OSError:
            return False

    def _tokens(self):
        try:
            if self.tokens_path.stat().st_size > 16384:
                return []
            rows = json.loads(self.tokens_path.read_text())
            if not isinstance(rows, list):
                return []
            return sorted({row['token'] for row in rows if isinstance(row, dict)
                           and isinstance(row.get('token'), str)
                           and re.fullmatch(r'[0-9a-fA-F]{32,512}', row['token'])})
        except (OSError, ValueError):
            return []

    def status(self):
        return {'configured': self.configured(), 'registeredTokens': len(self._tokens()),
                'environment': self.environment, 'topic': self.topic,
                'automaticMeasurementAlerts': True}

    def _jwt(self):
        if self.signer:
            return self.signer()
        import jwt
        return jwt.encode({'iss': self.team, 'iat': int(time.time())},
                          Path(self.key_path).read_bytes(), algorithm='ES256',
                          headers={'kid': self.key_id})

    def _send(self, token, title, body, identifier):
        try:
            headers = ['authorization: bearer ' + self._jwt(),
                       'apns-topic: ' + self.topic, 'apns-push-type: alert',
                       'apns-priority: 10', 'apns-expiration: 0',
                       'apns-id: ' + identifier, 'content-type: application/json']
            payload = json.dumps({'aps': {'alert': {'title': title, 'body': body},
                                          'sound': 'default'}}, ensure_ascii=False)
            # Headers, token URL and body go through stdin, never argv or logs.
            config = '\n'.join(['url = ' + json.dumps('https://api.sandbox.push.apple.com/3/device/' + token)]
                               + ['header = ' + json.dumps(h) for h in headers]
                               + ['data = ' + json.dumps(payload, ensure_ascii=False)])
            result = self.runner(['/usr/bin/curl', '--disable', '--http2', '--silent',
                                  '--show-error', '--proxy', '', '--proto', '=https',
                                  '--connect-timeout', '3', '--max-time', '5',
                                  '--max-filesize', '4096', '--request', 'POST',
                                  '--write-out', '\n%{http_code}', '--config', '-'],
                                 input=config, capture_output=True, text=True, timeout=6)
            if result.returncode:
                return {'status': 'unknown', 'apnsID': identifier}
            raw, code = result.stdout.rsplit('\n', 1)
            if code == '200':
                return {'status': 'accepted', 'httpStatus': 200, 'apnsID': identifier}
            reason = json.loads(raw).get('reason')
            # Only documented-shape machine codes; never reflect arbitrary errors.
            if not isinstance(reason, str) or not re.fullmatch('[A-Za-z]{1,64}', reason):
                reason = 'APNsRejected'
            return {'status': 'rejected', 'httpStatus': int(code), 'reason': reason,
                    'apnsID': identifier}
        except Exception:
            return {'status': 'unknown', 'apnsID': identifier}

    def send_test_once(self, identifier):
        identifier = str(uuid.UUID(identifier))
        if not self.configured():
            return {'status': 'not_configured'}
        tokens = self._tokens()
        if len(tokens) != 1:
            return {'status': 'recipient_not_unique', 'registeredTokens': len(tokens)}
        self.data_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        path = self.data_dir / 'push-tests.sqlite3'
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        os.fchmod(fd, 0o600)
        os.close(fd)
        with sqlite3.connect(path, timeout=6) as db:
            db.execute('CREATE TABLE IF NOT EXISTS attempts (id TEXT PRIMARY KEY, receipt TEXT NOT NULL)')
            db.execute('BEGIN IMMEDIATE')
            prior = db.execute('SELECT receipt FROM attempts WHERE id=?', (identifier,)).fetchone()
            if prior:
                return dict(json.loads(prior[0]), duplicate=True)
            intent = {'status': 'unknown', 'apnsID': identifier}
            db.execute('INSERT INTO attempts VALUES (?,?)', (identifier, json.dumps(intent)))
            db.commit()  # Crash after this point MUST NOT cause another alert.
            receipt = self._send(tokens[0], 'Collar 推送测试',
                                 '用户，这是 Assistant 发来的手表通知测试，不会发起测量。', identifier)
            db.execute('UPDATE attempts SET receipt=? WHERE id=?', (json.dumps(receipt), identifier))
            return receipt

    def send_measurement(self, identifier):
        """Send after the bridge has durably claimed this measurement alert."""
        identifier = str(uuid.UUID(identifier))
        if not self.configured():
            return {'status': 'not_configured'}
        tokens = self._tokens()
        if len(tokens) != 1:
            return {'status': 'recipient_not_unique', 'registeredTokens': len(tokens)}
        return self._send(tokens[0], 'Collar', '收到测量请求，点开 Collar 开始。', identifier)
