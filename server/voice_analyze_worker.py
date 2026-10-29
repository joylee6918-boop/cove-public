"""One bounded, offline voice-note job; JSON only on stdout, no credentials.

Run with the separate voice venv. PyAV supplies its own FFmpeg libraries.
Acoustic measurements are approximate descriptions, NOT emotion classification.
"""
import argparse
import io
import json
import os
import sys

MAX_BYTES = 20 * 1024 * 1024
RATE = 16000
MAX_SECONDS = 121  # recorder limit 120s, allow AAC padding


def decode(data):
    import av
    import numpy as np

    if not data or len(data) > MAX_BYTES:
        raise ValueError('音频为空或超过 20 MiB')
    # Force self-contained media demuxers, never playlists or external URLs.
    if data[4:8] == b'ftyp':
        fmt = 'mov'
    elif data[:4] == b'RIFF' and data[8:12] == b'WAVE':
        fmt = 'wav'
    elif data[:4] == b'OggS':
        fmt = 'ogg'
    elif data[:4] == b'\x1a\x45\xdf\xa3':
        fmt = 'matroska'
    elif data[:3] == b'ID3' or (len(data) > 1 and data[0] == 255 and data[1] & 224 == 224):
        fmt = 'mp3'
    else:
        raise ValueError('不支持的音频容器')
    chunks, count = [], 0
    with av.open(io.BytesIO(data), format=fmt, options={
        'protocol_whitelist': 'pipe', 'enable_drefs': '0', 'use_absolute_path': '0',
        'max_alloc': '33554432', 'probesize': '1048576', 'analyzeduration': '5000000',
    }) as container:
        streams = list(container.streams.audio)
        if not streams:
            raise ValueError('没有音轨')
        stream = streams[0]
        stream.codec_context.thread_count = 1
        if stream.duration and stream.time_base and float(stream.duration * stream.time_base) > MAX_SECONDS:
            raise ValueError('音频超过 120 秒录音限制')
        resampler = av.AudioResampler(format='fltp', layout='mono', rate=RATE)
        for frame in container.decode(stream):
            # Bound before resampling as well as after it.
            if frame.samples > RATE * MAX_SECONDS or len(frame.layout.channels) > 8:
                raise ValueError('音频帧超出限制')
            for out in resampler.resample(frame):
                count += out.samples
                if count > RATE * MAX_SECONDS:
                    raise ValueError('音频超过 120 秒录音限制')
                chunks.append(out.to_ndarray().reshape(-1).copy())
        for out in resampler.resample(None):
            count += out.samples
            if count > RATE * MAX_SECONDS:
                raise ValueError('音频超过 120 秒录音限制')
            chunks.append(out.to_ndarray().reshape(-1).copy())
    if not count:
        raise ValueError('没有可解码声音')
    result = np.concatenate(chunks).astype(np.float32, copy=False)
    if not np.isfinite(result).all():
        raise ValueError('音频采样无效')
    return result


def acoustics(samples):
    import numpy as np

    duration = len(samples) / RATE
    features = {'duration_seconds': round(duration, 2)}
    observations = []
    width, hop = 400, 160
    if len(samples) < width:
        return features, observations, False
    # Small overlapping view; FFT is per frame to keep peak RAM bounded.
    frames = np.lib.stride_tricks.sliding_window_view(samples, width)[::hop]
    rms = np.sqrt(np.mean(frames * frames, axis=1))
    peak = float(np.max(rms))
    threshold = max(0.003, peak * 0.10)
    active = rms > threshold
    active_indices = np.flatnonzero(active)
    features['active_seconds'] = round(float(active.sum()) * hop / RATE, 2)
    if peak < 0.004 or len(active_indices) * hop / RATE < 0.18:
        return features, observations, False
    inner = active[active_indices[0]:active_indices[-1] + 1]
    edges = np.diff(np.r_[True, inner, True].astype(np.int8))
    starts, ends = np.flatnonzero(edges == -1), np.flatnonzero(edges == 1)
    pauses = [(b - a) * hop / RATE for a, b in zip(starts, ends) if (b - a) * hop / RATE >= 0.35]
    features['internal_pause_count'] = len(pauses)
    if pauses:
        longest = round(max(pauses), 1)
        features['longest_internal_pause_seconds'] = longest
        observations.append(f'按录音能量估算，中间有 {len(pauses)} 处约 0.35 秒以上的停顿，最长约 {longest} 秒（低声可能被误计）。')
    # Frame-level periodicity and spectrum serve two separate purposes:
    # voiced frames describe pitch/voice quality; aperiodic broadband bursts are
    # conservative breath-like candidates. Neither is an emotion classifier.
    pitches = []
    periodicity = np.zeros(len(frames), dtype=np.float32)
    flatness = np.zeros(len(frames), dtype=np.float32)
    centroid = np.zeros(len(frames), dtype=np.float32)
    crossing = np.zeros(len(frames), dtype=np.float32)
    spectra = {}
    window = np.hanning(width)
    frequencies = np.fft.rfftfreq(1024, 1 / RATE)
    for index in active_indices:
        frame = frames[index].astype(np.float64)
        frame = (frame - frame.mean()) * window
        spectrum = np.fft.rfft(frame, n=1024)
        power = np.maximum(np.abs(spectrum) ** 2, 1e-15)
        flatness[index] = float(np.exp(np.mean(np.log(power[2:]))) / np.mean(power[2:]))
        centroid[index] = float(np.sum(frequencies * power) / np.sum(power))
        raw = frames[index]
        crossing[index] = float(np.mean(np.signbit(raw[1:]) != np.signbit(raw[:-1])))
        corr = np.fft.irfft(power, n=1024)[:width]
        if corr[0] <= 1e-12:
            continue
        lag = 40 + int(np.argmax(corr[40:201]))
        strength = float(corr[lag] / corr[0])
        periodicity[index] = strength
        if strength >= 0.60:
            spectra[int(index)] = power
            pitches.append((int(index), float(index) * hop / RATE, RATE / lag))

    # Breath-like audio is a bounded acoustic hint, not a claim about intent.
    # Requiring sustained broadband, aperiodic air noise avoids treating most
    # voiced speech as breath. Short holes are closed before counting bursts.
    breath_frames = (active & (periodicity < 0.42) & (flatness > 0.12)
                     & (centroid > 650) & (crossing > 0.035))
    if len(breath_frames) >= 3:
        breath_frames = np.convolve(breath_frames.astype(np.int8), np.ones(3, dtype=np.int8), mode='same') >= 2
    breath_edges = np.diff(np.r_[False, breath_frames, False].astype(np.int8))
    breath_starts, breath_ends = np.flatnonzero(breath_edges == 1), np.flatnonzero(breath_edges == -1)
    breath_runs = [(b - a) * hop / RATE for a, b in zip(breath_starts, breath_ends)
                   if 0.12 <= (b - a) * hop / RATE <= 2.5]
    features['breath_like_count'] = min(len(breath_runs), 50)
    features['breath_like_seconds'] = round(min(sum(breath_runs), duration), 2)

    features['pitch_samples'] = len(pitches)
    if len(pitches) >= 12:
        hz = np.asarray([p[2] for p in pitches])
        features['f0_mean'] = round(float(np.median(hz)), 1)
        span = float(12 * np.log2(np.percentile(hz, 90) / np.percentile(hz, 10)))
        features['pitch_span_semitones'] = round(span, 1)
        if span >= 5:
            observations.append('可测到的有声片段音高有一些起伏；这是声学近似，不表示某种确定情绪。')

        # Tail direction uses actual timestamps rather than compressing pauses.
        tail = pitches[max(0, int(len(pitches) * .75)):]
        if len(tail) >= 5 and tail[-1][1] - tail[0][1] >= .08:
            features['tail_slope'] = round(float(np.polyfit(
                np.asarray([p[1] for p in tail]), np.asarray([p[2] for p in tail]), 1)[0]), 1)

        # Jitter/shimmer are frame-to-frame approximations on contiguous voiced
        # frames. They are useful only as relative personal-baseline signals.
        pairs = [(a, b) for a, b in zip(pitches, pitches[1:]) if b[1] - a[1] <= .05]
        if pairs:
            features['jitter'] = round(float(np.median([
                abs(b[2] - a[2]) / max(a[2], 1) for a, b in pairs])), 4)
            features['shimmer'] = round(float(np.median([
                abs(rms[b[0]] - rms[a[0]]) / max(rms[a[0]], 1e-6) for a, b in pairs])), 4)

        # Voice quality, adapted from another assistant's lightweight voice_feel approach.
        # Values stay numeric here; the trusted parent compares them to Cove's
        # independent baseline and turns them into cautious natural language.
        f0 = float(np.median(hz))
        h1h2_values, hnr_values = [], []
        mean_power = np.zeros(len(frequencies), dtype=np.float64)
        used = 0
        harmonic_mask = np.zeros(len(frequencies), dtype=bool)
        harmonic = f0
        while harmonic < RATE / 2 and harmonic <= f0 * 20:
            harmonic_mask |= (frequencies >= harmonic - 40) & (frequencies <= harmonic + 40)
            harmonic += f0
        h1 = (frequencies >= f0 * .75) & (frequencies <= f0 * 1.25)
        h2 = (frequencies >= f0 * 1.75) & (frequencies <= f0 * 2.25)
        for index, _, _ in pitches:
            power = spectra.get(index)
            if power is None:
                continue
            mean_power += power
            used += 1
            if h1.any() and h2.any():
                h1h2_values.append(10 * np.log10(max(float(power[h1].max()), 1e-15)
                                                   / max(float(power[h2].max()), 1e-15)))
            harmonic_energy = float(power[harmonic_mask].sum())
            noise_energy = float(power[~harmonic_mask].sum())
            hnr_values.append(10 * np.log10(max(harmonic_energy, 1e-15) / max(noise_energy, 1e-15)))
        if h1h2_values:
            features['h1_h2'] = round(float(np.median(h1h2_values)), 1)
        if hnr_values:
            features['hnr_db'] = round(float(np.median(hnr_values)), 1)
        tilt_band = (frequencies >= 100) & (frequencies <= 6000)
        if used and tilt_band.sum() >= 3:
            db_spectrum = 10 * np.log10(np.maximum(mean_power[tilt_band] / used, 1e-15))
            features['spectral_tilt'] = round(float(np.polyfit(
                np.log10(frequencies[tilt_band]), db_spectrum, 1)[0]), 1)

    # Envelope peaks per active second are a deliberately rough syllable-rate
    # proxy. It is only compared against this same user's own future baseline.
    if active.any():
        envelope = np.convolve(rms, np.ones(5) / 5, mode='same')
        peaks = ((envelope[1:-1] > envelope[:-2]) & (envelope[1:-1] > envelope[2:])
                 & active[1:-1])
        active_seconds = float(active.sum()) * hop / RATE
        features['syllable_rate'] = round(float(peaks.sum()) / max(active_seconds, .1), 2)
        features['loudness_db'] = round(float(20 * np.log10(max(float(np.mean(rms[active])), 1e-9))), 1)
    return features, observations, True


def analyze(data, model_path):
    samples = decode(data)
    features, observations, audible = acoustics(samples)
    result = {'ok': True, 'transcript': '', 'duration': features['duration_seconds'],
              'observations': observations, 'features': features, 'warnings': []}
    if not audible:
        result['warnings'].append('录音太短、近乎静音或有效声音不足，没有可靠转写；不能据此猜测说话内容。')
        return result
    from faster_whisper import WhisperModel
    model = WhisperModel(model_path, device='cpu', compute_type='int8',
                         cpu_threads=1, num_workers=1, local_files_only=True)
    segments, info = model.transcribe(samples, beam_size=1, vad_filter=True,
                                     condition_on_previous_text=False)
    parts = []
    uncertain = False
    for segment in segments:
        if segment.no_speech_prob > 0.65 or segment.avg_logprob < -1.0:
            uncertain = True
            continue
        parts.append(segment.text.strip())
        if sum(map(len, parts)) > 8000:
            uncertain = True
            break
    result['transcript'] = ' '.join(parts)[:8000].strip()
    result['features']['language'] = info.language
    if uncertain:
        result['warnings'].append('部分片段识别不可靠，已省略；转写可能不完整。')
    if not result['transcript']:
        result['warnings'].append('未得到可靠文字；声音可能是环境声、音乐或识别失败，不编造内容。')
    result['warnings'].append('自动转写和声学线索可能出错；未识别笑哭、反话、身份或确定情绪。个人基线比较只由受信任的 Cove 父进程完成。')
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', required=True)
    args = parser.parse_args()
    try:
        os.nice(5)
        data = sys.stdin.buffer.read(MAX_BYTES + 1)
        result = analyze(data, args.model)
    except Exception as exc:
        # Do not emit file contents, credentials, paths or decoder diagnostics.
        result = {'ok': False, 'transcript': '', 'duration': 0, 'observations': [],
                  'features': {}, 'warnings': [], 'error': f'语音处理未完成（{type(exc).__name__}）；不能猜测内容。'}
    print(json.dumps(result, ensure_ascii=False, allow_nan=False))


if __name__ == '__main__':
    main()
