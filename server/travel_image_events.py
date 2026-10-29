"""Native imageGeneration completion -> bounded, durable Cove attachment.

Only runtime may call this for a real app-server completion notification. This is NOT an MCP tool or an HTTP endpoint. It never reads
savedPath, opens URLs, generates images, or infers an album/scene association.
Album binding must use the journey/scene captured when generation started, not
whatever trip happens to be current when a late event arrives.
"""
import base64
import binascii
import hashlib

from files import MAX_ATTACHMENT
from storage import APIError


def decode_completed_image(item):
    """Return (filename, mime, bytes), None for unrelated item; raise APIError.

    Runtime must independently verify actual native completion notification,
    matching active thread/turn, cancellation and origin, then persist under the
    image item id. This pure parser performs no network, filesystem or DB IO.
    """
    if not isinstance(item, dict) or item.get('type') != 'imageGeneration':
        return None
    item_id = item.get('id')
    if not isinstance(item_id, str) or not item_id or len(item_id) > 600:
        raise APIError(400, '图片事件标识无效')
    if item.get('status') != 'completed' or item.get('failure') is not None:
        raise APIError(503, '图片生成未确认成功，未保存图片')
    raw = item.get('result')
    if not isinstance(raw, str) or not raw:
        raise APIError(503, '图片事件未提供真实图片字节，未读取路径或链接')
    if len(raw) > (MAX_ATTACHMENT + 2) // 3 * 4:
        raise APIError(413, '生成图片超过附件大小限制')
    try:
        data = base64.b64decode(raw, validate=True)
    except (ValueError, binascii.Error):
        raise APIError(400, '生成图片不是有效 Base64 字节') from None
    if not data or len(data) > MAX_ATTACHMENT:
        raise APIError(413, '生成图片为空或超过附件大小限制')
    # Signature check, not a claim of full decoder validation. No SVG/HTML allowed.
    if data.startswith(b'\x89PNG\r\n\x1a\n'):
        extension, mime = 'png', 'image/png'
    elif data.startswith(b'\xff\xd8\xff'):
        extension, mime = 'jpg', 'image/jpeg'
    elif len(data) >= 12 and data[:4] == b'RIFF' and data[8:12] == b'WEBP':
        extension, mime = 'webp', 'image/webp'
    else:
        raise APIError(400, '生成图片格式不受支持')
    # Do not use untrusted item ids as paths/filenames. The origin-scoped store key
    # deliberately stays stable across duplicate completion notifications.
    digest = hashlib.sha256(item_id.encode()).hexdigest()
    return 'travel-'+digest[:16]+'.'+extension, mime, data
