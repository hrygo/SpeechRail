from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

_SCRIPT_PATH = (
    Path(__file__).resolve().parents[1] / "scripts" / "build_release_notes.py"
)
_SPEC = importlib.util.spec_from_file_location(
    "speechrail_test_build_release_notes", _SCRIPT_PATH
)
assert _SPEC is not None and _SPEC.loader is not None
_module = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = _module
_SPEC.loader.exec_module(_module)

_CHANGELOG = """# Changelog

## [Unreleased]

## [3.3.2] - 2026-09-28

### Fixed

- 修复甲。
- 修复乙。

## [3.3.1] - 2026-09-28

### Fixed

- 修复丙。
"""


def _render(version: str, changelog: str = _CHANGELOG, repository: str | None = "acme/rail"):
    return _module.render_release_notes(
        version=version, changelog=changelog, repository=repository
    )


def test_changelog_section_is_the_release_body() -> None:
    body = _render("3.3.2")

    assert "## 3.3.2 变更说明" in body
    assert "- 修复甲。" in body
    assert "- 修复乙。" in body
    # Earlier releases must not leak into this release's notes.
    assert "修复丙" not in body
    # An unreleased section is not part of any published release.
    assert "Unreleased" not in body


def test_installation_notes_precede_the_compare_link() -> None:
    body = _render("3.3.2")

    assert body.index("## 发布文件说明") < body.index("**Full Changelog**")
    assert body.rstrip().endswith(
        "**Full Changelog**: https://github.com/acme/rail/compare/v3.3.1...v3.3.2"
    )


def test_asset_names_carry_the_real_version() -> None:
    """The workflow used to publish a literal ``speechrail-<version>-*.whl``."""

    body = _render("3.3.2")

    assert "speechrail-3.3.2-*.whl" in body
    assert "SpeechRail-3.3.2-macOS-arm64.dmg" in body
    assert "<version>" not in body
    assert "{version}" not in body
    assert "{repository}" not in body


def test_compare_link_uses_the_previous_release_not_unreleased() -> None:
    assert "compare/v3.3.1...v3.3.2" in _render("3.3.2")


def test_first_release_has_no_compare_link() -> None:
    changelog = "## [1.0.0] - 2026-01-01\n\n- 初次发布。\n"

    body = _render("1.0.0", changelog=changelog)

    assert "初次发布" in body
    assert "**Full Changelog**" not in body


def test_manual_link_is_relative_without_a_repository() -> None:
    body = _render("3.3.2", repository=None)

    assert "github.com" not in body
    assert "**Full Changelog**" not in body
    assert "docs/users/installing-speechrail.md" in body


def test_missing_version_section_is_rejected() -> None:
    with pytest.raises(ValueError, match=r"no '## \[9\.9\.9\]' section"):
        _render("9.9.9")


def test_empty_version_section_is_rejected() -> None:
    changelog = "## [3.3.2] - 2026-09-28\n\n## [3.3.1] - 2026-09-28\n\n- 旧条目。\n"

    with pytest.raises(ValueError, match="has no entries"):
        _render("3.3.2", changelog=changelog)


def test_cli_fails_closed_for_a_missing_section(tmp_path: Path) -> None:
    changelog = tmp_path / "CHANGELOG.md"
    changelog.write_text(_CHANGELOG, encoding="utf-8")

    exit_code = _module.main(
        [
            "--version",
            "9.9.9",
            "--changelog",
            str(changelog),
            "--repository",
            "acme/rail",
        ]
    )

    assert exit_code == 1


def test_cli_writes_the_requested_output(tmp_path: Path) -> None:
    changelog = tmp_path / "CHANGELOG.md"
    changelog.write_text(_CHANGELOG, encoding="utf-8")
    output = tmp_path / "notes.md"

    exit_code = _module.main(
        [
            "--version",
            "3.3.2",
            "--changelog",
            str(changelog),
            "--repository",
            "acme/rail",
            "--output",
            str(output),
        ]
    )

    assert exit_code == 0
    written = output.read_text(encoding="utf-8")
    assert written == _render("3.3.2")
    assert written.endswith("\n")


def test_repository_changelog_renders_without_placeholder_text() -> None:
    """The shipped CHANGELOG must render for the version being released."""

    root = Path(__file__).resolve().parents[1]
    version = _project_version(root)

    body = _module.render_release_notes(
        version=version,
        changelog=(root / "CHANGELOG.md").read_text(encoding="utf-8"),
        repository="hrygo/SpeechRail",
    )

    assert "<version>" not in body
    assert f"SpeechRail-{version}-macOS-arm64.dmg" in body


def _project_version(root: Path) -> str:
    import tomllib

    with (root / "pyproject.toml").open("rb") as handle:
        return tomllib.load(handle)["project"]["version"]
