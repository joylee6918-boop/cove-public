"""Local authenticated ingress, using Cove's existing single-writer queue."""
import json
import uuid
from storage import APIError, now, encode
from wake_prompt import prompt, ROOM


def handle(app, body):
    store = app.store
    action = body.get('action')
    conversation = body.get('conversationID')
    if action == 'check':
        with store.lock:
            store.conversation(conversation)
            row = store.db.execute('SELECT thread FROM conversations WHERE id=?', (conversation,)).fetchone()
            busy = store.db.execute("SELECT 1 FROM jobs WHERE state IN ('queued','running') LIMIT 1").fetchone()
        return {'ok': bool(row and row[0]), 'busy': bool(busy), 'thread': row[0] if row else None}
    event = body.get('event', {})
    event_id = event.get('event_id')
    if type(event_id) is not int or event_id <= 0:
        raise APIError(400, 'invalid AISay event ID')
    key = 'aisay-cove-' + str(event_id)
    if action == 'status':
        with store.lock:
            row = store.db.execute('SELECT * FROM jobs WHERE message=?', (key,)).fetchone()
            return {'ok': True, 'state': row['state'] if row else 'absent'}
    if action != 'submit' or event.get('type') != 'aisay_wake':
        raise APIError(400, 'invalid AISay action')
    check = event.get('category') == 'test'
    if not check and (event.get('category') not in ('mention', 'private_room') or (event.get('resource') or {}).get('room_id') != ROOM):
        raise APIError(400, 'AISay room/category outside scope')
    text = prompt('assistant', event, check)
    fp = encode({'conversation': conversation, 'event': event})
    with store.lock, store.db:
        old = store.db.execute('SELECT fingerprint FROM messages WHERE id=?', (key,)).fetchone()
        if old:
            if old[0] != fp:
                raise APIError(409, 'AISay event conflict')
            return {'ok': True, 'id': key, 'duplicate': True}
        store.conversation(conversation)
        if store._handoff_busy(conversation) or store.db.execute("SELECT 1 FROM jobs WHERE state IN ('queued','running') LIMIT 1").fetchone():
            raise APIError(409, 'session_busy')
        message = {'id': key, 'conversationID': conversation, 'role': 'system', 'text': text,
                   'createdAt': now(), 'status': 'sent', 'aisayEventID': event_id,
                   'attachments': [], 'error': None, 'hidden': True}
        store._put(message, fp)
        store.db.execute('INSERT INTO jobs VALUES(?,?,NULL,?)', (key, 'queued', 'assistant-' + str(uuid.uuid4())))
    app.wake.set()
    return {'ok': True, 'id': key, 'duplicate': False}
