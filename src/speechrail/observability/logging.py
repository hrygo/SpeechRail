"""Structured logging that deliberately omits credentials, audio and transcript bodies.

The service configures its own rotating files instead of relying on the
LaunchAgent ``StandardOutPath``/``StandardErrorPath`` redirection, which appends
forever, carries no timestamps and cannot rotate. Two files are written:

* ``speechrail.log`` — readable lines for operators, with the bounded structured
  fields appended as ``key=value`` so a request line carries its own duration;
* ``access.jsonl`` — one JSON object per structured record, for queries.

A missing or unwritable log directory degrades to console logging; it must never
stop the service from serving.
"""

from __future__ import annotations

import json
import logging
import logging.handlers
import sys
from dataclasses import dataclass
from pathlib import Path

type LogValue = str | int | float | bool | None

SERVICE_LOG_FILENAME = "speechrail.log"
ACCESS_LOG_FILENAME = "access.jsonl"
DEFAULT_MAX_BYTES = 8 * 1024 * 1024
DEFAULT_BACKUP_COUNT = 5
_DATE_FORMAT = "%Y-%m-%dT%H:%M:%S%z"

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

_LOGGER = logging.getLogger(__name__)


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


def default_log_directory(user_home: Path | None = None) -> Path:
    """Return the log directory shared with the LaunchAgent's stdout/stderr files."""
    base = user_home or Path.home()
    if sys.platform == "darwin":
        return base / "Library" / "Logs" / "SpeechRail"
    return base / ".local" / "state" / "speechrail" / "logs"


@dataclass(frozen=True, slots=True)
class LoggingHandles:
    """Files the service writes to once ``configure_logging`` succeeded."""

    directory: Path
    service_log: Path
    access_log: Path


class _StructuredRecords(logging.Filter):
    """Keep only records that carry bounded structured fields."""

    def filter(self, record: logging.LogRecord) -> bool:
        return isinstance(getattr(record, "speechrail", None), dict)


class _TextFormatter(logging.Formatter):
    """Readable line plus the bounded structured fields as ``key=value`` pairs."""

    def format(self, record: logging.LogRecord) -> str:
        message = super().format(record)
        fields = getattr(record, "speechrail", None)
        if not isinstance(fields, dict) or not fields:
            return message
        extra = " ".join(f"{key}={value}" for key, value in sorted(fields.items()))
        return f"{message} {extra}"


class _AccessFormatter(logging.Formatter):
    """One bounded JSON object per structured record."""

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, object] = {
            "event": record.getMessage(),
            "level": record.levelname,
            "logger": record.name,
        }
        fields = getattr(record, "speechrail", None)
        if isinstance(fields, dict):
            payload.update(fields)
        return json.dumps(payload, ensure_ascii=False, sort_keys=True, default=str)


def configure_logging(
    log_directory: Path,
    *,
    level: int = logging.INFO,
    max_bytes: int = DEFAULT_MAX_BYTES,
    backup_count: int = DEFAULT_BACKUP_COUNT,
    console: bool | None = None,
) -> LoggingHandles | None:
    """Route service, vendor and structured access logs into rotating files.

    Returns ``None`` when the filesystem refused the directory, in which case the
    caller keeps its previous logging configuration.
    """
    directory = Path(log_directory)
    service_log = directory / SERVICE_LOG_FILENAME
    access_log = directory / ACCESS_LOG_FILENAME
    try:
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        service_handler = _rotating_handler(
            service_log,
            level=level,
            max_bytes=max_bytes,
            backup_count=backup_count,
            formatter=_text_formatter(),
        )
        try:
            access_handler = _rotating_handler(
                access_log,
                level=level,
                max_bytes=max_bytes,
                backup_count=backup_count,
                formatter=_AccessFormatter(),
                filters=(_StructuredRecords(),),
            )
        except BaseException:
            service_handler.close()
            raise
    except (OSError, ValueError) as exc:
        _LOGGER.warning(
            "SpeechRail could not open rotating logs in %s (%s); "
            "falling back to console logging",
            directory,
            exc.__class__.__name__,
        )
        return None

    root = logging.getLogger()
    for existing in list(root.handlers):
        root.removeHandler(existing)
        existing.close()
    root.setLevel(level)
    root.addHandler(service_handler)
    root.addHandler(access_handler)
    for path in (service_log, access_log):
        _restrict_mode(path)
    with_console = sys.stderr.isatty() if console is None else console
    if with_console:
        console_handler = logging.StreamHandler(sys.stderr)
        console_handler.setLevel(level)
        console_handler.setFormatter(_text_formatter())
        root.addHandler(console_handler)
    _silence_uvicorn_access_logger()
    return LoggingHandles(
        directory=directory, service_log=service_log, access_log=access_log
    )


def _text_formatter() -> _TextFormatter:
    return _TextFormatter(
        "%(asctime)s %(levelname)s %(name)s %(message)s", datefmt=_DATE_FORMAT
    )


def _restrict_mode(path: Path) -> None:
    """Keep the log files owner-only; rotated backups inherit the mode."""
    try:
        path.chmod(0o600)
    except OSError:
        _LOGGER.debug("could not restrict permissions on %s", path)


def _rotating_handler(
    path: Path,
    *,
    level: int,
    max_bytes: int,
    backup_count: int,
    formatter: logging.Formatter,
    filters: tuple[logging.Filter, ...] = (),
) -> logging.Handler:
    handler = logging.handlers.RotatingFileHandler(
        path,
        maxBytes=max_bytes,
        backupCount=backup_count,
        encoding="utf-8",
    )
    handler.setLevel(level)
    handler.setFormatter(formatter)
    for record_filter in filters:
        handler.addFilter(record_filter)
    return handler


def _silence_uvicorn_access_logger() -> None:
    """Drop uvicorn's access line: ``http_access`` states the same fact and more."""
    vendor_access = logging.getLogger("uvicorn.access")
    vendor_access.handlers = []
    vendor_access.propagate = False
    vendor_access.setLevel(logging.WARNING)


__all__ = [
    "ACCESS_LOG_FILENAME",
    "DEFAULT_BACKUP_COUNT",
    "DEFAULT_MAX_BYTES",
    "SERVICE_LOG_FILENAME",
    "LoggingHandles",
    "access",
    "configure_logging",
    "default_log_directory",
    "event",
]
