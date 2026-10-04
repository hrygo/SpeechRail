"""The macOS test-manifest parity checker must fail on the drift it claims to catch."""

from __future__ import annotations

import importlib.util
from pathlib import Path


def _checker() -> object:
    script_path = Path(__file__).parents[1] / "scripts" / "check_macos_test_target_coverage.py"
    spec = importlib.util.spec_from_file_location(
        "check_macos_test_target_coverage",
        script_path,
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_both_manifests_agree_today() -> None:
    """The real SwiftPM manifest and the real Xcode phase describe one suite."""

    module = _checker()
    assert module.find_drift() == []  # type: ignore[attr-defined]


def test_a_test_file_dropping_out_of_the_xcode_phase_is_reported() -> None:
    """The exact drift #194 describes: on disk, absent from Unit Test Sources."""

    module = _checker()
    problems = module.find_drift(  # type: ignore[attr-defined]
        package_body='.testTarget(name: "X", path: "Y")',
        compiled_tests={"AlreadyThere.swift"},
        on_disk={"AlreadyThere.swift", "QuietlyDropped.swift"},
        allowlist={},
    )
    assert any("QuietlyDropped.swift" in problem for problem in problems), problems
    assert not any("AlreadyThere.swift" in problem for problem in problems), problems


def test_a_deleted_test_file_left_in_the_xcode_phase_is_reported() -> None:
    """The other direction: the Xcode project would not build."""

    module = _checker()
    problems = module.find_drift(  # type: ignore[attr-defined]
        package_body='.testTarget(name: "X", path: "Y")',
        compiled_tests={"StillHere.swift", "RemovedLongAgo.swift"},
        on_disk={"StillHere.swift"},
        allowlist={},
    )
    assert any("RemovedLongAgo.swift" in problem for problem in problems), problems


def test_an_allowlist_entry_must_name_the_issue_that_unblocks_it() -> None:
    """An exemption without a reason is just a silent hole."""

    module = _checker()
    problems = module.find_drift(  # type: ignore[attr-defined]
        package_body='.testTarget(name: "X", path: "Y")',
        compiled_tests=set(),
        on_disk={"Blocked.swift"},
        allowlist={"Blocked.swift": "because"},
    )
    assert any("must name the issue" in problem for problem in problems), problems
    assert not any("does not compile it" in problem for problem in problems), problems


def test_an_allowlist_entry_cannot_outlive_its_reason() -> None:
    """Once the file is gone, the exemption has to go with it."""

    module = _checker()
    problems = module.find_drift(  # type: ignore[attr-defined]
        package_body='.testTarget(name: "X", path: "Y")',
        compiled_tests=set(),
        on_disk=set(),
        allowlist={"LongGone.swift": "#194"},
    )
    assert any("outlive its reason" in problem for problem in problems), problems


def test_narrowing_the_swiftpm_target_stops_the_checker_claiming_equivalence() -> None:
    """`swift test` is only "every file on disk" while the target is un-narrowed."""

    module = _checker()
    problems = module.find_drift(  # type: ignore[attr-defined]
        package_body='.testTarget(name: "X", exclude: ["Y.swift"])',
        compiled_tests=set(),
        on_disk=set(),
        allowlist={},
    )
    assert any("narrows" in problem for problem in problems), problems
