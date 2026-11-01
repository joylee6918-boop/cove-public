"""Optional APNs alerts with explicit, per-device message-preview consent."""
import os
import time
import unicodedata
from weather_tools import weather_preview


GENERIC_BODY = 'Assistant 有一条新回复'


def notification_payload(conversation, message, preview_mode='generic'):
    """Generic mode never includes text, files, or a hidden alternate preview.

    A preview is deliberately short (at most 240 Unicode code points / 960 UTF-8
    bytes). Together with bounded Cove IDs this remains below APNs' 4096-byte
    limit, including when a transport JSON-escapes non-ASCII characters.
    """
    message_id = message.get('id') if isinstance(message, dict) else message
    body = GENERIC_BODY
    if preview_mode == 'content' and isinstance(message, dict):
        raw = weather_preview(message) or message.get('text') or ''
        # Flatten whitespace, remove invisible/control characters, then bound
        # the actual body. Never include tool results or attachment URLs.
        raw = ''.join(c if not unicodedata.category(c).startswith('C') else ' ' for c in raw)
        text = ' '.join(raw.split())
        if text:
            body = text if len(text) <= 240 else text[:239] + '…'
        elif message.get('stickerID'):
            body = 'Assistant 发来一个表情'
        elif message.get('attachments'):
            attachments = message['attachments']
            images_only = all(str(item.get('mime', '')).startswith('image/') for item in attachments)
            body = 'Assistant 发来图片' if images_only else 'Assistant 发来文件'
        elif message.get('attachmentURL'):
            body = 'Assistant 发来文件'
    if isinstance(message, dict) and message.get('locationRequest') is True:
        return {'aps': {'alert': {'title': 'Cove', 'body': 'Assistant 想看看你的位置，打开 Cove 即可自动分享'}, 'sound': 'default'},
                'conversationID': conversation, 'locationRequest': True}
    return {'aps': {'alert': {'title': 'Cove', 'body': body}, 'sound': 'default'},
            'conversationID': conversation, 'messageID': message_id}


def configured_push():
    names = ['COVE_APNS_TEAM_ID', 'COVE_APNS_KEY_ID', 'COVE_APNS_KEY_PATH', 'COVE_APNS_BUNDLE_ID']
    values = [os.getenv(name) for name in names]
    if not any(values):
        return None
    if not all(values):
        raise ValueError('All four COVE_APNS_* credential settings are required')
    # Optional only: httpx HTTP/2 and PyJWT ES256. No credentials copied from CCC.
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
        for device in devices:
            # Old string-only callers are always private. A device must have
            # explicitly selected content; unknown values fail closed.
            token = device.get('token') if isinstance(device, dict) else device
            mode = device.get('previewMode', 'generic') if isinstance(device, dict) else 'generic'
            payload = notification_payload(conversation, message, mode)
            try:
                response = client.post(base + '/3/device/' + token, json=payload,
                                       headers={'authorization': 'bearer ' + cached['token'], 'apns-topic': bundle,
                                                'apns-push-type': 'alert', 'apns-priority': '10', 'apns-expiration': '0'})
                if response.status_code != 200:
                    print('Cove APNs notification rejected: HTTP', response.status_code, flush=True)
            except httpx.HTTPError:
                print('Cove APNs notification transport failed', flush=True)
    return push
