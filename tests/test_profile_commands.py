from __future__ import annotations

from pathlib import Path

import pytest

from speechrail.config.model_catalog import load_catalog
from speechrail.service import profile_commands as commands
from speechrail.service.diarization_assets import (
    _COREML_FILE_SIZES,
    DiarizationAssetPaths,
)
from speechrail.service.paths import ServiceLayout
from speechrail.service.profile_commands import (
    ProfileCommandError,
    _prepare_diarization_assets,
    _prepare_optional_vad_model,
    _update_env_keys,
    apply_profile,
    list_profiles,
    model_changes,
    profile_status,
    recommend_profile,
    rollback_profile,
)
from speechrail.service.profile_store import ProfileStore
from speechrail.service.profile_switch import ApplyResult


def _selection(preset: str, generation: int) -> dict[str, object]:
    selected = load_catalog().preset(preset)
    return {
        "schema_version": 1,
        "preset": preset,
        "generation": generation,
        "asr": selected.asr,
        "tts": selected.tts,
        "runtime_lock_id": "speechrail-mlx-py312-v1",
    }


def test_catalog_lists_exact_three_tiers_and_balanced_to_light_changes_models() -> None:
    catalog = load_catalog()
    profiles = list_profiles(catalog)
    assert [profile.id for profile in profiles] == ["quality", "balanced", "light"]
    by_id = {profile.id: profile for profile in profiles}
    balanced = by_id["balanced"]
    light = by_id["light"]
    quality = by_id["quality"]
    assert balanced.tts != light.tts
    assert model_changes(balanced, light) == frozenset({"asr", "tts", "aligner"})
    assert balanced.aligner == "aligner-q8"
    assert quality.aligner == "aligner-bf16"
    assert light.aligner is None

    artifacts = {artifact.key: artifact for artifact in catalog.artifacts}

    def artifact_bytes(key: str) -> int:
        return sum(file.size for file in artifacts[key].files)

    sortformer_bytes = sum(_COREML_FILE_SIZES)
    balanced_asr_tts = artifact_bytes("asr-1.7b-q8") + artifact_bytes("tts-0.6b-custom-q8")
    for profile in profiles:
        assert profile.download_bytes > 0
    assert light.download_bytes == (
        artifact_bytes("asr-0.6b-q4") + artifact_bytes("tts-0.6b-custom-q4")
    )
    assert balanced.download_bytes == (
        balanced_asr_tts + artifact_bytes("aligner-q8") + sortformer_bytes
    )
    assert quality.download_bytes > balanced_asr_tts


def test_model_changes_accepts_the_public_mapping_shape() -> None:
    old = {"asr": "large-q8", "tts": "small-custom-q8"}
    new = {"asr": "small-q8", "tts": "small-custom-q8"}
    assert model_changes(old, new) == frozenset({"asr"})


@pytest.mark.parametrize(
    ("memory_gib", "expected"),
    [(8, "light"), (12, "balanced"), (16, "quality"), (64, "quality")],
)
def test_recommendation_uses_memory_only(memory_gib: int, expected: str) -> None:
    assert recommend_profile(memory_gib * 1024**3) == expected


def test_status_is_read_only_and_preserves_unconfigured_directory(tmp_path: Path) -> None:
    assert profile_status(tmp_path).preset is None
    assert not (tmp_path / "config").exists()
    assert not (tmp_path / "state").exists()


def test_apply_prepares_then_switches_exact_preset(tmp_path: Path) -> None:
    events: list[str] = []

    def prepare(preset: str, app_home: Path) -> str:
        events.append(f"prepare:{preset}:{app_home.name}")
        return "prepared-light"

    def switch(prepared_id: str, app_home: Path) -> ApplyResult:
        events.append(f"switch:{prepared_id}:{app_home.name}")
        return ApplyResult("committed", "op_test", None)

    def prepare_vad(app_home: Path) -> None:
        events.append(f"prepare_vad:{app_home.name}")

    def prepare_diarization(preset: str, app_home: Path) -> None:
        events.append(f"prepare_diarization:{preset}:{app_home.name}")

    result = apply_profile(
        "light",
        app_home=tmp_path,
        prepare=prepare,
        switch=switch,
        prepare_vad=prepare_vad,
        prepare_diarization=prepare_diarization,
    )
    assert result.status == "committed"
    assert events == [
        f"prepare:light:{tmp_path.name}",
        f"prepare_vad:{tmp_path.name}",
        f"prepare_diarization:light:{tmp_path.name}",
        f"switch:prepared-light:{tmp_path.name}",
    ]


def test_apply_light_removes_diarization_env(tmp_path: Path, monkeypatch) -> None:
    layout = ServiceLayout.for_app_home(tmp_path)
    layout.config_file.parent.mkdir(parents=True, mode=0o700)
    layout.config_file.write_text(
        "SPEECHRAIL_PORT=8201\n"
        "SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH=/old/coreml\n"
        "SPEECHRAIL_QWEN3_ALIGNER_MODEL_DIR=/old/aligner\n",
        encoding="utf-8",
    )

    monkeypatch.setattr(
        commands,
        "prepare_diarization_assets",
        lambda app_home, *, preset_id, downloader: None,
    )
    monkeypatch.setattr(commands, "ModelScopeDownloader", lambda *, client: object())

    _prepare_diarization_assets("light", tmp_path)

    text = layout.config_file.read_text(encoding="utf-8")
    assert "SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH" not in text
    assert "SPEECHRAIL_QWEN3_ALIGNER_MODEL_DIR" not in text
    assert "SPEECHRAIL_PORT=8201\n" in text
    assert (layout.config_file.stat().st_mode & 0o777) == 0o600


def test_apply_balanced_writes_diarization_env(tmp_path: Path, monkeypatch) -> None:
    layout = ServiceLayout.for_app_home(tmp_path)
    layout.config_file.parent.mkdir(parents=True, mode=0o700)
    layout.config_file.write_text(
        "SPEECHRAIL_PORT=8201\n"
        "SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH=/stale/coreml\n",
        encoding="utf-8",
    )
    paths = DiarizationAssetPaths(
        coreml_model_path=tmp_path / "diarization" / "SortformerNvidiaLow_v2.1.mlmodelc",
        aligner_model_dir=tmp_path / "diarization" / "aligner-q8",
    )

    monkeypatch.setattr(
        commands,
        "prepare_diarization_assets",
        lambda app_home, *, preset_id, downloader: paths,
    )
    monkeypatch.setattr(commands, "ModelScopeDownloader", lambda *, client: object())

    _prepare_diarization_assets("balanced", tmp_path)

    text = layout.config_file.read_text(encoding="utf-8")
    assert f"SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH={paths.coreml_model_path}\n" in text
    assert f"SPEECHRAIL_QWEN3_ALIGNER_MODEL_DIR={paths.aligner_model_dir}\n" in text
    assert text.count("SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH=") == 1
    assert "SPEECHRAIL_PORT=8201\n" in text
    assert (layout.config_file.stat().st_mode & 0o777) == 0o600


def test_env_writer_replaces_exported_and_spaced_keys_in_place(tmp_path: Path) -> None:
    config_file = tmp_path / ".env"
    config_file.write_text(
        "export SPEECHRAIL_PORT=8201\n"
        "SPEECHRAIL_QWEN3_ALIGNER_MODEL_DIR = /old/aligner\n"
        "SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH=/old/coreml\n",
        encoding="utf-8",
    )

    _update_env_keys(
        config_file,
        {
            "SPEECHRAIL_PORT": "8300",
            "SPEECHRAIL_QWEN3_ALIGNER_MODEL_DIR": "/new/aligner",
            "SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH": "/new/coreml",
        },
    )

    text = config_file.read_text(encoding="utf-8")
    assert text.count("SPEECHRAIL_PORT=") == 1
    assert text.count("SPEECHRAIL_QWEN3_ALIGNER_MODEL_DIR") == 1
    assert text.count("SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH") == 1
    assert "export SPEECHRAIL_PORT=8300\n" in text
    assert "SPEECHRAIL_QWEN3_ALIGNER_MODEL_DIR=/new/aligner\n" in text
    assert "SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH=/new/coreml\n" in text
    assert (config_file.stat().st_mode & 0o777) == 0o600


def test_diarization_prepare_failure_is_explicit(tmp_path: Path, monkeypatch) -> None:
    layout = ServiceLayout.for_app_home(tmp_path)
    layout.config_file.parent.mkdir(parents=True, mode=0o700)
    layout.config_file.write_text("SPEECHRAIL_PORT=8201\n", encoding="utf-8")

    def boom(app_home, *, preset_id, downloader):
        raise RuntimeError("download failed")

    monkeypatch.setattr(commands, "prepare_diarization_assets", boom)
    monkeypatch.setattr(commands, "ModelScopeDownloader", lambda *, client: object())

    with pytest.raises(ProfileCommandError):
        _prepare_diarization_assets("balanced", tmp_path)


def test_rollback_uses_previous_complete_pair_without_download(tmp_path: Path) -> None:
    store = ProfileStore(tmp_path)
    old, current = _selection("quality", 1), _selection("light", 2)
    store.initialize(old)
    operation = store.begin(old, current)
    for stage in ("VERIFIED", "STOPPING", "SWITCHING"):
        store.mark(operation, stage)
    store.stage_candidate(operation)
    store.claim_startup_selection()
    store.mark(operation, "SMOKING")
    store.commit(operation)
    calls: list[str] = []

    def switch(prepared_id: str, app_home: Path) -> ApplyResult:
        calls.append(prepared_id)
        return ApplyResult("committed", "op_rollback", None)

    result = rollback_profile(
        app_home=tmp_path,
        switch=switch,
        resolve_previous=lambda selection, app_home: "prepared_quality",
    )
    assert result.status == "committed"
    assert len(calls) == 1 and calls[0].startswith("prepared_")


def test_rollback_without_previous_selection_is_explicit(tmp_path: Path) -> None:
    with pytest.raises(ProfileCommandError, match="previous"):
        rollback_profile(app_home=tmp_path, switch=lambda prepared_id, app_home: None)  # type: ignore[arg-type,return-value]


def test_prepare_optional_vad_writes_env_on_success(tmp_path: Path, monkeypatch) -> None:
    from speechrail.service import vad_model as vad_module

    layout = ServiceLayout.for_app_home(tmp_path)
    layout.config_file.parent.mkdir(parents=True, mode=0o700)
    layout.config_file.write_text("SPEECHRAIL_PORT=8201\n", encoding="utf-8")
    model = tmp_path / "models" / "vad" / "silero_vad.onnx"
    model.parent.mkdir(parents=True)
    model.write_bytes(b"fake-model")

    monkeypatch.setattr(vad_module, "ensure_vad_model", lambda app_home: model)

    _prepare_optional_vad_model(tmp_path)

    text = layout.config_file.read_text(encoding="utf-8")
    assert f"SPEECHRAIL_REALTIME_VAD_MODEL_PATH={model}\n" in text


def test_prepare_optional_vad_swallows_download_failure(tmp_path: Path, monkeypatch) -> None:
    from speechrail.service import vad_model as vad_module

    def boom(app_home: Path) -> None:
        raise RuntimeError("network down")

    monkeypatch.setattr(vad_module, "ensure_vad_model", boom)

    _prepare_optional_vad_model(tmp_path)  # must not raise


def test_prepare_optional_vad_swallows_config_write_failure(tmp_path: Path, monkeypatch) -> None:
    from speechrail.service import vad_model as vad_module

    layout = ServiceLayout.for_app_home(tmp_path)
    layout.config_file.parent.mkdir(parents=True, mode=0o700)
    # Non-UTF-8 content → read_text(encoding="utf-8") raises UnicodeDecodeError
    layout.config_file.write_bytes(b"\xff\xfe\x00 invalid")

    model = tmp_path / "models" / "vad" / "silero_vad.onnx"
    model.parent.mkdir(parents=True)
    model.write_bytes(b"fake-model")

    monkeypatch.setattr(vad_module, "ensure_vad_model", lambda app_home: model)

    _prepare_optional_vad_model(tmp_path)  # must not raise, even with non-UTF-8 .env
