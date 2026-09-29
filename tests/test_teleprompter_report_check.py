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
main = _TOOL.main
self_check = _TOOL.self_check

REPORT = (
    Path(__file__).resolve().parents[1]
    / "docs/implementation/SpeechRail_AI_Teleprompter_Stage_Report_2026-09-28.md"
)


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


def test_the_gate_fails_when_a_detector_goes_inert() -> None:
    # The self-check is the whole point: a checker that silently stops detecting
    # must not be able to report "ok" about the report.
    original = _TOOL._FIXTURES
    try:
        _TOOL._FIXTURES = (
            ("bogus detector", find_claim_drift, "找出 36 个真缺陷（第 41–76 条）\n"),
        )
        assert _TOOL.main() == 2
    finally:
        _TOOL._FIXTURES = original


def test_the_report_really_has_no_replacement_characters() -> None:
    # Guards the premise of the gate above: if this ever fails, the gate is
    # reporting on a file that was already broken before the gate existed.
    assert find_replacement_chars(REPORT.read_text(encoding="utf-8")) == []
