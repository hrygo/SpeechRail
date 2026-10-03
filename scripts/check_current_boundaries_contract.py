#!/usr/bin/env python3
"""Fail when ``docs/architecture/current-boundaries.md`` states a known-false fact.

This document answers "what is true right now", so a stale sentence there is
worse than no sentence. Each rule below pins one claim that has already drifted
from the implementation, and each rule is anchored on the sentence that carries
it rather than on a word list, so ordinary prose is not flagged.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BOUNDARIES = ROOT / "docs" / "architecture" / "current-boundaries.md"

#: A release number copied into a document that is supposed to track the code.
#: The version lives in ``pyproject.toml`` and is checked by its own gate.
_HARDCODED_RELEASE = re.compile(r"当前 release 版本为\s*`\d+\.\d+\.\d+`")

#: Qwen3-ASR has no native word-level timing; the aligner produces it.
_NATIVE_WORD_TIMESTAMPS = "词级时间戳由 ASR 原生输出提供"

#: ``voice_design`` is its own capability lane, not part of the ``reference``
#: spec. The document says so twice; this is the sentence that must not come back.
_VOICE_DESIGN_BOUND_TO_REFERENCE = re.compile(r"`reference`\s*另含\s*`voice_design`")
_VOICE_DESIGN_INDEPENDENT = "voice_design` 不与档位绑定"


def find_drift(text: str) -> list[str]:
    """Return every current-boundaries claim that contradicts the code."""

    problems: list[str] = []
    if _HARDCODED_RELEASE.search(text):
        problems.append(
            "current-boundaries hardcodes a release version; read pyproject.toml instead"
        )
    if _NATIVE_WORD_TIMESTAMPS in text:
        problems.append(
            "current-boundaries claims ASR-native word timestamps; "
            "the aligner produces them"
        )
    if _VOICE_DESIGN_BOUND_TO_REFERENCE.search(text):
        problems.append(
            "current-boundaries binds voice_design to the reference spec; "
            "it is an independent capability lane"
        )
    elif _VOICE_DESIGN_INDEPENDENT not in text:
        problems.append(
            "current-boundaries no longer states that voice_design is "
            "independent from the TTS specs"
        )
    return problems


def main() -> int:
    problems = find_drift(BOUNDARIES.read_text(encoding="utf-8"))
    if problems:
        for problem in problems:
            print(f"current-boundaries-contract: {problem}", file=sys.stderr)
        return 1
    print("current-boundaries-contract: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
