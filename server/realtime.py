"""Bounded bridge for Codex experimental thread/realtime.

The owning Runtime supplies request(). HTTP routing/auth and conversation->thread
resolution deliberately stay outside this module.
"""
import base64
import math
import os
import threading
import time
import uuid

from storage import APIError

REALTIME_METHODS = {
    'thread/realtime/started', 'thread/realtime/transcript/delta',
    'thread/realtime/transcript/done', 'thread/realtime/outputAudio/delta',
    'thread/realtime/sdp', 'thread/realtime/error', 'thread/realtime/closed',
}
MAX_INPUT_CHUNK = 256 * 1024
MAX_BUFFERED_AUDIO = 2 * 1024 * 1024
MAX_SDP = 256 * 1024
MAX_EVENTS = 256
VOICES = {'alloy','arbor','ash','ballad','breeze','cedar','coral','cove','echo','ember','juniper','maple','marin','sage','shimmer','sol','spruce','vale','verse'}


class RealtimeBridge:
    def init_realtime(self):
        self.realtime_lock = threading.RLock()
        self.realtime_sessions = {}
        self.realtime_idle_timeout = min(600, max(30, int(os.getenv('COVE_REALTIME_IDLE_TIMEOUT', '120'))))

    def realtime_start(self, thread_id, voice=None, transport=None):
        if not thread_id:
            raise APIError(409, '当前会话还没有 Codex thread')
        if voice is not None and (not isinstance(voice, str) or voice not in VOICES):
            raise APIError(400, '语音音色不受当前 Codex 支持')
        if transport is None:
            transport = {'type': 'websocket'}
        if not isinstance(transport, dict) or set(transport) != {'type', 'sdp'} or transport.get('type') != 'webrtc':
            if transport != {'type': 'websocket'}:
                raise APIError(400, '实时通话传输参数无效')
        if transport.get('type') == 'webrtc':
            sdp = transport.get('sdp')
            if not isinstance(sdp, str) or not sdp.startswith('v=0') or len(sdp.encode()) > MAX_SDP:
                raise APIError(400, 'WebRTC SDP 无效')
        with self.realtime_lock:
            previous = self.realtime_sessions.get(thread_id)
            if previous and not previous.get('stopConfirmed'):
                raise APIError(409, '当前会话已在语音中')
        catalog = self.request('thread/realtime/listVoices', {}, timeout=15).get('voices', {})
        # Match native Codex /voice: WebRTC uses realtime V3, whose voices are
        # the catalog's V1 family (not V2). Omitting version selects V1 for
        # WebRTC; choosing defaultV2 then fails before any network request.
        supported = set(catalog.get('v1', []))
        selected_voice = voice or catalog.get('defaultV1')
        if not isinstance(selected_voice, str) or selected_voice not in VOICES or selected_voice not in supported:
            raise APIError(400, '当前 Codex 没有可用的语音音色')
        with self.realtime_lock:
            previous = self.realtime_sessions.get(thread_id)
            if previous and not previous.get('stopConfirmed'):
                raise APIError(409, '当前会话已在语音中')
            session_id = str(uuid.uuid4())
            self.realtime_sessions[thread_id] = {'id': session_id, 'cursor': 0, 'events': [], 'audioBytes': 0,
                'closed': False, 'started': False, 'lastActivity': time.monotonic(), 'ioLock': threading.Lock()}
            self.realtime_sessions[thread_id]['stopConfirmed'] = False
        try:
            with self.realtime_sessions[thread_id]['ioLock']:
                self.request('thread/realtime/start', {
                    'threadId': thread_id, 'outputModality': 'audio', 'voice': selected_voice,
                    'transport': transport, 'realtimeSessionId': session_id,
                    'version': 'v3',
                    # Unlike the TUI, Cove does not consume client handoff
                    # events. Keep delegation on the existing app-server thread.
                    'clientManagedHandoffs': False,
                }, timeout=30)
        except Exception:
            with self.realtime_lock:
                session = self.realtime_sessions.get(thread_id)
                if session and session['id'] == session_id:
                    session['closed'] = True; session['failed'] = True
            if session: threading.Thread(target=self._abort_realtime, args=(thread_id, session), daemon=True).start()
            raise
        return {'ok': True, 'sessionID': session_id}

    def realtime_append_audio(self, thread_id, session_id, data, sample_rate, channels, samples=None):
        if isinstance(sample_rate, bool) or not isinstance(sample_rate, (int,float)) or not math.isfinite(sample_rate):
            raise APIError(400, '采样率无效')
        if isinstance(channels, bool) or not isinstance(channels, int):
            raise APIError(400, '声道数无效')
        if samples is not None and (isinstance(samples, bool) or not isinstance(samples, int) or samples <= 0):
            raise APIError(400, '样本数无效')
        try:
            raw = base64.b64decode(data, validate=True)
        except Exception:
            raise APIError(400, '语音数据不是有效 Base64')
        if not raw or len(raw) > MAX_INPUT_CHUNK:
            raise APIError(400, '单个语音分片必须在 1–262144 字节')
        if sample_rate < 8000 or sample_rate > 48000 or channels not in (1, 2):
            raise APIError(400, '语音格式不受支持')
        if len(raw) % (channels * 2) or (samples is not None and len(raw) != samples * channels * 2):
            raise APIError(400, 'PCM16 分片长度与声道/样本数不匹配')
        with self.realtime_lock:
            session = self.realtime_sessions.get(thread_id)
            if not session or session['id'] != session_id or session['closed'] or not session['started']:
                raise APIError(409, '语音会话未开始或已结束')
            session['lastActivity'] = time.monotonic()
        audio = {'data': data, 'sampleRate': sample_rate, 'numChannels': channels,
                 'samplesPerChannel': samples, 'itemId': None}
        with session['ioLock']:
            with self.realtime_lock:
                current = self.realtime_sessions.get(thread_id)
                if current is not session or session['id'] != session_id or session['closed']:
                    raise APIError(409, '语音会话已更换或结束')
            self.request('thread/realtime/appendAudio', {'threadId': thread_id, 'audio': audio}, timeout=15)
        return {'ok': True}

    def realtime_stop(self, thread_id, session_id):
        # Idempotent locally; the first call still requires app-server ACK.
        with self.realtime_lock:
            session = self.realtime_sessions.get(thread_id)
            if not session or session['id'] != session_id:
                raise APIError(409, '语音会话已更换或结束')
            if session['closed']:
                return {'ok': True}
        with session['ioLock']:
            with self.realtime_lock:
                current = self.realtime_sessions.get(thread_id)
                if current is not session or session['id'] != session_id:
                    raise APIError(409, '语音会话已更换或结束')
                if session['closed']: return {'ok': True}
            self.request('thread/realtime/stop', {'threadId': thread_id}, timeout=15)
            with self.realtime_lock: session['closed'] = True; session['stopConfirmed'] = True
        return {'ok': True}

    def realtime_poll(self, thread_id, session_id, after=0):
        if isinstance(after, bool) or not isinstance(after, int) or after < 0:
            raise APIError(400, '语音事件游标无效')
        with self.realtime_lock:
            session = self.realtime_sessions.get(thread_id)
            if not session or session['id'] != session_id:
                raise APIError(404, '语音会话不存在')
            kept = []
            for event in session['events']:
                if event['id'] <= after:
                    session['audioBytes'] -= event.get('_audioBytes', 0)
                else: kept.append(event)
            session['events'] = kept
            session['lastActivity'] = time.monotonic()
            events = [{k:v for k,v in e.items() if not k.startswith('_')} for e in kept]
            return {'cursor': session['cursor'], 'events': events, 'closed': session['closed']}

    def realtime_busy(self):
        expired, retries = [], []
        with self.realtime_lock:
            now = time.monotonic()
            for thread_id, session in self.realtime_sessions.items():
                if not session['closed'] and now - session['lastActivity'] > self.realtime_idle_timeout:
                    session['closed'] = True; expired.append(thread_id)
                if session['closed'] and not session.get('stopConfirmed') and now >= session.get('retryAt', 0):
                    session['retryAt'] = now + 2; retries.append((thread_id, session))
            busy = any(not s.get('stopConfirmed') for s in self.realtime_sessions.values())
        for thread_id in expired:
            session = self.realtime_sessions.get(thread_id)
            if session: threading.Thread(target=self._abort_realtime, args=(thread_id, session), daemon=True).start()
        for thread_id, session in retries:
            threading.Thread(target=self._abort_realtime, args=(thread_id, session), daemon=True).start()
        return busy

    def realtime_requires_reconnect(self):
        with self.realtime_lock:
            now = time.monotonic()
            return any(s.get('stopFailedAt') and now - s['stopFailedAt'] >= 30 and not s.get('stopConfirmed')
                       for s in self.realtime_sessions.values())

    def realtime_disconnect(self):
        with self.realtime_lock:
            for session in self.realtime_sessions.values(): session['closed'] = True
            self.realtime_sessions.clear()

    def _realtime_notification(self, message):
        method, params = message.get('method'), message.get('params', {})
        if method not in REALTIME_METHODS or not params.get('threadId'):
            return False
        thread_id = params['threadId']
        with self.realtime_lock:
            session = self.realtime_sessions.get(thread_id)
            if not session:
                return False
            public = {'method': method}
            if method == 'thread/realtime/started':
                if params.get('realtimeSessionId') != session['id'] or session['closed']:
                    return True
                session['started'] = True
                public.update(realtimeSessionId=session['id'], version=params.get('version'))
            elif method == 'thread/realtime/sdp':
                sdp = params.get('sdp')
                if not session['started'] or not isinstance(sdp, str) or not sdp.startswith('v=0') or len(sdp.encode()) > MAX_SDP:
                    return True
                public['sdp'] = sdp
            elif not session['started']:
                if method == 'thread/realtime/error':
                    public = {'method': method, 'message': 'Codex 语音启动失败'}; session['closed'] = True
                    threading.Thread(target=self._abort_realtime, args=(thread_id, session), daemon=True).start()
                elif method == 'thread/realtime/closed':
                    public = {'method': method, 'reason': ''}; session['closed'] = True; session['stopConfirmed'] = True
                else:
                    return True
            elif session['closed']:
                return True
            elif method == 'thread/realtime/outputAudio/delta':
                audio = params.get('audio') or {}
                data = audio.get('data', '')
                try: size = len(base64.b64decode(data, validate=True))
                except Exception: return True
                if session['audioBytes'] + size > MAX_BUFFERED_AUDIO:
                    session['closed'] = True
                    public = {'method': 'thread/realtime/error', 'message': '语音播放缓冲区已满，会话已停止'}
                    threading.Thread(target=self._abort_realtime, args=(thread_id, session), daemon=True).start()
                else:
                    session['audioBytes'] += size
                    public['audio'] = {k: audio.get(k) for k in ('data','sampleRate','numChannels','samplesPerChannel')}
                    public['_audioBytes'] = size
            elif method.endswith('transcript/delta'):
                public.update(role=str(params.get('role','')), delta=str(params.get('delta',''))[:16000])
            elif method.endswith('transcript/done'):
                public.update(role=str(params.get('role','')), text=str(params.get('text',''))[:16000])
            elif method.endswith('/error'):
                public['message'] = 'Codex 语音出错'; session['closed'] = True
                threading.Thread(target=self._abort_realtime, args=(thread_id, session), daemon=True).start()
            elif method.endswith('/closed'):
                public['reason'] = ''; session['closed'] = True; session['stopConfirmed'] = True
            session['cursor'] += 1; public['id'] = session['cursor']
            session['events'].append(public)
            while len(session['events']) > MAX_EVENTS:
                audio_index = next((i for i,e in enumerate(session['events']) if e.get('_audioBytes')), None)
                if audio_index is not None:
                    session['audioBytes'] = 0
                    non_audio = [e for e in session['events'] if not e.get('_audioBytes')]
                    session['events'] = non_audio[-(MAX_EVENTS - 1):]
                    session['closed'] = True
                    session['cursor'] += 1
                    session['events'].append({'id': session['cursor'], 'method':'thread/realtime/error',
                                              'message':'语音事件来不及交付，会话已停止'})
                    threading.Thread(target=self._abort_realtime, args=(thread_id, session), daemon=True).start()
                    break
                session['events'].pop(0)
        return True

    def _abort_realtime(self, thread_id, session):
        with session['ioLock']:
            with self.realtime_lock:
                if self.realtime_sessions.get(thread_id) is not session or session.get('stopConfirmed'):
                    return
            try:
                self.request('thread/realtime/stop', {'threadId': thread_id}, timeout=5)
                with self.realtime_lock:
                    if self.realtime_sessions.get(thread_id) is session: session['stopConfirmed'] = True
            except Exception:
                with self.realtime_lock:
                    if self.realtime_sessions.get(thread_id) is session:
                        session.setdefault('stopFailedAt', time.monotonic()); session['retryAt'] = time.monotonic() + 2
