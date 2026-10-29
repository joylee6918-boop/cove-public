"""Read-only OB creation calendar. Only bounded frontmatter scalars are inspected.

No OB API login, memory body reads, writes, touches, model calls or YAML execution.
The date means the first creation of a currently retained bucket, not all past writes.
"""
import calendar
from collections import Counter
from contextlib import contextmanager
from datetime import date, datetime, timezone
import json
import os
import re
import stat
import time
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

DIRECTORIES = ('permanent', 'dynamic', 'feel', 'plans', 'letters', 'archive')
DISPLAY_TIMEZONE = 'Asia/Shanghai'
MAX_FILES = 5_000
MAX_ENTRIES = 20_000
MAX_DEPTH = 12
MAX_HEADER_BYTES = 65_536
MAX_TOTAL_HEADER_BYTES = 8 * 1024 * 1024
MAX_LINE_BYTES = 8_192
MAX_SCAN_SECONDS = 10
_ERROR = '暂时无法读取 OB 记忆日期统计；数据未知，请稍后重试'


class CalendarError(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message
        super().__init__(message)


class _Unavailable(Exception):
    pass


def _month(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9]{4}-(?:0[1-9]|1[0-2])', value):
        raise CalendarError(400, 'month 必须为 YYYY-MM')
    year, month = (int(part) for part in value.split('-'))
    if not 1 <= year <= 9999:
        raise CalendarError(400, 'month 必须为有效的 YYYY-MM')
    return year, month


def _fingerprint(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _deadline(deadline):
    if time.monotonic() > deadline:
        raise _Unavailable()


def _flags(directory=False):
    # Fail closed on a platform that cannot refuse symlinks at open time.
    if not hasattr(os, 'O_NOFOLLOW') or not hasattr(os, 'O_DIRECTORY'):
        raise _Unavailable()
    return os.O_RDONLY | os.O_NOFOLLOW | (os.O_DIRECTORY if directory else 0)


def _inventory(root_fd, deadline):
    """Enumerate only the six selected categories, using anchored directory FDs."""
    files, directories = {}, {}
    entries = 0

    def walk(fd, parts, depth):
        nonlocal entries
        _deadline(deadline)
        if depth > MAX_DEPTH:
            raise _Unavailable()
        directories[parts] = _fingerprint(os.fstat(fd))
        with os.scandir(fd) as iterator:
            for entry in iterator:
                entries += 1
                if entries > MAX_ENTRIES:
                    raise _Unavailable()
                _deadline(deadline)
                info = entry.stat(follow_symlinks=False)
                if stat.S_ISLNK(info.st_mode):
                    raise _Unavailable()
                child = parts + (entry.name,)
                if stat.S_ISDIR(info.st_mode):
                    nested = os.open(entry.name, _flags(True), dir_fd=fd)
                    try:
                        walk(nested, child, depth + 1)
                    finally:
                        os.close(nested)
                elif entry.name.endswith('.md'):
                    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                        raise _Unavailable()
                    files[child] = _fingerprint(info)
                    if len(files) > MAX_FILES:
                        raise _Unavailable()

    for name in DIRECTORIES:
        try:
            fd = os.open(name, _flags(True), dir_fd=root_fd)
        except FileNotFoundError:
            continue
        try:
            walk(fd, (name,), 1)
        finally:
            os.close(fd)
    if not directories:
        raise _Unavailable()
    return files, directories


@contextmanager
def _open_header(root_fd, parts):
    opened = []
    parent = root_fd
    try:
        for component in parts[:-1]:
            parent = os.open(component, _flags(True), dir_fd=parent)
            opened.append(parent)
        fd = os.open(parts[-1], _flags(), dir_fd=parent)
        # buffering=0 is intentional: readline must not prefetch any body bytes.
        with os.fdopen(fd, 'rb', buffering=0) as stream:
            yield stream
    finally:
        for fd in reversed(opened):
            os.close(fd)


def _scalar(raw):
    """A strict string/null/bool subset, not an arbitrary YAML deserializer."""
    text = raw.strip()
    if not text or text.startswith('#'):
        return None
    if text.startswith('"'):
        try:
            value, consumed = json.JSONDecoder().raw_decode(text)
        except ValueError:
            raise _Unavailable()
        rest = text[consumed:].strip()
        if not isinstance(value, str) or (rest and not rest.startswith('#')):
            raise _Unavailable()
        return value
    if text.startswith("'"):
        result = []; index = 1
        while index < len(text):
            if text[index] != "'":
                result.append(text[index]); index += 1
            elif index + 1 < len(text) and text[index + 1] == "'":
                result.append("'"); index += 2
            else:
                rest = text[index + 1:].strip()
                if rest and not rest.startswith('#'):
                    raise _Unavailable()
                return ''.join(result)
        raise _Unavailable()
    if text[0] in '&*!|>[]{}%@`':
        raise _Unavailable()
    value = re.split(r'\s+#', text, maxsplit=1)[0].strip()
    if value.casefold() in ('null', '~'):
        return None
    if value.casefold() in ('false', 'true'):
        return value.casefold() == 'true'
    return value


def _read_header(stream, budget, deadline):
    used = 0
    values = {}
    started = False
    while True:
        _deadline(deadline)
        line = stream.readline(MAX_LINE_BYTES + 1)
        used += len(line); budget[0] += len(line)
        if not line or len(line) > MAX_LINE_BYTES or used > MAX_HEADER_BYTES or budget[0] > MAX_TOTAL_HEADER_BYTES:
            raise _Unavailable()
        decoded = line.decode('utf-8').rstrip('\r\n')
        if not started:
            if decoded.lstrip('\ufeff') != '---':
                raise _Unavailable()
            started = True
            continue
        if decoded == '---':
            return values
        match = re.match(r'^(id|created|deleted_at)[ \t]*:[ \t]*(.*)$', decoded)
        if match:
            key, raw = match.groups()
            if key in values:
                raise _Unavailable()
            values[key] = _scalar(raw)
        # All other fields (including arbitrary YAML tags/objects) are ignored,
        # not deserialized. The first closing delimiter ends reads immediately.


def _creation(value, naive_timezone, display_timezone):
    if not isinstance(value, str) or not 1 <= len(value) <= 80:
        raise _Unavailable()
    text = value.strip()
    if re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}', text):
        parsed = datetime.combine(date.fromisoformat(text), datetime.min.time())
    else:
        # Do not accept bare times, timezone abbreviations or relative dates.
        if not re.match(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ]', text):
            raise _Unavailable()
        parsed = datetime.fromisoformat(text[:-1] + '+00:00' if text.endswith(('Z','z')) else text)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=naive_timezone)
    return parsed.astimezone(timezone.utc).isoformat(), parsed.astimezone(display_timezone).date().isoformat()


def snapshot(month, buckets_path=None, naive_timezone=None):
    """Return a complete month, or an error. Never emit a partial-zero success."""
    year, month_number = _month(month)
    path = buckets_path if buckets_path is not None else os.getenv('COVE_OB_BUCKETS_PATH')
    source_timezone = naive_timezone if naive_timezone is not None else os.getenv('COVE_OB_NAIVE_TIMEZONE')
    if not path or not source_timezone:
        raise CalendarError(503, '尚未配置 OB 只读记忆目录和来源时区；数据未知')
    root_fd = None
    try:
        # Source naive timestamps require explicit provenance, never host-local guessing.
        if not os.path.isabs(os.fspath(path)):
            raise _Unavailable()
        source_zone = ZoneInfo(source_timezone)
        display_zone = ZoneInfo(DISPLAY_TIMEZONE)
        root_fd = os.open(os.fspath(path), _flags(True))
        root_before = _fingerprint(os.fstat(root_fd))
        deadline = time.monotonic() + MAX_SCAN_SECONDS
        files, directories = _inventory(root_fd, deadline)
        budget = [0]; buckets = {}; deleted_ids = set()
        for parts, fingerprint in sorted(files.items()):
            with _open_header(root_fd, parts) as stream:
                before = os.fstat(stream.fileno())
                if _fingerprint(before) != fingerprint:
                    raise _Unavailable()
                metadata = _read_header(stream, budget, deadline)
                if _fingerprint(os.fstat(stream.fileno())) != fingerprint:
                    raise _Unavailable()
            identifier = metadata.get('id')
            if not isinstance(identifier, str) or not 1 <= len(identifier) <= 256 or any(ord(c) < 32 for c in identifier):
                raise _Unavailable()
            if metadata.get('deleted_at'):
                deleted_ids.add(identifier)
                continue
            instant, day = _creation(metadata.get('created'), source_zone, display_zone)
            if identifier in buckets and buckets[identifier] != (instant, day):
                raise _Unavailable()
            buckets[identifier] = (instant, day)
        if (files, directories) != _inventory(root_fd, deadline) or _fingerprint(os.fstat(root_fd)) != root_before:
            raise _Unavailable()
        # Detect replacement of the configured root, not just changes inside its FD.
        if _fingerprint(os.stat(path, follow_symlinks=False)) != root_before:
            raise _Unavailable()
        counts = Counter(day for key, (_instant, day) in buckets.items() if key not in deleted_ids and day.startswith(month + '-'))
        days = [{'date':f'{month}-{day:02d}', 'count':counts.get(f'{month}-{day:02d}',0)} for day in range(1,calendar.monthrange(year,month_number)[1]+1)]
        return {'month':month,'timezone':DISPLAY_TIMEZONE,'source':'ombre','metric':'created','days':days,
                'updatedAt':datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00','Z'),
                'total':sum(day['count'] for day in days)}
    except (OSError, ValueError, TypeError, OverflowError, UnicodeError, ZoneInfoNotFoundError, _Unavailable):
        raise CalendarError(503, _ERROR) from None
    finally:
        if root_fd is not None:
            os.close(root_fd)
