"""Classify changed repository paths for the core GitHub Actions workflow.

Pull requests that only touch documentation do not need the Python test suite
or the macOS App build, and a Python-only change does not need the App build.
This classifier turns the changed-path list into two booleans the workflow
gates on. It is deliberately conservative: anything it does not recognise
selects the full gate set, so an unclassified path can never silently drop a
check.

The script reads a NUL-delimited path stream on stdin, which is what
``git diff --name-only -z`` produces, so paths containing spaces or quotes
survive intact.
"""

from __future__ import annotations

import argparse
import sys
from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass
from html import escape
from pathlib import Path
from typing import TextIO

# Tooling and workflow changes can alter how any gate behaves, so they always
# run everything.
FULL_PREFIXES = ("scripts/", ".github/", "deploy/")
# A contract change is observable from both sides: the Python parity gates read
# the OpenAPI/schema files and the Swift contract tests encode them.
CROSS_LANGUAGE_PREFIXES = ("contracts/",)
PYTHON_PREFIXES = ("src/", "tests/", "tools/", "examples/", "configs/")
PYTHON_FILES = {"pyproject.toml", "uv.lock", "hatch_build.py"}
SWIFT_PREFIXES = ("macos/",)
META_PREFIXES = ("docs/", ".agents/")
META_FILES = {
    "README.md",
    "README.zh-CN.md",
    "AGENTS.md",
    "CONTRIBUTING.md",
    "LICENSE",
    ".gitignore",
}
VALID_SCOPES = {"meta", "python", "swift", "full"}
_OUTPUT_KEYS = {"run_python", "run_swift", "scope"}


@dataclass(frozen=True)
class ScopeDecision:
    """The platform gates selected for one changed-path input."""

    run_python: bool
    run_swift: bool
    scope: str
    reason: str
    file_count: int = 0

    @classmethod
    def full(cls, reason: str, file_count: int = 0) -> ScopeDecision:
        return cls(True, True, "full", reason, file_count)


def _normalize_path(path: str) -> str:
    """Remove only explicit relative prefixes; preserve leading dot directories."""

    while path.startswith("./"):
        path = path[2:]
    return path


def classify_paths(paths: Iterable[str]) -> ScopeDecision:
    """Classify paths conservatively, defaulting unknown input to full scope."""

    normalized = [_normalize_path(path) for path in paths if path]
    file_count = len(normalized)
    if not normalized:
        return ScopeDecision.full("变更面为空, 按 full 运行", file_count)

    run_python = False
    run_swift = False
    saw_code = False
    for path in normalized:
        if path.startswith(FULL_PREFIXES) or path in PYTHON_FILES:
            if path in PYTHON_FILES:
                run_python = True
                saw_code = True
                continue
            return ScopeDecision.full(f"命中治理或工具链路径: {path}", file_count)
        if path.startswith(CROSS_LANGUAGE_PREFIXES):
            run_python = True
            run_swift = True
            saw_code = True
            continue
        if path.startswith(PYTHON_PREFIXES):
            run_python = True
            saw_code = True
            continue
        if path.startswith(SWIFT_PREFIXES):
            run_swift = True
            saw_code = True
            continue
        if path.startswith(META_PREFIXES) or path in META_FILES or path.endswith(".md"):
            continue
        return ScopeDecision.full(f"未知路径: {path}", file_count)

    if not saw_code:
        return ScopeDecision(False, False, "meta", "仅元数据变更", file_count)
    if run_python and run_swift:
        return ScopeDecision.full("命中 Python 与 Swift 变更面", file_count)
    if run_python:
        return ScopeDecision(True, False, "python", "仅 Python 变更面", file_count)
    return ScopeDecision(False, True, "swift", "仅 macOS App 变更面", file_count)


def decision_from_nul_bytes(raw: bytes) -> ScopeDecision:
    """Decode a git NUL-delimited path stream and fail closed on invalid bytes."""

    try:
        decoded = raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        return ScopeDecision.full("invalid path encoding; fail closed to full")

    paths = decoded.split("\0")
    if paths and paths[-1] == "":
        paths.pop()
    return classify_paths(paths)


def _write_scalar(name: str, value: str, stream: TextIO) -> None:
    if name not in _OUTPUT_KEYS:
        raise ValueError(f"unsupported GitHub output key: {name}")
    if "\n" in value or "\r" in value:
        raise ValueError(f"GitHub output value for {name} contains a newline")
    stream.write(f"{name}={value}\n")


def write_github_output(decision: ScopeDecision, stream: TextIO) -> None:
    """Write only the scalar values consumed by downstream GitHub jobs."""

    if decision.scope not in VALID_SCOPES:
        raise ValueError(f"unsupported scope: {decision.scope}")
    _write_scalar("run_python", str(decision.run_python).lower(), stream)
    _write_scalar("run_swift", str(decision.run_swift).lower(), stream)
    _write_scalar("scope", decision.scope, stream)


def write_summary(decision: ScopeDecision, stream: TextIO) -> None:
    """Write human-readable classification evidence to the step summary."""

    if decision.scope not in VALID_SCOPES:
        raise ValueError(f"unsupported scope: {decision.scope}")
    safe_reason = escape(decision.reason.replace("\r", " ").replace("\n", " "), quote=True)
    stream.write(f"### CI change scope: `{decision.scope}`\n\n")
    stream.write(f"- Changed paths: `{decision.file_count}`\n")
    stream.write(f"- Run Python gate: `{str(decision.run_python).lower()}`\n")
    stream.write(f"- Run Swift gate: `{str(decision.run_swift).lower()}`\n")
    stream.write(f"- Reason: <code>{safe_reason}</code>\n")


def _write_output_file(path_text: str, writer: Callable[[TextIO], None]) -> None:
    with Path(path_text).open("w", encoding="utf-8", newline="") as stream:
        writer(stream)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--github-output", help="path to the GitHub Actions output file")
    parser.add_argument("--summary", help="path to the GitHub Actions step summary")
    parser.add_argument(
        "--force-full",
        action="store_true",
        help="ignore stdin and select both platform gates",
    )
    args = parser.parse_args(argv)

    if args.force_full:
        decision = ScopeDecision.full("显式强制 full 模式")
    else:
        decision = decision_from_nul_bytes(sys.stdin.buffer.read())

    try:
        if args.github_output:
            _write_output_file(
                args.github_output,
                lambda stream: write_github_output(decision, stream),
            )
        if args.summary:
            _write_output_file(args.summary, lambda stream: write_summary(decision, stream))
    except (OSError, ValueError) as exc:
        print(f"CI scope output failed: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
