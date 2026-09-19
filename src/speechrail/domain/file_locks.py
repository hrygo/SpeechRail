"""Cross-process locks for local durable files."""

from __future__ import annotations

import fcntl
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import BinaryIO


class FileLockUnavailableError(RuntimeError):
    """A durable file's sibling transaction lock cannot be acquired."""


@contextmanager
def exclusive_file_lock(
    path: Path,
    *,
    unavailable_error: type[Exception] = FileLockUnavailableError,
) -> Iterator[None]:
    """Hold an exclusive sibling lock for one durable read/modify/write cycle."""

    lock_path = path.with_name(f".{path.name}.lock")
    handle: BinaryIO | None = None
    try:
        if path.parent.is_symlink() or lock_path.is_symlink():
            raise OSError("unsafe durable file path")
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        handle = lock_path.open("a+b")
        lock_path.chmod(0o600)
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
    except Exception as exc:
        if handle is not None:
            handle.close()
        raise unavailable_error("durable file lock is unavailable") from exc
    try:
        yield
    finally:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        finally:
            handle.close()
