"""Stage prepared image bytes in private, uniquely named native CLI inputs.

Never import arbitrary local paths supplied by a client or overwrite a file.
Unknown turns retain their staged bytes; cleanup is a separate confirmed action.
"""
import base64
import os
import stat
import uuid
from pathlib import Path

from storage import APIError
from tmux_images import _checked_image


def stage_images(inputs, directory):
    images = [item for item in inputs if item.get('type') == 'image']
    if not images:
        return []
    extensions = {'image/png': '.png', 'image/jpeg': '.jpg',
                  'image/gif': '.gif', 'image/webp': '.webp'}
    decoded = []
    total = 0
    try:
        for image in images:
            header, content = image['url'].split(',', 1)
            mime = header.removeprefix('data:').removesuffix(';base64')
            if header != 'data:' + mime + ';base64' or mime not in extensions or len(content) > 28 * 1024 * 1024:
                raise ValueError
            data = base64.b64decode(content, validate=True)
            total += len(data)
            if not data or total > 20 * 1024 * 1024 or len(images) > 10:
                raise ValueError
            decoded.append((extensions[mime], data))
    except (KeyError, ValueError, TypeError):
        raise APIError(400, '图片输入无效或超出读取预算；未发送到终端') from None
    root = Path(directory)
    if not root.is_absolute() or root != root.resolve(strict=False):
        raise APIError(503, '图片暂存目录不安全')
    root.mkdir(mode=0o700, exist_ok=True)
    info = root.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise APIError(503, '图片暂存目录不是私有目录')
    paths = []
    for extension, data in decoded:
        path = root / (str(uuid.uuid4()) + extension)
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            _checked_image(path, root)
        except ValueError:
            raise APIError(400, '图片类型与内容不符；未发送到终端') from None
        paths.append(path)
    return paths
