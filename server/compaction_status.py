"""Read-only, per-thread compaction evidence. Never exposes transcript content."""
import json
import sqlite3
import threading
from collections import OrderedDict
from datetime import datetime
from pathlib import Path

_LOCK = threading.Lock()
_CACHE = OrderedDict()
SCAN_BYTES = 128 * 1024 * 1024
# Current Codex rollouts can contain legitimate custom-tool outputs above 8 MiB.
# Keep the bound finite while allowing observed 9 MiB records to be skipped by type.
MAX_LINE = 16 * 1024 * 1024


def _unknown(message):
    return {'compactionCount': None, 'lastCompactedAt': None,
            'compactionError': message}


def compaction_status(codex_home, thread):
    if not codex_home or not thread:
        return _unknown('等待当前会话的压缩记录')
    try:
        home = Path(codex_home).expanduser().resolve()
        db = sqlite3.connect((home / 'state_5.sqlite').as_uri() + '?mode=ro', uri=True, timeout=1)
        try:
            row = db.execute('SELECT rollout_path FROM threads WHERE id=?', (thread,)).fetchone()
        finally:
            db.close()
        if not row:
            return _unknown('尚未找到当前会话的压缩记录')
        path = Path(row[0]).resolve()
        if path.suffix != '.jsonl' or not any(path.is_relative_to((home / folder).resolve()) for folder in ('sessions', 'archived_sessions')):
            return _unknown('当前会话的记录路径不可读取')
        return _scan(path)
    except (OSError, sqlite3.Error, ValueError, TypeError):
        return _unknown('压缩记录暂不可用，请稍后刷新')


def _scan(path):
    with _LOCK:
        stat = path.stat()
        identity = (stat.st_dev, stat.st_ino)
        key = str(path)
        entry = _CACHE.get(key)
        if (entry is None or entry['identity'] != identity or stat.st_size < entry['size']
                or (stat.st_size == entry['size'] and stat.st_mtime_ns != entry['mtime'])):
            entry = {'identity': identity, 'offset': 0, 'count': 0, 'last': None, 'bad': False, 'skip': False}
        entry.update(size=stat.st_size, mtime=stat.st_mtime_ns)
        _CACHE[key] = entry
        _CACHE.move_to_end(key)
        while len(_CACHE) > 8:
            _CACHE.popitem(last=False)
        budget = SCAN_BYTES
        incomplete = False
        with path.open('rb') as stream:
            stream.seek(entry['offset'])
            while budget > 0 and stream.tell() < stat.st_size:
                start = stream.tell()
                raw = stream.readline(min(MAX_LINE + 1, stat.st_size - start))
                budget -= len(raw)
                if not raw.endswith(b'\n'):
                    if len(raw) > MAX_LINE or entry['skip']:
                        entry['skip'] = True; entry['bad'] = True
                        entry['offset'] = stream.tell()
                    else:
                        incomplete = True
                    break
                entry['offset'] = stream.tell()
                if entry['skip']:
                    entry['skip'] = False
                    continue
                try:
                    item = json.loads(raw)
                    # Count canonical persisted records only, not duplicate UI notifications.
                    if item.get('type') == 'compacted':
                        stamp = item.get('timestamp')
                        parsed = datetime.fromisoformat(stamp.replace('Z', '+00:00'))
                        if parsed.tzinfo is None:
                            raise ValueError('missing timezone')
                        entry['count'] += 1
                        entry['last'] = stamp
                except (ValueError, TypeError, AttributeError):
                    entry['bad'] = True
        if entry['bad']:
            return _unknown('记录含不可识别内容，暂不显示压缩次数')
        if incomplete or entry['offset'] < stat.st_size:
            return _unknown('正在读取压缩记录，请稍后刷新')
        return {'compactionCount': entry['count'], 'lastCompactedAt': entry['last'],
                'compactionError': None}
