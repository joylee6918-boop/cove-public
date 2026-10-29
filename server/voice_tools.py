"""Small adapter for attaching generated speech through Cove's existing store."""
import json
from voice_provider import MiniMaxVoiceConfig, MiniMaxVoiceProvider, VoiceProviderError


def synthesize_attachment(store, text, provider=None):
    """Generate and persist an attachment; caller must bind it to the active reply.

    Keeping message/turn authorization in the existing MCP bridge prevents this
    provider from becoming a second, weaker tool path.
    """
    provider = provider or MiniMaxVoiceProvider(MiniMaxVoiceConfig.from_env())
    audio, mime = provider.synthesize(text)
    return store.add_attachment("Assistant-voice.mp3", mime, audio)


def synthesize_once(store, key, text, provider=None):
    """Charge at most once for a tool-call key, including concurrent retries.

    The receipt is committed before network IO. A failed/uncertain request stays
    failed rather than silently spending again; a successful result is retained
    for a same-call retry after a process restart.
    """
    with store.lock, store.db:
        store.db.execute('''CREATE TABLE IF NOT EXISTS voice_tool_results(
            call TEXT PRIMARY KEY, state TEXT NOT NULL, mime TEXT, audio BLOB, error TEXT)''')
        row = store.db.execute('SELECT * FROM voice_tool_results WHERE call=?', (key,)).fetchone()
        if row:
            if row['state'] == 'done': return bytes(row['audio']), row['mime']
            raise VoiceProviderError('这次语音生成已失败或结果不确定，为避免重复扣费不会自动重试')
        store.db.execute('INSERT INTO voice_tool_results(call,state) VALUES(?,?)', (key, 'running'))
    try:
        audio, mime = (provider or MiniMaxVoiceProvider(MiniMaxVoiceConfig.from_env())).synthesize(text)
        if not isinstance(audio, bytes) or not audio or len(audio) > 20 * 1024 * 1024 or mime != 'audio/mpeg':
            raise VoiceProviderError('语音结果为空、格式不匹配或超过 20 MiB')
    except Exception:
        with store.lock, store.db:
            store.db.execute("UPDATE voice_tool_results SET state='failed',error=? WHERE call=?", ('provider failure', key))
        raise
    with store.lock, store.db:
        store.db.execute("UPDATE voice_tool_results SET state='done',mime=?,audio=? WHERE call=?", (mime, audio, key))
    return audio, mime


__all__ = ["synthesize_attachment", "synthesize_once", "VoiceProviderError"]
