"""Isolated tmux process transport. Not a Codex/chat protocol adapter.

Every command targets one explicitly supplied private socket and exact session.
The persisted owner token is a capability for reattaching after a Cove restart;
it must be stored privately by the caller, never logged or sent to the phone.
"""
from __future__ import annotations

import os
import re
import secrets
import stat
import subprocess
import time
from pathlib import Path
from typing import Callable, Mapping, Sequence


class TmuxSessionError(RuntimeError):
    pass


class TmuxSession:
    _name = re.compile(r"[A-Za-z0-9_-]{1,64}\Z")
    _special = frozenset({"Enter", "C-c", "Escape", "BS", "Tab", "Up", "Down", "Left", "Right"})
    _fields = {"@cove_owner": "owner_token", "@cove_conversation": "conversation_id",
               "@cove_thread": "thread_id", "@cove_workspace": "workspace",
               "@cove_pane": "pane_id", "@cove_command": "expected_command"}
    MAX_TEXT = 64 * 1024
    MAX_PASTE = 100 * 1024
    MAX_CAPTURE = 1024 * 1024

    def __init__(self, *, socket_path: str | Path, session_name: str, conversation_id: str,
                 thread_id: str, workspace: str | Path, owner_token: str,
                 child_env: Mapping[str, str] | None = None,
                 runner: Callable[..., subprocess.CompletedProcess] = subprocess.run,
                 tmux_binary: str = "tmux"):
        path = Path(socket_path)
        if not path.is_absolute() or path.name in ("", ".", "..") or path != path.resolve(strict=False):
            raise ValueError("tmux socket must be an absolute explicit path")
        if not self._name.fullmatch(session_name):
            raise ValueError("invalid tmux session name")
        for label, value in (("conversation", conversation_id), ("thread", thread_id), ("owner", owner_token)):
            if not isinstance(value, str) or not value or len(value) > 200 or any(c in value for c in "\r\n\x00"):
                raise ValueError(f"invalid {label} binding")
        try:
            directory = Path(workspace).resolve(strict=True)
        except OSError as error:
            raise ValueError("workspace does not exist or is inaccessible") from error
        if not directory.is_dir():
            raise ValueError("workspace is not a directory")
        self.socket_path = path
        self.session_name = session_name
        self.conversation_id = conversation_id
        self.thread_id = thread_id
        self.workspace = str(directory)
        self.owner_token = owner_token
        if child_env and (set(child_env) != {"CODEX_HOME"} or not Path(child_env["CODEX_HOME"]).is_absolute()):
            raise ValueError("only explicit absolute CODEX_HOME is allowed")
        self.child_env = dict(child_env or {})
        self.runner = runner
        self.tmux_binary = tmux_binary
        self.pane_id = None
        self.expected_command = None
        self._created_here = False
        self._attached = False
        self._metadata_complete = False

    @property
    def _target(self) -> str:
        # tmux prefers an exact name when one exists. Every operation first
        # verifies that exact name in list-sessions, never a prefix match.
        return self.session_name

    def _private_parent(self) -> None:
        parent = self.socket_path.parent
        try:
            for ancestor in (parent, *parent.parents):
                if ancestor.is_symlink():
                    raise TmuxSessionError("tmux socket path crosses a symlink")
            info = parent.lstat()
        except OSError as error:
            raise TmuxSessionError("tmux socket parent is unavailable") from error
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise TmuxSessionError("tmux socket parent must be owned by this user and private (0700)")

    def _private_socket(self) -> None:
        self._private_parent()
        try:
            info = self.socket_path.lstat()
        except OSError as error:
            raise TmuxSessionError("tmux socket is unavailable") from error
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise TmuxSessionError("tmux socket is not a private owned socket")

    def _run(self, *args: str, check: bool = True, input: str | None = None) -> subprocess.CompletedProcess:
        argv = [self.tmux_binary, "-S", str(self.socket_path), *args]
        # The tmux client inherits no Cove bearer/API credentials. The launched
        # program receives a separately explicit minimal environment below.
        env = {key: os.environ[key] for key in ("PATH", "HOME", "LANG", "LC_ALL") if key in os.environ}
        try:
            result = self.runner(argv, shell=False, capture_output=True, text=True,
                                 timeout=10, env=env, check=False, **({'input': input} if input is not None else {}))
        except (OSError, subprocess.TimeoutExpired) as error:
            raise TmuxSessionError("tmux transport unavailable") from error
        if check and result.returncode != 0:
            # tmux stderr can contain private paths or pane output: do not echo it.
            raise TmuxSessionError(f"tmux command failed ({result.returncode})")
        return result

    def _session_exists(self) -> bool:
        result = self._run("list-sessions", "-F", "#{session_name}", check=False)
        if result.returncode != 0:
            return False
        return self.session_name in result.stdout.splitlines()

    def _option(self, name: str) -> str:
        return self._run("show-options", "-t", self._target, "-v", name).stdout.rstrip("\n")

    def _pane_details(self, pane_id: str | None = None) -> tuple[str, str, str]:
        rows = self._run("list-panes", "-s", "-t", self._target,
                         "-F", "#{pane_id}|#{pane_current_command}|#{pane_dead}").stdout.splitlines()
        matches = [row for row in rows if not pane_id or row.split("|", 1)[0] == pane_id]
        if len(matches) != 1 or len(matches[0].split("|")) != 3:
            raise TmuxSessionError("bound pane is missing or ambiguous")
        return tuple(matches[0].split("|"))

    def _verify_identity(self) -> tuple[str, str, str]:
        self._private_socket()
        if not self._session_exists():
            raise TmuxSessionError("bound tmux session does not exist")
        for option, attribute in self._fields.items():
            if option == "@cove_command":
                continue
            if option == "@cove_pane" and self.pane_id is None:
                self.pane_id = self._option(option)
            if self._option(option) != getattr(self, attribute):
                raise TmuxSessionError("tmux session binding mismatch")
        pane, command, dead = self._pane_details(self.pane_id)
        if pane != self.pane_id:
            raise TmuxSessionError("bound pane identity changed")
        return pane, command, dead

    def _verify_binding(self) -> None:
        pane, command, dead = self._verify_identity()
        if self.expected_command is None:
            self.expected_command = self._option("@cove_command")
        if self._option("@cove_command") != self.expected_command:
            raise TmuxSessionError("tmux command binding mismatch")
        if pane != self.pane_id or command != self.expected_command or dead != "0":
            raise TmuxSessionError("bound pane is gone or no longer runs its expected command")

    def start(self, argv: Sequence[str], *, rows: int = 30, cols: int = 100) -> None:
        """Create only this session; never take over an existing one or replay input."""
        self._private_parent()
        if self.socket_path.is_symlink():
            raise TmuxSessionError("tmux socket path is a symlink")
        if self.socket_path.exists():
            self._private_socket()
            if self._session_exists():
                raise TmuxSessionError("session already exists; use attach_existing")
        self._validate_size(rows, cols)
        if not argv or any(not isinstance(arg, str) or "\x00" in arg for arg in argv):
            raise ValueError("invalid command argv")
        executable = Path(argv[0])
        if not executable.is_absolute() or not executable.is_file():
            raise ValueError("command executable must be an absolute file path")
        # Multiple argv words make tmux exec directly rather than falling back to
        # the user's shell. `env -i` prevents API tokens in Cove's environment
        # from reaching either the fake test program or future child programs.
        command = ["/usr/bin/env", "-i", "PATH=" + os.environ.get("PATH", "/usr/bin:/bin"),
                   "HOME=" + os.environ.get("HOME", "/"),
                   *(key + "=" + value for key, value in self.child_env.items()), *argv]
        self._run("new-session", "-d", "-s", self.session_name, "-x", str(cols), "-y", str(rows),
                  "-c", self.workspace, "--", *command)
        self._created_here = True
        try:
            # If a future Codex launcher is a wrapper script, pane_current_command
            # may be the native binary rather than this path. Resolve that exact
            # expected native executable during integration; never disable this check.
            expected = executable.resolve(strict=True).name
            deadline = time.monotonic() + 2
            while True:
                self.pane_id, current, dead = self._pane_details()
                if dead == "0" and current == expected:
                    self.expected_command = expected
                    break
                if dead != "0" or time.monotonic() >= deadline:
                    raise TmuxSessionError("new pane did not start the expected executable")
                time.sleep(.02)
            for option, attribute in self._fields.items():
                self._run("set-option", "-t", self._target, option, getattr(self, attribute))
            self._metadata_complete = True
            self._verify_binding()
        except Exception:
            # Do not silently adopt an unmarked session. Cleanup is deliberately
            # left to the caller's explicit, scoped recovery decision.
            self._attached = False
            raise
        self._attached = True

    def attach_existing(self) -> None:
        self._private_socket()
        if not self._session_exists():
            raise TmuxSessionError("bound tmux session does not exist")
        self.pane_id = self._option("@cove_pane")
        self.expected_command = self._option("@cove_command")
        if not re.fullmatch(r"%[0-9]+", self.pane_id or "") or not self.expected_command:
            raise TmuxSessionError("missing bound pane metadata")
        self._verify_binding()
        self._attached = True

    def _require_attached(self) -> None:
        if not self._attached:
            raise TmuxSessionError("session is not attached")
        self._verify_binding()

    def capture(self, *, max_lines: int = 200, max_bytes: int = MAX_CAPTURE) -> str:
        self._require_attached()
        if not 1 <= max_lines <= 2000 or not 1 <= max_bytes <= self.MAX_CAPTURE:
            raise ValueError("capture limit out of range")
        result = self._run("capture-pane", "-p", "-t", self.pane_id, "-S", f"-{max_lines}")
        encoded = result.stdout.encode("utf-8")
        if len(encoded) > max_bytes:
            raise TmuxSessionError("captured output exceeds limit")
        return result.stdout

    def send_text(self, value: str) -> None:
        self._require_attached()
        if (not isinstance(value, str) or not value or
                any(ord(character) < 0x20 or ord(character) == 0x7f for character in value) or
                len(value.encode("utf-8")) > self.MAX_TEXT):
            raise ValueError("input text is empty or exceeds limit")
        self._run("send-keys", "-l", "-t", self.pane_id, "--", value)

    def send_special(self, key: str) -> None:
        self._require_attached()
        if key not in self._special:
            raise ValueError("special key is not allowed")
        self._run("send-keys", "-t", self.pane_id, "--", key)

    def send_paste(self, value: str, *, bracketed_verified: bool = False) -> None:
        """Paste without Enter; only after the caller verified TUI bracketed mode.

        tmux `paste-buffer -p` emits bracket markers only if the pane application
        requested them. tmux does not expose a documented mode query here, so
        the orchestrator must prove that request (for example from a trusted
        pane-output parser) before passing `bracketed_verified=True`. This gate
        must not be inferred merely from a session being alive.
        """
        self._require_attached()
        if bracketed_verified is not True:
            raise TmuxSessionError("bracketed paste mode has not been verified")
        if (not isinstance(value, str) or not value or
                any((ord(character) < 0x20 and character != '\n') or ord(character) == 0x7f
                    for character in value) or len(value.encode('utf-8')) > self.MAX_PASTE):
            raise ValueError("paste contains controls or exceeds 100 KiB")
        name = 'cove-' + secrets.token_hex(16)
        self._run('load-buffer', '-b', name, '-', input=value)
        try:
            # -r preserves LF instead of turning it into CR/Enter; -p asks tmux
            # to bracket it; -d deletes the one-use buffer after delivery.
            self._run('paste-buffer', '-dpr', '-b', name, '-t', self.pane_id)
        except Exception:
            self._run('delete-buffer', '-b', name, check=False)
            raise

    @staticmethod
    def _validate_size(rows: int, cols: int) -> None:
        if type(rows) is not int or type(cols) is not int or not 4 <= rows <= 300 or not 20 <= cols <= 500:
            raise ValueError("terminal dimensions out of range")

    def resize(self, *, rows: int, cols: int) -> None:
        self._require_attached()
        self._validate_size(rows, cols)
        self._run("resize-pane", "-t", self.pane_id, "-x", str(cols), "-y", str(rows))

    def detach(self) -> None:
        """Release this transport handle; the tmux session keeps running."""
        self._attached = False

    def close_created(self) -> None:
        """Scoped test cleanup only; never kills a socket/server or adopted session."""
        if not self._created_here:
            return
        if self._metadata_complete:
            self.terminate_bound()
            return
        else:
            self._private_socket()
            if not self._session_exists() or not self.pane_id or self._pane_details(self.pane_id)[0] != self.pane_id:
                raise TmuxSessionError("cannot verify partially created session for cleanup")
        self._run("kill-session", "-t", self._target)
        self._created_here = False
        self._attached = False

    def terminate_bound(self) -> None:
        """Force-stop this owned session even if its process has hung or changed.

        This works from a new handle after a restart. Identity is the private
        socket, exact session name, owner/conversation/thread/workspace and the
        original pane ID, not the pane's current command or process liveness.
        """
        self._verify_identity()
        self._run("kill-session", "-t", self._target)
        self._created_here = False
        self._attached = False
