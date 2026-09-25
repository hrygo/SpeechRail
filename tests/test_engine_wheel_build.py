"""Offline tests for the controlled engine wheel builder and its provenance."""

from __future__ import annotations

import hashlib
import json
import subprocess
import zipfile
from pathlib import Path
from runpy import run_path

import pytest

_ROOT = Path(__file__).resolve().parents[1]
TOOL = run_path(str(_ROOT / "tools" / "build_engine_wheel.py"))
EngineWheelBuildError = TOOL["EngineWheelBuildError"]
build_engine_wheel = TOOL["build_engine_wheel"]
hash_tree = TOOL["hash_tree"]
load_build_spec = TOOL["load_build_spec"]

LOCK_TOOL = run_path(str(_ROOT / "tools" / "update_runtime_lock.py"))
read_engine_wheel_pin = LOCK_TOOL["_read_engine_wheel_pin"]

_WHEEL_NAME = "mlx_audio-0.4.8+speechrail.1-py3-none-any.whl"
_REVISION = "b" * 40


def _git(root: Path, *args: str) -> str:
    completed = subprocess.run(
        ("git", "-C", str(root), *args),
        check=True,
        capture_output=True,
        text=True,
    )
    return completed.stdout.strip()


def _write_spec(
    root: Path,
    *,
    revision: str | None = None,
    initialize_git: bool = True,
) -> Path:
    upstream = root / "vendor" / "engine-build" / "upstream"
    source = upstream / "mlx_audio"
    source.mkdir(parents=True)
    (source / "__init__.py").write_text("ENGINE = 1\n", encoding="utf-8")
    if initialize_git:
        _git(upstream, "init", "-q")
        _git(upstream, "config", "user.name", "SpeechRail Test")
        _git(upstream, "config", "user.email", "speechrail-test@example.invalid")
        _git(upstream, "remote", "add", "origin", "https://github.com/Blaizzy/mlx-audio.git")
        _git(upstream, "add", "mlx_audio")
        _git(upstream, "commit", "-q", "-m", "fixture")
        committed_revision = _git(upstream, "rev-parse", "HEAD")
    else:
        committed_revision = _REVISION
    incremental = (
        root
        / "vendor"
        / "mlx-audio-incremental"
        / "src"
        / "mlx_audio"
        / "tts"
        / "models"
        / "qwen3_tts"
    )
    incremental.mkdir(parents=True)
    (incremental / "incremental.py").write_text(
        "INCREMENTAL = True\n", encoding="utf-8"
    )
    if initialize_git:
        _git(root, "init", "-q")
        _git(root, "config", "user.name", "SpeechRail Test")
        _git(root, "config", "user.email", "speechrail-test@example.invalid")
        _git(root, "add", "vendor/mlx-audio-incremental/src")
    spec = root / "vendor" / "engine-build" / "engine-build.json"
    spec.write_text(
        json.dumps(
            {
                "source_repository": "https://github.com/Blaizzy/mlx-audio",
                "source_revision": revision or committed_revision,
                "wheel_name": _WHEEL_NAME,
                "source_root": "vendor/engine-build/upstream",
                "incremental_root": "vendor/mlx-audio-incremental/src",
                "build_inputs": [
                    "vendor/engine-build/upstream",
                    "vendor/mlx-audio-incremental/src",
                ],
            }
        ),
        encoding="utf-8",
    )
    return spec


def _fake_builder(source_root: Path, out_dir: Path) -> Path:
    assert not (source_root / ".git").exists()
    overlay = (
        source_root
        / "mlx_audio"
        / "tts"
        / "models"
        / "qwen3_tts"
        / "incremental.py"
    )
    assert overlay.read_text(encoding="utf-8") == "INCREMENTAL = True\n"
    wheel = out_dir / _WHEEL_NAME
    with zipfile.ZipFile(wheel, "w") as archive:
        archive.writestr("mlx_audio/__init__.py", "VERSION = '0.4.8'\n")
        archive.writestr(
            "mlx_audio/tts/models/qwen3_tts/incremental.py",
            overlay.read_text(encoding="utf-8"),
        )
    return wheel


def test_hash_tree_is_stable_across_path_order(tmp_path: Path) -> None:
    first = tmp_path / "a.py"
    second = tmp_path / "b.py"
    first.write_bytes(b"first\n")
    second.write_bytes(b"second\n")

    assert hash_tree((first, second), root=tmp_path) == hash_tree(
        (second, first), root=tmp_path
    )
    second.write_bytes(b"changed\n")
    assert hash_tree((first, second), root=tmp_path) != hash_tree(
        (first,), root=tmp_path
    )


def test_build_engine_wheel_writes_provenance_the_lock_generator_accepts(
    tmp_path: Path,
) -> None:
    spec = load_build_spec(tmp_path, _write_spec(tmp_path))

    build = build_engine_wheel(
        spec, root=tmp_path, builder=_fake_builder
    )

    assert build.wheel_path.name == _WHEEL_NAME
    assert build.provenance["source_revision"] == spec.source_revision
    assert build.provenance["source_repository"] == "https://github.com/Blaizzy/mlx-audio"
    assert build.sha256 == hashlib.sha256(build.wheel_path.read_bytes()).hexdigest()
    provenance_path = tmp_path / "vendor" / "engine-build" / "dist" / "provenance.json"
    assert json.loads(provenance_path.read_text(encoding="utf-8")) == dict(
        build.provenance
    )
    # The runtime lock is generated from this exact provenance.
    assert read_engine_wheel_pin(tmp_path) == dict(build.provenance)


def test_build_engine_wheel_is_deterministic_for_the_same_inputs(tmp_path: Path) -> None:
    spec = load_build_spec(tmp_path, _write_spec(tmp_path))

    first = build_engine_wheel(spec, root=tmp_path, builder=_fake_builder)
    second = build_engine_wheel(spec, root=tmp_path, builder=_fake_builder)

    assert first.provenance["build_inputs_sha256"] == second.provenance["build_inputs_sha256"]
    assert first.provenance["patch_sha256"] == second.provenance["patch_sha256"]


def test_build_spec_rejects_an_unpinned_revision(tmp_path: Path) -> None:
    with pytest.raises(EngineWheelBuildError, match="revision"):
        load_build_spec(
            tmp_path,
            _write_spec(tmp_path, revision="main", initialize_git=False),
        )


def test_build_engine_wheel_rejects_missing_inputs(tmp_path: Path) -> None:
    spec = load_build_spec(tmp_path, _write_spec(tmp_path))
    import shutil

    shutil.rmtree(tmp_path / "vendor" / "mlx-audio-incremental" / "src")

    with pytest.raises(EngineWheelBuildError, match="input"):
        build_engine_wheel(spec, root=tmp_path, builder=_fake_builder)


def test_build_engine_wheel_rejects_a_non_archive_result(tmp_path: Path) -> None:
    spec = load_build_spec(tmp_path, _write_spec(tmp_path))

    def broken_builder(source_root: Path, out_dir: Path) -> Path:
        del source_root
        wheel = out_dir / _WHEEL_NAME
        wheel.write_bytes(b"not-a-wheel")
        return wheel

    with pytest.raises(EngineWheelBuildError, match="archive"):
        build_engine_wheel(spec, root=tmp_path, builder=broken_builder)


def test_build_engine_wheel_rejects_an_archive_without_the_incremental_overlay(
    tmp_path: Path,
) -> None:
    spec = load_build_spec(tmp_path, _write_spec(tmp_path))

    def broken_builder(source_root: Path, out_dir: Path) -> Path:
        assert (source_root / "mlx_audio" / "__init__.py").is_file()
        wheel = out_dir / _WHEEL_NAME
        with zipfile.ZipFile(wheel, "w") as archive:
            archive.writestr("mlx_audio/__init__.py", "VERSION = '0.4.8'\n")
        return wheel

    with pytest.raises(EngineWheelBuildError, match="incremental"):
        build_engine_wheel(spec, root=tmp_path, builder=broken_builder)


def test_build_engine_wheel_rejects_a_checkout_at_a_different_revision(
    tmp_path: Path,
) -> None:
    spec = load_build_spec(tmp_path, _write_spec(tmp_path, revision=_REVISION))

    with pytest.raises(EngineWheelBuildError, match="revision"):
        build_engine_wheel(spec, root=tmp_path, builder=_fake_builder)


def test_build_engine_wheel_rejects_a_dirty_checkout(tmp_path: Path) -> None:
    spec = load_build_spec(tmp_path, _write_spec(tmp_path))
    (spec.source_root / "mlx_audio" / "__init__.py").write_text(
        "ENGINE = 2\n", encoding="utf-8"
    )

    with pytest.raises(EngineWheelBuildError, match="dirty"):
        build_engine_wheel(spec, root=tmp_path, builder=_fake_builder)


def test_build_engine_wheel_stages_only_tracked_checkout_files(
    tmp_path: Path,
) -> None:
    spec = load_build_spec(tmp_path, _write_spec(tmp_path))
    (spec.source_root / "untracked.txt").write_text("do not ship\n", encoding="utf-8")

    def inspect_builder(source_root: Path, out_dir: Path) -> Path:
        assert not (source_root / "untracked.txt").exists()
        return _fake_builder(source_root, out_dir)

    build_engine_wheel(spec, root=tmp_path, builder=inspect_builder)


def test_build_engine_wheel_stages_only_tracked_overlay_files(
    tmp_path: Path,
) -> None:
    spec = load_build_spec(tmp_path, _write_spec(tmp_path))
    untracked = spec.incremental_root / "mlx_audio" / "tts" / "models" / "qwen3_tts"
    (untracked / "rogue.py").write_text("ROGUE = True\n", encoding="utf-8")

    def inspect_builder(source_root: Path, out_dir: Path) -> Path:
        assert not (
            source_root
            / "mlx_audio"
            / "tts"
            / "models"
            / "qwen3_tts"
            / "rogue.py"
        ).exists()
        return _fake_builder(source_root, out_dir)

    build_engine_wheel(spec, root=tmp_path, builder=inspect_builder)


def test_default_build_environment_pins_the_source_commit_timestamp(
    tmp_path: Path,
) -> None:
    spec = load_build_spec(tmp_path, _write_spec(tmp_path))
    expected_epoch = _git(spec.source_root, "show", "-s", "--format=%ct", "HEAD")

    environment = TOOL["_engine_build_environment"](spec.source_root)

    assert environment["SOURCE_DATE_EPOCH"] == expected_epoch
