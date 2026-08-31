"""Domain primitives shared by the Realtime v2 transport and backends."""

from __future__ import annotations


class RealtimeV2Error(ValueError):
    """A client-visible Realtime v2 protocol violation."""

    def __init__(self, message: str, *, code: str = "invalid_realtime_event") -> None:
        super().__init__(message)
        self.code = code
