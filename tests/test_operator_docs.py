from __future__ import annotations

import importlib.util
import re
from pathlib import Path

from speechrail.config import Settings


def test_operator_docs_share_one_contract() -> None:
    script_path = Path(__file__).parents[1] / "scripts" / "check_operator_docs.py"
    spec = importlib.util.spec_from_file_location("check_operator_docs", script_path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    assert module.main() == 0


def test_realtime_session_example_matches_settings_default() -> None:
    repository_root = Path(__file__).parents[1]
    example = (repository_root / "configs/speechrail.example.env").read_text(
        encoding="utf-8"
    )
    match = re.search(
        r"^SPEECHRAIL_REALTIME_MAX_SESSIONS=(\d+)$", example, re.MULTILINE
    )
    assert match is not None
    default = Settings.model_fields["realtime_max_sessions"].default
    assert type(default) is int
    assert int(match.group(1)) == default
