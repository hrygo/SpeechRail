from __future__ import annotations

import json
from pathlib import Path

import pytest

from speechrail.config.model_locations import (
    ModelLocationError,
    load_model_locations,
    resolve_artifact_dir,
)


def _write_locations(app_home: Path, bindings: dict[str, Path | str]) -> None:
    config = app_home / "config"
    config.mkdir(parents=True, exist_ok=True)
    payload = {
        "schema_version": 1,
        "bindings": {key: str(value) for key, value in bindings.items()},
    }
    (config / "model_locations.json").write_text(json.dumps(payload), encoding="utf-8")


def test_missing_file_yields_no_bindings(tmp_path: Path) -> None:
    assert load_model_locations(tmp_path).bindings == {}


def test_binding_resolves_to_external_root(tmp_path: Path) -> None:
    external = tmp_path / "omlx" / "mlx-community--Qwen3-TTS-12Hz-1.7B-Base-bf16"
    external.mkdir(parents=True)
    _write_locations(tmp_path, {"tts-1.7b-base-bf16": external})

    locations = load_model_locations(tmp_path)

    assert locations.root_for("tts-1.7b-base-bf16") == external
    assert resolve_artifact_dir(tmp_path, "tts-1.7b-base-bf16", locations) == external
    assert locations.root_for("tts-1.7b-custom-q8") is None


def test_unbound_artifact_keeps_managed_default(tmp_path: Path) -> None:
    resolved = resolve_artifact_dir(tmp_path, "tts-1.7b-custom-q8", None)

    assert resolved == tmp_path / "models" / "tts-1.7b-custom-q8"


def test_relative_root_is_rejected(tmp_path: Path) -> None:
    _write_locations(tmp_path, {"asr-1.7b-bf16": "relative/dir"})

    with pytest.raises(ModelLocationError, match="absolute"):
        load_model_locations(tmp_path)


def test_missing_root_is_rejected(tmp_path: Path) -> None:
    _write_locations(tmp_path, {"asr-1.7b-bf16": tmp_path / "omlx" / "absent"})

    with pytest.raises(ModelLocationError, match="missing"):
        load_model_locations(tmp_path)


def test_root_inside_managed_store_is_rejected(tmp_path: Path) -> None:
    managed = tmp_path / "models" / "asr-1.7b-bf16"
    managed.mkdir(parents=True)
    _write_locations(tmp_path, {"asr-1.7b-bf16": managed})

    with pytest.raises(ModelLocationError, match="app-home models/"):
        load_model_locations(tmp_path)


def test_root_inside_diarization_is_rejected(tmp_path: Path) -> None:
    aligned = tmp_path / "diarization" / "aligner-bf16"
    aligned.mkdir(parents=True)
    _write_locations(tmp_path, {"aligner-bf16": aligned})

    with pytest.raises(ModelLocationError, match="app-home diarization/"):
        load_model_locations(tmp_path)


def test_symlink_root_is_rejected(tmp_path: Path) -> None:
    real = tmp_path / "elsewhere"
    real.mkdir()
    link = tmp_path / "link"
    link.symlink_to(real)
    _write_locations(tmp_path, {"asr-1.7b-bf16": link})

    with pytest.raises(ModelLocationError, match="symlink"):
        load_model_locations(tmp_path)


def test_staging_root_is_rejected(tmp_path: Path) -> None:
    staging = tmp_path / "omlx" / ".staging" / "asr-1.7b-bf16"
    staging.mkdir(parents=True)
    _write_locations(tmp_path, {"asr-1.7b-bf16": staging})

    with pytest.raises(ModelLocationError, match="staging"):
        load_model_locations(tmp_path)


def test_unknown_schema_version_is_rejected(tmp_path: Path) -> None:
    _write_locations(tmp_path, {})
    config = tmp_path / "config" / "model_locations.json"
    config.write_text(json.dumps({"schema_version": 99, "bindings": {}}), encoding="utf-8")

    with pytest.raises(ModelLocationError, match="schema_version"):
        load_model_locations(tmp_path)


def test_invalid_artifact_key_is_rejected(tmp_path: Path) -> None:
    external = tmp_path / "omlx"
    external.mkdir()
    _write_locations(tmp_path, {"TTS 1.7b": external})

    with pytest.raises(ModelLocationError, match="artifact key"):
        load_model_locations(tmp_path)


def test_unreadable_config_is_rejected(tmp_path: Path) -> None:
    config = tmp_path / "config"
    config.mkdir()
    (config / "model_locations.json").write_text("{not json", encoding="utf-8")

    with pytest.raises(ModelLocationError, match="unreadable"):
        load_model_locations(tmp_path)
