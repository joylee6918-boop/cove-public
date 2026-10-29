"""Bounded, read-only projection of one authorized Codex rollout.

This is not an MCP permit source or a turn dispatcher.  The owner must supply the
exact rollout path and selected turn before polling.  In particular, a terminal
screen or tool result can never finish a turn.
"""

from __future__ import annotations

import hashlib
import json
import os
import stat
from dataclasses import dataclass
from pathlib import Path


class RolloutUnsafe(RuntimeError):
    """The cursor cannot safely continue; create a new, explicitly bound tailer."""


@dataclass(frozen=True)
class RolloutEvent:
    kind: str
    turn_id: str
    text: str | None = None
    label: str | None = None
    projection_complete: bool = True


@dataclass(frozen=True)
class CursorSnapshot:
    device: int
    inode: int
    offset: int
    pending_bytes: int
    failed: bool
    projection_gap: bool


class RolloutTailer:
    """Tail only new complete JSONL records from an exact path under sessions.

    Starts at EOF, deliberately never importing old transcript records. A tailer
    is single-use for one thread and one selected turn.  Its cursor is in memory;
    callers must not reconstruct it from an untrusted offset after restart.
    """

    MAX_POLL_BYTES = 256 * 1024
    MAX_LINE_BYTES = 64 * 1024
    MAX_TEXT_CHARS = 32 * 1024

    def __init__(self, codex_home: str | Path, rollout_path: str | Path,
                 thread_id: str, turn_id: str | None = None, *, arm_next: bool = False):
        if not isinstance(thread_id, str) or not thread_id:
            raise ValueError('thread must be explicitly selected')
        if arm_next == (turn_id is not None) or (turn_id is not None and (not isinstance(turn_id, str) or not turn_id)):
            raise ValueError('select a turn or explicitly arm exactly one next turn')
        self.thread_id, self.turn_id = thread_id, turn_id
        self._arm_next = arm_next
        self._home = Path(codex_home).expanduser().resolve(strict=True)
        path = Path(rollout_path).expanduser()
        if not path.is_absolute() or '..' in path.parts or path.suffix != '.jsonl':
            raise RolloutUnsafe('invalid rollout path')
        try:
            relative = path.relative_to(self._home)
        except ValueError as exc:
            raise RolloutUnsafe('rollout outside authorized home') from exc
        if len(relative.parts) < 2 or relative.parts[0] not in ('sessions', 'archived_sessions'):
            raise RolloutUnsafe('rollout outside authorized session trees')
        self._parts = relative.parts
        self._path = path
        self._fd = self._open_exact()
        info = os.fstat(self._fd)
        self._identity = (info.st_dev, info.st_ino)
        self._offset = info.st_size
        self._pending = b''
        self._discard_initial_partial = False
        if self._offset:
            os.lseek(self._fd, self._offset - 1, os.SEEK_SET)
            self._discard_initial_partial = os.read(self._fd, 1) != b'\n'
        self._seal = self._fingerprint(self._offset)
        self._started = False
        self._completed = False
        self._failed = False
        self._dropping_line = False
        self._projection_gap = False

    def _open_exact(self) -> int:
        """Walk below trusted home using no-follow directory descriptors."""
        flags_dir = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        directory = os.open(self._home, flags_dir)
        try:
            for part in self._parts[:-1]:
                next_fd = os.open(part, flags_dir, dir_fd=directory)
                os.close(directory)
                directory = next_fd
            fd = os.open(self._parts[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                os.close(fd)
                raise RolloutUnsafe('rollout is not a regular file')
            return fd
        except OSError as exc:
            raise RolloutUnsafe('rollout path is unavailable or symlinked') from exc
        finally:
            os.close(directory)

    def _fingerprint(self, offset: int) -> bytes:
        # Detect same-inode rewrites of the last committed bytes as well as truncation.
        start = max(0, offset - 64)
        return hashlib.sha256(os.pread(self._fd, offset - start, start)).digest()

    def snapshot(self) -> CursorSnapshot:
        return CursorSnapshot(*self._identity, self._offset, len(self._pending), self._failed,
                              self._projection_gap)

    def close(self) -> None:
        if self._fd is not None:
            os.close(self._fd)
            self._fd = None

    def _fail(self, why: str):
        self._failed = True
        self.close()
        raise RolloutUnsafe(why)

    def poll(self, max_bytes: int = MAX_POLL_BYTES) -> list[RolloutEvent]:
        if self._failed or self._fd is None:
            raise RolloutUnsafe('rollout cursor is closed or unsafe')
        if type(max_bytes) is not int or not 1 <= max_bytes <= self.MAX_POLL_BYTES:
            raise ValueError('invalid poll byte limit')
        try:
            current = self._open_exact()
            try:
                identity = os.fstat(current)
                if (identity.st_dev, identity.st_ino) != self._identity:
                    self._fail('rollout path replaced')
            finally:
                os.close(current)
            info = os.fstat(self._fd)
            if (info.st_dev, info.st_ino) != self._identity or info.st_size < self._offset:
                self._fail('rollout truncated or replaced')
            if self._fingerprint(self._offset) != self._seal:
                self._fail('rollout prefix changed')
            count = min(max_bytes, info.st_size - self._offset)
            data = os.pread(self._fd, count, self._offset)
            if len(data) != count:
                self._fail('rollout changed during read')
            self._offset += count
            self._seal = self._fingerprint(self._offset)
            events: list[RolloutEvent] = []
            # Never buffer a record larger than MAX_LINE_BYTES.  Skip it without
            # decoding/projection and mark the turn projection incomplete.
            for fragment in data.split(b'\n')[:-1]:
                line = self._pending + fragment if not self._dropping_line else b''
                self._pending = b''
                if self._dropping_line or len(line) > self.MAX_LINE_BYTES:
                    self._mark_gap()
                    self._dropping_line = False
                    continue
                if self._discard_initial_partial:
                    self._discard_initial_partial = False
                    continue
                try:
                    record = json.loads(line.decode('utf-8'))
                except (UnicodeError, ValueError):
                    self._fail('invalid rollout JSONL record')
                event = self._project(record)
                if event is not None:
                    events.append(event)
            remainder = data.rsplit(b'\n', 1)[-1]
            if self._dropping_line:
                pass
            elif b'\n' in data:
                self._pending = remainder
            else:
                self._pending += remainder
            if len(self._pending) > self.MAX_LINE_BYTES:
                self._pending = b''
                self._dropping_line = True
                self._mark_gap()
            return events
        except RolloutUnsafe:
            self._failed = True
            self.close()
            raise

    def _mark_gap(self):
        # A skipped line might itself be a start event. Never bind a later turn
        # as "first" after this uncertainty, even if its JSON looks valid.
        if not self._started:
            self._fail('oversized record before selected turn started')
        self._projection_gap = True

    def _project(self, record: object) -> RolloutEvent | None:
        if not isinstance(record, dict):
            return None
        payload = record.get('payload')
        if not isinstance(payload, dict):
            return None
        kind = record.get('type')
        event_type = payload.get('type')
        if kind == 'event_msg':
            if payload.get('thread_id', self.thread_id) != self.thread_id:
                return None
            if event_type == 'task_started':
                candidate = payload.get('turn_id')
                if self._arm_next and not self._started and isinstance(candidate, str) and candidate:
                    self.turn_id = candidate
                    self._arm_next = False
                if candidate == self.turn_id and not self._started and not self._completed:
                    self._started = True
                    return RolloutEvent('turn_started', self.turn_id)
                if self._started and not self._completed and candidate != self.turn_id:
                    self._fail('another turn started before selected turn completed')
            elif event_type == 'task_complete' and payload.get('turn_id') == self.turn_id:
                if self._started and not self._completed:
                    final = payload.get('last_agent_message')
                    if isinstance(final, str) and len(final) > self.MAX_TEXT_CHARS:
                        # Do not truncate a final answer and call it complete.
                        self._projection_gap = True
                        final = None
                    if not isinstance(final, str) or not final.strip():
                        final = None
                    self._completed = True
                    return RolloutEvent('turn_completed', self.turn_id,
                                        text=final,
                                        projection_complete=not self._projection_gap)
            elif event_type == 'item_completed':
                if (self._started and not self._completed and
                        payload.get('thread_id') == self.thread_id and payload.get('turn_id') == self.turn_id):
                    item = payload.get('item')
                    if isinstance(item, dict) and item.get('type') in ('mcpToolCall', 'commandExecution', 'fileChange'):
                        return RolloutEvent('tool_completed', self.turn_id, label='tool')
            return None
        if kind != 'response_item' or not self._started or self._completed:
            return None
        # If a newer schema supplies explicit IDs, they must agree. Otherwise the
        # task-start / task-complete envelope is the only allowed attribution.
        if payload.get('thread_id', self.thread_id) != self.thread_id or payload.get('turn_id', self.turn_id) != self.turn_id:
            return None
        if event_type == 'message' and payload.get('role') == 'user':
            content = payload.get('content')
            if isinstance(content, list):
                images = [part for part in content if isinstance(part, dict) and
                          part.get('type') == 'input_image' and
                          isinstance(part.get('image_url'), str) and part['image_url'].startswith('data:image/')]
                if images:
                    # A native vision item, not a path in input_text. Do not
                    # expose, copy into chat, or log the private image bytes.
                    return RolloutEvent('image_input', self.turn_id, label=str(len(images)))
            return None
        if event_type == 'custom_tool_call':
            return RolloutEvent('tool_started', self.turn_id, label='tool')
        if event_type == 'custom_tool_call_output':
            return RolloutEvent('tool_completed', self.turn_id, label='tool')
        if event_type != 'message' or payload.get('role') != 'assistant' or payload.get('phase') not in ('final', 'final_answer'):
            return None
        content = payload.get('content')
        if not isinstance(content, list):
            return None
        chunks = []
        for part in content:
            if not isinstance(part, dict) or part.get('type') != 'output_text' or not isinstance(part.get('text'), str):
                return None
            chunks.append(part['text'])
        result = ''.join(chunks)
        if len(result) > self.MAX_TEXT_CHARS:
            self._projection_gap = True
            return None
        if not result:
            return None
        return RolloutEvent('message', self.turn_id, text=result)


class ContinuousRolloutTailer(RolloutTailer):
    """Observe successive native turns on one fixed thread without tool permits.

    Default attaches at EOF and never replays old history. ``from_start`` is only
    for a newly created rollout chosen by the owning dispatcher; it verifies the
    session header before attributing any turn. Restarted callers should attach
    at EOF and quarantine an unfinished turn rather than replay uncertain work.
    """

    def __init__(self, codex_home: str | Path, rollout_path: str | Path,
                 thread_id: str, *, from_start: bool = False):
        super().__init__(codex_home, rollout_path, thread_id, arm_next=True)
        self._need_header = from_start
        if from_start:
            self._offset = 0
            self._seal = self._fingerprint(0)
            self._discard_initial_partial = False

    def _mark_gap(self):
        if self._completed:
            # Between turns, a skipped record might be the next task_started.
            self._fail('oversized record between native turns')
        super()._mark_gap()

    def _project(self, record: object) -> RolloutEvent | None:
        if self._need_header:
            self._need_header = False
            if not isinstance(record, dict) or record.get('type') != 'session_meta':
                self._fail('new rollout missing session header')
            payload = record.get('payload')
            if (not isinstance(payload, dict) or
                    payload.get('id', payload.get('session_id')) != self.thread_id or
                    payload.get('session_id', self.thread_id) != self.thread_id):
                self._fail('new rollout belongs to a different thread')
            return None
        if not isinstance(record, dict) or not isinstance(record.get('payload'), dict):
            return None
        payload = record['payload']
        if record.get('type') == 'event_msg' and payload.get('type') == 'task_started' and self._completed:
            # The preceding turn completed authoritatively. Arm once for the
            # next native turn; never rebind a still-active selected turn.
            self.turn_id = None
            self._arm_next = True
            self._started = False
            self._completed = False
            self._projection_gap = False
        if (record.get('type') == 'response_item' and payload.get('type') == 'message' and
                payload.get('role') == 'user' and self._started and not self._completed):
            provenance = payload.get('internal_chat_message_metadata_passthrough')
            if (not isinstance(provenance, dict) or provenance.get('turn_id') != self.turn_id or
                    provenance.get('content_item_kinds') != ['user.text']):
                # Media records are not an owner text message, but the bounded
                # base reader still verifies actual native input_image receipts.
                return super()._project(record)
            content = payload.get('content')
            if (not isinstance(content, list) or len(content) != 1 or
                    not isinstance(content[0], dict) or content[0].get('type') != 'input_text' or
                    not isinstance(content[0].get('text'), str)):
                return None
            result = content[0]['text']
            if len(result) > self.MAX_TEXT_CHARS:
                self._projection_gap = True
                return None
            if result:
                return RolloutEvent('user_message', self.turn_id, text=result)
            return None
        return super()._project(record)


# Public observer name used by the long-running native coordinator.
RolloutObserver = ContinuousRolloutTailer
