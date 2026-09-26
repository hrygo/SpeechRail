#!/usr/bin/env python3
"""Fail when the live FastAPI app and ``contracts/openapi.yaml`` drift apart.

The public REST contract is a hard interface: a route that exists only in the
runtime (or only in the contract) is a defect, not a cosmetic mismatch. This
check compares path and method sets so drift is caught before merge.
"""

from __future__ import annotations

import sys
from pathlib import Path

import yaml

from speechrail.app import create_app

CONTRACT = Path(__file__).resolve().parents[1] / "contracts" / "openapi.yaml"
_METHODS = {"get", "put", "post", "delete", "patch", "options", "head", "trace"}


def _operations(spec: dict[str, object]) -> dict[str, set[str]]:
    paths = spec["paths"]
    assert isinstance(paths, dict)
    operations: dict[str, set[str]] = {}
    for path, item in paths.items():
        if not isinstance(item, dict):
            continue
        operations[str(path)] = {
            method.lower() for method in item if method.lower() in _METHODS
        }
    return operations


def find_drift() -> list[str]:
    app_ops = _operations(create_app().openapi())
    doc_ops = _operations(yaml.safe_load(CONTRACT.read_text(encoding="utf-8")))

    problems: list[str] = []
    for path in sorted(set(app_ops) - set(doc_ops)):
        problems.append(f"undocumented path: {path} {sorted(app_ops[path])}")
    for path in sorted(set(doc_ops) - set(app_ops)):
        problems.append(f"documented path not served: {path} {sorted(doc_ops[path])}")
    for path in sorted(set(app_ops) & set(doc_ops)):
        if missing := app_ops[path] - doc_ops[path]:
            problems.append(f"{path}: undocumented methods {sorted(missing)}")
        if extra := doc_ops[path] - app_ops[path]:
            problems.append(f"{path}: documented but unserved methods {sorted(extra)}")
    return problems


def main() -> int:
    problems = find_drift()
    if problems:
        for problem in problems:
            print(f"openapi-contract: {problem}", file=sys.stderr)
        return 1
    app_ops = _operations(create_app().openapi())
    print(
        f"openapi-contract: OK ({len(app_ops)} paths, "
        f"{sum(len(v) for v in app_ops.values())} operations)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
