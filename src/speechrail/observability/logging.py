"""Structured logging that deliberately omits credentials, audio and transcript bodies."""

from __future__ import annotations

import logging

type LogValue = str | int | float | bool | None

_ACCESS_FIELDS = frozenset(
    {
        "timestamp",
        "request_id",
        "route",
        "status",
        "outcome",
        "duration_ms",
        "error_code",
        "tts_warm",
        "worker_state",
    }
)


def _bounded(value: LogValue) -> LogValue:
    """Keep operator-facing string fields bounded even when sourced from a header."""
    if isinstance(value, str):
        return value[:128]
    return value


def event(logger: logging.Logger, name: str, **fields: str | int | float | bool | None) -> None:
    safe = {
        key: value
        for key, value in fields.items()
        if key
        in {"request_id", "session_id", "client", "model", "backend", "duration_ms", "error_code"}
    }
    logger.info(name, extra={"speechrail": safe})


def access(logger: logging.Logger, **fields: LogValue) -> None:
    """Emit one bounded HTTP access record without request content or credentials."""
    safe = {
        key: _bounded(value)
        for key, value in fields.items()
        if key in _ACCESS_FIELDS
    }
    logger.info("http_access", extra={"speechrail": safe})
