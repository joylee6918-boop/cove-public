"""Read-only, stdlib Pulse v3 projection shared by Cove and pulse-service."""
import json
import math
import sqlite3
import re
from datetime import datetime, timezone
from pathlib import Path

MAX_STATE = 2 * 1024 * 1024
LABELS = {'energy': '精力', 'focus': '专注', 'calm': '平静', 'charge': '蓄能', 'libido': '欲望',
          'intimacy': '亲近', 'attachment': '依恋', 'curiosity': '好奇', 'reflection': '反思',
          'touch': '触觉', 'smell': '嗅觉', 'taste': '味觉', 'sound': '听觉'}


class PulseReadError(ValueError):
    pass


def _iso(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and math.isfinite(value) and value > 0:
        return datetime.fromtimestamp(value, timezone.utc).isoformat().replace('+00:00', 'Z')
    if isinstance(value, str):
        try:
            parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
            if parsed.tzinfo is None:
                return None
            return parsed.astimezone(timezone.utc).isoformat().replace('+00:00', 'Z')
        except ValueError:
            pass
    return None


def _load(path):
    if not path:
        raise PulseReadError('尚未配置 Pulse 状态文件')
    source = Path(path).expanduser()
    try:
        if source.stat().st_size > MAX_STATE:
            raise ValueError()
        value = json.loads(source.read_text(encoding='utf-8'))
        if not isinstance(value, dict):
            raise ValueError()
        return source, value
    except (OSError, ValueError, UnicodeError):
        raise PulseReadError('Pulse 状态文件不可读取')


def _metrics(raw, section):
    entries = raw.get(section) or {}
    if isinstance(entries, list):
        entries = {m.get('id'): m for m in entries if isinstance(m, dict) and isinstance(m.get('id'), str)}
    if not isinstance(entries, dict):
        return []
    result = []
    for key, metric in entries.items():
        if not isinstance(key, str):
            continue
        value = metric.get('value') if isinstance(metric, dict) else metric
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            continue
        detail = metric.get('detail', metric.get('label', '')) if isinstance(metric, dict) else ''
        # Legacy prose described an earlier active state. Once the drive has
        # decayed, showing it as current is misleading.
        if value < .15:
            detail = ''
        result.append({'id': key, 'label': LABELS.get(key, key), 'value': min(1., max(0., float(value))), 'detail': str(detail or '')[:1000]})
    return result


def snapshot(state_path):
    _, raw = _load(state_path)
    updated = _iso(raw.get('updatedAt', raw.get('updated_at')))
    if not updated:
        raise PulseReadError('Pulse 状态缺少真实记录时间')
    heartbeat = raw.get('heartbeat')
    if isinstance(heartbeat, dict):
        interval = heartbeat.get('intervalSeconds', heartbeat.get('interval_seconds'))
        valid_interval = isinstance(interval, int) and not isinstance(interval, bool) and 1 <= interval <= 86400
        heartbeat = {'lastTickAt': _iso(heartbeat.get('lastTickAt', heartbeat.get('last_tick_at'))),
                     'lastWakeAt': _iso(heartbeat.get('lastWakeAt', heartbeat.get('last_wake_at'))),
                     'intervalSeconds': interval if valid_interval else 300,
                     'quiet': bool(heartbeat.get('quiet', False)),
                     'nextTickAt': _iso(heartbeat.get('nextTickAt', heartbeat.get('next_tick_at')))}
    else:
        heartbeat = None
    vitals = raw.get('vitals')
    required = ('heartRate', 'temperature', 'breathingRate', 'breathingDepth', 'chord', 'activity', 'emotion')
    numeric_vitals = ('heartRate', 'temperature', 'breathingRate')
    string_vitals = ('breathingDepth', 'chord', 'activity', 'emotion')
    if (not isinstance(vitals, dict) or any(k not in vitals for k in required) or
            any(isinstance(vitals[k], bool) or not isinstance(vitals[k], (int, float)) or not math.isfinite(vitals[k]) for k in numeric_vitals) or
            any(not isinstance(vitals[k], str) or len(vitals[k]) > 240 for k in string_vitals)):
        vitals = None
    else:
        vitals = {k: vitals[k] for k in required}
        vitals['source'] = 'digital_model'
    environment = raw.get('environment')
    if isinstance(environment, dict):
        time_of_day, weather, temp, source_name = (environment.get(k) for k in ('timeOfDay', 'weather', 'temperature', 'source'))
        valid = (isinstance(time_of_day, str) and len(time_of_day) <= 120 and
                 (weather is None or isinstance(weather, str) and len(weather) <= 240) and
                 (temp is None or isinstance(temp, (int, float)) and not isinstance(temp, bool) and math.isfinite(temp)) and
                 isinstance(source_name, str) and len(source_name) <= 120)
        environment = {'timeOfDay': time_of_day, 'weather': weather, 'temperature': temp, 'source': source_name,
                       'updatedAt': _iso(environment.get('updatedAt', environment.get('updated_at')))} if valid else None
    else:
        environment = None
    return {'updatedAt': updated, 'summary': str(raw.get('summary') or ''),
            'physical': _metrics(raw, 'physical'), 'senses': _metrics(raw, 'senses'), 'desires': _metrics(raw, 'desires'),
            'vitals': vitals, 'heartbeat': heartbeat, 'environment': environment}


def _jsonl(path, limit, validator):
    warnings, result = [], []
    if not path.exists():
        return result, [path.name + ' 尚无历史记录']
    try:
        if path.stat().st_size > 16 * 1024 * 1024:
            warnings.append(path.name + ' 过大，仅读取末尾')
        # Never allocate an attacker-controlled append-only file. A bounded
        # tail is enough for the bounded dashboard window; discard a partial
        # first line after seeking.
        with path.open('rb') as stream:
            size = stream.seek(0, 2); start = max(0, size - 1024 * 1024)
            stream.seek(start)
            raw = stream.read(1024 * 1024)
        if start:
            raw = raw.split(b'\n', 1)[-1]
        lines = raw.decode('utf-8').splitlines()[-limit * 3:]
        for line in lines:
            try:
                item = validator(json.loads(line))
                if item:
                    result.append(item)
            except (ValueError, TypeError):
                continue
    except (OSError, UnicodeError):
        warnings.append(path.name + ' 不可读取')
    return result[-limit:], warnings


def _history(x):
    if not isinstance(x, dict) or not isinstance(x.get('id'), str) or not _iso(x.get('at')):
        return None
    nums = [x.get(k) for k in ('heartRate', 'temperature', 'breathingRate')]
    if any(isinstance(n, bool) or not isinstance(n, (int, float)) or not math.isfinite(n) for n in nums):
        return None
    return {'id': x['id'], 'at': _iso(x['at']), 'heartRate': nums[0], 'temperature': nums[1], 'breathingRate': nums[2]}


def _murmur(x):
    if not isinstance(x, dict) or not isinstance(x.get('id'), str) or not isinstance(x.get('text'), str) or not _iso(x.get('createdAt')):
        return None
    return {'id': x['id'], 'createdAt': _iso(x['createdAt']), 'text': x['text'][:2000], 'source': str(x.get('source', 'pulse'))[:100]}


def _db_events(db_path):
    if not db_path or not Path(db_path).exists():
        return [], ['Cove 历史数据库不可用']
    events = []
    try:
        uri = Path(db_path).resolve().as_uri() + '?mode=ro'
        db = sqlite3.connect(uri, uri=True, timeout=.25)
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA query_only=ON'); db.execute('PRAGMA busy_timeout=250')
        rows = db.execute("SELECT j.*,m.body AS user_body,a.body AS assistant_body FROM jobs j JOIN messages m ON m.id=j.message LEFT JOIN messages a ON a.id=j.assistant WHERE j.message LIKE 'pulse-cove-%' ORDER BY m.rowid DESC LIMIT 100").fetchall()
        notes = {}
        try:
            ids = [r['message'] for r in rows]
            if ids:
                notes = {r['message']: r for r in db.execute('SELECT * FROM pulse_notes WHERE message IN (' + ','.join('?' for _ in ids) + ')', ids)}
        except sqlite3.OperationalError:
            pass
        for row in rows:
            user = json.loads(row['user_body']); assistant = json.loads(row['assistant_body']) if row['assistant_body'] else {}
            terminal = db.execute('SELECT id,body FROM terminal_events WHERE conversation=? AND json_extract(body,\'$.turnID\')=? ORDER BY id', (user.get('conversationID'), row['turn'])).fetchall() if row['turn'] else []
            by_item, completed = {}, None
            for t in terminal:
                body = json.loads(t['body'])
                if body.get('kind') == 'turn' and str(body.get('text', '')).startswith('回合结束：'):
                    completed = _iso(body.get('createdAt'))
                if body.get('kind') not in ('command', 'fileChange', 'tool'):
                    continue
                text = body.get('text', '')
                key = body.get('itemID') or str(t['id'])
                status = 'started'
                if body.get('kind') == 'command' and text.startswith('完成：'):
                    match = re.search(r'(?:^|\n)exitCode=(-?\d+)(?:\n|$)', text)
                    status = 'complete' if match and int(match.group(1)) == 0 else ('failed' if match else 'unknown')
                elif body.get('kind') == 'tool':
                    status = 'complete' if '· 成功' in text else ('failed' if '· 失败' in text else ('unknown' if '· 已结束' in text or '· 完成' in text else 'started'))
                elif body.get('kind') == 'fileChange' and text.startswith('完成：'):
                    status = 'unknown'
                raw_title = text.split('\n', 1)[0][:240]
                lowered = raw_title.casefold()
                if body.get('kind') == 'tool' and ('memory' in lowered or 'breath' in lowered):
                    title = '检索记忆'
                elif body.get('kind') == 'tool' and 'cove_record_pulse_note' in lowered:
                    title = '留下想法摘要'
                else:
                    title = raw_title
                by_item[key] = {'id': str(key), 'title': title, 'status': status,
                                'detail': (raw_title if body.get('kind') == 'tool' else text[:2000]) or None}
            actions = list(by_item.values())
            note = notes.get(row['message'])
            created = _iso(user.get('createdAt'))
            quiet = row['state'] == 'complete' and assistant.get('hidden') and not assistant.get('text') and not assistant.get('attachments')
            event_status = 'quiet' if quiet else row['state']
            result_summary = '本次已完成，未发送聊天消息' if quiet else (assistant.get('text') or assistant.get('error') or None)
            events.append({'id': row['message'], 'createdAt': created, 'completedAt': completed,
                           'reason': str(user.get('pulseWakeReason') or 'attachment_crossed_threshold')[:240],
                           'status': event_status, 'thoughtSummary': note['thought_summary'] if note else None,
                           'actions': actions, 'resultSummary': result_summary,
                           'conversationID': user.get('conversationID'), 'messageID': row['assistant'] if assistant and not assistant.get('hidden') else None})
        db.close()
        return events, []
    except (sqlite3.Error, OSError, ValueError):
        try:
            db.close()
        except Exception:
            pass
        return [], ['Cove 唤醒历史暂时不可读取']


def recent_user_messages(cove_db_path, since=None, limit=20):
    """Coordinator-only read helper; returns genuine persisted user messages."""
    limit = min(100, max(1, int(limit)))
    uri = Path(cove_db_path).resolve().as_uri() + '?mode=ro'
    db = sqlite3.connect(uri, uri=True, timeout=.25); db.row_factory = sqlite3.Row
    try:
        rows = db.execute("SELECT body FROM messages WHERE json_extract(body,'$.role')='user' AND id NOT LIKE 'pulse-cove-%' ORDER BY rowid DESC LIMIT ?", (limit,)).fetchall()
        values = [json.loads(r['body']) for r in rows]
        return [v for v in values if not since or (_iso(v.get('createdAt')) or '') > since]
    finally:
        db.close()


def dashboard(state_path, cove_db_path=None):
    source, _ = _load(state_path)
    snap = snapshot(state_path)
    history, w1 = _jsonl(source.with_name('history.jsonl'), 288, _history)
    murmurs, w2 = _jsonl(source.with_name('murmurs.jsonl'), 30, _murmur)
    events, w3 = _db_events(cove_db_path)
    return {'generatedAt': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'), 'snapshot': snap,
            'history': history, 'events': events, 'murmurs': murmurs, 'warnings': w1 + w2 + w3}
