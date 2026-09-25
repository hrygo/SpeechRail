#!/usr/bin/env python3
"""Validate the current Realtime schema and shared Python/Swift fixtures."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[1]
SCHEMA_PATH = ROOT / "contracts" / "realtime-events.schema.json"
MATRIX_PATH = ROOT / "contracts" / "realtime-field-matrix.json"
FIXTURE_ROOT = ROOT / "tests" / "fixtures" / "realtime-current"
MANIFEST_PATH = FIXTURE_ROOT / "manifest.json"


def _load(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return payload


def _path_exists(value: object, dotted: str) -> bool:
    current = value
    for component in dotted.split("."):
        if not isinstance(current, dict) or component not in current:
            return False
        current = current[component]
    return True


def main() -> int:
    schema = _load(SCHEMA_PATH)
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema)
    manifest = _load(MANIFEST_PATH)
    cases = manifest.get("cases")
    if manifest.get("contract_version") != 1 or not isinstance(cases, list):
        raise ValueError("fixture manifest must declare contract_version=1 and cases[]")

    case_by_name: dict[str, dict[str, Any]] = {}
    for case in cases:
        name = case["name"]
        if name in case_by_name:
            raise ValueError(f"duplicate fixture case: {name}")
        case_by_name[name] = case
        fixture = _load(FIXTURE_ROOT / case["file"])
        errors = list(validator.iter_errors(fixture))
        if case["valid"]:
            if errors:
                raise ValueError(f"{name} is not valid: {errors[0].message}")
        elif not errors:
            raise ValueError(f"{name} unexpectedly matches the current schema")
        elif not case.get("rejection"):
            raise ValueError(f"{name} has no explicit rejection reason")

    matrix = _load(MATRIX_PATH)
    if matrix.get("contract_version") != 1 or not isinstance(matrix.get("fields"), list):
        raise ValueError("field matrix must declare contract_version=1 and fields[]")
    seen_paths: set[str] = set()
    for row in matrix["fields"]:
        path = row["path"]
        if path in seen_paths:
            raise ValueError(f"duplicate field matrix path: {path}")
        seen_paths.add(path)
        positive = case_by_name[row["positive_case"]]
        positive_name = str(row["positive_case"])
        if not positive["valid"]:
            raise ValueError(f"{path} positive_case is not valid")
        fixture = _load(FIXTURE_ROOT / positive["file"])
        if not _path_exists(fixture, path):
            raise ValueError(f"{path} is missing from {positive_name}")
        reject = row.get("reject_case")
        if reject is not None and (
            reject not in case_by_name or case_by_name[reject]["valid"]
        ):
            raise ValueError(f"{path} reject_case is not a rejection fixture")

    print(
        f"Realtime contract OK: {len(cases)} fixtures, "
        f"{len(seen_paths)} tracked fields"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
