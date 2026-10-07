from __future__ import annotations

import importlib.util
from pathlib import Path
from typing import Any


def _checker() -> Any:
    script_path = Path(__file__).parents[1] / "scripts" / "check_mcp_tool_contract.py"
    spec = importlib.util.spec_from_file_location("check_mcp_tool_contract", script_path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_mcp_tool_surface_matches_documented_contract() -> None:
    """tools/list, resources/list, the docs and the skill manifest agree."""

    assert _checker().find_drift() == []


def test_checker_reports_missing_tools(monkeypatch: Any, tmp_path: Path) -> None:
    """The checker must fail closed when a published tool is undocumented."""

    module = _checker()
    guide = tmp_path / "guide.md"
    guide.write_text(
        "### 1.1 工具集（1 个）\n"
        "\n"
        "| 工具 | 作用 | 关键点 |\n"
        "|---|---|---|\n"
        "| `describe()` | capability snapshot | call first |\n"
        "\n"
        "只读资源：`speechrail://capabilities`、`speechrail://voices`、`speechrail://models`。\n",
        encoding="utf-8",
    )
    monkeypatch.setattr(module, "USER_GUIDE", guide)

    problems = module.find_drift()

    assert any("user guide declares 1 tools" in problem for problem in problems)
    assert any("does not document tool: transcribe" in problem for problem in problems)


def test_user_guide_parser_reads_declared_count_and_names() -> None:
    """Grouped rows such as ``create_voice` / `delete_voice`` are both counted."""

    declared, names = _checker()._user_guide_tool_section()

    assert declared == 18
    assert "describe" in names
    assert "publish_voice_design" in names
    assert len(names) == len(set(names)) == 18


def test_proxy_contract_parser_reads_declared_count_and_names() -> None:
    """The stable contract declaration and grouped tool rows are parsed."""

    declared, names = _checker()._proxy_contract_tools()

    assert declared == 18
    assert "create_voice" in names
    assert "delete_voice" in names
    assert len(names) == len(set(names)) == 18


def test_reclamation_failure_requires_packaged_recovery_guidance() -> None:
    """A quarantined lane cannot be recovered by generic 503 retry advice."""

    assert "backend_reclamation_failed" in _checker().REQUIRED_SKILL_ERROR_CODES


def test_checker_rejects_missing_reclamation_guidance(
    monkeypatch: Any, tmp_path: Path
) -> None:
    module = _checker()
    errors = tmp_path / "errors.md"
    errors.write_text(
        module.SKILL_ERRORS.read_text(encoding="utf-8").replace(
            "backend_reclamation_failed", "removed_reclamation_code"
        ),
        encoding="utf-8",
    )
    monkeypatch.setattr(module, "SKILL_ERRORS", errors)

    assert (
        "packaged skill does not teach error code: backend_reclamation_failed"
        in module.find_drift()
    )
