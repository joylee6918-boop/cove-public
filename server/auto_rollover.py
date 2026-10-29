"""Model-free in-place Cove thread rollover before native compaction.

The visible Cove conversation never changes.  Once the current gpt-5.6-sol
thread reaches the soft token limit, or a queued turn would cross the hard
planning limit, Cove atomically detaches that thread.  The queued/next turn
starts a fresh native thread and receives bounded same-conversation evidence.
No hidden model turn is spent on the crowded source thread.

Rows created by the older compaction-triggered implementation remain readable;
an already completed legacy hidden turn may still finish its idempotent detach.
"""
import hashlib
import json
import os

DEFAULT_COMPACTION_THRESHOLD = 1
DEFAULT_SOFT_TOKENS = 190_000
DEFAULT_HARD_TOKENS = 210_000
DEFAULT_TURN_RESERVE = 30_000


def _bounded_env(name, default, lower, upper):
    try:
        value = int(os.getenv(name, str(default)))
    except ValueError:
        return default
    return value if lower <= value <= upper else default


def threshold():
    """One canonical compaction is already too late; never wait for three."""
    return _bounded_env('COVE_AUTO_ROLLOVER_COMPACTIONS', DEFAULT_COMPACTION_THRESHOLD, 1, 20)


def token_limits():
    soft = _bounded_env('COVE_AUTO_ROLLOVER_SOFT_TOKENS', DEFAULT_SOFT_TOKENS, 50_000, 240_000)
    hard = _bounded_env('COVE_AUTO_ROLLOVER_HARD_TOKENS', DEFAULT_HARD_TOKENS, 60_000, 250_000)
    if hard <= soft:
        return DEFAULT_SOFT_TOKENS, DEFAULT_HARD_TOKENS
    return soft, hard


def turn_reserve():
    return _bounded_env('COVE_AUTO_ROLLOVER_TURN_RESERVE', DEFAULT_TURN_RESERVE, 10_000, 80_000)


def _text_tokens(text):
    """Conservative local estimate only; native tokenUsage remains authoritative."""
    if not isinstance(text, str):
        return 0
    cjk = sum(1 for char in text if '\u3400' <= char <= '\u9fff')
    return cjk + max(0, len(text) - cjk + 3) // 4


def estimated_turn_tokens(message):
    estimate = turn_reserve() + _text_tokens(message.get('text'))
    for item in message.get('attachments') or []:
        if not isinstance(item, dict):
            continue
        size = item.get('size')
        size = size if type(size) is int and size > 0 else 0
        mime = str(item.get('mime') or '')
        if mime.startswith('text/') or mime in ('application/json', 'application/xml'):
            estimate += min(size, 256 * 1024) // 3
        elif mime.startswith('image/'):
            estimate += 4_000
        elif mime.startswith('audio/'):
            estimate += 8_000
        else:
            estimate += 200
    return estimate


def _id(conversation, thread):
    return 'auto-rollover-' + hashlib.sha256((conversation + '\0' + thread).encode()).hexdigest()[:32]


class AutoRolloverStore:
    def init_auto_rollover(self):
        self.db.executescript('''
        CREATE TABLE IF NOT EXISTS auto_rollovers(
            id TEXT PRIMARY KEY, conversation TEXT NOT NULL REFERENCES conversations(id),
            source_thread TEXT NOT NULL UNIQUE, compaction_count INTEGER NOT NULL,
            message TEXT NOT NULL UNIQUE, state TEXT NOT NULL,
            created TEXT NOT NULL, updated TEXT NOT NULL, error TEXT);
        ''')
        columns = {row[1] for row in self.db.execute('PRAGMA table_info(auto_rollovers)')}
        if 'trigger_kind' not in columns:
            self.db.execute('ALTER TABLE auto_rollovers ADD COLUMN trigger_kind TEXT')
        if 'used_tokens' not in columns:
            self.db.execute('ALTER TABLE auto_rollovers ADD COLUMN used_tokens INTEGER')
        self.db.commit()
        # Legacy compatibility: its model turn is already durable and is never
        # replayed. Finish only the idempotent local detach after restart.
        pending = [row[0] for row in self.db.execute(
            "SELECT id FROM auto_rollovers WHERE state='model_complete'").fetchall()]
        for identifier in pending:
            self.commit_auto_rollover(identifier)

    def _rollover_locked(self, conversation, source_thread, count, used_tokens,
                         trigger_kind, continuity_note=None):
        from storage import encode, now
        current = self.conversation(conversation)
        if not source_thread or current['thread'] != source_thread:
            return None
        if self.db.execute("SELECT 1 FROM jobs JOIN messages ON jobs.message=messages.id "
                           "WHERE messages.conversation=? AND jobs.state='running' LIMIT 1",
                           (conversation,)).fetchone():
            return None
        old = self.db.execute('SELECT * FROM auto_rollovers WHERE source_thread=?',
                              (source_thread,)).fetchone()
        if old and old['state'] == 'complete':
            return dict(old)
        if old and old['state'] in ('queued', 'running', 'model_complete'):
            return dict(old)
        identifier = old['id'] if old else _id(conversation, source_thread)
        stamp = now()
        marker = {
            'previousThread': source_thread,
            'automatic': True,
            'compactionCount': count,
            'usedTokens': used_tokens,
            'trigger': trigger_kind,
            'softLimitTokens': token_limits()[0],
            'hardLimitTokens': token_limits()[1],
            'rolloverID': identifier,
        }
        if isinstance(continuity_note, str) and continuity_note.strip():
            marker['continuityNote'] = continuity_note.strip()[:8_000]
        if old:
            self.db.execute(
                "UPDATE auto_rollovers SET compaction_count=?,message=?,state='complete',"
                "created=coalesce(created,?),updated=?,error=NULL,trigger_kind=?,used_tokens=? WHERE id=?",
                (count, identifier + '-local', stamp, stamp, trigger_kind, used_tokens, identifier))
        else:
            self.db.execute(
                'INSERT INTO auto_rollovers(id,conversation,source_thread,compaction_count,message,state,created,updated,error,trigger_kind,used_tokens) '
                'VALUES(?,?,?,?,?,?,?,?,NULL,?,?)',
                (identifier, conversation, source_thread, count, identifier + '-local',
                 'complete', stamp, stamp, trigger_kind, used_tokens))
        self.db.execute('INSERT INTO state VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
                        ('window-reset:' + conversation, encode(marker)))
        changed = self.db.execute('UPDATE conversations SET thread=NULL WHERE id=? AND thread=?',
                                  (conversation, source_thread)).rowcount
        if changed != 1:
            self.db.execute("UPDATE auto_rollovers SET state='failed',error='会话线程已变化，未覆盖',updated=? WHERE id=?",
                            (now(), identifier))
            return None
        self.db.execute('DELETE FROM context_usage WHERE conversation=?', (conversation,))
        return dict(self.db.execute('SELECT * FROM auto_rollovers WHERE id=?', (identifier,)).fetchone())

    def schedule_auto_rollover(self, conversation, source_thread, count=0,
                               used_tokens=None, trigger_kind=None,
                               continuity_note=None):
        """Immediately detach an idle crowded thread; never run a model handoff."""
        soft, _hard = token_limits()
        canonical = type(count) is int and count >= threshold()
        token_ready = type(used_tokens) is int and used_tokens >= soft
        explicit = trigger_kind in ('projected-hard', 'authorized-current-repair')
        if not (canonical or token_ready or explicit):
            return None
        kind = trigger_kind or ('canonical-compaction' if canonical else 'token-soft')
        safe_count = count if type(count) is int and count >= 0 else 0
        safe_tokens = used_tokens if type(used_tokens) is int and used_tokens >= 0 else None
        with self.lock, self.db:
            return self._rollover_locked(conversation, source_thread, safe_count,
                                         safe_tokens, kind, continuity_note)

    def prepare_auto_rollover(self):
        """Detach before claiming a queued turn if its projected request is crowded."""
        soft, hard = token_limits()
        with self.lock, self.db:
            if self.db.execute("SELECT 1 FROM jobs WHERE state='running' LIMIT 1").fetchone():
                return None
            row = self.db.execute(
                "SELECT jobs.message,messages.body FROM jobs JOIN messages ON messages.id=jobs.message "
                "WHERE jobs.state='queued' ORDER BY CASE WHEN json_extract(messages.body,'$.autoRolloverID') "
                "IS NOT NULL THEN 0 ELSE 1 END,messages.rowid LIMIT 1").fetchone()
            if not row:
                return None
            message = json.loads(row['body'])
            if message.get('autoRolloverID') or message.get('handoffID'):
                return None
            conversation = message.get('conversationID')
            current = self.conversation(conversation)
            if not current['thread']:
                return None
            usage = self.db.execute('SELECT body FROM context_usage WHERE conversation=?',
                                    (conversation,)).fetchone()
            if not usage:
                return None
            try:
                value = json.loads(usage[0])
            except (TypeError, ValueError):
                return None
            used = value.get('usedTokens')
            if (type(used) is not int or used < 0 or
                    value.get('threadID') != current['thread']):
                return None
            projected = used + estimated_turn_tokens(message)
            if used >= soft:
                kind = 'token-soft'
            elif projected >= hard:
                kind = 'projected-hard'
            else:
                return None
            return self._rollover_locked(conversation, current['thread'], 0, used, kind)

    # The following three methods only serve durable rows created by the older
    # hidden-model implementation. New token rollovers never create such jobs.
    def auto_rollover_claimed(self, message):
        from storage import now
        origin = self._message(message)
        if origin and origin.get('autoRolloverID'):
            self.db.execute("UPDATE auto_rollovers SET state='running',updated=? WHERE id=? AND state='queued'",
                            (now(), origin['autoRolloverID']))

    def auto_rollover_finished(self, message, status, error=None):
        from storage import now
        origin = self._message(message)
        if not origin or not origin.get('autoRolloverID'):
            return
        state = 'model_complete' if status == 'complete' else 'failed'
        self.db.execute('UPDATE auto_rollovers SET state=?,updated=?,error=? WHERE id=?',
                        (state, now(), None if state == 'model_complete' else
                         (error or '旧版后台记忆整理未完成；保留原线程'), origin['autoRolloverID']))

    def commit_auto_rollover(self, identifier):
        """Finish an already-paid legacy hidden turn without replaying it."""
        from storage import encode, now
        with self.lock, self.db:
            row = self.db.execute('SELECT * FROM auto_rollovers WHERE id=?', (identifier,)).fetchone()
            if not row or row['state'] != 'model_complete':
                return False
            current = self.conversation(row['conversation'])
            if current['thread'] != row['source_thread']:
                self.db.execute("UPDATE auto_rollovers SET state='failed',error='会话线程已变化，未覆盖',updated=? WHERE id=?",
                                (now(), identifier))
                return False
            if self.db.execute("SELECT 1 FROM jobs JOIN messages ON jobs.message=messages.id "
                               "WHERE messages.conversation=? AND jobs.state='running' LIMIT 1",
                               (row['conversation'],)).fetchone():
                return False
            marker = {'previousThread': row['source_thread'], 'automatic': True,
                      'compactionCount': row['compaction_count'],
                      'trigger': row['trigger_kind'] or 'legacy-compaction',
                      'usedTokens': row['used_tokens'], 'rolloverID': identifier}
            self.db.execute('INSERT INTO state VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
                            ('window-reset:' + row['conversation'], encode(marker)))
            self.db.execute('UPDATE conversations SET thread=NULL WHERE id=? AND thread=?',
                            (row['conversation'], row['source_thread']))
            self.db.execute('DELETE FROM context_usage WHERE conversation=?', (row['conversation'],))
            self.db.execute("UPDATE auto_rollovers SET state='complete',updated=?,error=NULL WHERE id=?",
                            (now(), identifier))
            return True

    def auto_rollover_status(self, conversation):
        with self.lock:
            row = self.db.execute(
                'SELECT id,source_thread,compaction_count,state,created,updated,error,trigger_kind,used_tokens '
                'FROM auto_rollovers WHERE conversation=? ORDER BY rowid DESC LIMIT 1',
                (conversation,)).fetchone()
            return dict(row) if row else None
