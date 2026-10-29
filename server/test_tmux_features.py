"""Offline native CLI capability projections; no auth, network or model run."""
import json
import os
import tempfile
import threading
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

from tmux_features import (NativeFeatureUnavailable, bundled_catalog, cached_catalog,
                           native_client_version,
                           unavailable_usage, quota_from_records, quota_from_rollout,
                           quota_from_registry,
                           validate_cached_model, capabilities,
                           exact_turn_usage, explicit_resume_argv,
                           require_cove_realtime, require_current_pane_image)


class NativeFeatureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.binary = self.root / "codex"
        self.binary.write_bytes(b"synthetic binary")
        self.home = self.root / "home"
        self.home.mkdir()
        self.workspace = self.root / "work"
        self.workspace.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def test_catalog_uses_only_bundled_offline_command_and_projects_no_prompts(self):
        calls = []
        def runner(argv, **kwargs):
            calls.append((argv, kwargs))
            payload = {"models": [{"slug": "fake-model", "display_name": "Fake",
                                   "supported_reasoning_levels": [{"effort": "low"}, {"effort": "high"}],
                                   "default_reasoning_level": "low", "visibility": "list",
                                   "model_messages": {"persistent_instructions": "private internal prompt"}}]}
            return SimpleNamespace(returncode=0, stdout=json.dumps(payload))
        models = bundled_catalog(self.binary, self.home, runner=runner)
        self.assertEqual(calls[0][0], [str(self.binary), "debug", "models", "--bundled"])
        self.assertEqual(calls[0][1]["env"]["CODEX_HOME"], str(self.home))
        self.assertEqual(models, [{"id": "fake-model", "displayName": "Fake",
                                   "supportedEfforts": ["low", "high"], "defaultEffort": "low",
                                   "visibility": "list", "source": "bundled-offline",
                                   "availableToAccount": None}])
        self.assertNotIn("private internal prompt", repr(models))

    def test_native_version_is_pinned_offline_and_strict(self):
        calls = []
        def runner(argv, **kwargs):
            calls.append((argv, kwargs))
            return SimpleNamespace(returncode=0, stdout='codex-cli 0.155.0\n')
        self.assertEqual(native_client_version(self.binary, runner=runner), '0.155.0')
        self.assertEqual(calls[0][0], [str(self.binary), '--version'])
        self.assertFalse(calls[0][1]['shell'])
        with self.assertRaises(NativeFeatureUnavailable):
            native_client_version(self.binary, runner=lambda *_args, **_kwargs:
                                  SimpleNamespace(returncode=0, stdout='unknown 0.155.0'))

    def test_resume_plan_is_explicit_and_cannot_guess_latest_or_unsupported_effort(self):
        thread = "d2a93789-20a3-4cde-9259-d06c376f82e1"
        catalog = [{"id": "fake-model", "supportedEfforts": ["low"]}]
        argv = explicit_resume_argv(self.binary, thread, self.workspace, "fake-model", "low", catalog)
        self.assertEqual(argv[-5:], [thread, "-m", "fake-model", "-c", 'model_reasoning_effort="low"'])
        with self.assertRaises(ValueError):
            explicit_resume_argv(self.binary, "latest", self.workspace, "fake-model", "low", catalog)
        with self.assertRaises(NativeFeatureUnavailable):
            explicit_resume_argv(self.binary, thread, self.workspace, "fake-model", "high", catalog)

    def test_usage_uses_last_cumulative_turn_total_without_cross_thread_or_quota(self):
        records = [
            {"type": "event_msg", "payload": {"type": "task_started", "turn_id": "turn-a", "model_context_window": 1000}},
            {"type": "token_usage_record", "payload": {"thread_id": "other", "turn_id": "turn-a", "turn_token_usage": self.usage(99)}},
            {"type": "token_usage_record", "payload": {"thread_id": "thread-a", "turn_id": "turn-a", "turn_token_usage": self.usage(2)}},
            {"type": "token_usage_record", "payload": {"thread_id": "thread-a", "turn_id": "turn-a", "turn_token_usage": self.usage(5)}},
            {"type": "event_msg", "payload": {"type": "task_complete", "turn_id": "turn-a"}},
        ]
        value = exact_turn_usage(records, "thread-a", "turn-a")
        self.assertTrue(value["complete"])
        self.assertEqual(value["tokenUsage"]["total_tokens"], 10)
        self.assertEqual(value["modelContextWindow"], 1000)
        self.assertIsNone(value["quota"])

    @staticmethod
    def usage(n):
        return {"input_tokens": n, "cached_input_tokens": 0, "cache_write_input_tokens": 0,
                "output_tokens": n, "reasoning_output_tokens": 0, "total_tokens": n * 2}

    def test_image_and_cove_realtime_fail_closed_but_report_native_host_capability(self):
        status = capabilities()
        self.assertFalse(status["images"]["currentPane"])
        self.assertTrue(status["images"]["initialCLIFlag"])
        self.assertFalse(status["realtime"]["coveAudioTransport"])
        self.assertEqual(status["realtime"]["hostTUIVoiceFeatureFlag"], "experimental")
        self.assertIsNone(status["realtime"]["hostVoiceAvailableToAccount"])
        with self.assertRaises(NativeFeatureUnavailable):
            require_current_pane_image()
        with self.assertRaises(NativeFeatureUnavailable):
            require_cove_realtime()

    def test_recent_private_native_account_cache_projects_only_visible_models(self):
        self.home.chmod(0o700)
        stamp = datetime(2026, 9, 23, 14, 0, tzinfo=timezone.utc)
        path = self.home / 'models_cache.json'
        path.write_text(json.dumps({
            'fetched_at': stamp.isoformat().replace('+00:00', 'Z'),
            'identity': 'opaque-account-identity', 'client_version': '0.155.0',
            'models': [
                {'slug': 'gpt-6-sol', 'display_name': 'GPT-6 Sol', 'visibility': 'list',
                 'default_reasoning_level': 'medium',
                 'supported_reasoning_levels': [{'effort': 'low'}, {'effort': 'medium'}],
                 'model_messages': {'persistent_instructions': 'private prompt'}},
                {'slug': 'hidden', 'visibility': 'hide', 'default_reasoning_level': 'low',
                 'supported_reasoning_levels': [{'effort': 'low'}]},
            ]}))
        path.chmod(0o600)
        result = cached_catalog(self.home, now=stamp + timedelta(minutes=1),
                                expected_client_version='0.155.0')
        self.assertEqual(result['source'], 'native-account-cache')
        self.assertFalse(result['accountAvailabilityVerified'])
        self.assertFalse(result['cacheIdentityVerified'])
        self.assertEqual(result['cacheClientVersion'], '0.155.0')
        self.assertEqual(result['cacheAgeSeconds'], 60)
        self.assertEqual(result['models'], [{
            'id': 'gpt-6-sol', 'model': 'gpt-6-sol', 'displayName': 'GPT-6 Sol',
            'supportedEfforts': ['low', 'medium'], 'defaultEffort': 'medium'}])
        self.assertNotIn('private prompt', repr(result))
        self.assertEqual(validate_cached_model(self.home, 'gpt-6-sol', now=stamp + timedelta(minutes=1),
                                               expected_client_version='0.155.0'),
                         ('gpt-6-sol', 'medium'))
        self.assertEqual(validate_cached_model(self.home, 'gpt-6-sol', 'low',
                                               now=stamp + timedelta(minutes=1),
                                               expected_client_version='0.155.0'),
                         ('gpt-6-sol', 'low'))
        with self.assertRaises(NativeFeatureUnavailable):
            validate_cached_model(self.home, 'hidden', now=stamp + timedelta(minutes=1),
                                  expected_client_version='0.155.0')
        with self.assertRaises(NativeFeatureUnavailable):
            validate_cached_model(self.home, 'gpt-6-sol', 'ultra',
                                  now=stamp + timedelta(minutes=1),
                                  expected_client_version='0.155.0')
        with self.assertRaises(NativeFeatureUnavailable):
            cached_catalog(self.home, now=stamp + timedelta(minutes=1),
                           expected_client_version='0.155.1')
        with self.assertRaises(NativeFeatureUnavailable):
            cached_catalog(self.home, now=stamp + timedelta(minutes=6),
                           expected_client_version='0.155.0')
        with self.assertRaises(NativeFeatureUnavailable):
            cached_catalog(self.home, now=stamp + timedelta(minutes=1))
        with self.assertRaises(NativeFeatureUnavailable):
            cached_catalog(self.home, now=stamp + timedelta(days=2))
        path.chmod(0o644)
        with self.assertRaises(NativeFeatureUnavailable):
            cached_catalog(self.home, now=stamp + timedelta(minutes=1),
                           expected_client_version='0.155.0')

    def test_quota_is_explicitly_unavailable_not_token_percent(self):
        result = unavailable_usage(updated_at='2026-09-23T14:00:00Z')
        self.assertEqual(result['plan'], None)
        self.assertEqual(result['windows'], [])
        self.assertIn('未用 token', result['error'])

    def test_exact_native_rate_limit_only_not_tokens_or_other_bucket(self):
        stamp = datetime(2026, 9, 23, 14, 0, tzinfo=timezone.utc)
        records = [
            {'type': 'event_msg', 'timestamp': '2026-09-23T13:50:00Z',
             'payload': {'type': 'token_count', 'info': {'total_token_usage': {'total_tokens': 9999999}},
                         'rate_limits': {'limit_id': 'spark', 'primary': {
                             'used_percent': 99, 'window_minutes': 10080, 'resets_at': 1790608272}}}},
            {'type': 'event_msg', 'timestamp': '2026-09-23T13:55:00Z',
             'payload': {'type': 'token_count', 'rate_limits': {'limit_id': 'codex',
                 'primary': {'used_percent': 95.0, 'window_minutes': 10080,
                             'resets_at': 1790608272},
                 'secondary': {'used_percent': 12.0, 'window_minutes': 300,
                               'resets_at': 1790160000}, 'plan_type': None}}},
        ]
        result = quota_from_records(records, now=stamp)
        self.assertEqual(result['source'], 'native-rollout-rate-limits')
        self.assertEqual([(window['id'], window['usedPercent']) for window in result['windows']],
                         [('codex-5h', 12.0), ('codex-weekly', 95.0)])
        self.assertIsNone(result['plan'])
        self.assertNotIn('9999999', repr(result))
        self.assertEqual(quota_from_records(records, now=stamp + timedelta(days=1))['windows'], [])

    def test_quota_reader_requires_exact_private_session_meta_and_path(self):
        self.home.chmod(0o700)
        sessions = self.home / 'sessions'
        sessions.mkdir(mode=0o700)
        path = sessions / 'rollout-2026-thread-a.jsonl'
        stamp = datetime(2026, 9, 23, 14, 0, tzinfo=timezone.utc)
        lines = [
            {'type': 'session_meta', 'payload': {'id': 'thread-a'}},
            {'type': 'event_msg', 'timestamp': '2026-09-23T13:55:00Z',
             'payload': {'type': 'token_count', 'rate_limits': {'limit_id': 'codex',
                 'primary': {'used_percent': 95, 'window_minutes': 10080,
                             'resets_at': 1790608272}}}},
        ]
        path.write_text(''.join(json.dumps(item) + '\n' for item in lines))
        path.chmod(0o600)
        result = quota_from_rollout(self.home, path, 'thread-a', now=stamp)
        self.assertEqual(result['windows'][0]['usedPercent'], 95)
        class DB:
            def execute(self, _):
                return SimpleNamespace(fetchall=lambda: [
                    {'thread_id': 'thread-a', 'rollout_path': str(path)}])
        registry = SimpleNamespace(lock=threading.RLock(), db=DB(), codex_home=str(self.home),
                                   _check_rollout=lambda row: row['rollout_path'])
        self.assertEqual(quota_from_registry(registry, now=stamp)['windows'][0]['usedPercent'], 95)
        with self.assertRaises(NativeFeatureUnavailable):
            quota_from_rollout(self.home, path, 'other', now=stamp)
        path.chmod(0o644)
        with self.assertRaises(NativeFeatureUnavailable):
            quota_from_rollout(self.home, path, 'thread-a', now=stamp)


if __name__ == "__main__":
    unittest.main()
