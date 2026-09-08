"""Small helpers for propagating one absolute request deadline."""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable


async def await_until[T](operation: Awaitable[T], expires_at: float) -> T:
    """Await ``operation`` until the caller-owned monotonic deadline."""
    async with asyncio.timeout_at(expires_at):
        return await operation


__all__ = ["await_until"]
