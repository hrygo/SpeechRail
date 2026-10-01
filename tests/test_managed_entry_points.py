"""Managed release entry points: stable CLI wrappers plus the launchd service entry."""

from __future__ import annotations

from pathlib import Path

import pytest

from speechrail.service.constants import SERVICE_ENTRY_NAME
from speechrail.service.managed_install import _patch_entry_points


def _release(tmp_path: Path, *, with_python: bool = True) -> Path:
    bin_directory = tmp_path / "releases" / "speechrail-1.0" / ".venv" / "bin"
    bin_directory.mkdir(parents=True)
    if with_python:
        (bin_directory / "python").touch()
    for name in ("speechrail", "speechrail-mcp"):
        (bin_directory / name).write_text("#!/Users/hardcoded/python\n")
    return tmp_path / "releases" / "speechrail-1.0"


def test_console_scripts_are_replaced_with_runtime_current_wrappers(tmp_path: Path) -> None:
    release = _release(tmp_path)

    _patch_entry_points(release)

    for name in ("speechrail", "speechrail-mcp"):
        script = release / ".venv" / "bin" / name
        content = script.read_text(encoding="utf-8")
        assert content.startswith("#!/bin/sh\n")
        assert "runtime/current/.venv/bin/python" in content
        assert "/Users/hardcoded" not in content
        assert script.stat().st_mode & 0o111


def test_service_entry_is_a_relative_shell_free_symlink_to_the_interpreter(tmp_path: Path) -> None:
    release = _release(tmp_path)

    _patch_entry_points(release)

    entry = release / ".venv" / "bin" / SERVICE_ENTRY_NAME
    assert entry.is_symlink()
    assert Path(entry.readlink()).name == "python"
    assert not entry.readlink().is_absolute()
    assert entry.resolve() == (release / ".venv" / "bin" / "python").resolve()


def test_service_entry_is_idempotent_across_repeated_patching(tmp_path: Path) -> None:
    release = _release(tmp_path)

    _patch_entry_points(release)
    first = (release / ".venv" / "bin" / SERVICE_ENTRY_NAME).readlink()
    _patch_entry_points(release)

    entry = release / ".venv" / "bin" / SERVICE_ENTRY_NAME
    assert entry.is_symlink()
    assert entry.readlink() == first


def test_service_entry_replaces_a_stale_regular_file(tmp_path: Path) -> None:
    release = _release(tmp_path)
    entry = release / ".venv" / "bin" / SERVICE_ENTRY_NAME
    entry.write_text("stale")

    _patch_entry_points(release)

    assert entry.is_symlink()


def test_missing_interpreter_skips_only_the_service_entry(tmp_path: Path) -> None:
    """A release without ``bin/python`` still gets its CLI wrappers rewritten."""
    release = _release(tmp_path, with_python=False)

    _patch_entry_points(release)

    assert not (release / ".venv" / "bin" / SERVICE_ENTRY_NAME).exists()
    assert (release / ".venv" / "bin" / "speechrail").read_text(encoding="utf-8").startswith(
        "#!/bin/sh\n"
    )


@pytest.mark.parametrize("entry_name", [SERVICE_ENTRY_NAME, "speechrail", "speechrail-mcp"])
def test_every_entry_is_resolvable_after_patching(tmp_path: Path, entry_name: str) -> None:
    release = _release(tmp_path)

    _patch_entry_points(release)

    assert (release / ".venv" / "bin" / entry_name).exists()
