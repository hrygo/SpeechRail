#!/usr/bin/env python3
"""Check that the teleprompter stage report's own claims match its own content.

Finding 77 of the stage report is the reason this exists. That report's
verification table carried a row claiming a passed self-check over replacement
characters, table columns and identifier resolvability, sitting next to
``pytest`` and ``ruff`` -- but no such gate existed in the repository, it had
always been one manual ``grep``. The claim proved the point: commit
``1258eb03`` shipped a 第 that had rotted into two U+FFFD replacement
characters, and that same commit recorded the row as green.

So this gate is deliberately narrow and mechanical. It checks the four things
that can be decided without judgement:

* no U+FFFD replacement characters anywhere in the report;
* every markdown table has a constant unescaped-pipe count (a stray ``|``
  inside a cell silently splits one row into two and the table renders wrong);
* the header's claimed defect count agrees with its own claimed range;
* the 4.3 table carries one row per condition in that range.

What it deliberately does **not** check, because the boundary is the point:

* **Identifier resolvability.** Section 10 of the report asks for a check that
  named identifiers in the report still exist in code. The first attempt at
  that reported both false negatives and false positives because its criteria
  were incomplete. It needs its own tool with its own fixtures, not a guess
  bolted onto this one.

The table-completeness check is here because the earlier reasoning against it
was wrong. It was recorded as "an editorial rule, not a mechanical one" on the
strength of a note saying conditions 68, 69 and 70 lived in their own ``§2``
sections. Measuring it showed 69 and 70 stranded in ``### 3.1`` and 68 with no
table row anywhere, while the header's own arithmetic stayed self-consistent
the entire time -- so a reader counting the table got 34, not 37, and every
self-consistency check passed. Noticing a gap is not the same as knowing its
shape; a rule derived from the second guess encodes the guess.

Every detector runs against a known-bad fixture before the real file is read.
If a detector does not fire on its own fixture this exits non-zero and reports
nothing about the report -- an inert checker that reports "ok" forever is the
exact failure this script exists to prevent.

Firing is not enough, so each fixture also names the message it must produce: a
detector that fails for some other reason is as useless as one that stays
silent, and the difference is invisible unless the fixture says what it is
for. Each detector is likewise run against a known-good fixture, because one
that fires on everything would satisfy the check above forever.

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


def find_table_gaps(text: str) -> list[str]:
    """Return a note when the 4.3 summary table does not carry every condition.

    The header claims a condition count and a range. This checks the third
    thing those two imply: that the table actually has one row per condition.
    It exists because the table once shipped with 68, 69 and 70 missing -- 69
    and 70 were stranded in another section and 68 had no row at all -- and the
    header's own arithmetic stayed self-consistent the whole time. Checking the
    claim against itself is not enough; it has to be checked against the table.
    """
    lines = text.splitlines()
    start = next(
        (i for i, line in enumerate(lines) if line.startswith("### 4.3")), None
    )
    if start is None:
        return ["cannot locate the 4.3 section"]
    end = next(
        (i for i, line in enumerate(lines[start:], start=start) if line.startswith("## 5.")),
        len(lines),
    )
    numbers = sorted(
        int(match.group(1))
        for line in lines[start:end]
        if (match := re.match(r"\| 第 (\d+) 条 ", line))
    )
    if not numbers:
        return ["the 4.3 table has no condition rows"]

    claim = next(
        (match for line in lines if (match := _CLAIM_RE.search(line))), None
    )
    if claim is None:
        return ["cannot locate the header's condition claim"]
    low, high = int(claim.group(2)), int(claim.group(3))
    missing = sorted(set(range(low, high + 1)) - set(numbers))
    extra = sorted(set(numbers) - set(range(low, high + 1)))
    failures: list[str] = []
    if missing:
        failures.append(f"4.3 table is missing conditions {missing}")
    if extra:
        failures.append(f"4.3 table has conditions outside the claimed range: {extra}")
    if len(numbers) != len(set(numbers)):
        failures.append("4.3 table has duplicate condition rows")
    return failures


_TABLE = "找出 3 个真缺陷（§2 第 41–43 条）\n\n### 4.3\n\n"

_FIXTURES: tuple[tuple[str, object, str, str], ...] = (
    (
        "replacement-character detector",
        find_replacement_chars,
        f"依据三条，{REPLACEMENT_CHAR}{REPLACEMENT_CHAR}一条是量出来的\n",
        "line 1",
    ),
    (
        "ragged-table detector",
        find_ragged_tables,
        "| a | b | c |\n| --- | --- | --- |\n| 1 | 2 | 3 | 4 |\n",
        "ragged",
    ),
    (
        "claim-drift detector",
        find_claim_drift,
        "找出 37 个真缺陷（§2 第 41–76 条）\n",
        "37",
    ),
    (
        "table-gap detector, missing row",
        find_table_gaps,
        _TABLE + "| 第 41 条 x | a | b |\n| 第 43 条 z | a | b |\n",
        "missing conditions [42]",
    ),
    (
        "table-gap detector, row outside the range",
        find_table_gaps,
        _TABLE + "| 第 41 条 x | a | b |\n| 第 42 条 y | a | b |\n| 第 44 条 z | a | b |\n",
        "outside the claimed range: [44]",
    ),
    (
        "table-gap detector, duplicate row",
        find_table_gaps,
        _TABLE
        + "| 第 41 条 x | a | b |\n| 第 41 条 again | a | b |\n| 第 42 条 y | a | b |\n",
        "duplicate condition rows",
    ),
    (
        "table-gap detector, unlocatable section",
        find_table_gaps,
        "### 4.2\n\n| 第 41 条 x | a | b |\n",
        "cannot locate the 4.3 section",
    ),
)

_CLEAN_FIXTURES: tuple[tuple[str, object, str], ...] = (
    (
        "table-gap detector, complete table",
        find_table_gaps,
        _TABLE + "| 第 41 条 x | a | b |\n| 第 42 条 y | a | b |\n| 第 43 条 z | a | b |\n",
    ),
    (
        "table-gap detector, prose that merely mentions a condition",
        find_table_gaps,
        _TABLE + "| 第 41 条 x | a | b |\n| 第 42 条 y | a | b |\n| 第 43 条 z | a | b |\n"
        + "\n本节另记第 44 条，与上表无关。\n",
    ),
)


def self_check() -> list[str]:
    """Prove each detector fires for the right reason, and stays quiet when it should."""
    inert: list[str] = []
    for name, detector, fixture, expected in _FIXTURES:
        found = detector(fixture)  # type: ignore[operator]
        if not found:
            inert.append(f"detector is inert, refusing to interpret results: {name}")
        elif not any(expected in problem for problem in found):
            inert.append(
                f"detector fired for the wrong reason, refusing to interpret "
                f"results: {name}, expected {expected!r} in {found}"
            )
    for name, detector, fixture in _CLEAN_FIXTURES:
        found = detector(fixture)  # type: ignore[operator]
        if found:
            inert.append(
                f"detector reports on a clean document, refusing to interpret "
                f"results: {name}, got {found}"
            )
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
        + find_table_gaps(text)
    )
    if problems:
        for problem in problems:
            print(f"error: {REPORT}: {problem}", file=sys.stderr)
        return 1

    print("teleprompter report: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
