"""Native owner-input observation, separate from app message dispatch.

Terminal bytes are journalled by TmuxConsole before this gate. A terminal editor
or unconsumed Enter owns the pane, so app jobs must wait rather than append to a
draft or race a queued native turn. Only exact native user.text is projected as
an owner message. This module never manufactures a model tool permission.
"""
from __future__ import annotations

import threading
import time
import uuid
import json

from storage import APIError
from tmux_rollout import RolloutObserver


class InteractiveTurns:
    APP_CLEAR_TIMEOUT = 10

    def __init__(self, runtime, *, observer_factory=RolloutObserver):
        self.runtime = runtime
        self.observer_factory = observer_factory
        self.states = {}

    def busy(self):
        return any(s['editing'] or s['credits'] or s['turn'] or s['error']
                   for s in self.states.values())

    def before_control(self, conversation, operation, value):
        r = self.runtime
        # Called with runtime.state_lock, which also protects app dispatch.
        if not r.run_done.is_set() and not r.active:
            raise APIError(409, '聊天任务正在准备，稍后再操作终端')
        if r.active and r.active['conversation'] != conversation:
            raise APIError(409, '另一个对话正在执行任务')
        with r.store.lock:
            if r.store._handoff_busy(conversation):
                raise APIError(409, '正在安全换窗，暂不接收终端输入')
            if not r.active and r.store.db.execute("SELECT 1 FROM jobs WHERE state='running' LIMIT 1").fetchone():
                raise APIError(409, '聊天任务正在准备，稍后再操作终端')
        state = self.states.get(conversation)
        if state is None:
            binding = r.bindings[conversation]
            reader = self.observer_factory(r.codex_home, binding['rolloutPath'], binding['threadID'])
            state = {'reader': reader, 'binding': binding, 'editing': False,
                     'credits': 0, 'turn': None, 'job': None, 'chunks': [],
                     'intent': None, 'skip_turn': None, 'error': None,
                     'stop': threading.Event()}
            self.states[conversation] = state
            state['worker'] = threading.Thread(target=self._watch, args=(conversation, state), daemon=True)
            state['worker'].start()
        if state['error']:
            raise APIError(409, '终端同步状态未知，请检查并显式恢复会话')
        note_pending = getattr(r.session_provider, 'note_console_pending', None)
        if note_pending:
            note_pending(conversation, 'terminal-' + str(uuid.uuid4()))
        if not r.active and state['intent'] is None:
            self._reserve(conversation, state)
        if operation == 'key' and value == 'Enter':
            state['credits'] += 1
            state['editing'] = False
        else:
            # Arrow/history/escape can change a composer too. Never assume a
            # screen drawing proves an empty draft or an approval dialog.
            state['editing'] = True

    def _reserve(self, conversation, state):
        intent = 'terminal-' + str(uuid.uuid4())
        self.runtime.session_provider.begin_console(conversation, intent)
        state['intent'] = intent

    def after_app_complete(self, conversation):
        state = self.states.get(conversation)
        if state and not state['error'] and state['intent'] is None and (state['editing'] or state['credits']):
            self._reserve(conversation, state)

    def revoke(self, conversation):
        r = self.runtime
        with r.state_lock:
            state = self.states.get(conversation)
            if not state:
                return
            state['error'] = 'owner-interrupted'
            state['stop'].set()
            # C-c/termination revokes the native owner turn immediately. Do
            # not leave a live Store writer permanently running until restart.
            active = r.active
            if active and active.get('source') == 'terminal' and active['conversation'] == conversation:
                active['cancel'].set()
                if state['job']:
                    r.store.finish(state['job']['message'], 'failed',
                                   '终端回合已中断；执行状态未确认，未自动重发')
                r.active = None
                r.native_signal.set()

    def _watch(self, conversation, state):
        r = self.runtime
        try:
            while not state['stop'].wait(.025):
                events = state['reader'].poll()
                for event in events:
                    if event.kind == 'turn_started':
                        with r.state_lock:
                            if self._is_app_start(conversation, event.turn_id):
                                state['skip_turn'] = event.turn_id
                                continue
                        # The app worker may still be committing the preceding
                        # turn. Wait for both runtime and Store.finish before
                        # adopting a queued native owner turn.
                        self._await_app_clear(state)
                    with r.state_lock:
                        if r.closed or state['stop'].is_set():
                            return
                        if state['skip_turn'] is not None:
                            if event.turn_id != state['skip_turn']:
                                raise RuntimeError('app turn projection crossed native turn')
                            if event.kind == 'turn_completed':
                                state['skip_turn'] = None
                            continue
                        self._event(conversation, state, event)
        except Exception:
            with r.state_lock:
                state['error'] = 'native-projection-uncertain'
                r.session_provider.quarantine(conversation, state['error'])
                if state['job']:
                    r.store.finish(state['job']['message'], 'failed',
                                   '终端回合投影未确认，未自动重发；请检查终端')
                if r.active and r.active.get('source') == 'terminal' and r.active['conversation'] == conversation:
                    r.active['cancel'].set()
                    r.active = None
                    r.native_signal.set()
        finally:
            state['reader'].close()

    def _is_app_start(self, conversation, turn):
        r = self.runtime
        active = r.active
        if (active and active.get('conversation') == conversation and
                active.get('source') != 'terminal' and active.get('turn') in (None, turn)):
            return True
        # The app runner may have cleared active before this disk observer
        # catches up. Its durable turn binding still distinguishes it from an
        # unadopted terminal turn without reading screen text.
        with r.store.lock:
            row = r.store.db.execute('''SELECT messages.body FROM jobs JOIN messages
                ON jobs.message=messages.id WHERE jobs.turn=? LIMIT 1''', (turn,)).fetchone()
            return bool(row and json.loads(row[0]).get('source') != 'native-terminal')

    def _await_app_clear(self, state):
        r = self.runtime
        deadline = time.monotonic() + self.APP_CLEAR_TIMEOUT
        while True:
            with r.state_lock, r.store.lock:
                running = r.store.db.execute("SELECT 1 FROM jobs WHERE state='running' LIMIT 1").fetchone()
                if r.active is None and r.run_done.is_set() and not running:
                    return
            if state['stop'].wait(.025) or time.monotonic() > deadline:
                raise RuntimeError('native turn overlaps an uncommitted app turn')

    def _event(self, conversation, state, event):
        r = self.runtime
        if event.kind == 'turn_started':
            if not state['credits'] or state['turn'] or r.active:
                raise RuntimeError('native turn has no matching owner submission')
            if state['intent'] is None:
                self._reserve(conversation, state)
            state['credits'] -= 1
            state['turn'] = event.turn_id
            state['chunks'] = []
            r.active = {'conversation': conversation, 'thread': state['binding']['threadID'],
                        'turn': event.turn_id, 'message': None, 'cancel': threading.Event(),
                        'source': 'terminal', 'interrupt_attempted': False}
            r._native_mcp_calls = {}
            return
        if state['turn'] is None:
            # Attached during an existing app turn: that turn's own reader is
            # authoritative. Ignore its remaining records until a new start.
            return
        if event.turn_id != state['turn']:
            raise RuntimeError('native projection changed turn')
        if event.kind == 'user_message':
            if state['job'] is not None:
                raise RuntimeError('more than one owner input in one native turn')
            job = r.store.adopt_native_turn(conversation, state['binding']['threadID'], event.turn_id, event.text)
            if job['duplicate']:
                raise RuntimeError('native turn was already projected; no replay')
            state['job'] = job
            r.session_provider.adopt_console_dispatch(conversation, state['intent'], job['message'])
            r.active['message'] = job['message']
            r.native_signal.set()
        elif event.kind == 'message':
            if state['job'] is None:
                raise RuntimeError('native reply has no verified owner input')
            state['chunks'].append(event.text or '')
            if sum(map(len, state['chunks'])) > 2_000_000:
                raise RuntimeError('native reply exceeds limit')
            r.store.stream(state['job']['message'], '\n'.join(state['chunks']))
        elif event.kind == 'turn_completed':
            if not event.projection_complete:
                raise RuntimeError('native projection incomplete')
            job = state['job']
            if job:
                if not state['chunks'] and event.text:
                    state['chunks'].append(event.text)
                if not state['chunks'] and not r.store._message(job['assistant']).get('attachments'):
                    raise RuntimeError('native turn has no confirmed answer')
                r.store.stream(job['message'], '\n'.join(state['chunks']))
                r.session_provider.finish_dispatch(conversation, job['message'])
                r.store.finish(job['message'], 'complete')
            else:
                # Native local commands may finish without creating a user
                # message. Do not fabricate a chat bubble for them.
                r.session_provider.finish_console(conversation, state['intent'])
            state.update(turn=None, job=None, chunks=[], intent=None)
            r.active = None
            r.native_signal.set()
            if state['editing'] or state['credits']:
                self._reserve(conversation, state)
            else:
                clear_pending = getattr(r.session_provider, 'clear_console_pending', None)
                if clear_pending:
                    clear_pending(conversation)

    def close(self):
        for state in self.states.values():
            state['stop'].set()
        for state in self.states.values():
            state['worker'].join(11)
            if state['worker'].is_alive():
                raise RuntimeError('native terminal observer has not stopped')
        r = self.runtime
        with r.state_lock:
            for conversation, state in self.states.items():
                if state['job']:
                    # Shutdown has no authoritative task_complete. Persist a
                    # failed answer, but preserve the registry's uncertain
                    # dispatch marker so restart cannot replay the turn.
                    r.store.finish(state['job']['message'], 'failed',
                                   '服务停止时终端回合仍未确认；未自动重发')
                    state['job'] = None
                active = r.active
                if active and active.get('source') == 'terminal' and active['conversation'] == conversation:
                    active['cancel'].set()
                    r.active = None
                    r.native_signal.set()
