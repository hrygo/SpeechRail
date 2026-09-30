"""List Swift functions that mutate state before a point that can fail.

Why
===
41 of the 50 real defects found in the AI-teleprompter stage report share one
shape: **state is written first, a failure can happen later, and the failure
path does not put the state back.** The earliest candidate for that shape was
found by a one-off static scan (stage report defect 43): it hit 12 sites, and
reading the source one by one left 11 false positives or already-rolled-back
cases plus exactly one real defect - the heaviest one at the time. That scan
never made it into the repository. This script is its reusable form (issue
#121).

What it reports
===============
For every Swift function body it relates state writes to points that can fail,
and classifies the functions where both are present:

``unprotected``
    State is written, a ``try``/``throw``/``guard ... else`` follows, and no
    ``catch`` or ``defer`` appears after it. **No safety net at all: read these
    first.**
``guarded``
    State is written, a failure point follows, but a ``catch`` or ``defer``
    appears on the failure path. **This does not mean it is safe.** Defect 44
    died right here: the outer ``catch`` set an error message but never restored
    ``versions`` and ``document.updatedAt``, so the reader was told "the AI
    failed" while the new annotations stayed in memory and would be written to
    disk on the next unrelated save. A recovery construct only means the author
    thought about it; whether the rollback is complete, and whether it restores
    the right fields, is a human judgement. **Both verdicts need review.**
``none``
    No state write, or every failure point precedes any write. Not reported.

Usage
=====
  tools/scan_state_before_failure.py macos/SpeechRailApp/SpeechRailApp
  tools/scan_state_before_failure.py --self-check
  tools/scan_state_before_failure.py --fail-on-unprotected <path>

Boundaries (cite these together with any result)
================================================
**Output is candidates, not conclusions.** This is a text ruler, not a type
checker:

- Function bodies are split by brace matching, without full parsing, so
  closures, nested functions, or braces inside literals can misalign the split
  (comments and string literals are blanked first; see ``_strip``).
- A state write is an assignment, with names declared ``let``/``var``/``if let``
  inside the function excluded. Writes through computed properties, closure
  capture, or indirect setters are not seen.
- Ordering is decided by **line number**. An assignment that carries the failing
  call on the same line, ``sum = try add(sum)``, does not count as "failure after
  the write"; put the failing call on its own line to have it considered.
- **Zero hits does not mean clean.** The stage report (section 2.52) records a
  case where a scanner was vacuously true on its own output. ``--self-check``
  therefore proves the classification is not vacuous on five built-in snippets;
  only after that passes may "no hits" be cited for a scope.
- **Neither verdict means "safe."** ``guarded`` only records that a
  ``catch``/``defer`` appears. Defect 44 shows "has a catch" and "rolls back
  fully" are different things, so this script does not offer, or pretend to
  offer, an "excluded" conclusion.

Known false-positive classes (seen when run on the fixed TeleprompterSession.swift,
each one read and excluded - an exclusion is a conclusion, stage report section 2.51):

- ``guard ... else { return }`` used as a *precondition* before any risky write, or
  in a branch that is mutually exclusive with the writes (e.g. a reset branch
  followed by an unrelated guard). Not a rollback concern.
- ``try?`` inside a per-item closure (``compactMap``/``map``) that merely skips one
  item; the earlier write is unrelated to that item's success.
- A pure "replace all state from input" function (e.g. applying a freshly-loaded
  bundle): many assignments, no fallible operation after a partial write.
- Writing an error/block reason on an early-return branch - writing the block IS
  the intended behavior, not a half-applied change.

After the ``guard let self`` exclusion, running on the fully-repaired
TeleprompterSession.swift yields 6 ``unprotected`` hits, all six of which fall
into the classes above; the three historically heaviest sites (defects 43/44 and
useDeterministicFallback) are correctly reported as ``guarded``.

This script is **not part of regular CI** (like mutation verification: it yields
a candidate list, not a verdict).
"""

from __future__ import annotations

import argparse
import dataclasses
import pathlib
import re
import sys

# Assignment: not the '=' inside ==, !=, <=, >=, nor a compound assign.
_ASSIGNMENT = re.compile(
    r"(?<![\w.])((?:self\.)?[A-Za-z_][A-Za-z0-9_]*"
    r"(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\s*(?:[+\-*/|&^]?=)(?!=)"
)

# Points that can fail. try?/try! come before try so plain `try` cannot
# match them first.
_FAILURE = re.compile(r"\b(?:try!|try\?|try|throw|guard\b)")

# `guard let self else { return }` is idiomatic weak-self capture inside a Task
# or closure; it is not a failure that should roll anything back. This codebase
# uses it in nearly every async entry point, so counting it produced mostly
# noise.
_SELF_GUARD = re.compile(r"\bguard\s+let\s+self\b")

# Recovery constructs on a failure path.
_RECOVERY = re.compile(r"\b(?:catch|defer)\b")

# Names declared inside the function: assignments to these are not state writes.
_LOCAL_DECL = re.compile(r"\b(?:let|var)\s+(?:mutating\s+)?([A-Za-z_][A-Za-z0-9_]*)")
_GUARD_LET = re.compile(r"\b(?:if|guard)\s+let\s+([A-Za-z_][A-Za-z0-9_]*)")
_FOR_IN = re.compile(r"\bfor\s+(?:let\s+|var\s+)?([A-Za-z_][A-Za-z0-9_]*)\s+in\b")
_CATCH_LET = re.compile(r"\bcatch\s+let\s+([A-Za-z_][A-Za-z0-9_]*)")

_FUNC = re.compile(
    r"(?m)^[ \t]*(?:@[A-Za-z_][\w.]*\s+)*"
    r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|open\s+)?"
    r"(?:static\s+|class\s+|final\s+|mutating\s+|nonmutating\s+)*"
    r"func\s+([A-Za-z_][A-Za-z0-9_]*)"
)


@dataclasses.dataclass(frozen=True)
class Finding:
    """One function whose body writes state before something that can fail."""

    path: pathlib.Path
    line: int
    function: str
    verdict: str
    writes: tuple
    failures: tuple
    recovery: tuple


def _strip(source):
    """Blank out comments and string literals, preserving offsets and newlines.

    Without this, reporting by line number is impossible: a comment saying
    'try here' would create a hit. Offsets and newlines are preserved, so line
    numbers still refer to the original file.
    """
    out = list(source)
    i = 0
    n = len(source)
    while i < n:
        ch = source[i]
        if ch == "/" and i + 1 < n and source[i + 1] == "/":
            while i < n and source[i] != "\n":
                out[i] = " "
                i += 1
        elif ch == "/" and i + 1 < n and source[i + 1] == "*":
            depth = 1
            out[i] = out[i + 1] = " "
            i += 2
            while i < n and depth:
                if source.startswith("/*", i):
                    depth += 1
                    out[i] = out[i + 1] = " "
                    i += 2
                elif source.startswith("*/", i):
                    depth -= 1
                    out[i] = out[i + 1] = " "
                    i += 2
                else:
                    if source[i] != "\n":
                        out[i] = " "
                    i += 1
        elif ch == '"':
            triple = source.startswith('"""', i)
            quote = '"""' if triple else '"'
            j = i + len(quote)
            while j < n:
                if source[j] == "\\":
                    j += 2
                    continue
                if source.startswith(quote, j):
                    j += len(quote)
                    break
                j += 1
            for k in range(i, min(j, n)):
                if source[k] != "\n":
                    out[k] = " "
            i = j
        else:
            i += 1
    return "".join(out)


def _line_of(source, offset):
    return source.count("\n", 0, offset) + 1


def _function_bodies(source):
    """Return ``(name, start_offset, body)`` for each brace-balanced function."""
    results = []
    for match in _FUNC.finditer(source):
        brace = source.find("{", match.end())
        if brace == -1:
            continue
        depth = 0
        i = brace
        n = len(source)
        while i < n:
            if source[i] == "{":
                depth += 1
            elif source[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        results.append((match.group(1), match.start(), source[brace : i + 1]))
    return results


def _locals(body):
    names = set()
    for pattern in (_LOCAL_DECL, _GUARD_LET, _FOR_IN, _CATCH_LET):
        names.update(pattern.findall(body))
    return names


def _recovery_spans(body):
    """Brace-matched spans of ``defer``/``catch`` blocks inside one function body.

    Assignments inside these blocks are the *recovery* (the rollback), not the
    risky mutation. Counting them as writes would both inflate the first write
    and make the ``defer`` keyword look like it precedes the write it actually
    restores - which is how an already-fixed function gets misreported.
    """
    spans = []
    for keyword in ("defer", "catch"):
        for match in re.finditer(r"\b" + keyword + r"\b", body):
            brace = body.find("{", match.end())
            # `defer`/`catch` without a brace (e.g. `catch {` always has one, but
            # a bare `defer` followed by newline+code) - skip when absent.
            if brace == -1 or body[match.end() : brace].strip():
                continue
            depth = 0
            i = brace
            while i < len(body):
                if body[i] == "{":
                    depth += 1
                elif body[i] == "}":
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            spans.append((match.start(), i + 1))
    return spans


def _in_spans(offset, spans):
    return any(start <= offset < end for start, end in spans)


def scan_source(source, path):
    """Classify every function in one Swift file."""
    cleaned = _strip(source)
    findings = []
    for name, start, body in _function_bodies(cleaned):
        locals_ = _locals(body)
        recovery_spans = _recovery_spans(body)

        writes = []
        for match in _ASSIGNMENT.finditer(body):
            target = match.group(1)
            # The base of a dotted path decides ownership: `document.title = x`
            # writes through `document`, so a local `document` makes it a local
            # write. Using the last component instead would call every field
            # assignment a state write (that is what flagged saveBundle()).
            root = target.split(".")[0]
            if root in locals_:
                continue
            # A write inside a defer/catch block is the rollback, not the risky
            # mutation; it must not count as "state changed before failure".
            if _in_spans(match.start(), recovery_spans):
                continue
            prefix = body[: match.start()].rstrip()
            if prefix.endswith(("let", "var")):
                continue
            writes.append((_line_of(cleaned, start + match.start()), target))

        failures = [
            (_line_of(cleaned, start + match.start()), match.group(0))
            for match in _FAILURE.finditer(body)
            if not _SELF_GUARD.match(body, match.start())
        ]
        recovery = [_line_of(cleaned, start + match.start()) for match in _RECOVERY.finditer(body)]

        if not writes or not failures:
            continue
        first_write = min(line for line, _ in writes)
        if not any(line > first_write for line, _ in failures):
            continue
        # A catch/defer only means the author considered it; it does not mean
        # the rollback is complete (defect 44). Both verdicts are listed;
        # `unprotected` has no net at all and is read first.
        # A defer/catch is a function-scoped safety net wherever it is written:
        # `defer` runs at scope exit no matter how early it is declared, and a
        # `catch` handles the throw that precedes it. Position relative to the
        # write is therefore irrelevant - only presence matters. Whether the
        # rollback is complete stays a human judgement (see `guarded`).
        protected = bool(recovery)
        findings.append(
            Finding(
                path=path,
                line=first_write,
                function=name,
                verdict="guarded" if protected else "unprotected",
                writes=tuple(sorted(writes)),
                failures=tuple(sorted(failures)),
                recovery=tuple(sorted(recovery)),
            )
        )
    return findings


def _self_check():
    """Prove the classifier is not vacuously true.

    Stage report section 2.52 records a scanner that was vacuously true on its
    own output; only after the classification is shown non-vacuous may "no hits"
    be cited for a scope. These five snippets are that proof.
    """
    cases = [
        (
            "state write, no recovery",
            """
      func adopt() throws {
        phase = .ready
        try save()
      }
      """,
            "unprotected",
        ),
        (
            "state write, catch restores it",
            """
      func adopt() throws {
        phase = .ready
        do { try save() } catch {
          phase = .draft
          throw error
        }
      }
      """,
            "guarded",
        ),
        (
            "state write, defer restores it",
            """
      func annotate() async {
        isAnnotating = true
        defer { isAnnotating = false }
        let x = try await load()
        use(x)
      }
      """,
            "guarded",
        ),
        (
            "defect-44 shape: catch present but no rollback",
            """
      func annotate() async {
        versions[0] = note
        document.updatedAt = Date()
        do {
          try await saveBundle()
        } catch {
          return aiFailureMessage(for: error)
        }
      }
      """,
            "guarded",
        ),
        (
            "only locals assigned, not state writes",
            """
      func total() throws {
        let base = 1
        var sum = base
        sum = base
        sum = try add(sum)
        return sum
      }
      """,
            "none",
        ),
    ]

    failures = 0
    for title, snippet, expected in cases:
        source = "final class S {\n" + snippet + "\n}\n"
        found = scan_source(source, pathlib.Path("<self-check>"))
        got = found[0].verdict if found else "none"
        ok = got == expected
        failures += 0 if ok else 1
        status = "PASS" if ok else "FAIL"
        print(f"{status}  expected {expected:<11} got {got:<11} {title}")
    print(f"\nself-check: {len(cases) - failures}/{len(cases)} passed")
    return 0 if failures == 0 else 1


def _render(findings):
    lines = []
    for finding in findings:
        marker = "!!" if finding.verdict == "unprotected" else "??"
        lines.append(
            f"{marker} {finding.path}:{finding.line} {finding.function}() [{finding.verdict}]"
        )
        for line, target in finding.writes:
            lines.append(f"    写入 {target} (L{line})")
        for line, token in finding.failures:
            lines.append(f"    失败 {token} (L{line})")
        if finding.recovery:
            lines.append(
                "    兜底 catch/defer 于 L" + ", L".join(str(line) for line in finding.recovery)
            )
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("paths", nargs="*", type=pathlib.Path)
    parser.add_argument(
        "--self-check",
        action="store_true",
        help="prove the classification on built-in snippets; run before citing zero hits",
    )
    parser.add_argument(
        "--fail-on-unprotected",
        action="store_true",
        help="exit 1 when any unprotected is found (default: list only, no verdict)",
    )
    args = parser.parse_args(argv)

    if args.self_check:
        return _self_check()
    if not args.paths:
        parser.error("至少给一个路径，或用 --self-check")

    findings = []
    for root in args.paths:
        files = [root] if root.is_file() else sorted(root.rglob("*.swift"))
        for file in files:
            findings.extend(scan_source(file.read_text(encoding="utf-8"), file))

    unprotected = [f for f in findings if f.verdict == "unprotected"]
    print(_render(findings))
    print(
        f"\n{len(findings)} candidates: {len(unprotected)} unprotected / "
        f"{len(findings) - len(unprotected)} guarded"
    )
    print("Candidates are not conclusions - guarded only means a catch/defer was seen.")
    if args.fail_on_unprotected and unprotected:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
