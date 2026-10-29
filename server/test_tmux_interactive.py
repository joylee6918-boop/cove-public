"""Synthetic native terminal adoption; no tmux, model, or live MCP calls."""
import queue
import tempfile
import threading
import time
import unittest
from pathlib import Path

from storage import APIError, Store
from tmux_interactive import InteractiveTurns
from tmux_rollout import RolloutEvent, RolloutUnsafe


class QueueReader:
    def __init__(self):
        self.values = queue.Queue()
        self.closed = False
        self.delivered = 0
        self.raise_error = None

    def poll(self):
        if self.raise_error:
            raise self.raise_error
        try:
            value = self.values.get_nowait()
            self.delivered += 1
            return value
        except queue.Empty:
            return []

    def push(self, *events):
        self.values.put(list(events))

    def close(self):
        self.closed = True


class FakeRegistry:
    def __init__(self):
        self.calls = []
        self.quarantined = False

    def begin_console(self, *args): self.calls.append(('begin', *args))
    def adopt_console_dispatch(self, *args): self.calls.append(('adopt', *args))
    def finish_dispatch(self, *args): self.calls.append(('finish_dispatch', *args))
    def finish_console(self, *args): self.calls.append(('finish_console', *args))
    def quarantine(self, *args):
        self.calls.append(('quarantine', *args)); self.quarantined = True


class FakeRuntime:
    def __init__(self, store):
        self.store = store
        self.state_lock = threading.RLock()
        self.session_provider = FakeRegistry()
        self.codex_home = str(store.directory)
        self.bindings = {'c': {'threadID': 't', 'rolloutPath': str(store.directory / 'fake.jsonl')}}
        self.active = None
        self.run_done = threading.Event(); self.run_done.set()
        self.native_signal = threading.Event()
        self.closed = False


def event(kind, turn, text=None, complete=True):
    return RolloutEvent(kind, turn, text=text, projection_complete=complete)


class InteractiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.temp.name).resolve())
        self.store.create_conversation('c')
        self.store.bind_thread('c', 't')
        self.runtime = FakeRuntime(self.store)
        self.reader = QueueReader()
        self.interactive = InteractiveTurns(self.runtime, observer_factory=lambda *_: self.reader)

    def tearDown(self):
        self.interactive.close()
        self.store.close()
        self.temp.cleanup()

    def wait(self, predicate, timeout=2):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate(): return
            time.sleep(.01)
        self.fail('observer did not reach expected synthetic state')

    def owner_enter(self, text='hello'):
        with self.runtime.state_lock:
            self.interactive.before_control('c', 'input', text)
            self.interactive.before_control('c', 'key', 'Enter')

    def test_app_turn_is_skipped_then_queued_raw_turn_adopted(self):
        # App native task_started can arrive while its dispatch has not yet
        # bound the turn; it must never consume the terminal Enter credit.
        app_cancel = threading.Event()
        self.runtime.active = {'conversation': 'c', 'thread': 't', 'turn': None,
                               'source': 'app', 'cancel': app_cancel}
        self.runtime.run_done.clear()
        self.owner_enter('queued terminal')
        self.reader.push(event('turn_started', 'app-turn'),
                         event('user_message', 'app-turn', 'app input'),
                         event('turn_completed', 'app-turn', 'app result'))
        self.wait(lambda: self.reader.delivered >= 1 and self.interactive.states['c']['skip_turn'] is None)
        self.assertEqual(self.interactive.states['c']['credits'], 1)
        self.assertFalse(any(call[0] == 'adopt' for call in self.runtime.session_provider.calls))
        self.runtime.active = None
        self.runtime.run_done.set()
        self.reader.push(event('turn_started', 'raw-1'),
                         event('user_message', 'raw-1', 'queued terminal'),
                         event('turn_completed', 'raw-1', 'raw answer'))
        self.wait(lambda: any(call[0] == 'finish_dispatch' for call in self.runtime.session_provider.calls))
        with self.store.lock:
            row = self.store.db.execute('SELECT state FROM jobs WHERE turn=?', ('raw-1',)).fetchone()
        self.assertEqual(row[0], 'complete')
        self.assertFalse(self.runtime.session_provider.quarantined)

    def test_bound_app_turn_skips_despite_terminal_enter_credit(self):
        self.store.accept({'id': 'app-message', 'conversationID': 'c', 'text': 'app input'})
        self.store.claim()
        self.assertTrue(self.store.bind_turn('app-message', 'app-turn', 't'))
        self.runtime.active = {'conversation': 'c', 'thread': 't', 'turn': 'app-turn',
                               'source': 'app', 'cancel': threading.Event()}
        self.runtime.run_done.clear()
        self.owner_enter('queued raw')
        self.reader.push(event('turn_started', 'app-turn'),
                         event('user_message', 'app-turn', 'app input'),
                         event('turn_completed', 'app-turn', 'app answer'))
        self.wait(lambda: self.reader.delivered >= 1 and self.interactive.states['c']['skip_turn'] is None)
        self.assertEqual(self.interactive.states['c']['credits'], 1)
        self.store.finish('app-message', 'complete')
        self.runtime.active = None
        self.runtime.run_done.set()
        self.reader.push(event('turn_started', 'raw-next'),
                         event('user_message', 'raw-next', 'queued raw'),
                         event('turn_completed', 'raw-next', 'answer'))
        self.wait(lambda: any(c[0] == 'finish_dispatch' for c in self.runtime.session_provider.calls))
        self.assertFalse(self.runtime.session_provider.quarantined)

    def test_multiple_raw_turns_under_one_observer(self):
        self.owner_enter('first')
        self.reader.push(event('turn_started', 'raw-1'), event('user_message', 'raw-1', 'first'),
                         event('turn_completed', 'raw-1', 'one'))
        self.wait(lambda: len([c for c in self.runtime.session_provider.calls if c[0] == 'finish_dispatch']) == 1)
        self.owner_enter('second')
        self.reader.push(event('turn_started', 'raw-2'), event('user_message', 'raw-2', 'second'),
                         event('turn_completed', 'raw-2', 'two'))
        self.wait(lambda: len([c for c in self.runtime.session_provider.calls if c[0] == 'finish_dispatch']) == 2)
        self.assertEqual(len([c for c in self.runtime.session_provider.calls if c[0] == 'adopt']), 2)

    def test_uncredited_turn_and_incomplete_projection_quarantine(self):
        self.owner_enter('first')
        self.reader.push(event('turn_started', 'raw-1'), event('user_message', 'raw-1', 'first'),
                         event('turn_completed', 'raw-1', 'partial', complete=False))
        self.wait(lambda: self.runtime.session_provider.quarantined)
        with self.runtime.state_lock:
            with self.assertRaises(APIError):
                self.interactive.before_control('c', 'input', 'retry')

    def test_uncredited_native_turn_refused(self):
        self.owner_enter('first')
        self.interactive.states['c']['credits'] = 0
        self.reader.push(event('turn_started', 'uncredited'))
        self.wait(lambda: self.runtime.session_provider.quarantined)
        self.assertFalse(any(c[0] == 'adopt' for c in self.runtime.session_provider.calls))

    def test_app_commit_timeout_quarantines_queued_native_turn(self):
        self.interactive.APP_CLEAR_TIMEOUT = .05
        self.runtime.active = {'conversation': 'c', 'thread': 't', 'turn': 'old-app',
                               'source': 'app', 'cancel': threading.Event()}
        self.runtime.run_done.clear()
        self.owner_enter('queued')
        self.reader.push(event('turn_started', 'raw-next'))
        self.wait(lambda: self.runtime.session_provider.quarantined)
        self.assertFalse(any(c[0] == 'adopt' for c in self.runtime.session_provider.calls))

    def test_oversized_rollout_failure_quarantines(self):
        self.owner_enter('first')
        self.reader.raise_error = RolloutUnsafe('oversized native line')
        self.wait(lambda: self.runtime.session_provider.quarantined)
        self.assertFalse(any(c[0] == 'adopt' for c in self.runtime.session_provider.calls))

    def test_close_stops_observer_without_killing_pane(self):
        self.owner_enter('unsent')
        self.interactive.close()
        self.assertTrue(self.reader.closed)
        self.assertFalse(any(c[0] == 'finish_dispatch' for c in self.runtime.session_provider.calls))


if __name__ == '__main__':
    unittest.main()
