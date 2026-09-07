from __future__ import annotations

import importlib.util
from pathlib import Path


def test_operator_docs_share_one_contract() -> None:
    script_path = Path(__file__).parents[1] / "scripts" / "check_operator_docs.py"
    spec = importlib.util.spec_from_file_location("check_operator_docs", script_path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    assert module.main() == 0
