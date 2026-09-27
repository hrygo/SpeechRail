#!/usr/bin/env python3
"""Fail when ``docs/users/api-contract.md`` stops describing the served surface.

``check_openapi_contract.py`` proves the runtime and the machine-readable
contract agree, but neither of them proves the hand-written user guide still
names every served path, every documented error code and every model alias the
service advertises. That gap is how real capabilities silently disappear from
the documentation, so it is checked here instead of being re-reviewed by hand.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

from speechrail.compatibility.openai_realtime import (
    asr_model_aliases,
    tts_model_aliases,
)

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / "contracts" / "openapi.yaml"
USER_GUIDE = ROOT / "docs" / "users" / "api-contract.md"
SOURCE_ROOT = ROOT / "src" / "speechrail"

_ERROR_TABLE_HEADING = "### 标准错误码速查表"
_ERROR_ROW = re.compile(r"^\|\s*\*\*\d{3}\*\*\s*\|(.+?)\|")
_BACKTICKED = re.compile(r"`([a-z][a-z0-9_]*)`")


def _contract_paths() -> list[str]:
    spec = yaml.safe_load(CONTRACT.read_text(encoding="utf-8"))
    paths = spec["paths"]
    assert isinstance(paths, dict)
    return [str(path) for path in paths]


def _documented_error_codes(guide: str) -> list[str]:
    """Return every error code named in the guide's standard error-code table."""

    try:
        table = guide.split(_ERROR_TABLE_HEADING, 1)[1]
    except IndexError:  # pragma: no cover - the table is a required section
        raise ValueError(f"{_ERROR_TABLE_HEADING} section is missing") from None
    codes: list[str] = []
    for line in table.splitlines():
        row = _ERROR_ROW.match(line)
        if row is None:
            continue
        codes.extend(_BACKTICKED.findall(row.group(1)))
    return codes


def _source_text() -> str:
    return "\n".join(
        path.read_text(encoding="utf-8") for path in sorted(SOURCE_ROOT.rglob("*.py"))
    )


def find_drift() -> list[str]:
    guide = USER_GUIDE.read_text(encoding="utf-8")
    source = _source_text()
    problems: list[str] = []

    for path in _contract_paths():
        if path not in guide:
            problems.append(f"undocumented path: {path}")

    for code in _documented_error_codes(guide):
        if code not in source:
            problems.append(f"documented error code is not implemented: {code}")

    for alias in sorted({*asr_model_aliases(), *tts_model_aliases()}):
        if f"`{alias}`" not in guide:
            problems.append(f"advertised model alias is not documented: {alias}")

    return problems


def main() -> int:
    problems = find_drift()
    if problems:
        for problem in problems:
            print(f"user-doc-contract: {problem}", file=sys.stderr)
        return 1
    print(
        "user-doc-contract: OK "
        f"({len(_contract_paths())} paths, "
        f"{len(_documented_error_codes(USER_GUIDE.read_text(encoding='utf-8')))} "
        "documented error codes, "
        f"{len(asr_model_aliases()) + len(tts_model_aliases())} model aliases)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
