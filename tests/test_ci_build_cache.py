from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci_build_cache.py"


def _run(root: Path, mode: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "python3", str(SCRIPT), mode, "--manifest", "cache/inputs.json",
            "--root", str(root), "sources",
        ],
        cwd=root,
        capture_output=True,
        text=True,
        timeout=10,
    )


def test_restore_only_unchanged_tracked_files(tmp_path: Path) -> None:
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    source_dir = tmp_path / "sources"
    source_dir.mkdir()
    files = [source_dir / name for name in ("same.swift", "changed.swift", "deleted.swift")]
    for path in files:
        path.write_text("old")
        os.utime(path, ns=(1_000_000_000, 2_000_000_000))
    subprocess.run(["git", "-C", str(tmp_path), "add", "sources"], check=True)
    snapshot = _run(tmp_path, "snapshot")
    assert snapshot.returncode == 0, snapshot.stderr
    old_time = files[0].stat().st_mtime_ns
    os.utime(files[0], ns=(3_000_000_000, 4_000_000_000))
    files[1].write_text("new")
    changed_time = files[1].stat().st_mtime_ns
    files[2].unlink()
    new_file = source_dir / "new.swift"
    new_file.write_text("new")
    new_time = new_file.stat().st_mtime_ns
    result = _run(tmp_path, "restore")
    assert result.returncode == 0, result.stderr
    assert files[0].stat().st_mtime_ns == old_time
    assert files[1].stat().st_mtime_ns == changed_time
    assert not files[2].exists()
    assert new_file.stat().st_mtime_ns == new_time


@pytest.mark.parametrize("name", ["../outside.swift", "/tmp/outside.swift", "sources/link.swift"])
def test_restore_never_follows_unsafe_paths(tmp_path: Path, name: str) -> None:
    source_dir = tmp_path / "sources"
    source_dir.mkdir()
    outside = tmp_path / "outside.swift"
    outside.write_text("secret")
    (source_dir / "link.swift").symlink_to(outside)
    original_time = outside.stat().st_mtime_ns
    manifest = tmp_path / "cache/inputs.json"
    manifest.parent.mkdir()
    manifest.write_text(json.dumps({name: {"sha256": "ignored", "mtime_ns": 0}}))
    result = _run(tmp_path, "restore")
    assert result.returncode == 0, result.stderr
    assert outside.stat().st_mtime_ns == original_time


def test_missing_or_invalid_cache_falls_back_to_a_cold_build(tmp_path: Path) -> None:
    assert _run(tmp_path, "restore").returncode == 0
    cache = tmp_path / "cache"
    cache.mkdir()
    (cache / "inputs.json").write_text("incomplete cache")
    assert _run(tmp_path, "restore").returncode == 0
