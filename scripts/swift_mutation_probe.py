#!/usr/bin/env python3
"""Run directed mutations against the Swift package and report what caught them.

Section 5 item 10 of the teleprompter stage report asks for this tool. The
report also records why it did not exist yet: three rounds of mutation
evidence lived only in ``/tmp`` and in prose, so the next team could read the
conclusions and not the method. Three failure modes were paid for along the
way, and each one is a rule this script enforces rather than a habit:

* **Matching one framework's failure marker is not enough.** swift-testing
  prints a crossed-out ``Test ... failed``; XCTest prints ``Test Case '...'``
  with a ``failed`` verdict. A probe that watches only the first reports every
  XCTest-killed mutation as a survivor. Both are counted here, and the test
  tally counts both too, so a filter that silently stops running an entire
  framework becomes visible instead of turning into false survivors.
* **A mutation that does not compile proves nothing.** Comments can swallow
  the guard that follows them, and the resulting source does not build. Every
  mutation is compiled before it is run; a build failure is reported as
  INVALID and is never counted as killed.
* **A probe that did not run marks everything as killed.** One round recorded
  six "kills" that were really a missing test dependency: the runner exited
  non-zero on ``module not found`` each time. So the baseline must be green
  and must actually run tests, and a mutation declared in the spec as
  ``sanity`` must be caught. If either fails this script exits 2 and refuses
  to interpret any mutation.

The probe never restores a file with ``git checkout``. It holds the original
bytes, writes them back, and then asserts that ``git status`` for the touched
paths is exactly what it was before the run, so a concurrent edit is reported
instead of silently reverted.

Usage:
  uv run python scripts/swift_mutation_probe.py scripts/teleprompter_swift_mutations.json
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]

# swift-testing and XCTest report failures in different shapes. Both are
# required: watching one of them turns the other's kills into survivors.
_SWIFT_TESTING_FAILED = re.compile("^✘ Test .* failed", re.MULTILINE)
_SWIFT_TESTING_PASSED = re.compile("^✔ Test .* passed", re.MULTILINE)
_XCTEST_FAILED = re.compile("^Test Case '.*' failed", re.MULTILINE)
_XCTEST_PASSED = re.compile("^Test Case '.*' passed", re.MULTILINE)
_COMPILE_ERROR = re.compile(r"^(?:.*:\d+:\d+: )?error: ", re.MULTILINE)
# A trap inside the test process is not a build failure, but its report line
# reads `... exited with unexpected signal code 5`, and `_COMPILE_ERROR`
# matches the `error: ` inside it. Checking the build is `_measure`'s job --
# `compiles()` already refuses to run tests at all when the build fails -- so
# a crash reaching `classify` has to be recognised before the compile rule
# gets to mislabel it "does not compile". Round 59: M38 was recorded with the
# right verdict and the wrong reason, and the reason is what tells a reader
# whether the guard the mutation removed is being exercised at all.
_TEST_CRASH = re.compile(
    r"Fatal error:|exited with unexpected signal code|Trace/BPT trap"
)
# swift-testing closes with a summary line -- "Test run with 322 tests in 16
# suites passed" -- that the pattern above also matches. It is a total, not a
# test, and counting it inflates every tally in the report by one per run.
_SWIFT_TESTING_SUMMARY = re.compile("^✔ Test run with ", re.MULTILINE)

KILLED = "KILLED"
SURVIVED = "SURVIVED"
INVALID = "INVALID"


@dataclass(frozen=True)
class Verdict:
    status: str
    detail: str
    passed: int
    failed: int


@dataclass(frozen=True)
class Mutation:
    identifier: str
    file: str
    find: str
    replace: str
    test_filter: str
    note: str
    declared: str
    rationale: str


def _run(command: list[str], cwd: Path) -> tuple[int, str]:
    completed = subprocess.run(
        command, cwd=cwd, capture_output=True, text=True, check=False
    )
    return completed.returncode, completed.stdout + completed.stderr


def classify(exit_code: int, output: str) -> Verdict:
    """Turn one test run into a verdict without guessing.

    The tally is a count of output lines, not of tests, and it is *not* bounded
    by the number of tests in the suite: a run that kills N tests reports
    `passed + N + 5` against a baseline of `passed`. The constant 5 shows up on
    every observed run here, including the sanity mutation, so `passed + failed
    <= baseline` is not a valid invariant and an earlier attempt to enforce it
    refused the sanity kill. What the numbers *can* be used for is the
    pass/fail split itself; the absolute total is context, not a bound.
    """
    tallied = _SWIFT_TESTING_SUMMARY.sub("", output)
    passed = len(_SWIFT_TESTING_PASSED.findall(tallied)) + len(
        _XCTEST_PASSED.findall(tallied)
    )
    failed = len(_SWIFT_TESTING_FAILED.findall(output)) + len(
        _XCTEST_FAILED.findall(output)
    )
    if _TEST_CRASH.search(output):
        # Checked before the failure tally on purpose: a run that dies partway
        # never reached the tests after it, so its failures are not evidence
        # that anything was caught. The count is kept in the detail so nothing
        # is lost.
        return Verdict(
            INVALID,
            f"test process crashed after {failed} failing",
            passed,
            failed,
        )
    if _COMPILE_ERROR.search(output):
        return Verdict(INVALID, "does not compile", passed, failed)
    if passed == 0 and failed == 0:
        # The round-33 failure mode: the runner never reached a test, so a
        # non-zero exit says nothing about coverage.
        return Verdict(INVALID, "no test ran", passed, failed)
    if failed > 0:
        return Verdict(KILLED, f"{failed} failing", passed, failed)
    if exit_code != 0:
        return Verdict(INVALID, f"exit {exit_code} with no failure line", passed, failed)
    return Verdict(SURVIVED, "all green", passed, failed)


_CLASSIFY_FIXTURES: tuple[tuple[str, int, str, str, str, int, int], ...] = (
    (
        "swift-testing failure",
        1,
        "\u2718 Test anOutOfRangeStablePrefixPausesInsteadOfAligningUnrevisedText() "
        "failed after 0.011 seconds with 4 issues.\n"
        "\u2714 Test run with 38 tests in 2 suites failed after 1.5 seconds.\n",
        KILLED,
        "failing",
        0,
        1,
    ),
    (
        # The round-27 lesson: XCTest announces a kill in a completely
        # different shape, and a probe that only watches the first marker
        # calls this one a survivor.
        "XCTest failure",
        1,
        "Test Case '-[SpeechRailMacControlTests ReplayTest advances]' "
        "failed (0.001 seconds).\n"
        "Executed 1 test, with 1 failure (0 unexpected) in 0.001 seconds.\n",
        KILLED,
        "failing",
        0,
        1,
    ),
    (
        # The round-33 lesson: the runner never reached a test, so its
        # non-zero exit carries no information about coverage.
        "runner never started",
        1,
        "No module named 'pytest'\n",
        INVALID,
        "no test ran",
        0,
        0,
    ),
    (
        "comment swallowed the guard",
        1,
        "TeleprompterFollowController.swift:238:40: error: consecutive "
        "statements on a line must be separated by ';'\n",
        INVALID,
        "does not compile",
        0,
        0,
    ),
    (
        "clean run",
        0,
        "\u2714 Test three() passed after 0.1 seconds.\n"
        "\u2714 Test run with 38 tests in 2 suites passed after 0.5 seconds.\n",
        SURVIVED,
        "all green",
        1,
        0,
    ),
    (
        "non-zero exit with no failure line",
        1,
        "\u2714 Test three() passed after 0.1 seconds.\n"
        "\u2714 Test run with 38 tests in 2 suites passed after 0.5 seconds.\n"
        "Fatal error: Unexpectedly found nil\n",
        INVALID,
        "crashed",
        1,
        0,
    ),
    (
        # The round-59 lesson: this run is genuinely invalid, but the reason
        # the probe used to record was "does not compile" -- the crash report
        # reads `... error: Process '...' exited with unexpected signal code
        # 5`, and the compile-error regex matched the `error: ` inside it.
        "test process crashes partway through",
        1,
        "\u2718 Test groupingRejects() failed after 0.011 seconds with 1 issue.\n"
        "\u2718 Test run with 4 tests in 1 suite failed after 0.2 seconds.\n"
        "Swift/ContiguousArrayBuffer.swift:695: Fatal error: Index out of range\n"
        "\u2718 result.fallbackBlockCountererror: Process 'swiftpm-testing-helper' "
        "exited with unexpected signal code 5\n",
        INVALID,
        "crashed after 2 failing",
        0,
        2,
    ),
    (
        # The other half of the same lesson: a failure message that happens to
        # contain `error: ` is still a kill. Without the crash rule ordered
        # first this run is reported INVALID, and a real kill is lost.
        "failure text containing the word error",
        1,
        "\u2718 Test rejectsABadPayload() failed after 0.011 seconds with 1 issue.\n"
        "  error: unexpected schema_version in the grouping response\n"
        "\u2718 Test run with 4 tests in 1 suite failed after 0.2 seconds.\n",
        KILLED,
        "failing",
        0,
        2,
    ),
)


def self_check() -> list[str]:
    """Prove each classification rule fires on its own fixture first.

    A probe is the one tool whose own failure silently turns every result into
    the answer the author wanted, so its rules are pinned the same way the
    report gate's are: each fixture names the verdict and the detail it must
    produce, and every fixture carries a non-empty tally so the "no test ran"
    rule cannot be satisfied by a run that did nothing.
    """
    problems: list[str] = []
    for name, exit_code, output, expected, detail, passed, failed in _CLASSIFY_FIXTURES:
        verdict = classify(exit_code, output)
        if verdict.status != expected:
            problems.append(
                f"classification rule disagrees with its fixture: {name}, "
                f"expected {expected} got {verdict.status}"
            )
        elif detail not in verdict.detail:
            problems.append(
                f"classification rule fired for the wrong reason: {name}, "
                f"expected {detail!r} in {verdict.detail!r}"
            )
        elif (verdict.passed, verdict.failed) != (passed, failed):
            # The tally decides what a survivor means, so an off-by-one here
            # is as load-bearing as a wrong status.
            problems.append(
                f"classification rule miscounts its fixture: {name}, "
                f"expected {passed} passed / {failed} failed, got "
                f"{verdict.passed} / {verdict.failed}"
            )
    return problems


def unexplained_invalid(verdicts: list[tuple[Mutation, Verdict]]) -> list[str]:
    """Names the INVALID results the spec did not predict.

    Removing a bounds guard can abort the whole test process rather than fail
    an assertion. The probe is right to refuse to call that a clean kill, but
    a spec that declared the outcome in advance has recorded a known property
    of that mutation, not a defect in the probe -- so only the *undeclared*
    ones fail the run.
    """
    return [
        mutation.identifier
        for mutation, verdict in verdicts
        if verdict.status == INVALID and mutation.declared != INVALID
    ]


def compiles(package: Path) -> tuple[bool, str]:
    code, output = _run(["swift", "build", "--build-tests"], cwd=package)
    return code == 0 and not _COMPILE_ERROR.search(output), output


def run_tests(package: Path, test_filter: str) -> Verdict:
    # An empty filter means the whole package. A narrow filter that happens to
    # exclude every test touching the mutated symbol reports a survivor that
    # means nothing, so widening to everything is a routine part of asking
    # why a mutation survived.
    command = ["swift", "test"]
    if test_filter:
        command += ["--filter", test_filter]
    code, output = _run(command, cwd=package)
    return classify(code, output)


def _status_of(paths: list[Path]) -> str:
    """Snapshot git's view of the touched paths so parallel edits stay visible."""
    completed = subprocess.run(
        ["git", "status", "--porcelain", "--", *[str(p) for p in paths]],
        cwd=REPOSITORY_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    return completed.stdout


def _load(spec_path: Path) -> tuple[Path, Mutation, list[Mutation]]:
    spec = json.loads(spec_path.read_text(encoding="utf-8"))
    package = REPOSITORY_ROOT / spec.get("package", "macos/SpeechRailApp")

    def build(entry: dict, default_filter: str) -> Mutation:
        return Mutation(
            identifier=str(entry["id"]),
            file=str(entry["file"]),
            find=str(entry["find"]),
            replace=str(entry["replace"]),
            test_filter=str(entry.get("filter", default_filter)),
            note=str(entry.get("note", "")),
            declared=str(entry.get("expect", "")),
            rationale=str(entry.get("rationale", "")),
        )

    default_filter = str(spec.get("filter", ""))
    sanity = build(spec["sanity"], default_filter)
    mutations = [build(entry, default_filter) for entry in spec["mutations"]]
    return package, sanity, mutations


def _measure(mutation: Mutation, package: Path, originals: dict[str, str]) -> Verdict:
    path = REPOSITORY_ROOT / mutation.file
    original = originals[mutation.file]
    occurrences = original.count(mutation.find)
    if occurrences != 1:
        raise SystemExit(
            f"error: {mutation.identifier}: anchor appears {occurrences} times in "
            f"{mutation.file}, expected exactly 1"
        )
    path.write_text(original.replace(mutation.find, mutation.replace), encoding="utf-8")
    try:
        ok, build_output = compiles(package)
        if not ok:
            first = next(
                (line for line in build_output.splitlines() if "error:" in line),
                "build failed",
            )
            return Verdict(INVALID, f"does not compile: {first.strip()}", 0, 0)
        return run_tests(package, mutation.test_filter)
    finally:
        path.write_text(original, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Swift mutation probe")
    parser.add_argument("spec", type=Path, help="JSON mutation spec")
    arguments = parser.parse_args()

    problems = self_check()
    if problems:
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        return 2

    package, sanity, mutations = _load(arguments.spec)
    if not package.is_dir():
        print(f"error: missing package: {package}", file=sys.stderr)
        return 1

    everything = [sanity, *mutations]
    originals = {
        m.file: (REPOSITORY_ROOT / m.file).read_text(encoding="utf-8")
        for m in everything
    }
    paths = sorted((REPOSITORY_ROOT / m.file).resolve() for m in everything)
    before = _status_of(paths)

    # Baseline: green, and actually running tests. Both matter -- see the
    # module docstring for what a non-zero exit without a test run cost once.
    for test_filter in sorted({m.test_filter for m in everything}):
        ok, build_output = compiles(package)
        if not ok:
            print("error: the package does not build as committed", file=sys.stderr)
            print(build_output, file=sys.stderr)
            return 2
        baseline = run_tests(package, test_filter)
        if baseline.status != SURVIVED or baseline.passed == 0:
            print(
                f"error: baseline for filter {test_filter!r} is not a clean run "
                f"({baseline.status}: {baseline.detail}, {baseline.passed} passed); "
                f"refusing to interpret any mutation",
                file=sys.stderr,
            )
            return 2
        print(f"baseline ok: {test_filter} -> {baseline.passed} passed")

    started = time.monotonic()
    sanity_verdict = _measure(sanity, package, originals)
    if sanity_verdict.status != KILLED:
        print(
            f"error: the sanity mutation {sanity.identifier} was not caught "
            f"({sanity_verdict.status}: {sanity_verdict.detail}); this probe "
            f"cannot tell kills from noise, refusing to interpret any mutation",
            file=sys.stderr,
        )
        return 2
    print(
        f"sanity ok: {sanity.identifier} caught by {sanity_verdict.failed} "
        f"failing test(s) alongside {sanity_verdict.passed} passing"
    )

    verdicts: list[tuple[Mutation, Verdict]] = []
    for index, mutation in enumerate(mutations, start=1):
        print(f"[{index}/{len(mutations)}] {mutation.identifier} ...", flush=True)
        verdict = _measure(mutation, package, originals)
        verdicts.append((mutation, verdict))
        print(
            f"    {verdict.status}: {verdict.detail} "
            f"({verdict.passed} passed, {verdict.failed} failed)"
        )

    after = _status_of(paths)
    if after != before:
        print(
            "error: the working tree changed under the probe. The touched files "
            "were restored from memory, so this is a concurrent edit, not "
            "something the probe did:",
            file=sys.stderr,
        )
        print(f"before:\n{before}\nafter:\n{after}", file=sys.stderr)
        return 2

    print()
    print("| 变异 | 处置 | 通过 | 失败 | 查因 |")
    print("| --- | --- | --- | --- | --- |")
    contradictions: list[str] = []
    for mutation, verdict in verdicts:
        label = f"{mutation.identifier} {mutation.note}".strip()
        if mutation.declared and verdict.status != mutation.declared:
            contradictions.append(
                f"{mutation.identifier}: declared {mutation.declared}, observed "
                f"{verdict.status}"
            )
        print(
            f"| {label} | {verdict.status} | {verdict.passed} | {verdict.failed} "
            f"| {mutation.rationale} |"
        )
    print(
        f"\n{len(verdicts)} mutations in {time.monotonic() - started:.0f}s",
        file=sys.stderr,
    )

    invalid = unexplained_invalid(verdicts)
    if invalid:
        print(
            f"error: {len(invalid)} mutation(s) are INVALID and prove nothing: "
            + ", ".join(invalid),
            file=sys.stderr,
        )
        return 1
    if contradictions:
        # A survivor that was investigated and written down must keep matching
        # what was written, otherwise the record is stale the moment coverage
        # improves -- which is the same failure as an undocumented survivor.
        print(
            "error: a mutation no longer behaves the way the spec declares:",
            file=sys.stderr,
        )
        for contradiction in contradictions:
            print(f"  {contradiction}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
