"""Per-user, per-port singleton guard for the local SpeechRail server."""

from __future__ import annotations

import contextlib
import fcntl
import json
import os
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path


class ServerInstanceError(RuntimeError):
    """The configured local server port is already owned by this user."""


@dataclass(frozen=True, slots=True)
class ServerInstanceOwner:
    """Non-secret identity written while a server lock is held."""

    pid: int
    executable: str
    role: str
    started_at: float


class ServerInstanceLock:
    """Hold a kernel lock for the lifetime of one SpeechRail ASGI process.

    The lock is keyed by port rather than app home because a development
    checkout and the managed installation can otherwise start two processes
    with different working directories while still competing for one port.
    The file is intentionally retained after release; ``flock`` ownership is
    tied to the process and cannot become stale after a crash.
    """

    def __init__(self, port: int, *, directory: Path | None = None) -> None:
        if type(port) is not int or not 1 <= port <= 65_535:
            raise ValueError("port must be between 1 and 65535")
        root = (directory or Path(tempfile.gettempdir())).absolute()
        self.path = root / f"speechrail-port-{getattr(os, 'getuid', lambda: 0)()}-{port}.lock"
        self._descriptor: int | None = None

    def __enter__(self) -> ServerInstanceLock:
        self.acquire()
        return self

    def __exit__(self, *_: object) -> None:
        self.release()

    @classmethod
    def read_owner(
        cls,
        port: int,
        *,
        directory: Path | None = None,
    ) -> ServerInstanceOwner | None:
        """Read the last owner metadata without acquiring the lock.

        The metadata is only a recovery hint. Callers must still verify that
        the port lock is held and that the PID is the expected SpeechRail
        process before sending a signal.
        """
        instance = cls(port, directory=directory)
        try:
            payload = json.loads(instance.path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError):
            return None
        if not isinstance(payload, dict):
            return None
        pid = payload.get("pid")
        executable = payload.get("executable")
        role = payload.get("role")
        started_at = payload.get("started_at")
        if (
            type(pid) is not int
            or pid <= 1
            or not isinstance(executable, str)
            or not executable
            or role != "speechrail-serve"
            or not isinstance(started_at, (int, float))
            or isinstance(started_at, bool)
        ):
            return None
        return ServerInstanceOwner(
            pid=pid,
            executable=executable,
            role=role,
            started_at=float(started_at),
        )

    def acquire(self) -> None:
        if self._descriptor is not None:
            raise RuntimeError("server_lock_already_acquired")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            os.fchmod(descriptor, 0o600)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise ServerInstanceError("server_already_running") from exc
        except BaseException:
            os.close(descriptor)
            raise
        self._descriptor = descriptor
        try:
            self._write_owner_metadata()
        except BaseException:
            self._descriptor = None
            with contextlib.suppress(OSError):
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)
            raise

    def _write_owner_metadata(self) -> None:
        if self._descriptor is None:
            raise RuntimeError("server_lock_not_acquired")
        payload = json.dumps(
            {
                "schema_version": 1,
                "pid": os.getpid(),
                "executable": os.path.realpath(sys.executable),
                "role": "speechrail-serve",
                "started_at": time.time(),
            },
            separators=(",", ":"),
        ).encode("utf-8")
        os.ftruncate(self._descriptor, 0)
        os.lseek(self._descriptor, 0, os.SEEK_SET)
        os.write(self._descriptor, payload)
        os.fsync(self._descriptor)

    def release(self) -> None:
        descriptor, self._descriptor = self._descriptor, None
        if descriptor is None:
            return
        with contextlib.suppress(OSError):
            os.ftruncate(descriptor, 0)
            os.lseek(descriptor, 0, os.SEEK_SET)
            os.fsync(descriptor)
        with contextlib.suppress(OSError):
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


__all__ = ["ServerInstanceError", "ServerInstanceLock", "ServerInstanceOwner"]
