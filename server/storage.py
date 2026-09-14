"""Private Cove records; every externally acknowledged write is committed."""
import json
import fcntl
import os
import sqlite3
import threading
import uuid
from datetime import datetime, timezone, timedelta
from pathlib import Path


def now():
    return datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=False)


class APIError(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message
        super().__init__(message)


class Store:
    def __init__(self, directory):
        self.directory = Path(directory).expanduser().resolve()
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self.directory, 0o700)
        self.process_lock = open(self.directory / 'server.lock', 'a')
        os.chmod(self.directory / 'server.lock', 0o600)
        try:
            fcntl.flock(self.process_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.process_lock.close()
            raise RuntimeError('Another Cove server already owns this data directory')
        self.lock = threading.RLock()
        self.db = sqlite3.connect(self.directory / 'cove.sqlite3', check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.executescript('''
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        PRAGMA foreign_keys=ON;
        PRAGMA secure_delete=ON;
        CREATE TABLE IF NOT EXISTS conversations(id TEXT PRIMARY KEY, title TEXT NOT NULL, created TEXT NOT NULL, thread TEXT UNIQUE);
        CREATE TABLE IF NOT EXISTS messages(id TEXT PRIMARY KEY, conversation TEXT NOT NULL REFERENCES conversations(id), body TEXT NOT NULL, fingerprint TEXT, revision INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS message_cursor ON messages(conversation,revision);
        CREATE TABLE IF NOT EXISTS revisions(id INTEGER PRIMARY KEY AUTOINCREMENT);
        CREATE TABLE IF NOT EXISTS jobs(message TEXT PRIMARY KEY REFERENCES messages(id), state TEXT NOT NULL, turn TEXT, assistant TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS state(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS attachments(id TEXT PRIMARY KEY, filename TEXT NOT NULL, mime TEXT NOT NULL, data BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS devices(token TEXT PRIMARY KEY, registered TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS health_history(day TEXT PRIMARY KEY, snapshot TEXT NOT NULL, synced TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS file_tool_results(call TEXT PRIMARY KEY, attachment TEXT NOT NULL REFERENCES attachments(id));
        CREATE TABLE IF NOT EXISTS stickers(id TEXT PRIMARY KEY, owner TEXT NOT NULL CHECK(owner IN ('user','assistant')), label TEXT NOT NULL, created TEXT NOT NULL, attachment TEXT NOT NULL REFERENCES attachments(id), UNIQUE(owner,attachment));
        CREATE TABLE IF NOT EXISTS sticker_tool_results(call TEXT PRIMARY KEY, result TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS terminal_events(id INTEGER PRIMARY KEY AUTOINCREMENT, conversation TEXT NOT NULL REFERENCES conversations(id), body TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS terminal_cursor ON terminal_events(conversation,id);
        CREATE TABLE IF NOT EXISTS terminal_inputs(id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, result TEXT NOT NULL);
        ''')
        self.db.commit()
        for p in self.directory.glob('cove.sqlite3*'):
            os.chmod(p, 0o600)
        # Uncertain dispatches are never replayed; queued work has not reached runtime.
        with self.lock, self.db:
            for row in self.db.execute("SELECT * FROM jobs WHERE state='running'").fetchall():
                self._finish(row['message'], 'failed', '服务在回复途中重启；未自动重发，请确认后发一条新消息。')

    def _revision(self):
        return self.db.execute('INSERT INTO revisions DEFAULT VALUES').lastrowid

    def _put(self, message, fingerprint=None):
        revision = self._revision()
        message['revision'] = revision
        self.db.execute('INSERT INTO messages VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET body=excluded.body,revision=excluded.revision',
                        (message['id'], message['conversationID'], encode(message), fingerprint, revision))

    def _message(self, id):
        row = self.db.execute('SELECT body,revision FROM messages WHERE id=?', (id,)).fetchone()
        return dict(self._decode_message(row[0]), revision=row[1]) if row else None

    def _decode_message(self, body):
        message = json.loads(body)
        message.setdefault('readAt', None)
        message.setdefault('isLiked', False)
        if 'attachments' not in message:
            url = message.get('attachmentURL') or ''
            attachment = self._file_metadata(url.rsplit('/', 1)[-1]) if url.startswith('/v1/attachments/') else None
            message['attachments'] = [attachment] if attachment else []
        return message

    @staticmethod
    def attachment_ids(body):
        from files import MAX_ATTACHMENTS
        ids = body.get('attachmentIDs')
        legacy = body.get('attachmentID')
        if ids is None:
            ids = [legacy] if legacy else []
        if not isinstance(ids, list) or len(ids) > MAX_ATTACHMENTS or any(not isinstance(id, str) or not id for id in ids) or len(set(ids)) != len(ids):
            raise APIError(400, 'attachmentIDs 最多 10 个且不能重复')
        if legacy and ids != [legacy] and (not ids or ids[0] != legacy):
            raise APIError(400, 'attachmentID 与 attachmentIDs 不一致')
        return ids

    @classmethod
    def _identity(cls, body):
        result = {k: body.get(k) for k in ('id', 'conversationID', 'text', 'replyTo')}
        result['attachmentIDs'] = cls.attachment_ids(body)
        # Omit absent sticker identity so all existing durable retries remain valid.
        if body.get('stickerID') is not None:
            result['stickerID'] = body['stickerID']
        return result

    def conversation(self, id):
        row = self.db.execute('SELECT * FROM conversations WHERE id=?', (id,)).fetchone()
        if not row:
            raise APIError(404, '会话不存在')
        return dict(row)

    def create_conversation(self, id=None):
        id = id or str(uuid.uuid4())
        with self.lock, self.db:
            self.db.execute('INSERT OR IGNORE INTO conversations VALUES(?,?,?,NULL)', (id, '新对话', now()))
            self.db.execute("INSERT INTO state VALUES('active',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (encode(id),))
            c = self.conversation(id)
            return {'id': id, 'title': c['title'], 'createdAt': c['created']}

    def conversations(self):
        with self.lock:
            rows = self.db.execute('SELECT * FROM conversations ORDER BY created').fetchall()
            active = self.db.execute("SELECT value FROM state WHERE key='active'").fetchone()
            return {'conversations': [{'id': r['id'], 'title': r['title'], 'createdAt': r['created']} for r in rows],
                    'activeConversationID': json.loads(active[0]) if active else None}

    def accept(self, body):
        identity = self._identity(body)
        fingerprint = encode(identity)
        with self.lock, self.db:
            if self.db.execute('SELECT 1 FROM terminal_inputs WHERE id=?', (body['id'],)).fetchone():
                raise APIError(409, '消息 ID 已用于控制指令')
            row = self.db.execute('SELECT fingerprint FROM messages WHERE id=?', (body['id'],)).fetchone()
            if row:
                if row[0] is None or self._identity(json.loads(row[0])) != identity:
                    raise APIError(409, '消息 ID 已用于不同内容')
                return self._message(body['id'])
            self.conversation(body['conversationID'])
            attachments = [self._file_metadata(id) for id in identity['attachmentIDs']]
            if any(attachment is None for attachment in attachments):
                raise APIError(404, '附件不存在')
            if body.get('stickerID') is not None:
                sticker = self.sticker(body['stickerID'])
                if identity['attachmentIDs'] != [sticker['attachment']['id']]:
                    raise APIError(400, '表情包与附件不一致')
            if body.get('replyTo'):
                quoted = self._message(body['replyTo'])
                if not quoted or quoted['conversationID'] != body['conversationID']:
                    raise APIError(400, '引用消息不属于此会话')
            message = {'id': body['id'], 'conversationID': body['conversationID'], 'role': 'user', 'text': body['text'],
                       'createdAt': now(), 'status': 'sent', 'replyTo': body.get('replyTo'),
                       'attachmentURL': attachments[0]['url'] if attachments else None, 'attachments': attachments, 'error': None,
                       'readAt': None, 'isLiked': False}
            if body.get('stickerID') is not None:
                message['stickerID'] = body['stickerID']
            self._put(message, fingerprint)
            self.db.execute('INSERT INTO jobs VALUES(?,?,NULL,?)', (message['id'], 'queued', 'assistant-' + str(uuid.uuid4())))
            self._terminal_event(message['conversationID'], 'input', message['text'])
            self.db.execute("UPDATE conversations SET title=? WHERE id=? AND title='新对话'", (message['text'][:36] or '附件', message['conversationID']))
            return message

    def poll(self, conversation, after, limit=200):
        with self.lock:
            self.conversation(conversation)
            rows = self.db.execute('SELECT body,revision FROM messages WHERE conversation=? AND revision>? ORDER BY revision LIMIT ?', (conversation, after, limit)).fetchall()
            busy = self.db.execute("SELECT 1 FROM jobs JOIN messages ON jobs.message=messages.id WHERE messages.conversation=? AND jobs.state IN ('queued','running') LIMIT 1", (conversation,)).fetchone()
            return {'messages': [dict(self._decode_message(r[0]), revision=r[1]) for r in rows], 'cursor': rows[-1][1] if rows else after, 'busy': bool(busy)}

    def claim(self):
        with self.lock, self.db:
            row = self.db.execute("SELECT jobs.* FROM jobs JOIN messages ON messages.id=jobs.message WHERE state='queued' ORDER BY messages.rowid LIMIT 1").fetchone()
            if not row:
                return None
            self.db.execute("UPDATE jobs SET state='running' WHERE message=?", (row['message'],))
            user = self._message(row['message'])
            assistant = {'id': row['assistant'], 'conversationID': user['conversationID'], 'role': 'assistant', 'text': '',
                         'createdAt': now(), 'status': 'streaming', 'replyTo': user['id'], 'attachmentURL': None, 'attachments': [], 'error': None}
            self._put(assistant)
            job = dict(row)
            job.update(user=user, conversation=self.conversation(user['conversationID']))
            return job

    def bind_thread(self, conversation, thread):
        with self.lock, self.db:
            self.db.execute('UPDATE conversations SET thread=? WHERE id=?', (thread, conversation))

    def bind_turn(self, message, turn, thread=None):
        with self.lock, self.db:
            row = self.db.execute("SELECT jobs.turn,conversations.thread FROM jobs JOIN messages ON messages.id=jobs.message JOIN conversations ON conversations.id=messages.conversation WHERE jobs.message=? AND jobs.state='running'", (message,)).fetchone()
            if not row or not isinstance(turn, str) or not turn or (row['turn'] and row['turn'] != turn) or (thread is not None and row['thread'] != thread):
                return False
            if self.db.execute('SELECT 1 FROM jobs WHERE turn=? AND message!=? LIMIT 1', (turn, message)).fetchone():
                return False
            self.db.execute('UPDATE jobs SET turn=? WHERE message=?', (turn, message))
            user = self._message(message)
            if user and user['role'] == 'user' and user['readAt'] is None:
                user['readAt'] = now()
                self._put(user)
            return True

    def set_reaction(self, conversation, message, liked):
        if not isinstance(liked, bool):
            raise APIError(400, 'isLiked 必须是布尔值')
        with self.lock, self.db:
            self.conversation(conversation)
            current = self._message(message)
            if not current:
                raise APIError(404, '消息不存在')
            if current['conversationID'] != conversation:
                raise APIError(400, '消息不属于此会话')
            if current['isLiked'] != liked:
                current['isLiked'] = liked
                self._put(current)
            return current

    def stream(self, message, text):
        with self.lock, self.db:
            row = self.db.execute("SELECT assistant FROM jobs WHERE message=? AND state='running'", (message,)).fetchone()
            if row:
                m = self._message(row[0]); m['text'] = text; self._put(m)

    def _finish(self, message, status, error=None):
        row = self.db.execute('SELECT assistant FROM jobs WHERE message=?', (message,)).fetchone()
        if not row:
            return
        m = self._message(row[0])
        if not m:
            user = self._message(message)
            m = {'id': row[0], 'conversationID': user['conversationID'], 'role': 'assistant', 'text': '', 'createdAt': now(), 'replyTo': message, 'attachmentURL': None}
        m.update(status=status, error=error)
        self._put(m)
        self.db.execute('UPDATE jobs SET state=? WHERE message=?', (status, message))
        if error or status == 'interrupted':
            self._terminal_event(m['conversationID'], 'error' if error else 'turn', error or '回合已停止')

    def finish(self, message, status, error=None):
        with self.lock, self.db:
            self._finish(message, status, error)

    def cancel_queued(self, conversation):
        with self.lock, self.db:
            self.conversation(conversation)
            rows = self.db.execute("SELECT jobs.message FROM jobs JOIN messages ON messages.id=jobs.message WHERE conversation=? AND state='queued'", (conversation,)).fetchall()
            for r in rows:
                self._finish(r[0], 'interrupted')

    def _terminal_event(self, conversation, kind, text, thread=None, turn=None, item=None):
        from terminal import redact
        body = {'kind': kind, 'text': redact(text), 'createdAt': now(), 'threadID': thread, 'turnID': turn, 'itemID': item}
        return self.db.execute('INSERT INTO terminal_events(conversation,body) VALUES(?,?)', (conversation, encode(body))).lastrowid

    def terminal_event(self, conversation, kind, text, thread=None, turn=None, item=None):
        with self.lock, self.db:
            self.conversation(conversation)
            return self._terminal_event(conversation, kind, text, thread, turn, item)

    def terminal_settings(self, conversation, model=None, effort=None):
        with self.lock:
            self.conversation(conversation)
            row = self.db.execute('SELECT value FROM state WHERE key=?', ('terminal-model:'+conversation,)).fetchone()
            return json.loads(row[0]) if row else {'model': model, 'effort': effort}

    def set_terminal_model(self, conversation, model, effort):
        with self.lock, self.db:
            self.conversation(conversation)
            self.db.execute('INSERT INTO state VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
                            ('terminal-model:'+conversation, encode({'model': model, 'effort': effort})))
            self._terminal_event(conversation, 'model', '下一回合：'+model+' · '+effort)

    def terminal_poll(self, conversation, after, tail=False):
        with self.lock:
            c = self.conversation(conversation)
            if tail:
                rows = list(reversed(self.db.execute('SELECT id,body FROM terminal_events WHERE conversation=? ORDER BY id DESC LIMIT 200', (conversation,)).fetchall()))
            else:
                rows = self.db.execute('SELECT id,body FROM terminal_events WHERE conversation=? AND id>? ORDER BY id LIMIT 200', (conversation, after)).fetchall()
            busy = self.db.execute("SELECT 1 FROM jobs JOIN messages ON jobs.message=messages.id WHERE messages.conversation=? AND jobs.state IN ('queued','running') LIMIT 1", (conversation,)).fetchone()
            return {'conversationID': conversation, 'events': [dict(json.loads(r['body']), id=r['id']) for r in rows],
                    'cursor': rows[-1]['id'] if rows else after, 'busy': bool(busy), 'threadID': c['thread']}

    def terminal_control(self, body, result=None, model=None, effort=None):
        identity = encode({k: body[k] for k in ('id', 'conversationID', 'text')})
        with self.lock, self.db:
            self.conversation(body['conversationID'])
            old = self.db.execute('SELECT fingerprint,result FROM terminal_inputs WHERE id=?', (body['id'],)).fetchone()
            if old:
                if old['fingerprint'] != identity:
                    raise APIError(409, '控制指令 ID 已用于不同内容')
                return json.loads(old['result']), False
            if result is None:
                return None, False
            if self.db.execute('SELECT 1 FROM messages WHERE id=?', (body['id'],)).fetchone():
                raise APIError(409, '控制指令 ID 已用于消息')
            if model:
                self.db.execute('INSERT INTO state VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
                                ('terminal-model:'+body['conversationID'], encode({'model': model, 'effort': effort})))
                self._terminal_event(body['conversationID'], 'model', '下一回合：'+model+' · '+effort)
            self._terminal_event(body['conversationID'], result['kind'], body['text'])
            self.db.execute('INSERT INTO terminal_inputs VALUES(?,?,?)', (body['id'], identity, encode(result)))
            return result, True

    def health(self):
        with self.lock:
            row = self.db.execute("SELECT value FROM state WHERE key='health'").fetchone()
            result = json.loads(row[0]) if row else {'snapshot': None, 'syncedAt': None, 'readAt': None}
            return result

    def health_for_tool(self):
        with self.lock:
            version = self.db.execute("SELECT value FROM state WHERE key='healthVersion'").fetchone()
            return self.health(), version[0] if version else None

    def mark_health_read(self, delivered, version):
        """Mark only the snapshot whose dynamic-tool response was written successfully."""
        if delivered['snapshot'] is None:
            return
        with self.lock, self.db:
            row = self.db.execute("SELECT value FROM state WHERE key='health'").fetchone()
            current = json.loads(row[0]) if row else None
            current_version = self.db.execute("SELECT value FROM state WHERE key='healthVersion'").fetchone()
            current_version = current_version[0] if current_version else None
            if current and current_version == version and current['syncedAt'] == delivered['syncedAt'] and current['snapshot'] == delivered['snapshot']:
                current['readAt'] = now()
                self.db.execute("UPDATE state SET value=? WHERE key='health'", (encode(current),))

    def upload_health(self, snapshot):
        result = {'snapshot': snapshot, 'syncedAt': now(), 'readAt': None}
        capture_day = datetime.fromisoformat(snapshot['capturedAt'].replace('Z', '+00:00')).astimezone(timezone.utc).date().isoformat()
        with self.lock, self.db:
            self.db.execute("INSERT INTO state VALUES('health',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (encode(result),))
            self.db.execute("INSERT INTO state VALUES('healthVersion',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (str(uuid.uuid4()),))
            self.db.execute('INSERT INTO health_history VALUES(?,?,?) ON CONFLICT(day) DO UPDATE SET snapshot=excluded.snapshot,synced=excluded.synced',
                            (capture_day, encode(snapshot), result['syncedAt']))
        return result['syncedAt']

    def health_history(self, days=7):
        today = datetime.now(timezone.utc).date()
        since = (today - timedelta(days=days-1)).isoformat()
        with self.lock:
            rows = self.db.execute('SELECT snapshot,synced FROM health_history WHERE day>=? AND day<=? ORDER BY day', (since, today.isoformat())).fetchall()
            return {'snapshots': [json.loads(r[0]) for r in rows], 'updatedAt': max((r[1] for r in rows), default=None)}

    def delete_health(self):
        with self.lock, self.db:
            self.db.execute("DELETE FROM state WHERE key IN ('health','healthVersion')")
            self.db.execute('DELETE FROM health_history')

    def add_attachment(self, filename, mime, data):
        from files import validate_file
        filename, mime, data = validate_file(filename, mime, data)
        id = str(uuid.uuid4())
        with self.lock, self.db:
            self.db.execute('INSERT INTO attachments VALUES(?,?,?,?)', (id, filename, mime, data))
            return self._file_metadata(id)

    def _file_metadata(self, id):
        row = self.db.execute('SELECT id,filename,mime,length(data) AS size FROM attachments WHERE id=?', (id,)).fetchone()
        if not row:
            return None
        result = dict(row); result['url'] = '/v1/attachments/' + id
        return result

    def attachment(self, id):
        with self.lock:
            row = self.db.execute('SELECT * FROM attachments WHERE id=?', (id,)).fetchone()
            if not row:
                raise APIError(404, '附件不存在')
            return dict(row)

    def attachment_for_message(self, id):
        attachments = self.attachments_for_message(id)
        return attachments[0] if attachments else None

    def attachments_for_message(self, id):
        with self.lock:
            row = self.db.execute('SELECT fingerprint FROM messages WHERE id=?', (id,)).fetchone()
            return [self.attachment(aid) for aid in self.attachment_ids(json.loads(row[0]))]

    def create_assistant_file(self, message, turn, call, filename, mime, data):
        from files import MAX_ATTACHMENTS, validate_file
        filename, mime, data = validate_file(filename, mime, data)
        with self.lock, self.db:
            job = self.db.execute("SELECT assistant FROM jobs WHERE message=? AND turn=? AND state='running'", (message, turn)).fetchone()
            if not job:
                raise APIError(409, '文件请求不属于正在运行的 Cove 回合')
            call = encode([message, turn, call])
            previous = self.db.execute('SELECT attachment FROM file_tool_results WHERE call=?', (call,)).fetchone()
            if previous:
                return self._file_metadata(previous[0])
            assistant = self._message(job[0])
            if len(assistant.get('attachments', [])) >= MAX_ATTACHMENTS:
                raise APIError(413, '每条回复最多 10 个文件')
            id = str(uuid.uuid4())
            self.db.execute('INSERT INTO attachments VALUES(?,?,?,?)', (id, filename, mime, data))
            attachment = self._file_metadata(id)
            assistant.setdefault('attachments', []).append(attachment)
            assistant['attachmentURL'] = assistant['attachments'][0]['url']
            assistant.pop('stickerID', None)
            self._put(assistant)
            self.db.execute('INSERT INTO file_tool_results VALUES(?,?)', (call, id))
            return attachment

    def _sticker(self, row):
        return {'id': row['id'], 'owner': row['owner'], 'label': row['label'],
                'createdAt': row['created'], 'attachment': self._file_metadata(row['attachment'])}

    def sticker(self, id):
        if not isinstance(id, str) or not id or len(id) > 128:
            raise APIError(400, '表情包 ID 无效')
        with self.lock:
            row = self.db.execute('SELECT * FROM stickers WHERE id=?', (id,)).fetchone()
            if not row:
                raise APIError(404, '表情包不存在')
            return self._sticker(row)

    def stickers(self, owner=None):
        with self.lock:
            rows = self.db.execute('SELECT * FROM stickers WHERE (? IS NULL OR owner=?) ORDER BY created,id', (owner, owner)).fetchall()
            return {'stickers': [self._sticker(row) for row in rows]}

    def _save_sticker(self, attachment_id, label, owner):
        from files import vision_image
        if not isinstance(attachment_id, str) or not attachment_id or len(attachment_id) > 128:
            raise APIError(400, '附件 ID 无效')
        if not isinstance(label, str) or not label.strip() or len(label) > 120 or any(ord(c) < 32 or ord(c) == 127 for c in label):
            raise APIError(400, '表情包名称需为 1–120 字且不能含控制字符')
        attachment = self.attachment(attachment_id)
        if not vision_image(attachment):
            raise APIError(400, '表情包仅支持格式匹配的 PNG、JPEG、GIF 或 WebP 图片')
        previous = self.db.execute('SELECT * FROM stickers WHERE owner=? AND attachment=?', (owner, attachment_id)).fetchone()
        if previous:
            return self._sticker(previous)
        if self.db.execute('SELECT count(*) FROM stickers WHERE owner=?', (owner,)).fetchone()[0] >= 500:
            raise APIError(413, '每人的表情包库最多 500 个')
        id = str(uuid.uuid4())
        self.db.execute('INSERT INTO stickers VALUES(?,?,?,?,?)', (id, owner, label.strip(), now(), attachment_id))
        return self.sticker(id)

    def save_user_sticker(self, attachment_id, label):
        with self.lock, self.db:
            return self._save_sticker(attachment_id, label, 'user')

    def assistant_sticker_tool(self, message, turn, call, tool, arguments):
        """Current-turn transaction; no global-token or path access for the model."""
        from files import MAX_ATTACHMENTS
        with self.lock, self.db:
            job = self.db.execute("SELECT assistant FROM jobs WHERE message=? AND turn=? AND state='running'", (message, turn)).fetchone()
            if not job:
                raise APIError(409, '表情包请求不属于正在运行的 Cove 回合')
            key = encode([message, turn, call])
            previous = self.db.execute('SELECT result FROM sticker_tool_results WHERE call=?', (key,)).fetchone()
            if previous:
                return json.loads(previous[0])
            if tool == 'cove_list_stickers':
                if arguments:
                    raise APIError(400, '列出表情包不接受参数')
                result = self.stickers('assistant')
            elif tool == 'cove_save_sticker':
                if set(arguments) != {'attachmentID', 'label'} or not isinstance(arguments['attachmentID'], str):
                    raise APIError(400, '保存表情包需 attachmentID 和 label')
                user = self._message(message)
                # The assistant can save only an image actually sent by the user in
                # this conversation, never an unshared upload or another chat's file.
                source = self.db.execute('''SELECT 1 FROM messages m
                    WHERE conversation=? AND json_extract(body,'$.role')='user'
                    AND (json_extract(body,'$.attachmentURL')=? OR EXISTS
                        (SELECT 1 FROM json_each(m.body,'$.attachments') a WHERE json_extract(a.value,'$.id')=?)) LIMIT 1''',
                    (user['conversationID'], '/v1/attachments/'+arguments['attachmentID'], arguments['attachmentID'])).fetchone()
                if not source:
                    raise APIError(403, '只能保存本会话中用户已发送的图片')
                result = {'sticker': self._save_sticker(arguments['attachmentID'], arguments['label'], 'assistant')}
            elif tool == 'cove_send_sticker':
                if set(arguments) != {'stickerID'}:
                    raise APIError(400, '发送表情包需 stickerID')
                sticker = self.sticker(arguments['stickerID'])
                if sticker['owner'] != 'assistant':
                    raise APIError(403, '只能发送自己已保存的表情包')
                assistant = self._message(job[0])
                if len(assistant.get('attachments', [])) >= MAX_ATTACHMENTS:
                    raise APIError(413, '每条回复最多 10 个文件')
                attachment = sticker['attachment']
                assistant.setdefault('attachments', []).append(attachment)
                assistant['attachmentURL'] = assistant['attachments'][0]['url']
                # A single-sticker reply has the same rendering marker as user sends.
                # Mixed/multiple files retain ordinary attachment presentation.
                if len(assistant['attachments']) == 1:
                    assistant['stickerID'] = sticker['id']
                else:
                    assistant.pop('stickerID', None)
                self._put(assistant)
                result = {'sticker': sticker, 'attachment': attachment}
            else:
                raise APIError(400, '未知表情包工具')
            self.db.execute('INSERT INTO sticker_tool_results VALUES(?,?)', (key, encode(result)))
            return result

    def register_device(self, token):
        with self.lock, self.db:
            self.db.execute('INSERT INTO devices VALUES(?,?) ON CONFLICT(token) DO UPDATE SET registered=excluded.registered', (token, now()))

    def unregister_device(self, token):
        with self.lock, self.db:
            self.db.execute('DELETE FROM devices WHERE token=?', (token,))

    def device_tokens(self):
        with self.lock:
            return [r[0] for r in self.db.execute('SELECT token FROM devices')]

    def close(self):
        with self.lock:
            self.db.close()
            self.process_lock.close()
