"""Optional standard APNs alert; no conversation body on lock screen."""
import os
import time


def configured_push():
    names = ['COVE_APNS_TEAM_ID', 'COVE_APNS_KEY_ID', 'COVE_APNS_KEY_PATH', 'COVE_APNS_BUNDLE_ID']
    values = [os.getenv(name) for name in names]
    if not any(values):
        return None
    if not all(values):
        raise ValueError('All four COVE_APNS_* credential settings are required')
    # Optional only: httpx HTTP/2 and PyJWT ES256. No credentials copied from other applications.
    import httpx
    import jwt
    from pathlib import Path
    team, key_id, path, bundle = values
    key = Path(path).expanduser().read_text()
    sandbox = os.getenv('COVE_APNS_SANDBOX', '0') == '1'
    base = 'https://api.sandbox.push.apple.com' if sandbox else 'https://api.push.apple.com'
    client = httpx.Client(http2=True, timeout=10)
    cached = {'at': 0, 'token': None}

    def push(conversation, message, devices):
        if time.time() - cached['at'] > 2400:
            cached.update(at=time.time(), token=jwt.encode({'iss': team, 'iat': int(time.time())}, key, algorithm='ES256', headers={'kid': key_id}))
        payload = {'aps': {'alert': {'title': 'Cove', 'body': '助手 有一条新回复'}, 'sound': 'default'}, 'conversationID': conversation, 'messageID': message}
        for device in devices:
            try:
                response = client.post(base + '/3/device/' + device, json=payload,
                                       headers={'authorization': 'bearer ' + cached['token'], 'apns-topic': bundle,
                                                'apns-push-type': 'alert', 'apns-priority': '10', 'apns-expiration': '0'})
                if response.status_code != 200:
                    print('Cove APNs notification rejected: HTTP', response.status_code, flush=True)
            except httpx.HTTPError:
                print('Cove APNs notification transport failed', flush=True)
    return push
