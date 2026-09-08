"""Shared local API-key discovery for SpeechRail clients and operators."""

from __future__ import annotations

import os
from collections.abc import Mapping
from pathlib import Path

_API_KEY_NAME = "SPEECHRAIL_API_KEY"
_APP_HOME_NAME = "SPEECHRAIL_APP_HOME"


def default_app_home(*, environ: Mapping[str, str] | None = None) -> Path:
    """Return the managed app home used for zero-configuration key discovery."""

    values = os.environ if environ is None else environ
    configured = values.get(_APP_HOME_NAME)
    if configured and configured.strip():
        return Path(configured).expanduser().absolute()
    return Path.home() / "Library" / "Application Support" / "SpeechRail"


def _validate_key(value: str | None) -> str | None:
    if value is None:
        return None
    key = value.strip()
    if not key:
        return None
    if "\r" in key or "\n" in key:
        raise ValueError(f"{_API_KEY_NAME} contains invalid characters")
    return key


def _parse_env_value(value: str) -> str | None:
    parsed = value.strip()
    if parsed and parsed[0] in {"'", '"'}:
        quote = parsed[0]
        closing = parsed.find(quote, 1)
        suffix = parsed[closing + 1 :].strip() if closing >= 0 else ""
        if closing > 0 and (not suffix or suffix.startswith("#")):
            parsed = parsed[1:closing]
    elif " #" in parsed:
        parsed = parsed.split(" #", 1)[0].rstrip()
    return _validate_key(parsed)


def _read_key_from_env_file(env_file: Path) -> str | None:
    try:
        lines = env_file.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return None
    for raw_line in lines:
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        name, separator, value = line.partition("=")
        if separator and name.strip() == _API_KEY_NAME:
            return _parse_env_value(value)
    return None


def resolve_api_key(
    *,
    app_home: Path | None = None,
    environ: Mapping[str, str] | None = None,
) -> str | None:
    """Resolve the local API key without sourcing or exposing the private config.

    An explicitly populated environment key wins.  Blank environment values are
    treated as unset so an operator can leave a shell export in place while the
    managed app home's private ``config/.env`` remains the source of truth.
    """

    values = os.environ if environ is None else environ
    key = _validate_key(values.get(_API_KEY_NAME))
    if key is not None:
        return key
    selected_home = (
        Path(app_home).expanduser().absolute()
        if app_home is not None
        else default_app_home(environ=values)
    )
    return _read_key_from_env_file(selected_home / "config" / ".env")


__all__ = ["default_app_home", "resolve_api_key"]
