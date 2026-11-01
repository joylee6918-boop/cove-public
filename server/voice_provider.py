"""Bounded, opt-in operator-configured text-to-speech providers.

The API key and voice id are host configuration.  They are deliberately never
accepted from a phone request.  Network IO is injectable so tests never spend
credits or transmit user text.
"""
from __future__ import annotations

import json
import math
import os
import urllib.error
import urllib.request
from dataclasses import dataclass


class VoiceProviderError(RuntimeError):
    pass


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never forward the server API key to a redirected origin."""
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _no_redirect_open(request, timeout):
    return urllib.request.build_opener(_NoRedirect()).open(request, timeout=timeout)


@dataclass(frozen=True)
class MiniMaxVoiceConfig:
    api_key: str
    voice_id: str
    model: str = "speech-2.8-turbo"
    endpoint: str = "https://api.minimax.io/v1/t2a_v2"
    timeout: float = 30.0
    maximum_characters: int = 2_000
    maximum_audio_bytes: int = 20 * 1024 * 1024
    speed: float = 1.0
    volume: float = 1.0
    emotion: str = ""

    @classmethod
    def from_env(cls, env=None):
        env = os.environ if env is None else env
        key = env.get("COVE_MINIMAX_API_KEY", "").strip()
        voice = env.get("COVE_MINIMAX_VOICE_ID", "").strip()
        if not key or not voice:
            raise VoiceProviderError("MiniMax 语音未配置")
        model = env.get("COVE_MINIMAX_MODEL", "speech-2.8-turbo").strip()
        if model not in ("speech-2.8-turbo", "speech-2.8-hd", "speech-2.6-turbo", "speech-2.6-hd"):
            raise VoiceProviderError("MiniMax 语音模型不在允许列表")
        endpoint = env.get("COVE_MINIMAX_ENDPOINT", "https://api.minimax.io/v1/t2a_v2").strip()
        if endpoint not in ("https://api.minimax.io/v1/t2a_v2", "https://api.minimax.cn/v1/t2a_v2"):
            raise VoiceProviderError("MiniMax 语音地址不在官方允许列表")
        emotion = env.get("COVE_MINIMAX_EMOTION", "").strip()
        if emotion not in ("", "happy", "sad", "angry", "fearful", "disgusted", "surprised", "calm", "fluent", "whisper"):
            raise VoiceProviderError("MiniMax 语音情绪无效")
        if emotion in ("fluent", "whisper") and not model.startswith("speech-2.6-"):
            raise VoiceProviderError("当前情绪需要 speech-2.6 模型")
        try:
            speed = float(env.get("COVE_MINIMAX_SPEED", "1"))
            volume = float(env.get("COVE_MINIMAX_VOLUME", "1"))
        except ValueError as exc:
            raise VoiceProviderError("MiniMax 语速或音量配置无效") from exc
        if not math.isfinite(speed) or not .5 <= speed <= 2 or not math.isfinite(volume) or not 0 < volume <= 10:
            raise VoiceProviderError("MiniMax 语速或音量超出范围")
        try:
            timeout = min(60.0, max(5.0, float(env.get("COVE_MINIMAX_TIMEOUT", "30"))))
        except ValueError as exc:
            raise VoiceProviderError("MiniMax 超时配置无效") from exc
        return cls(key, voice, model=model, endpoint=endpoint, timeout=timeout,
                   speed=speed, volume=volume, emotion=emotion)


class MiniMaxVoiceProvider:
    def __init__(self, config: MiniMaxVoiceConfig, opener=None):
        self.config = config
        self._opener = opener or _no_redirect_open

    def synthesize(self, text: str) -> tuple[bytes, str]:
        text = text.strip() if isinstance(text, str) else ""
        if not text:
            raise VoiceProviderError("语音文本不能为空")
        if len(text) > self.config.maximum_characters:
            raise VoiceProviderError(f"语音文本最多 {self.config.maximum_characters} 个字符")
        payload = {
            "model": self.config.model,
            "text": text,
            "stream": False,
            "language_boost": "auto",
            "output_format": "hex",
            "voice_setting": {"voice_id": self.config.voice_id, "speed": self.config.speed, "vol": self.config.volume, "pitch": 0},
            "audio_setting": {"sample_rate": 32000, "bitrate": 128000, "format": "mp3", "channel": 1},
        }
        if self.config.emotion:
            payload["voice_setting"]["emotion"] = self.config.emotion
        request = urllib.request.Request(
            self.config.endpoint, data=json.dumps(payload).encode(), method="POST",
            headers={"Authorization": "Bearer " + self.config.api_key, "Content-Type": "application/json"},
        )
        try:
            with self._opener(request, timeout=self.config.timeout) as response:
                raw = response.read(self.config.maximum_audio_bytes * 2 + 65536)
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise VoiceProviderError("MiniMax 语音请求失败") from exc
        try:
            result = json.loads(raw)
            base = result.get("base_resp") or {}
            if base.get("status_code", 0) != 0:
                # Provider messages are untrusted and can echo request/account
                # details. Return only the bounded numeric code, never raw text.
                code = base.get("status_code")
                code = code if isinstance(code, int) else "unknown"
                raise VoiceProviderError(f"音频生成失败（MiniMax {code}）")
            encoded = ((result.get("data") or {}).get("audio"))
            if not isinstance(encoded, str):
                raise ValueError("missing audio")
            audio = bytes.fromhex(encoded)
        except VoiceProviderError:
            raise
        except (ValueError, TypeError, json.JSONDecodeError) as exc:
            raise VoiceProviderError("MiniMax 返回了无效音频") from exc
        if not audio or len(audio) > self.config.maximum_audio_bytes:
            raise VoiceProviderError("MiniMax 音频为空或超过 20 MiB")
        return audio, "audio/mpeg"


# Optional paid provider. No maintainer voice identity or delivery profile is bundled.
class ElevenLabsVoiceProvider:
    MODEL = "eleven_v4"
    SETTINGS = {"stability": 0.5, "similarity_boost": 0.75}
    MAX_AUDIO = 20 * 1024 * 1024

    def __init__(self, key_path, voice_id="", opener=None):
        from pathlib import Path
        import re
        if not key_path or not Path(key_path).is_absolute():
            raise VoiceProviderError("ElevenLabs 语音未配置")
        if not isinstance(voice_id, str) or not re.fullmatch(r"[A-Za-z0-9]{20,64}", voice_id):
            raise VoiceProviderError("ElevenLabs 音色配置无效")
        self.key_path, self.voice_id = Path(key_path), voice_id
        self._opener = opener or _no_redirect_open

    def _key(self):
        import stat
        try:
            fd = os.open(self.key_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, "r") as file:
                info = os.fstat(file.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
                    raise ValueError("unsafe credential file")
                key = file.read(8193).strip()
                if not key or len(key) > 8192: raise ValueError("invalid credential")
                return key
        except (OSError, ValueError, UnicodeError):
            raise VoiceProviderError("ElevenLabs 服务端凭据不可用") from None

    def synthesize(self, text):
        if not isinstance(text, str) or not 1 <= len(text.strip()) <= 2000:
            raise VoiceProviderError("语音文本须为 1 至 2000 个字符")
        payload = {"text": text, "model_id": self.MODEL, "voice_settings": dict(self.SETTINGS)}
        request = urllib.request.Request(
            "https://api.elevenlabs.io/v1/text-to-speech/" + self.voice_id + "?output_format=mp3_44100_128",
            data=json.dumps(payload, ensure_ascii=False).encode(), method="POST",
            headers={"xi-api-key": self._key(), "Content-Type": "application/json", "Accept": "audio/mpeg"})
        try:
            with self._opener(request, timeout=60) as response:
                audio = response.read(self.MAX_AUDIO + 1)
                if response.status != 200: raise ValueError("invalid response")
        except (urllib.error.URLError, TimeoutError, OSError, ValueError):
            raise VoiceProviderError("ElevenLabs 语音结果未确认，请勿自动重试或更换声音重试") from None
        if (not audio or len(audio) > self.MAX_AUDIO or not
                (audio.startswith(b"ID3") or (len(audio) > 1 and audio[0] == 255 and audio[1] & 224 == 224))):
            raise VoiceProviderError("ElevenLabs 返回了无效或过大的 MP3，不自动重试")
        return audio, "audio/mpeg"


def selected_voice_provider(voice=None, env=None):
    env = os.environ if env is None else env
    selected = env.get("COVE_VOICE_DEFAULT", "minimax") if voice is None else voice
    if selected == "minimax":
        return MiniMaxVoiceProvider(MiniMaxVoiceConfig.from_env(env))
    if selected == "elevenlabs":
        return ElevenLabsVoiceProvider(env.get("COVE_ELEVENLABS_KEY_PATH", ""),
            env.get("COVE_ELEVENLABS_VOICE_ID", ""))
    raise VoiceProviderError("声音选择须为 elevenlabs 或 minimax")
