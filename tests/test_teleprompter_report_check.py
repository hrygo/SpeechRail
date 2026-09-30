from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

_SCRIPT = Path(__file__).resolve().parents[1] / "scripts/check_teleprompter_report.py"
_SPEC = importlib.util.spec_from_file_location("check_teleprompter_report", _SCRIPT)
assert _SPEC is not None and _SPEC.loader is not None
_TOOL = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = _TOOL
_SPEC.loader.exec_module(_TOOL)

find_claim_drift = _TOOL.find_claim_drift
find_ragged_tables = _TOOL.find_ragged_tables
find_replacement_chars = _TOOL.find_replacement_chars
find_table_gaps = _TOOL.find_table_gaps
main = _TOOL.main
self_check = _TOOL.self_check

REPORT = (
    Path(__file__).resolve().parents[1]
    / "docs/implementation/SpeechRail_AI_Teleprompter_Stage_Report_2026-09-28.md"
)

TABLE = "找出 3 个真缺陷（§2 第 41–43 条）\n\n### 4.3\n\n"


def test_the_report_satisfies_its_own_gate() -> None:
    assert main() == 0


def test_every_detector_proves_itself_before_it_is_trusted() -> None:
    assert self_check() == []


def test_a_replacement_character_is_reported_with_its_line() -> None:
    text = "clean line\n依据三条，\ufffd\ufffd一条\n"
    found = find_replacement_chars(text)
    assert len(found) == 1
    assert "line 2" in found[0]


def test_an_escaped_pipe_does_not_make_a_table_ragged() -> None:
    # `元\|个` is a literal pipe inside a cell; the row still has three columns.
    text = "| 变异 | 处置 |\n|---|---|\n| 表（`元\\|个`） | KILLED |\n"
    assert find_ragged_tables(text) == []


def test_an_unescaped_pipe_inside_a_cell_is_reported() -> None:
    text = "| 变异 | 处置 |\n|---|---|\n| 表（`元|个`） | KILLED |\n"
    found = find_ragged_tables(text)
    assert len(found) == 1
    assert "ragged" in found[0]


def test_a_count_that_contradicts_its_own_range_is_reported() -> None:
    # 41-76 spans 36, so claiming 37 drifts.
    assert find_claim_drift("找出 37 个真缺陷（§2 第 41–76 条）")
    assert find_claim_drift("找出 36 个真缺陷（§2 第 41–76 条）") == []


def test_a_condition_missing_from_the_table_is_reported() -> None:
    # The 4.3 table once shipped without 68, 69 and 70 while the header's own
    # arithmetic stayed self-consistent, so checking the claim against itself
    # passed. This is the check that notices the claim is not being honoured.
    text = TABLE + "| 第 41 条 x | a | b |\n| 第 43 条 z | a | b |\n"
    found = find_table_gaps(text)
    assert found == ["4.3 table is missing conditions [42]"]


def test_a_condition_row_outside_the_claimed_range_is_reported() -> None:
    text = (
        TABLE
        + "| 第 41 条 x | a | b |\n| 第 42 条 y | a | b |\n"
        + "| 第 43 条 z | a | b |\n| 第 44 条 w | a | b |\n"
    )
    assert find_table_gaps(text) == [
        "4.3 table has conditions outside the claimed range: [44]"
    ]


def test_a_duplicated_condition_row_is_reported() -> None:
    text = (
        TABLE
        + "| 第 41 条 x | a | b |\n| 第 41 条 again | a | b |\n"
        + "| 第 42 条 y | a | b |\n| 第 43 条 z | a | b |\n"
    )
    assert find_table_gaps(text) == ["4.3 table has duplicate condition rows"]


def test_a_table_with_one_row_per_condition_is_accepted() -> None:
    text = TABLE + "| 第 41 条 x | a | b |\n| 第 42 条 y | a | b |\n| 第 43 条 z | a | b |\n"
    assert find_table_gaps(text) == []


def test_prose_mentioning_a_condition_is_not_counted_as_a_row() -> None:
    # The range is a table claim; a section that discusses 第 44 条 must not
    # read as the table carrying it, or the check would be silenced by prose.
    text = (
        TABLE
        + "| 第 41 条 x | a | b |\n| 第 42 条 y | a | b |\n| 第 43 条 z | a | b |\n"
        + "\n本节另记第 44 条，与上表无关。\n"
    )
    assert find_table_gaps(text) == []


def test_the_gate_refuses_a_detector_that_fires_for_the_wrong_reason() -> None:
    # A detector that always complains about something else satisfies "did it
    # fire?", so each fixture names the message it must produce. The first
    # table-gap fixture shipped without a claim line and passed for exactly
    # that reason -- it proved the function was non-empty, not that it works.
    original_bad = _TOOL._FIXTURES
    original_clean = _TOOL._CLEAN_FIXTURES
    try:
        _TOOL._FIXTURES = (
            (
                "table-gap detector, missing row",
                find_table_gaps,
                TABLE + "| 第 41 条 x | a | b |\n| 第 43 条 z | a | b |\n",
                "cannot locate the 4.3 section",
            ),
        )
        _TOOL._CLEAN_FIXTURES = ()
        assert _TOOL.main() == 2
    finally:
        _TOOL._FIXTURES = original_bad
        _TOOL._CLEAN_FIXTURES = original_clean


def test_the_gate_refuses_a_detector_that_complains_about_clean_input() -> None:
    original_bad = _TOOL._FIXTURES
    original_clean = _TOOL._CLEAN_FIXTURES
    try:
        _TOOL._FIXTURES = (
            (
                "table-gap detector, missing row",
                find_table_gaps,
                TABLE + "| 第 41 条 x | a | b |\n| 第 43 条 z | a | b |\n",
                "missing conditions [42]",
            ),
        )
        _TOOL._CLEAN_FIXTURES = (
            (
                "table-gap detector, complete table",
                lambda text: ["4.3 table is missing conditions [42]"],
                TABLE + "| 第 41 条 x | a | b |\n",
            ),
        )
        assert _TOOL.main() == 2
    finally:
        _TOOL._FIXTURES = original_bad
        _TOOL._CLEAN_FIXTURES = original_clean


def test_the_gate_fails_when_a_detector_goes_inert() -> None:
    # The self-check is the whole point: a checker that silently stops detecting
    # must not be able to report "ok" about the report.
    original_bad = _TOOL._FIXTURES
    original_clean = _TOOL._CLEAN_FIXTURES
    try:
        _TOOL._FIXTURES = (
            (
                "bogus detector",
                find_claim_drift,
                "找出 36 个真缺陷（第 41–76 条）\n",
                "36",
            ),
        )
        _TOOL._CLEAN_FIXTURES = ()
        assert _TOOL.main() == 2
    finally:
        _TOOL._FIXTURES = original_bad
        _TOOL._CLEAN_FIXTURES = original_clean


def test_the_report_really_has_no_replacement_characters() -> None:
    # Guards the premise of the gate above: if this ever fails, the gate is
    # reporting on a file that was already broken before the gate existed.
    assert find_replacement_chars(REPORT.read_text(encoding="utf-8")) == []
