from __future__ import annotations

import importlib.util
from pathlib import Path


def _checker() -> object:
    script_path = Path(__file__).parents[1] / "scripts" / "check_openapi_contract.py"
    spec = importlib.util.spec_from_file_location("check_openapi_contract", script_path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_runtime_routes_match_openapi_contract() -> None:
    """Every served path/method must be documented, and vice versa."""

    module = _checker()
    assert module.find_drift() == []  # type: ignore[attr-defined]


def test_checker_reports_undocumented_paths() -> None:
    """The checker must fail closed on drift rather than silently passing."""

    module = _checker()
    operations = module._operations(  # type: ignore[attr-defined]
        {"paths": {"/v1/only-in-app": {"get": {}, "post": {}}}}
    )
    assert operations == {"/v1/only-in-app": {"get", "post"}}
