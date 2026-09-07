"""Shared errors for local installation helpers."""

from __future__ import annotations


class InstallerError(RuntimeError):
    """Raised when a local installation cannot be completed safely."""
