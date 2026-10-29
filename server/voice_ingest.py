"""Private offline voice analysis subprocess. Never inherit provider credentials."""
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time

from audio_inputs import validate_audio

TIMEOUT = 120
MAX_RESULT = 128 * 1024
BASELINE_LOCK = threading.Lock()
BASELINE_LIMIT = 60
BASELINE_MINIMUM = 5
PROFILE_RANGES = {
    'f0_mean': (50, 500), 'loudness_db': (-100, 0), 'syllable_rate': (0, 20),
    'h1_h2': (-40, 40), 'hnr_db': (-40, 40), 'spectral_tilt': (-100, 50),
    'jitter': (0, 2), 'shimmer': (0, 5), 'tail_slope': (-1000, 1000),
    'pitch_span_semitones': (0, 48), 'breath_like_count': (0, 50),
    'breath_like_seconds': (0, 121),
}


def failure(message):
    return {'ok': False, 'error': message, 'transcript': '', 'observations': [], 'warnings': []}


def _strings(value, count, length):
    if not isinstance(value, list) or len(value) > count or any(not isinstance(x, str) or len(x) > length for x in value):
        raise ValueError('invalid string list')
    return value


def _profile(value):
    if not isinstance(value, dict):
        return {}
    result = {}
    for key, (low, high) in PROFILE_RANGES.items():
        item = value.get(key)
        if isinstance(item, bool) or not isinstance(item, (int, float)) or not math.isfinite(item):
            continue
        item = float(item)
        if low <= item <= high:
            result[key] = item
    return result


def _baseline_path():
    return Path(os.environ.get('COVE_VOICE_BASELINE', '/var/lib/cove/voice-baseline.json'))


def _baseline_load():
    try:
        value = json.loads(_baseline_path().read_text(encoding='utf-8'))
        samples = value.get('samples', []) if isinstance(value, dict) else []
        return [_profile(item) for item in samples[-BASELINE_LIMIT:] if _profile(item)]
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        return []


def _median_baseline(samples):
    if len(samples) < BASELINE_MINIMUM:
        return None
    result = {}
    for key in ('f0_mean', 'loudness_db', 'syllable_rate', 'h1_h2', 'hnr_db',
                'spectral_tilt', 'jitter', 'shimmer'):
        values = sorted(item[key] for item in samples if key in item)
        if values:
            middle = len(values) // 2
            result[key] = values[middle] if len(values) % 2 else (values[middle - 1] + values[middle]) / 2
    return result


def _baseline_update(features, transcript, duration):
    """Persist numeric voice quality only; never audio or transcript text."""
    with BASELINE_LOCK:
        samples = _baseline_load()
        before = _median_baseline(samples)
        if transcript.strip() and duration >= 1.5 and features.get('f0_mean'):
            sample = {key: features[key] for key in (
                'f0_mean', 'loudness_db', 'syllable_rate', 'h1_h2', 'hnr_db',
                'spectral_tilt', 'jitter', 'shimmer') if key in features}
            samples = (samples + [sample])[-BASELINE_LIMIT:]
            temporary = None
            try:
                path = _baseline_path()
                path.parent.mkdir(parents=True, exist_ok=True)
                with tempfile.NamedTemporaryFile('w', encoding='utf-8', dir=path.parent,
                                                 prefix='.voice-baseline-', delete=False) as handle:
                    json.dump({'version': 1, 'samples': samples}, handle, ensure_ascii=False,
                              allow_nan=False, separators=(',', ':'))
                    temporary = Path(handle.name)
                os.chmod(temporary, 0o600)
                os.replace(temporary, path)
            except OSError:
                try:
                    if temporary is not None:
                        temporary.unlink(missing_ok=True)
                except Exception:
                    pass
        return before


def _profile_observations(features, baseline, transcript):
    notes = []
    breaths = int(features.get('breath_like_count', 0))
    breath_seconds = features.get('breath_like_seconds', 0)
    if breaths >= 2 and breath_seconds >= .24:
        notes.append(f'录音里测到 {breaths} 段短促、重复的非周期气流声，声学上接近呼吸或喘气；近麦气流、摩擦和环境噪声也可能造成这种结果。')
    elif breaths == 1 and breath_seconds >= .12:
        notes.append('录音里测到一段非周期气流声，可能是呼吸或喘气，也可能是近麦气流、摩擦或环境噪声。')
    if not transcript.strip():
        return notes

    if baseline:
        if features.get('syllable_rate') and baseline.get('syllable_rate'):
            ratio = features['syllable_rate'] / max(baseline['syllable_rate'], .1)
            if ratio > 1.25:
                notes.append('可测语速比她在 Cove 里近期的个人基线快。')
            elif ratio < .78:
                notes.append('可测语速比她在 Cove 里近期的个人基线慢。')
        if features.get('f0_mean') and baseline.get('f0_mean'):
            delta = features['f0_mean'] - baseline['f0_mean']
            if delta > 18:
                notes.append('有声部分的音调比她在 Cove 里近期的个人基线高。')
            elif delta < -18:
                notes.append('有声部分的音调比她在 Cove 里近期的个人基线低。')
        if features.get('loudness_db') is not None and baseline.get('loudness_db') is not None:
            delta = features['loudness_db'] - baseline['loudness_db']
            if delta > 4:
                notes.append('录音响度比她在 Cove 里近期的个人基线大。')
            elif delta < -5:
                notes.append('录音响度比她在 Cove 里近期的个人基线小。')
        if features.get('h1_h2') is not None and baseline.get('h1_h2') is not None:
            delta = features['h1_h2'] - baseline['h1_h2']
            if delta > 3.5:
                notes.append('有声部分比她在 Cove 里近期的个人基线更松、更带气声。')
            elif delta < -3.5:
                notes.append('有声部分比她在 Cove 里近期的个人基线更收紧。')
    else:
        h1h2, hnr = features.get('h1_h2'), features.get('hnr_db')
        if h1h2 is not None and h1h2 > 6:
            notes.append('有声部分声门闭合较松、带一些气声；这是绝对声学近似，尚无个人基线。')
        if hnr is not None and hnr < -6:
            notes.append('有声部分的非谐波成分较多，听感可能偏沙；这是声学近似。')

    slope = features.get('tail_slope')
    if slope is not None:
        if slope < -25:
            notes.append('可测句尾音高往下走。')
        elif slope > 25:
            notes.append('可测句尾音高往上走。')
    jitter, shimmer = features.get('jitter'), features.get('shimmer')
    if jitter is not None and jitter > .045:
        notes.append('有声部分的音高有较明显的短时抖动。')
    if shimmer is not None and shimmer > .42:
        notes.append('有声部分的响度有较明显的短时起伏，可能与气息、距离或录音条件有关。')
    return notes


def _result(raw):
    if len(raw) > MAX_RESULT:
        raise ValueError('oversized result')
    value = json.loads(raw)
    if not isinstance(value, dict) or value.get('ok') is not True:
        return failure('本地语音分析未成功，原语音仍保留；不能声称已听懂。')
    transcript, duration = value.get('transcript'), value.get('duration')
    if not isinstance(transcript, str) or len(transcript) > 20000:
        raise ValueError('invalid transcript')
    # Recorder limit is 120 s; AAC encoder padding may add a small final frame.
    if isinstance(duration, bool) or not isinstance(duration, (int, float)) or not math.isfinite(duration) or not 0 < duration <= 121:
        raise ValueError('invalid duration')
    observations = _strings(value.get('observations', []), 16, 500)
    warnings = _strings(value.get('warnings', []), 16, 500)
    features = _profile(value.get('features', {}))
    baseline = _baseline_update(features, transcript, float(duration))
    profile_notes = _profile_observations(features, baseline, transcript)
    if not transcript.strip():
        # Silence/no intelligible speech must not become an invented utterance.
        observations = profile_notes
        warnings = warnings + ['没有识别出可确认的话语；只能保留明确标注为近似的非语言声音线索，不能编造说话内容或确定情绪。']
    else:
        observations = (observations + profile_notes)[:16]
    return {'ok': True, 'transcript': transcript.strip(), 'duration': duration,
            'observations': observations, 'warnings': warnings}


def analyze(attachment, cancelled):
    error = validate_audio(attachment)
    if error:
        return failure(error)
    if cancelled.is_set():
        return failure('语音分析已取消。')
    executable = os.environ.get('COVE_VOICE_PYTHON', '/opt/cove/voice-venv/bin/python')
    model = os.environ.get('COVE_VOICE_MODEL', '/opt/cove/voice-model')
    helper = str(Path(__file__).with_name('voice_analyze_worker.py'))
    process = None
    try:
        with tempfile.TemporaryDirectory(prefix='cove-voice-analysis-') as home, tempfile.TemporaryFile() as output_file:
            env = {'PATH': '/usr/local/bin:/usr/bin:/bin', 'HOME': home, 'TMPDIR': home,
                   'LANG': 'C.UTF-8', 'OMP_NUM_THREADS': '1', 'OPENBLAS_NUM_THREADS': '1',
                   'MKL_NUM_THREADS': '1', 'VECLIB_MAXIMUM_THREADS': '1', 'NUMEXPR_NUM_THREADS': '1',
                   'HF_HUB_OFFLINE': '1', 'TRANSFORMERS_OFFLINE': '1', 'PYTHONNOUSERSITE': '1',
                   'PYTHONDONTWRITEBYTECODE': '1'}
            process = subprocess.Popen([executable, helper, '--model', model], stdin=subprocess.PIPE,
                                       stdout=output_file, stderr=subprocess.DEVNULL, env=env)
            deadline, data = time.monotonic() + TIMEOUT, attachment['data']
            while True:
                if cancelled.is_set():
                    process.kill(); process.communicate()
                    return failure('语音分析已取消。')
                if time.monotonic() >= deadline:
                    process.kill(); process.communicate()
                    return failure('语音分析超时，原语音仍保留，这次没有完成识别。')
                if os.fstat(output_file.fileno()).st_size > MAX_RESULT:
                    process.kill(); process.communicate()
                    return failure('本地语音分析结果超出限制，未采纳这次识别。')
                try:
                    process.communicate(input=data, timeout=min(.2, max(.01, deadline - time.monotonic())))
                    break
                except subprocess.TimeoutExpired:
                    data = None
            if process.returncode:
                return failure('本地语音识别暂时不可用，原语音仍保留，这次未识别成功。')
            output_file.seek(0)
            return _result(output_file.read(MAX_RESULT + 1))
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        return failure('本地语音识别暂时不可用或返回无效结果，原语音仍保留；不能声称已听懂。')
    finally:
        if process and process.poll() is None:
            process.kill(); process.communicate()
