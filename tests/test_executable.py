from __future__ import annotations

from pathlib import Path

import pytest

from speechrail.service.executable import resolve_configured_executable


def _write_executable(path: Path) -> Path:
    path.parent.mkdir(parents=True)
    path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    path.chmod(0o755)
    return path


def test_configured_executable_resolves_vendor_current_symlink_to_file(
    tmp_path: Path,
) -> None:
    target = _write_executable(tmp_path / "vendor" / "releases" / "ffmpeg")
    current = tmp_path / "vendor" / "current"
    current.symlink_to(target.parent, target_is_directory=True)

    resolved = resolve_configured_executable(
        current / target.name,
        error_code="audio_decode_failed",
    )

    assert resolved == str(target.resolve())


@pytest.mark.parametrize("kind", ["relative", "missing", "directory", "not_executable"])
def test_configured_executable_rejects_invalid_paths_without_leaking_path(
    tmp_path: Path,
    kind: str,
) -> None:
    if kind == "relative":
        candidate = Path("relative-ffmpeg")
    elif kind == "missing":
        candidate = tmp_path / "missing" / "ffmpeg"
    elif kind == "directory":
        candidate = tmp_path / "ffmpeg-dir"
        candidate.mkdir()
    else:
        candidate = tmp_path / "ffmpeg"
        candidate.touch()
        candidate.chmod(0o644)

    with pytest.raises(ValueError, match="audio_decode_failed") as exc_info:
        resolve_configured_executable(candidate, error_code="audio_decode_failed")

    assert str(candidate) not in str(exc_info.value)
    if candidate.is_absolute():
        assert str(candidate) not in str(exc_info.value)
    assert candidate.name not in str(exc_info.value)
