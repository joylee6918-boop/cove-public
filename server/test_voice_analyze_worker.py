"""Synthetic, offline fixtures only; never owner recordings."""
import io
import unittest
import wave
import numpy as np
from voice_analyze_worker import RATE, acoustics, decode, analyze


def wav(samples):
    data = io.BytesIO()
    with wave.open(data, 'wb') as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes((np.asarray(samples) * 32767).astype('<i2').tobytes())
    return data.getvalue()


class WorkerTests(unittest.TestCase):
    def test_wav_round_trip(self):
        x = np.sin(np.arange(RATE) * 2 * np.pi * 200 / RATE) * .2
        decoded = decode(wav(x))
        self.assertEqual(len(decoded), RATE)
        self.assertLess(np.max(np.abs(x - decoded)), .0001)

    def test_silence_does_not_load_model(self):
        r = analyze(wav(np.zeros(RATE)), '/no-model-should-be-opened')
        self.assertTrue(r['ok'])
        self.assertEqual(r['transcript'], '')
        self.assertTrue(r['warnings'])

    def test_very_short_does_not_crash(self):
        f, o, audible = acoustics(np.ones(100, dtype=np.float32))
        self.assertFalse(audible)
        self.assertEqual(o, [])

    def test_internal_pause_excludes_edges(self):
        tone = np.sin(np.arange(RATE) * 2 * np.pi * 200 / RATE) * .2
        x = np.concatenate([np.zeros(RATE), tone, np.zeros(RATE), tone, np.zeros(RATE)])
        f, o, audible = acoustics(x)
        self.assertTrue(audible)
        self.assertEqual(f['internal_pause_count'], 1)
        self.assertAlmostEqual(f['longest_internal_pause_seconds'], 1, places=1)
        self.assertFalse(any('比平时' in item or '开心' in item for item in o))

    def test_repeated_broadband_bursts_are_only_breath_like_features(self):
        rng = np.random.default_rng(7)
        def burst(seconds=.32):
            count = int(RATE * seconds)
            envelope = np.sin(np.linspace(0, np.pi, count)) ** 1.5
            return rng.normal(0, .08, count) * envelope
        x = np.concatenate([np.zeros(RATE // 4), burst(), np.zeros(RATE // 5),
                            burst(.28), np.zeros(RATE // 5), burst(.36), np.zeros(RATE // 4)])
        f, o, audible = acoustics(x.astype(np.float32))
        self.assertTrue(audible)
        self.assertGreaterEqual(f['breath_like_count'], 2)
        self.assertGreaterEqual(f['breath_like_seconds'], .24)
        self.assertFalse(any('情绪' in item or '兴奋' in item for item in o))

    def test_periodic_tone_is_not_breath(self):
        x = np.sin(np.arange(RATE * 2) * 2 * np.pi * 200 / RATE) * .2
        f, _, audible = acoustics(x.astype(np.float32))
        self.assertTrue(audible)
        self.assertEqual(f['breath_like_count'], 0)
        self.assertIn('f0_mean', f)

    def test_malformed_rejected(self):
        for data in (b'', b'not audio', b'RIFFxxxxWAVEbroken', b'#EXTM3U\nhttps://example.com/audio'):
            with self.subTest(data=data), self.assertRaises(Exception):
                decode(data)

    def test_oversize_rejected(self):
        with self.assertRaises(ValueError):
            decode(b'x' * (20 * 1024 * 1024 + 1))

    def test_overlong_rejected(self):
        with self.assertRaises(ValueError):
            decode(wav(np.zeros(RATE * 122)))


if __name__ == '__main__':
    unittest.main()
