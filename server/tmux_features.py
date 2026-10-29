"""Native Codex 0.155.1 feature probes for the persistent CLI route.

This module does not send to a pane, change a running model, start realtime,
open an image as text, or fall back to app-server. Callers must keep those
operations disabled until a separately verified native transport exists.
"""

from __future__ import annotations

import json
import math
import os
import re
import stat
import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Mapping


class NativeFeatureUnavailable(RuntimeError):
    pass


_MODEL_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,99}\Z")
_EFFORTS = frozenset({"minimal", "low", "medium", "high", "xhigh", "max", "ultra"})


def native_client_version(binary: str | Path, *, runner=subprocess.run) -> str:
    """Read only the pinned executable's version; never refresh the catalog."""
    path = Path(binary)
    if not path.is_absolute() or not path.is_file() or path.is_symlink():
        raise ValueError('explicit native CLI binary required')
    env = {key: os.environ[key] for key in ('PATH', 'HOME', 'LANG', 'LC_ALL') if key in os.environ}
    try:
        result = runner([str(path), '--version'], shell=False, capture_output=True,
                        text=True, timeout=5, check=False, env=env)
        output = result.stdout.strip()
        match = re.fullmatch(r'codex-cli (\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?)', output)
        if result.returncode or len(output) > 80 or match is None:
            raise ValueError
        return match.group(1)
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        raise NativeFeatureUnavailable('无法验证原生 CLI 版本') from error


def cached_catalog(codex_home: str | Path, *, now: datetime | None = None,
                   expected_client_version: str | None = None,
                   max_age_seconds: int = 300) -> dict:
    """Project a recent *native account cache*, not the bundled catalog.

    This does not refresh, authenticate, or prove that the current account can
    still use every cached model. A missing/stale/unsafe cache is unavailable,
    never replaced with a hard-coded list or the binary's bundled fallback.
    """
    home = Path(codex_home)
    if not home.is_absolute() or '..' in home.parts:
        raise ValueError('explicit canonical CODEX_HOME required')
    if (not isinstance(expected_client_version, str) or
            not re.fullmatch(r'\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?', expected_client_version)):
        raise NativeFeatureUnavailable('缺少已验证的原生 CLI 版本，不能信任模型缓存')
    if type(max_age_seconds) is not int or not 0 < max_age_seconds <= 300:
        raise ValueError('native cache TTL must be at most 300 seconds')
    path = home / 'models_cache.json'
    try:
        if home != home.resolve(strict=True):
            raise ValueError
        home_info = home.lstat()
        info = path.lstat()
        if (not stat.S_ISDIR(home_info.st_mode) or home_info.st_uid != os.getuid() or
                home_info.st_mode & 0o077 or not stat.S_ISREG(info.st_mode) or
                info.st_uid != os.getuid() or info.st_mode & 0o077 or
                info.st_size <= 0 or info.st_size > 8 * 1024 * 1024):
            raise ValueError
        data = json.loads(path.read_text(encoding='utf-8'))
        if not isinstance(data, dict) or not isinstance(data.get('identity'), str) or not data['identity']:
            raise ValueError
        version = data.get('client_version')
        if version != expected_client_version:
            raise ValueError
        fetched = data['fetched_at']
        stamp = datetime.fromisoformat(fetched.replace('Z', '+00:00'))
        clock = now or datetime.now(timezone.utc)
        if stamp.tzinfo is None or clock.tzinfo is None:
            raise ValueError
        age = (clock - stamp).total_seconds()
        if not 0 <= age <= max_age_seconds:
            raise ValueError
        source = data['models']
        if not isinstance(source, list) or len(source) > 200:
            raise ValueError
        models, seen = [], set()
        for item in source:
            if not isinstance(item, dict) or item.get('visibility') != 'list':
                continue
            slug = item.get('slug')
            if not isinstance(slug, str) or not _MODEL_ID.fullmatch(slug) or slug in seen:
                continue
            levels = item.get('supported_reasoning_levels')
            if not isinstance(levels, list):
                continue
            efforts = list(dict.fromkeys(level['effort'] for level in levels
                                         if isinstance(level, dict) and level.get('effort') in _EFFORTS))
            default = item.get('default_reasoning_level')
            if not efforts or default not in efforts:
                continue
            title = item.get('display_name')
            if (not isinstance(title, str) or not 1 <= len(title) <= 120 or
                    any(ord(character) < 32 for character in title)):
                title = slug
            seen.add(slug)
            models.append({'id': slug, 'model': slug, 'displayName': title,
                           'supportedEfforts': efforts, 'defaultEffort': default})
        if not models:
            raise ValueError
        updated = stamp.astimezone(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
        return {'models': models, 'updatedAt': updated,
                'source': 'native-account-cache', 'accountAvailabilityVerified': False,
                'cacheIdentityVerified': False, 'cacheClientVersion': version,
                'cacheAgeSeconds': int(age)}
    except (OSError, UnicodeError, KeyError, TypeError, ValueError, OverflowError) as error:
        raise NativeFeatureUnavailable('原生账号模型缓存缺失、过期或无法安全验证') from error


def validate_cached_model(codex_home: str | Path, model: str, effort: str | None = None,
                          *, now: datetime | None = None,
                          expected_client_version: str | None = None) -> tuple[str, str]:
    """Validate a requested setting against the recent native cache only.

    This is *not* a live availability probe and never changes a pane. The
    orchestrator must not persist the selection as applied to an existing TUI
    until a separately authorized native switch/resume is confirmed.
    """
    if not isinstance(model, str) or not _MODEL_ID.fullmatch(model):
        raise ValueError('invalid model ID')
    if effort is not None and (not isinstance(effort, str) or effort not in _EFFORTS):
        raise ValueError('invalid reasoning effort')
    options = cached_catalog(codex_home, now=now,
                             expected_client_version=expected_client_version)['models']
    selected = next((item for item in options if model in (item['id'], item['model'])), None)
    if selected is None:
        raise NativeFeatureUnavailable('所选模型不在当前安全的原生账号缓存中')
    chosen = effort or selected['defaultEffort']
    if chosen not in selected['supportedEfforts']:
        raise NativeFeatureUnavailable('该模型缓存未列出所选推理强度')
    return selected['model'], chosen


def unavailable_usage(*, updated_at: str | None = None) -> dict:
    """Quota cannot be inferred from rollout tokens or a bundled model list."""
    stamp = updated_at or datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
    return {'plan': None, 'updatedAt': stamp, 'windows': [],
            'error': '原生 CLI 未提供已验证的账号额度；未用 token 消耗推算配额'}


def quota_from_records(records: Iterable[Mapping], *, now: datetime | None = None,
                       max_age_seconds: int = 2 * 3600) -> dict:
    """Project only an exact native `codex` rate-limit sample, never tokens.

    Native `token_count` events may include quota metadata, but their token
    usage counters are unrelated to subscription windows. A stale, absent or
    model-specific rate-limit bucket yields explicit unavailable state.
    """
    clock = now or datetime.now(timezone.utc)
    winner = None
    for record in records:
        if not isinstance(record, Mapping) or record.get('type') != 'event_msg':
            continue
        payload = record.get('payload')
        if not isinstance(payload, Mapping) or payload.get('type') != 'token_count':
            continue
        quota = payload.get('rate_limits')
        if not isinstance(quota, Mapping) or quota.get('limit_id') != 'codex':
            continue
        try:
            stamp = datetime.fromisoformat(record['timestamp'].replace('Z', '+00:00'))
            age = (clock - stamp).total_seconds()
            if stamp.tzinfo is None or not 0 <= age <= max_age_seconds:
                continue
        except (KeyError, AttributeError, TypeError, ValueError, OverflowError):
            continue
        windows = []
        seen = set()
        for key in ('primary', 'secondary'):
            value = quota.get(key)
            if not isinstance(value, Mapping):
                continue
            duration, percent, resets = (value.get('window_minutes'),
                                         value.get('used_percent'), value.get('resets_at'))
            if type(duration) is not int or duration not in (300, 10080) or duration in seen:
                continue
            if (isinstance(percent, bool) or not isinstance(percent, (float, int)) or
                    not math.isfinite(percent) or not 0 <= percent <= 100):
                continue
            reset_iso = None
            if isinstance(resets, (float, int)) and not isinstance(resets, bool) and math.isfinite(resets):
                try:
                    reset_iso = datetime.fromtimestamp(resets, timezone.utc).isoformat(
                        timespec='seconds').replace('+00:00', 'Z')
                except (ValueError, OverflowError, OSError):
                    pass
            seen.add(duration)
            windows.append({'id': 'codex-5h' if duration == 300 else 'codex-weekly',
                            'title': '5 小时窗口' if duration == 300 else '周额度',
                            'usedPercent': float(percent), 'resetsAt': reset_iso})
        if not windows:
            continue
        windows.sort(key=lambda item: item['id'] != 'codex-5h')
        plan = quota.get('plan_type')
        if not isinstance(plan, str) or not 1 <= len(plan) <= 40 or not plan.isascii():
            plan = None
        if winner is None or stamp > winner[0]:
            winner = (stamp, {'plan': plan,
                              'updatedAt': stamp.astimezone(timezone.utc).isoformat(
                                  timespec='milliseconds').replace('+00:00', 'Z'),
                              'windows': windows, 'error': None,
                              'source': 'native-rollout-rate-limits'})
    return winner[1] if winner else unavailable_usage()


def quota_from_rollout(codex_home: str | Path, rollout_path: str | Path,
                       thread_id: str, *, now: datetime | None = None) -> dict:
    """Read at most 2 MiB of one exact, private, verified native rollout tail."""
    home, path = Path(codex_home), Path(rollout_path)
    if (not home.is_absolute() or '..' in home.parts or
            not path.is_absolute() or '..' in path.parts or path.suffix != '.jsonl'):
        raise ValueError('explicit canonical native rollout required')
    try:
        if home != home.resolve(strict=True):
            raise ValueError
        home_info = home.lstat()
        if (not stat.S_ISDIR(home_info.st_mode) or home_info.st_uid != os.getuid() or
                home_info.st_mode & 0o077):
            raise ValueError
        relative = path.relative_to(home)
        if len(relative.parts) < 2 or relative.parts[0] not in ('sessions', 'archived_sessions'):
            raise ValueError
        if path != path.resolve(strict=True):
            raise ValueError
        info = path.stat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            with os.fdopen(fd, 'rb') as stream:
                first = stream.readline(1024 * 1024 + 1)
                if len(first) > 1024 * 1024 or not first.endswith(b'\n'):
                    raise ValueError
                header = json.loads(first)
                if (header.get('type') != 'session_meta' or
                        header.get('payload', {}).get('id') != thread_id):
                    raise ValueError
                start = max(stream.tell(), info.st_size - 2 * 1024 * 1024)
                stream.seek(start)
                if start > len(first):
                    stream.readline()  # discard a partial JSONL record
                tail = stream.read(2 * 1024 * 1024)
                lines = tail.splitlines()
                if tail and not tail.endswith(b'\n'):
                    lines.pop()  # an append-in-progress is not an authoritative record
        except BaseException:
            # fdopen takes ownership of fd. On error its context closes it.
            raise
        records = []
        for line in lines:
            if len(line) > 1024 * 1024:
                continue
            try:
                record = json.loads(line)
            except (UnicodeError, ValueError):
                continue
            if (isinstance(record, dict) and record.get('type') == 'event_msg' and
                    isinstance(record.get('payload'), dict) and
                    record['payload'].get('type') == 'token_count'):
                records.append(record)
        return quota_from_records(records, now=now)
    except (OSError, ValueError, TypeError, KeyError) as error:
        raise NativeFeatureUnavailable('原生额度记录路径无法安全验证') from error


def quota_from_registry(registry, *, now: datetime | None = None) -> dict:
    """Pick the freshest real `codex` quota from at most 16 Cove-bound threads.

    This does not browse unrelated CODEX_HOME conversations or call an API.
    A bounded, exact registered rollout is the sole source of each sample.
    """
    candidates = []
    with registry.lock:
        rows = registry.db.execute('''SELECT * FROM bindings WHERE thread_id IS NOT NULL
            AND rollout_path IS NOT NULL''').fetchall()
        for row in rows:
            try:
                path = registry._check_rollout(row)
                candidates.append((Path(path).stat().st_mtime, path, row['thread_id']))
            except (OSError, ValueError, RuntimeError):
                continue
    best = None
    for _, path, thread in sorted(candidates, reverse=True)[:16]:
        try:
            result = quota_from_rollout(registry.codex_home, path, thread, now=now)
        except NativeFeatureUnavailable:
            continue
        if result['windows'] and (best is None or result['updatedAt'] > best['updatedAt']):
            best = result
    return best or unavailable_usage()


def capabilities() -> dict:
    """Product-facing facts, not a claim that this account can use a model."""
    return {
        "images": {"currentPane": False, "initialCLIFlag": True,
                   "reason": "-i only attaches to an initial CLI/resume prompt; per-turn TUI attachment is unverified"},
        "modelSwitch": {"currentPane": False, "explicitResume": True,
                        "reason": "-m and model_reasoning_effort are launch/resume settings, not a verified live pane command"},
        "modelCatalog": {"bundledOffline": True, "recentNativeAccountCache": True,
                         "cacheIdentityVerified": False, "accountAvailabilityVerified": False},
        "usage": {"rolloutTokenCounts": True, "rolloutRateLimitSamples": True,
                  "liveQuotaVerified": False},
        "realtime": {"hostTUIVoiceFeatureFlag": "experimental", "hostVoiceAvailableToAccount": None,
                     "coveAudioTransport": False,
                     "reason": "TUI /realtime uses host audio; no verified iOS audio stream over the CLI pane"},
    }


def require_current_pane_image() -> None:
    raise NativeFeatureUnavailable("当前 CLI pane 尚无经验证的逐回合图片附着；图片路径不是视觉输入")


def require_cove_realtime() -> None:
    raise NativeFeatureUnavailable("原生 CLI 的主机端 /realtime 不提供已验证的 Cove iOS 音频传输")


def bundled_catalog(binary: str | Path, codex_home: str | Path, *, runner=subprocess.run) -> list[dict]:
    """Read only the pinned binary's bundled catalog; never refresh or call a model.

    The debug JSON includes long internal prompts. Project only the fields
    needed for UI rather than logging or storing that unfiltered response.
    """
    executable, home = Path(binary), Path(codex_home)
    if not executable.is_absolute() or not executable.is_file() or not home.is_absolute() or not home.is_dir():
        raise ValueError("explicit native binary and CODEX_HOME are required")
    env = {k: os.environ[k] for k in ("PATH", "HOME", "LANG", "LC_ALL") if k in os.environ}
    env["CODEX_HOME"] = str(home.resolve(strict=True))
    result = runner([str(executable), "debug", "models", "--bundled"], shell=False,
                    capture_output=True, text=True, timeout=15, check=False, env=env)
    if result.returncode or len(result.stdout.encode("utf-8")) > 16 * 1024 * 1024:
        raise NativeFeatureUnavailable("原生离线模型目录不可用")
    try:
        raw = json.loads(result.stdout)
        models = raw["models"]
        if not isinstance(models, list):
            raise ValueError
        projected = []
        for model in models:
            if not isinstance(model, dict) or not isinstance(model.get("slug"), str):
                continue
            slug = model["slug"]
            if not _MODEL_ID.fullmatch(slug):
                continue
            levels = model.get("supported_reasoning_levels") or []
            efforts = [value["effort"] for value in levels if isinstance(value, dict)
                       and value.get("effort") in _EFFORTS]
            projected.append({"id": slug, "displayName": model.get("display_name") or slug,
                              "supportedEfforts": efforts, "defaultEffort": model.get("default_reasoning_level"),
                              "visibility": model.get("visibility"), "source": "bundled-offline",
                              "availableToAccount": None})
        return projected
    except (ValueError, TypeError, KeyError) as error:
        raise NativeFeatureUnavailable("原生离线模型目录格式无法验证") from error


def explicit_resume_argv(binary: str | Path, thread_id: str, workspace: str | Path,
                         model_id: str, effort: str, catalog: Iterable[Mapping]) -> list[str]:
    """Plan a *new explicit resume*, never modify or replace a live pane.

    The caller must separately obtain owner consent, stop/reattach the exact
    prior pane, and verify the new native thread+rollout before dispatch.
    """
    path, cwd = Path(binary), Path(workspace)
    if not path.is_absolute() or not path.is_file() or not cwd.is_absolute() or not cwd.is_dir():
        raise ValueError("explicit native binary and workspace are required")
    try:
        if str(uuid.UUID(thread_id)) != thread_id:
            raise ValueError
    except (ValueError, AttributeError) as error:
        raise ValueError("exact canonical thread UUID required") from error
    if not isinstance(model_id, str) or not _MODEL_ID.fullmatch(model_id) or effort not in _EFFORTS:
        raise ValueError("invalid model or effort")
    matching = [model for model in catalog if model.get("id") == model_id]
    if len(matching) != 1 or effort not in matching[0].get("supportedEfforts", ()):
        raise NativeFeatureUnavailable("该离线目录未列出所选模型/推理强度；未尝试切换")
    return [str(path), "--no-alt-screen", "-C", str(cwd), "resume", thread_id,
            "-m", model_id, "-c", f'model_reasoning_effort="{effort}"']


def exact_turn_usage(records: Iterable[Mapping], thread_id: str, turn_id: str) -> dict:
    """Project native disk records for one known turn, never infer quota/health.

    `turn_token_usage` is cumulative within a turn; summing records would
    double-count a tool-using turn. `usage` is the last single response only.
    """
    if not isinstance(thread_id, str) or not thread_id or not isinstance(turn_id, str) or not turn_id:
        raise ValueError("exact thread and turn required")
    started = completed = False
    context_window = None
    counters = None
    for record in records:
        if not isinstance(record, Mapping) or not isinstance(record.get("payload"), Mapping):
            continue
        kind, value = record.get("type"), record["payload"]
        if kind == "event_msg" and value.get("turn_id") == turn_id:
            if value.get("type") == "task_started":
                started = True
                window = value.get("model_context_window")
                if type(window) is int and window > 0:
                    context_window = window
            elif value.get("type") == "task_complete":
                completed = True
        elif kind == "token_usage_record" and value.get("thread_id") == thread_id and value.get("turn_id") == turn_id:
            candidate = value.get("turn_token_usage")
            if isinstance(candidate, Mapping):
                names = ("input_tokens", "cached_input_tokens", "cache_write_input_tokens",
                         "output_tokens", "reasoning_output_tokens", "total_tokens")
                if all(type(candidate.get(name)) is int and candidate[name] >= 0 for name in names):
                    counters = {name: candidate[name] for name in names}
    return {"threadID": thread_id, "turnID": turn_id, "started": started,
            "complete": started and completed, "modelContextWindow": context_window,
            "tokenUsage": counters, "quota": None, "source": "native-rollout"}
