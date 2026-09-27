#!/usr/bin/env python3
"""Fail when the live FastAPI app and ``contracts/openapi.yaml`` drift apart.

The public REST contract is a hard interface: a route that exists only in the
runtime (or only in the contract) is a defect, not a cosmetic mismatch. This
check compares the routing table, the declared success status codes and the
security scheme against the reviewed contract file.

The service serves that same file at ``/openapi.json``, so the document itself
can no longer prove anything. The evidence has to come from the routes: FastAPI
wraps included routers in ``_IncludedRouter``, so the table has to be walked
recursively instead of read straight from ``app.routes``.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

import yaml
from fastapi.routing import APIRoute

from speechrail.app import create_app

CONTRACT = Path(__file__).resolve().parents[1] / "contracts" / "openapi.yaml"
_METHODS = {"get", "put", "post", "delete", "patch", "options", "head", "trace"}
_DECLARED_METHODS = {"get", "put", "post", "delete", "patch"}


def _walk_routes(routes: Any) -> list[APIRoute]:
    """Return every APIRoute, unwrapping FastAPI's lazy router inclusion."""

    found: list[APIRoute] = []
    for route in routes:
        if isinstance(route, APIRoute):
            found.append(route)
            continue
        original = getattr(route, "original_router", None)
        if original is not None:
            # An included router already carries its prefix in each route path.
            found.extend(_walk_routes(original.routes))
            continue
        nested = getattr(route, "routes", None)
        if nested:
            found.extend(_walk_routes(nested))
    return found


def _operations(spec: dict[str, Any]) -> dict[str, set[str]]:
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


def _served_operations() -> dict[str, set[str]]:
    operations: dict[str, set[str]] = {}
    for route in _walk_routes(create_app().routes):
        operations.setdefault(route.path, set()).update(
            method.lower() for method in route.methods or ()
        )
    return operations


def _contract() -> dict[str, Any]:
    return yaml.safe_load(CONTRACT.read_text(encoding="utf-8"))


def _success_codes(spec: dict[str, Any]) -> dict[tuple[str, str], set[str]]:
    paths = spec["paths"]
    assert isinstance(paths, dict)
    codes: dict[tuple[str, str], set[str]] = {}
    for path, item in paths.items():
        if not isinstance(item, dict):
            continue
        for method, operation in item.items():
            if method.lower() not in _DECLARED_METHODS or not isinstance(operation, dict):
                continue
            responses = operation.get("responses", {})
            codes[(str(path), method.lower())] = {
                str(code) for code in responses if str(code).startswith("2")
            }
    return codes


def _status_drift() -> list[str]:
    """Every success code a route can return must be published by the contract."""

    problems: list[str] = []
    contract_codes = _success_codes(_contract())
    for route in _walk_routes(create_app().routes):
        declared = str(route.status_code or 200)
        for method in route.methods or ():
            key = (route.path, method.lower())
            if key not in contract_codes:
                continue
            if declared not in contract_codes[key]:
                problems.append(
                    f"{method.upper()} {route.path}: route declares {declared}, "
                    f"contract publishes {sorted(contract_codes[key])}"
                )
    return problems


def _security_drift() -> list[str]:
    """Every security requirement in the contract must name a declared scheme."""

    problems: list[str] = []
    spec = _contract()
    components = spec.get("components")
    schemes = components.get("securitySchemes", {}) if isinstance(components, dict) else {}
    declared = set(schemes) if isinstance(schemes, dict) else set()
    if not declared:
        return ["contract declares no security scheme"]
    for path, method in _success_codes(spec):
        operation = spec["paths"][path][method]
        security = operation.get("security")
        if security is None:
            continue
        if not isinstance(security, list):
            problems.append(f"{method.upper()} {path}: security is not a list")
            continue
        for requirement in security:
            if not isinstance(requirement, dict):
                continue
            for scheme in requirement:
                if scheme not in declared:
                    problems.append(
                        f"{method.upper()} {path}: undeclared security scheme {scheme}"
                    )
    return problems


def find_drift() -> list[str]:
    app_ops = _served_operations()
    doc_ops = _operations(_contract())

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
    problems.extend(_status_drift())
    problems.extend(_security_drift())
    return problems


def main() -> int:
    problems = find_drift()
    if problems:
        for problem in problems:
            print(f"openapi-contract: {problem}", file=sys.stderr)
        return 1
    app_ops = _served_operations()
    print(
        f"openapi-contract: OK ({len(app_ops)} paths, "
        f"{sum(len(v) for v in app_ops.values())} operations)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
