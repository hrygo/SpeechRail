#!/usr/bin/env python3
"""Check that local operator skills share one lifecycle and benchmark contract."""

from __future__ import annotations

import sys
from pathlib import Path

REQUIRED_SKILLS = (
    "speechrail-local-deploy/SKILL.md",
    "speechrail-release/SKILL.md",
    "speechrail-perf-benchmark/SKILL.md",
    "speechrail-zero-setup/SKILL.md",
)
LIFECYCLE_SKILLS = (
    "speechrail-local-deploy/SKILL.md",
    "speechrail-release/SKILL.md",
    "speechrail-perf-benchmark/SKILL.md",
)
SHARED_REFERENCE = Path(".agents/skills/speechrail-local-deploy/references/operator-contract.md")


def main() -> int:
    repository_root = Path(__file__).resolve().parents[1]
    failures: list[str] = []
    reference = repository_root / SHARED_REFERENCE
    if not reference.is_file():
        failures.append(f"missing shared reference: {SHARED_REFERENCE}")
    for relative in REQUIRED_SKILLS:
        path = repository_root / ".agents" / "skills" / relative
        if not path.is_file():
            failures.append(f"missing skill: {relative}")
            continue
        content = path.read_text(encoding="utf-8")
        if "operator-contract.md" not in content:
            failures.append(f"skill does not link shared contract: {relative}")
        if "run_all_benchmarks.py" in content:
            failures.append(f"skill still references removed benchmark entrypoint: {relative}")
        if "export SPEECHRAIL_API_KEY=" in content:
            failures.append(f"skill instructs operators to export an API key: {relative}")
        if relative in LIFECYCLE_SKILLS:
            for phrase in ("2 秒", "10 秒", "SIGKILL"):
                if phrase not in content:
                    failures.append(f"skill omits lifecycle invariant {phrase!r}: {relative}")
            if "runtime/current/.venv/bin/python" not in content:
                failures.append(f"skill omits managed runtime command: {relative}")
            for block in content.split("```")[1::2]:
                if any(token in block for token in ("pkill ", "killall ", "grep | kill")):
                    failures.append(f"skill contains a forbidden kill command example: {relative}")
        if relative == "speechrail-perf-benchmark/SKILL.md":
            for phrase in ("--app-home", "config/.env", "只读受保护路由"):
                if phrase not in content:
                    failures.append(f"benchmark skill omits auth invariant {phrase!r}")
    legacy = (
        repository_root
        / ".agents/skills/speechrail-perf-benchmark/scripts/run_all_benchmarks.py"
    )
    if legacy.exists():
        failures.append(
            "removed benchmark entrypoint still exists: "
            f"{legacy.relative_to(repository_root)}"
        )
    if failures:
        for failure in failures:
            print(f"error: {failure}", file=sys.stderr)
        return 1
    print("operator docs: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
