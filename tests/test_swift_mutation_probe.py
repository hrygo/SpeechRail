from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[1]
_SCRIPT = _ROOT / "scripts/swift_mutation_probe.py"
_SPEC = _ROOT / "scripts/teleprompter_swift_mutations.json"

_spec = importlib.util.spec_from_file_location("swift_mutation_probe", _SCRIPT)
assert _spec is not None and _spec.loader is not None
_PROBE = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = _PROBE
_spec.loader.exec_module(_PROBE)

MUTATIONS = json.loads(_SPEC.read_text(encoding="utf-8"))["mutations"]
SANITY = json.loads(_SPEC.read_text(encoding="utf-8"))["sanity"]


def test_the_probe_proves_its_own_classification_rules() -> None:
    assert _PROBE.self_check() == []


def test_an_xctest_only_failure_counts_as_a_kill() -> None:
    # The round-27 lesson, pinned directly: swift-testing and XCTest announce a
    # kill in different shapes, and a probe that watches only the first reports
    # every XCTest-killed mutation as a survivor.
    xctest = (
        "Test Case '-[SpeechRailMacControlTests ReplayTest advances]' "
        "failed (0.001 seconds).\n"
    )
    swift_testing = "✘ Test advances() failed after 0.001 seconds with 1 issue.\n"
    assert _PROBE.classify(1, xctest).status == _PROBE.KILLED
    assert _PROBE.classify(1, swift_testing).status == _PROBE.KILLED


def test_a_run_that_never_reached_a_test_is_not_a_kill() -> None:
    # The round-33 failure mode: a missing dependency made every run exit
    # non-zero, and six mutations were recorded as "killed" for it.
    assert _PROBE.classify(1, "No module named 'pytest'\n").status == _PROBE.INVALID


def test_the_summary_line_is_not_counted_as_a_test() -> None:
    # swift-testing closes with a total that the failure pattern also matches;
    # counting it inflated every tally in the report by one per run.
    output = (
        "✔ Test a() passed after 0.1 seconds.\n"
        "✔ Test run with 322 tests in 16 suites passed after 0.9 seconds.\n"
    )
    assert _PROBE.classify(0, output).passed == 1


def test_every_mutation_anchor_still_identifies_exactly_one_place() -> None:
    # A refactor that makes an anchor ambiguous would otherwise surface as a
    # runtime abort the first time somebody runs the probe. Failing here says
    # "update the spec" at the point where the code changed.
    for entry in [SANITY, *MUTATIONS]:
        source = (_ROOT / entry["file"]).read_text(encoding="utf-8")
        occurrences = source.count(entry["find"])
        assert occurrences == 1, f"{entry['id']}: anchor matched {occurrences} times"


def test_a_declared_survivor_carries_its_reason() -> None:
    # A survivor that was investigated has to say so in the spec, or the next
    # reader cannot tell it apart from a coverage gap nobody looked at.
    for entry in MUTATIONS:
        assert entry.get("expect"), f"{entry['id']}: no declared outcome"
        if entry["expect"] == _PROBE.SURVIVED:
            assert len(entry.get("rationale", "")) > 40, (
                f"{entry['id']}: declared survivor without a reason"
            )
