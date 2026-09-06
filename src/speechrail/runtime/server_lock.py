"""Per-user, per-port singleton guard for the local SpeechRail server."""

from __future__ import annotations

import contextlib
import fcntl
import os
import tempfile
from pathlib import Path


class ServerInstanceError(RuntimeError):
    """The configured local server port is already owned by this user."""


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

    def release(self) -> None:
        descriptor, self._descriptor = self._descriptor, None
        if descriptor is None:
            return
        with contextlib.suppress(OSError):
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


__all__ = ["ServerInstanceError", "ServerInstanceLock"]
