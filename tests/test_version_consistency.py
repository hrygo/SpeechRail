"""Tests for the release version-consistency gate."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

VERSION = "9.9.9"

_SCRIPT_PATH = Path(__file__).resolve().parents[1] / "scripts" / "check_version_consistency.py"
_SPEC = importlib.util.spec_from_file_location("speechrail_test_version_check", _SCRIPT_PATH)
assert _SPEC is not None and _SPEC.loader is not None
_check_module = importlib.util.module_from_spec(_SPEC)
sys.modules["speechrail_test_version_check"] = _check_module
_SPEC.loader.exec_module(_check_module)

check_tree = _check_module.check_tree


def _write_tree(root: Path, version: str = VERSION) -> None:
    files = {
        "pyproject.toml": f'[project]\nversion = "{version}"\n',
        "src/speechrail/__init__.py": f'__version__ = "{version}"\n',
        "src/speechrail/config/__init__.py": f'version: str = "{version}"\n',
        "contracts/openapi.yaml": f"version: {version}\nversion: {version}\n",
        "configs/speechrail.example.env": f"SPEECHRAIL_VERSION={version}\n",
        "configs/speechrail.example.yaml": f"  version: {version}\n",
        "tests/test_app_contract.py": f'"version": "{version}"\n"version": "{version}"\n',
        "tests/test_installer.py": f"speechrail-{version}-py3-none-any.whl\n",
        "tests/test_release_verification.py": f"speechrail-{version}.dist-info/METADATA\n",
        "uv.lock": f'name = "speechrail"\nversion = "{version}"\n',
        "CHANGELOG.md": f"## [{version}] - 2026-09-02\n",
    }
    for relative, content in files.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")


def test_all_locations_consistent(tmp_path: Path) -> None:
    _write_tree(tmp_path)

    assert check_tree(tmp_path, VERSION) == []


def test_missing_file_is_reported(tmp_path: Path) -> None:
    _write_tree(tmp_path)
    (tmp_path / "contracts/openapi.yaml").unlink()

    problems = check_tree(tmp_path, VERSION)

    assert any("MISSING OpenAPI" in problem for problem in problems)
    assert len(problems) == 1


def test_mixed_version_is_reported(tmp_path: Path) -> None:
    _write_tree(tmp_path)
    (tmp_path / "contracts/openapi.yaml").write_text("version: 9.9.8\n", encoding="utf-8")

    problems = check_tree(tmp_path, VERSION)

    assert any("MISMATCH OpenAPI" in problem and "9.9.8" not in problem for problem in problems)


def test_openapi_requires_both_version_spots(tmp_path: Path) -> None:
    _write_tree(tmp_path)
    openapi = tmp_path / "contracts/openapi.yaml"
    openapi.write_text("version: 9.9.9\n", encoding="utf-8")

    problems = check_tree(tmp_path, VERSION)

    assert any("MISMATCH OpenAPI" in problem and "found 1/2" in problem for problem in problems)


def test_settings_version_is_the_health_source(tmp_path: Path) -> None:
    _write_tree(tmp_path)
    write = tmp_path / "src/speechrail/config/__init__.py"
    write.write_text('version: str = "9.9.8"\n', encoding="utf-8")

    problems = check_tree(tmp_path, VERSION)

    assert any("Settings.version" in problem for problem in problems)


def test_historical_changelog_headers_are_exempt(tmp_path: Path) -> None:
    _write_tree(tmp_path)
    changelog = tmp_path / "CHANGELOG.md"
    changelog.write_text(
        f"## [{VERSION}] - 2026-09-02\n## [1.5.0] - 2026-09-02\n", encoding="utf-8"
    )

    assert check_tree(tmp_path, VERSION) == []


def test_changelog_header_for_current_release_is_required(tmp_path: Path) -> None:
    _write_tree(tmp_path)
    (tmp_path / "CHANGELOG.md").write_text("## [1.5.0] - 2026-09-02\n", encoding="utf-8")

    problems = check_tree(tmp_path, VERSION)

    assert any("CHANGELOG release header" in problem for problem in problems)


def test_yaml_history_comment_is_ignored(tmp_path: Path) -> None:
    _write_tree(tmp_path)
    yaml_path = tmp_path / "configs/speechrail.example.yaml"
    yaml_path.write_text(
        f"# Reference configuration. The .env example is the launch path for 1.2.0.\n"
        f"service:\n  name: speechrail\n  version: {VERSION}\n",
        encoding="utf-8",
    )

    assert check_tree(tmp_path, VERSION) == []


def test_uv_lock_requires_the_speechrail_block(tmp_path: Path) -> None:
    _write_tree(tmp_path)
    lock = tmp_path / "uv.lock"
    lock.write_text(
        f'name = "speechrail"\nversion = "{VERSION}"\nsome-other-package-version-below\n'
        f'name = "other"\nversion = "9.9.8"\n',
        encoding="utf-8",
    )

    assert check_tree(tmp_path, VERSION) == []
