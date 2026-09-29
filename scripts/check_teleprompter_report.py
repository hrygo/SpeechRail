#!/usr/bin/env python3
"""Check that the teleprompter stage report's own claims match its own content.

Finding 77 of the stage report is the reason this exists. That report's
verification table carried a row claiming a passed self-check over replacement
characters, table columns and identifier resolvability, sitting next to
``pytest`` and ``ruff`` -- but no such gate existed in the repository, it had
always been one manual ``grep``. The claim proved the point: commit
``1258eb03`` shipped a 第 that had rotted into two U+FFFD replacement
characters, and that same commit recorded the row as green.

So this gate is deliberately narrow and mechanical. It checks the three things
that can be decided without judgement:

* no U+FFFD replacement characters anywhere in the report;
* every markdown table has a constant unescaped-pipe count (a stray ``|``
  inside a cell silently splits one row into two and the table renders wrong);
* the header's claimed defect count agrees with its own claimed range.

What it deliberately does **not** check, because the boundary is the point:

* **Table completeness.** The 4.3 table does not carry every condition -- 68,
  69 and 70 live in their own ``§2`` sections. Requiring a row per condition
  would be an editorial rule, not a mechanical one, and a gate that encodes
  taste gets disabled. The known gap is written down in the report instead.
* **Identifier resolvability.** Section 10 of the report asks for a check that
  named identifiers in the report still exist in code. The first attempt at
  that reported both false negatives and false positives because its criteria
  were incomplete. It needs its own tool with its own fixtures, not a guess
  bolted onto this one.

Every detector runs against a known-bad fixture before the real file is read.
If a detector does not fire on its own fixture this exits non-zero and reports
nothing about the report -- an inert checker that reports "ok" forever is the
exact failure this script exists to prevent.

Usage:
  uv run python scripts/check_teleprompter_report.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPORT = Path("docs/implementation/SpeechRail_AI_Teleprompter_Stage_Report_2026-09-28.md")
REPLACEMENT_CHAR = "�"

_CLAIM_RE = re.compile(r"找出 (\d+) 个真缺陷.*?第 (\d+)[–-](\d+) 条")
_UNESCAPED_PIPE_RE = re.compile(r"(?<!\\)\|")


def find_replacement_chars(text: str) -> list[str]:
    """Return every line that carries a U+FFFD replacement character."""
    return [
        f"line {number}: replacement character (U+FFFD)"
        for number, line in enumerate(text.splitlines(), start=1)
        if REPLACEMENT_CHAR in line
    ]


def find_ragged_tables(text: str) -> list[str]:
    """Return a note for each markdown table whose rows disagree on column count.

    Only unescaped pipes are counted: ``\\|`` is the GFM escape for a literal
    pipe inside a cell, so a row may legitimately contain more pipe characters
    than its neighbours as long as the extras are escaped.
    """
    failures: list[str] = []
    table: list[tuple[int, str]] = []

    def flush() -> None:
        if len(table) < 2:
            table.clear()
            return
        counts = {len(_UNESCAPED_PIPE_RE.findall(line)) for _, line in table}
        if len(counts) > 1:
            first = table[0][0]
            detail = ", ".join(
                f"line {number}: {len(_UNESCAPED_PIPE_RE.findall(line))} pipes"
                for number, line in table
            )
            failures.append(f"table starting line {first} has ragged columns ({detail})")
        table.clear()

    for number, line in enumerate(text.splitlines(), start=1):
        if line.lstrip().startswith("|"):
            table.append((number, line))
        else:
            flush()
    flush()
    return failures


def find_claim_drift(text: str) -> list[str]:
    """Return a note when the header's count disagrees with its own range."""
    failures: list[str] = []
    for number, line in enumerate(text.splitlines(), start=1):
        match = _CLAIM_RE.search(line)
        if match is None:
            continue
        count, low, high = (int(group) for group in match.groups())
        span = high - low + 1
        if count != span:
            failures.append(
                f"line {number}: claims {count} defects but range "
                f"{low}-{high} spans {span}"
            )
    return failures


_FIXTURES: tuple[tuple[str, object, str], ...] = (
    (
        "replacement-character detector",
        find_replacement_chars,
        f"依据三条，{REPLACEMENT_CHAR}{REPLACEMENT_CHAR}一条是量出来的\n",
    ),
    (
        "ragged-table detector",
        find_ragged_tables,
        "| a | b | c |\n| --- | --- | --- |\n| 1 | 2 | 3 | 4 |\n",
    ),
    (
        "claim-drift detector",
        find_claim_drift,
        "找出 37 个真缺陷（§2 第 41–76 条）\n",
    ),
)


def self_check() -> list[str]:
    """Prove each detector fires on its own fixture before trusting its verdict."""
    inert: list[str] = []
    for name, detector, fixture in _FIXTURES:
        if not detector(fixture):  # type: ignore[operator]
            inert.append(f"detector is inert, refusing to interpret results: {name}")
    return inert


def main() -> int:
    repository_root = Path(__file__).resolve().parents[1]
    report = repository_root / REPORT

    failures = self_check()
    if failures:
        for failure in failures:
            print(f"error: {failure}", file=sys.stderr)
        return 2

    if not report.is_file():
        print(f"error: missing report: {REPORT}", file=sys.stderr)
        return 1

    text = report.read_text(encoding="utf-8")
    problems = (
        find_replacement_chars(text)
        + find_ragged_tables(text)
        + find_claim_drift(text)
    )
    if problems:
        for problem in problems:
            print(f"error: {REPORT}: {problem}", file=sys.stderr)
        return 1

    print("teleprompter report: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
