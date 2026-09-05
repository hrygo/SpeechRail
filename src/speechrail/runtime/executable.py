"""Helpers for validating executable paths supplied by private runtime settings."""

from __future__ import annotations

import os
import stat
from pathlib import Path


def resolve_configured_executable(
    path: Path | str,
    *,
    error_code: str,
) -> str:
    """Resolve a configured executable without exposing filesystem details.

    A configured path must be absolute. Symlinks are followed so an active
    ``vendor/current`` path is accepted, while the resolved target still has
    to be a regular executable file. Failures expose only the caller-provided
    stable error code.
    """

    candidate = Path(path)
    if not candidate.is_absolute():
        raise ValueError(error_code)
    try:
        target = candidate.resolve(strict=True)
        mode = target.stat().st_mode
    except (OSError, RuntimeError, ValueError) as exc:
        raise ValueError(error_code) from exc
    if not stat.S_ISREG(mode) or not mode & 0o111 or not os.access(target, os.X_OK):
        raise ValueError(error_code)
    return str(target)


__all__ = ["resolve_configured_executable"]
