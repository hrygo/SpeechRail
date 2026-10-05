"""Join owned cleanup before propagating cancellation to its caller."""

from __future__ import annotations

import asyncio


async def join_cleanup[T](task: asyncio.Task[T]) -> T:
    """Retain and join a cleanup task even if its caller is cancelled repeatedly.

    The cleanup operation owns its failure and any internal deadline. Cancelling
    a waiter cannot abandon it or imply that the resources have been reclaimed.
    """
    cancelled = False
    while not task.done():
        try:
            await asyncio.shield(task)
        except asyncio.CancelledError:
            cancelled = True
    result = task.result()
    if cancelled:
        raise asyncio.CancelledError
    return result
