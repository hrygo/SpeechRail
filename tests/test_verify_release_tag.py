from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

_SCRIPT_PATH = Path(__file__).resolve().parents[1] / "scripts" / "verify_release_tag.py"
_SPEC = importlib.util.spec_from_file_location("speechrail_test_verify_release_tag", _SCRIPT_PATH)
assert _SPEC is not None and _SPEC.loader is not None
_module = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = _module
_SPEC.loader.exec_module(_module)


def _project(root: Path, version: str = "2.6.0") -> None:
    (root / "pyproject.toml").write_text(
        f'[project]\nname = "speechrail"\nversion = "{version}"\n',
        encoding="utf-8",
    )


def test_matching_tag_is_accepted(tmp_path: Path) -> None:
    _project(tmp_path)

    assert _module.main(["--root", str(tmp_path), "--tag", "v2.6.0"]) == 0


def test_tag_with_wrong_version_is_rejected(tmp_path: Path) -> None:
    _project(tmp_path)

    assert _module.main(["--root", str(tmp_path), "--tag", "v2.6.1"]) == 1


def test_missing_project_version_is_rejected(tmp_path: Path) -> None:
    (tmp_path / "pyproject.toml").write_text('[project]\nname = "speechrail"\n', encoding="utf-8")

    assert _module.main(["--root", str(tmp_path), "--tag", "v2.6.0"]) == 1
