from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[1]
_SCRIPT = _ROOT / "tools/scan_state_before_failure.py"

_spec = importlib.util.spec_from_file_location("scan_state_before_failure", _SCRIPT)
assert _spec is not None and _spec.loader is not None
_SCANNER = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = _SCANNER
_spec.loader.exec_module(_SCANNER)


def _scan(swift: str) -> list:
    return _SCANNER.scan_source(swift, Path("<test>"))


def test_the_scanner_proves_its_own_classification_rules() -> None:
    # Stage report section 2.52: a scanner was vacuously true on its own
    # output, so "zero hits" may only be cited once the classification is
    # proven non-vacuous first.
    assert _SCANNER.main(["--self-check"]) == 0


def test_a_state_write_before_a_throwing_call_without_a_catch_is_unprotected() -> None:
    findings = _scan(
        """
        func adopt() throws {
            phase = .ready
            try saveBundle()
        }
        """
    )
    assert [f.verdict for f in findings] == ["unprotected"]


def test_a_catch_only_marks_guarded_not_safe() -> None:
    # Defect 44's shape: the outer catch sets an error message but never
    # restores versions / document.updatedAt. A catch is present, so this is
    # guarded - but that verdict is not "safe"; see the tool's docs.
    findings = _scan(
        """
        func annotateActiveVersion() async -> String {
            versions[0] = note
            document.updatedAt = Date()
            do {
                try await saveBundle()
            } catch {
                return aiFailureMessage(for: error)
            }
        }
        """
    )
    assert [f.verdict for f in findings] == ["guarded"]


def test_local_variables_are_not_treated_as_state_writes() -> None:
    # The failing call sits on its own line: ordering is by line number, so
    # `sum = try add(sum)` on one line does not count (see tool boundaries).
    assert (
        _scan(
            """
            func total() throws {
                let base = 1
                var sum = base
                sum = base
                sum = try add(sum)
                return sum
            }
            """
        )
        == []
    )


def test_writes_in_comments_and_strings_do_not_create_candidates() -> None:
    # Comments and strings are blanked first; otherwise a comment saying
    # "try here" would create a false hit.
    hit = _scan(
        """
        func adopt() throws {
            // phase = .ready; try saveBundle()
            let message = "try saveBundle()"
            phase = .ready
            try saveBundle()
        }
        """
    )
    assert hit[0].verdict == "unprotected"
    # Only a try inside comments/strings, with no real write, yields no candidate.
    assert (
        _scan(
            """
            func describe() {
                // try saveBundle()
                let message = "phase = .ready"
            }
            """
        )
        == []
    )


def test_a_failure_before_any_write_is_not_reported() -> None:
    assert (
        _scan(
            """
            func load() throws -> Int {
                let value = try read()
                state = value
                return value
            }
            """
        )
        == []
    )


def test_a_defer_declared_before_the_writes_still_counts_as_guarded() -> None:
    # Regression lock: `defer` runs at scope exit no matter how early it is
    # written, so its position relative to the write must not matter. The first
    # version of the scanner required recovery to appear *after* the first write
    # and therefore misreported the real `useDeterministicFallback()` (whose
    # defer sits above the writes) as unprotected.
    findings = _scan(
        """
        func useDeterministicFallback() throws {
            let previous = phase
            var didPersist = false
            defer {
                if !didPersist { phase = previous }
            }
            phase = .ready
            try saveBundle()
            didPersist = true
        }
        """
    )
    assert [f.verdict for f in findings] == ["guarded"]


def test_writes_inside_a_defer_or_catch_are_the_rollback_not_the_risky_mutation() -> None:
    # Regression lock: assignments inside a defer/catch block are the recovery.
    # Counting them as writes inflated the first write into the defer body and
    # made the safety net look like it preceded the change it restores.
    #
    # The only assignments here live inside the defer/catch, so if they were
    # counted as the risky mutation the function would be reported - which is
    # exactly the false positive this test exists to prevent.
    assert (
        _scan(
            """
            func restoreOnExit() throws {
                let previous = phase
                defer {
                    phase = previous
                }
                try load()
            }
            """
        )
        == []
    )
    assert (
        _scan(
            """
            func restoreOnError() async {
                let previous = phase
                do {
                    try await load()
                } catch {
                    phase = previous
                    throw error
                }
            }
            """
        )
        == []
    )
