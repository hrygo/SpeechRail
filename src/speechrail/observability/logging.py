"""Structured logging that deliberately omits credentials, audio and transcript bodies."""

from __future__ import annotations

import logging


def event(logger: logging.Logger, name: str, **fields: str | int | float | bool | None) -> None:
    safe = {
        key: value
        for key, value in fields.items()
        if key
        in {"request_id", "session_id", "client", "model", "backend", "duration_ms", "error_code"}
    }
    logger.info(name, extra={"speechrail": safe})
