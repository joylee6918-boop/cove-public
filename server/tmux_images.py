"""Explicit bracketed paste for a verified, runtime-owned Codex tmux pane.

Codex 0.155.1's composer recognizes a pasted absolute image path as a native
image. This module never treats terminal pixels as delivery evidence; callers
must verify the resulting native rollout/model input and preserve unknown-send
idempotency in their dispatch journal.
"""
from __future__ import annotations

import secrets
import stat
from pathlib import Path


MAX_PASTE = 100 * 1024
MAX_IMAGE = 20 * 1024 * 1024
START = '\x1b[200~'
END = '\x1b[201~'


def _paste(transport, body: str) -> None:
    """Send literal bracket markers through this pane's one-use tmux buffer."""
    transport._require_attached()  # validates socket/session/owner/thread/pane
    name = 'cove-' + secrets.token_hex(16)
    transport._run('load-buffer', '-b', name, '-', input=START + body + END)
    try:
        # -r retains embedded LF; deliberately omit -p because its behavior
        # depends on a pane mode tmux does not expose reliably.
        transport._run('paste-buffer', '-dr', '-b', name, '-t', transport.pane_id)
    except Exception:
        transport._run('delete-buffer', '-b', name, check=False)
        raise


def paste_text(transport, text: str) -> None:
    """Paste one literal text body without submitting it."""
    if (not isinstance(text, str) or not text or len(text.encode('utf-8')) > MAX_PASTE or
            any((ord(ch) < 32 and ch != '\n') or ord(ch) == 127 for ch in text)):
        raise ValueError('tmux paste text is empty, oversized, or contains controls')
    _paste(transport, text)


def _checked_image(path: str | Path, allowed_root: str | Path) -> str:
    root_source = Path(allowed_root)
    root = root_source.resolve(strict=True)
    if root_source != root:
        raise ValueError('image root crosses a symlink')
    image = Path(path)
    if not image.is_absolute() or '..' in image.parts or any(ord(ch) < 32 or ord(ch) == 127 for ch in str(image)):
        raise ValueError('invalid image path')
    try:
        parts = image.relative_to(root).parts
    except ValueError as error:
        raise ValueError('image outside allowed root') from error
    if not parts:
        raise ValueError('image path is a directory')
    cursor = root
    for part in parts:
        cursor = cursor / part
        if cursor.is_symlink():
            raise ValueError('image path crosses a symlink')
    info = image.stat()
    if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= MAX_IMAGE:
        raise ValueError('image is not a supported regular file')
    with image.open('rb') as stream:
        header = stream.read(16)
    if not (header.startswith(b'\x89PNG\r\n\x1a\n') or header.startswith(b'\xff\xd8\xff') or
            header.startswith((b'GIF87a', b'GIF89a')) or
            (header.startswith(b'RIFF') and header[8:12] == b'WEBP')):
        raise ValueError('image signature is not PNG/JPEG/GIF/WebP')
    return str(image)


def paste_image(transport, path: str | Path, *, allowed_root: str | Path) -> None:
    """Paste one authorized absolute image path; does not press Enter."""
    _paste(transport, _checked_image(path, allowed_root))


def submit(transport, *, text: str = '', image_paths=(), allowed_root: str | Path | None = None) -> None:
    """Compose text/images with explicit brackets, then submit exactly once."""
    if not isinstance(text, str):
        raise ValueError('invalid tmux text')
    paths = tuple(image_paths)
    if not text and not paths:
        raise ValueError('empty tmux turn')
    if paths and allowed_root is None:
        raise ValueError('image root is required')
    # Validate every item before sending any bytes. The outer dispatch journal
    # still owns unknown-result fencing if a later tmux operation fails.
    checked = [_checked_image(path, allowed_root) for path in paths]
    if text:
        if (not isinstance(text, str) or len(text.encode('utf-8')) > MAX_PASTE or
                any((ord(ch) < 32 and ch != '\n') or ord(ch) == 127 for ch in text)):
            raise ValueError('invalid tmux text')
    for path in checked:
        _paste(transport, path)
    if text:
        _paste(transport, text)
    transport.send_special('Enter')
