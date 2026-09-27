from __future__ import annotations

import importlib.util
from pathlib import Path


def _checker() -> object:
    script_path = Path(__file__).parents[1] / "scripts" / "check_user_doc_contract.py"
    spec = importlib.util.spec_from_file_location("check_user_doc_contract", script_path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_user_guide_documents_every_served_surface() -> None:
    """The guide, the contract and the runtime must not drift apart."""

    module = _checker()
    assert module.find_drift() == []  # type: ignore[attr-defined]


def test_drift_is_reported_when_the_guide_drops_a_path(
    tmp_path: Path, monkeypatch
) -> None:
    """A path served by the contract but missing from the guide must fail."""

    module = _checker()
    contract = tmp_path / "openapi.yaml"
    contract.write_text(
        "paths:\n  /v1/served-but-undocumented:\n    get: {}\n",
        encoding="utf-8",
    )
    guide = tmp_path / "api-contract.md"
    guide.write_text(
        "### 标准错误码速查表\n"
        "| HTTP | Error Code | retryable |\n"
        "|---|---|---|\n"
        "| **400** | `voice_in_use` | `true` |\n",
        encoding="utf-8",
    )
    source = tmp_path / "src"
    source.mkdir()
    (source / "service.py").write_text('"voice_in_use"', encoding="utf-8")
    monkeypatch.setattr(module, "CONTRACT", contract)
    monkeypatch.setattr(module, "USER_GUIDE", guide)
    monkeypatch.setattr(module, "SOURCE_ROOT", source)

    problems = module.find_drift()  # type: ignore[attr-defined]
    assert "undocumented path: /v1/served-but-undocumented" in problems


def test_drift_is_reported_for_an_unimplemented_error_code(
    tmp_path: Path, monkeypatch
) -> None:
    """A documented error code with no implementation must fail."""

    module = _checker()
    contract = tmp_path / "openapi.yaml"
    contract.write_text("paths: {}\n", encoding="utf-8")
    guide = tmp_path / "api-contract.md"
    guide.write_text(
        "### 标准错误码速查表\n"
        "| **400** | `totally_unimplemented_code` | `false` |\n",
        encoding="utf-8",
    )
    source = tmp_path / "src"
    source.mkdir()
    (source / "service.py").write_text("# nothing here", encoding="utf-8")
    monkeypatch.setattr(module, "CONTRACT", contract)
    monkeypatch.setattr(module, "USER_GUIDE", guide)
    monkeypatch.setattr(module, "SOURCE_ROOT", source)

    problems = module.find_drift()  # type: ignore[attr-defined]
    assert (
        "documented error code is not implemented: totally_unimplemented_code"
        in problems
    )


def test_drift_is_reported_for_an_undocumented_model_alias(
    tmp_path: Path, monkeypatch
) -> None:
    """Every alias the service advertises must be named in the guide."""

    module = _checker()
    contract = tmp_path / "openapi.yaml"
    contract.write_text("paths: {}\n", encoding="utf-8")
    guide = tmp_path / "api-contract.md"
    guide.write_text("### 标准错误码速查表\n", encoding="utf-8")
    source = tmp_path / "src"
    source.mkdir()
    (source / "service.py").write_text("# nothing here", encoding="utf-8")
    monkeypatch.setattr(module, "CONTRACT", contract)
    monkeypatch.setattr(module, "USER_GUIDE", guide)
    monkeypatch.setattr(module, "SOURCE_ROOT", source)

    problems = module.find_drift()  # type: ignore[attr-defined]
    assert any(problem.startswith("advertised model alias") for problem in problems)
