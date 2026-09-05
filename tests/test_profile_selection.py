"""Tests for resolving user model selection while preserving runtime configuration."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

from speechrail.backends.qwen3_native import MODEL_FILES
from speechrail.config import Settings
from speechrail.config.model_catalog import (
    ModelArtifact,
    load_catalog,
)
from speechrail.config.selection import resolve_selection
from speechrail.service.paths import ServiceLayout
from speechrail.service.preflight import run_preflight
from speechrail.service.profile_store import ProfileStore


@pytest.fixture
def catalog_artifacts() -> dict[str, ModelArtifact]:
    return {a.key: a for a in load_catalog().artifacts}


def _make_selection(
    preset: str = "quality",
    asr: str = "asr-1.7b-q8",
    tts: str = "tts-1.7b-design-q8",
    generation: int = 1,
) -> dict[str, object]:
    return {
        "schema_version": 1,
        "preset": preset,
        "generation": generation,
        "asr": asr,
        "tts": tts,
        "runtime_lock_id": "runtime-v1",
    }


def _settings(**kwargs: object) -> Settings:
    return Settings(_env_file=None, **kwargs)  # type: ignore[arg-type,call-arg]


def test_existing_install_without_selection_is_unchanged(tmp_path: Path) -> None:
    original = _settings(port=8299)
    assert resolve_selection(original, None, {}, tmp_path) == original


def test_selection_overlays_asr_model_dir_and_identity(
    tmp_path: Path,
    catalog_artifacts: dict[str, ModelArtifact],
) -> None:
    asr_dir = tmp_path / "models" / "asr-0.6b-q8"
    asr_dir.mkdir(parents=True)

    original = _settings(port=8201, device="mps", dtype="float16")
    selection = _make_selection(preset="light", asr="asr-0.6b-q8", tts="tts-0.6b-custom-q8")

    resolved = resolve_selection(original, selection, catalog_artifacts, tmp_path)

    assert resolved.qwen3_model_dir == asr_dir.resolve()
    assert resolved.model_id == "mlx-community/Qwen3-ASR-0.6B-8bit"
    assert resolved.dtype == "int8"


def test_preserves_unrelated_user_configurations(
    tmp_path: Path,
    catalog_artifacts: dict[str, ModelArtifact],
) -> None:
    asr_dir = tmp_path / "models" / "asr-1.7b-q8"
    asr_dir.mkdir(parents=True)

    original = _settings(
        host="127.0.0.2",
        port=9999,
        api_key="secret-test-key",
        compatibility_model_ids=("whisper-1", "custom-alias"),
        worker_idle_timeout_seconds=450.0,
        diarization_model_path=Path("/tmp/fake-diarization"),
        max_upload_bytes=100_000_000,
    )
    selection = _make_selection()

    resolved = resolve_selection(original, selection, catalog_artifacts, tmp_path)

    assert resolved.host == "127.0.0.2"
    assert resolved.port == 9999
    assert resolved.api_key == "secret-test-key"
    assert resolved.compatibility_model_ids == ("whisper-1", "custom-alias")
    assert resolved.worker_idle_timeout_seconds == 450.0
    assert resolved.diarization_model_path == Path("/tmp/fake-diarization")
    assert resolved.max_upload_bytes == 100_000_000


def test_disabled_tts_is_not_automatically_enabled(
    tmp_path: Path,
    catalog_artifacts: dict[str, ModelArtifact],
) -> None:
    asr_dir = tmp_path / "models" / "asr-1.7b-q8"
    asr_dir.mkdir(parents=True)

    original = _settings(qwen3_tts_model_dir=None, qwen3_tts_python=None)
    selection = _make_selection()

    resolved = resolve_selection(original, selection, catalog_artifacts, tmp_path)

    assert resolved.qwen3_tts_model_dir is None


def test_enabled_tts_is_updated_to_selected_model(
    tmp_path: Path,
    catalog_artifacts: dict[str, ModelArtifact],
) -> None:
    asr_dir = tmp_path / "models" / "asr-1.7b-q8"
    asr_dir.mkdir(parents=True)
    tts_dir = tmp_path / "models" / "tts-1.7b-design-q8"
    tts_dir.mkdir(parents=True)

    original = _settings(
        qwen3_tts_python=Path("/fake/python"),
        qwen3_tts_model_dir=Path("/old/tts/dir"),
    )
    selection = _make_selection()

    resolved = resolve_selection(original, selection, catalog_artifacts, tmp_path)

    assert resolved.qwen3_tts_model_dir == tts_dir.resolve()
    assert resolved.tts_model_id == "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit"


def test_disabled_realtime_is_not_automatically_enabled(
    tmp_path: Path,
    catalog_artifacts: dict[str, ModelArtifact],
) -> None:
    asr_dir = tmp_path / "models" / "asr-1.7b-q8"
    asr_dir.mkdir(parents=True)

    original = _settings(realtime_asr_backend="disabled")
    selection = _make_selection()

    resolved = resolve_selection(original, selection, catalog_artifacts, tmp_path)

    assert resolved.realtime_asr_backend == "disabled"


def test_missing_model_directory_raises_error(
    tmp_path: Path,
    catalog_artifacts: dict[str, ModelArtifact],
) -> None:
    original = _settings()
    selection = _make_selection(asr="asr-0.6b-q8")

    with pytest.raises(ValueError, match="missing"):
        resolve_selection(original, selection, catalog_artifacts, tmp_path)


def test_missing_tts_directory_when_tts_enabled_raises_error(
    tmp_path: Path,
    catalog_artifacts: dict[str, ModelArtifact],
) -> None:
    asr_dir = tmp_path / "models" / "asr-1.7b-q8"
    asr_dir.mkdir(parents=True)

    original = _settings(qwen3_tts_python=Path("/fake/python"))
    selection = _make_selection(tts="tts-1.7b-design-q8")

    with pytest.raises(ValueError, match="missing"):
        resolve_selection(original, selection, catalog_artifacts, tmp_path)


def test_corrupt_or_invalid_selection_schema_raises_error(
    tmp_path: Path,
    catalog_artifacts: dict[str, ModelArtifact],
) -> None:
    original = _settings()

    with pytest.raises(ValueError, match="selection"):
        resolve_selection(original, {"invalid": "payload"}, catalog_artifacts, tmp_path)

    with pytest.raises(ValueError, match="selection"):
        resolve_selection(original, {"schema_version": 999}, catalog_artifacts, tmp_path)  # type: ignore[arg-type]


def test_unknown_artifact_key_in_catalog_raises_error(
    tmp_path: Path,
    catalog_artifacts: dict[str, ModelArtifact],
) -> None:
    asr_dir = tmp_path / "models" / "asr-unknown"
    asr_dir.mkdir(parents=True)

    original = _settings()
    selection = _make_selection(asr="asr-unknown")

    with pytest.raises(ValueError, match="unknown ASR artifact"):
        resolve_selection(original, selection, catalog_artifacts, tmp_path)


def test_traversal_rejected(
    tmp_path: Path,
    catalog_artifacts: dict[str, ModelArtifact],
) -> None:
    original = _settings()
    selection = _make_selection(asr="../escape")

    with pytest.raises(ValueError):
        resolve_selection(original, selection, catalog_artifacts, tmp_path)


def test_accepts_model_catalog_instance_directly(
    tmp_path: Path,
) -> None:
    catalog = load_catalog()
    asr_dir = tmp_path / "models" / "asr-1.7b-q8"
    asr_dir.mkdir(parents=True)

    original = _settings()
    selection = _make_selection()

    resolved = resolve_selection(original, selection, catalog, tmp_path)
    assert resolved.qwen3_model_dir == asr_dir.resolve()


def test_preflight_integrates_selection_successfully(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    app_home = tmp_path / "SpeechRail"
    layout = ServiceLayout.for_app_home(app_home)
    layout.ensure_directories()

    # Base env configuration with ASR & TTS enabled
    values = [
        "SPEECHRAIL_QWEN3_MODEL_DIR=/placeholder/asr",
        f"SPEECHRAIL_QWEN3_PYTHON={sys.executable}",
        "SPEECHRAIL_QWEN3_TTS_MODEL_DIR=/placeholder/tts",
        f"SPEECHRAIL_QWEN3_TTS_PYTHON={sys.executable}",
        "SPEECHRAIL_ALLOW_MODEL_DOWNLOADS=false",
        "SPEECHRAIL_TTS_ALLOW_MODEL_DOWNLOADS=false",
    ]
    layout.config_file.write_text("\n".join(values) + "\n", encoding="utf-8")
    layout.config_file.chmod(0o600)

    # Prepare model snapshots according to selection
    asr_model = app_home / "models" / "asr-1.7b-q8"
    asr_model.mkdir(parents=True)
    for name in (*MODEL_FILES, "model.safetensors"):
        (asr_model / name).touch()

    tts_model = app_home / "models" / "tts-1.7b-design-q8"
    tts_model.mkdir(parents=True)
    (tts_model / "config.json").write_text("{}", encoding="utf-8")

    # Persist selection
    store = ProfileStore(app_home)
    store.initialize(_make_selection(asr="asr-1.7b-q8", tts="tts-1.7b-design-q8"))

    monkeypatch.setattr("speechrail.service.preflight.shutil.which", lambda _: sys.executable)

    def _runner(cmd: tuple[str, ...]) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

    result = run_preflight(layout, require_tts=True, runner=_runner)
    assert result.ok is True


def test_preflight_fails_when_selected_model_is_missing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    app_home = tmp_path / "SpeechRail"
    layout = ServiceLayout.for_app_home(app_home)
    layout.ensure_directories()

    values = [
        "SPEECHRAIL_QWEN3_MODEL_DIR=/placeholder/asr",
        f"SPEECHRAIL_QWEN3_PYTHON={sys.executable}",
        "SPEECHRAIL_ALLOW_MODEL_DOWNLOADS=false",
        "SPEECHRAIL_TTS_ALLOW_MODEL_DOWNLOADS=false",
    ]
    layout.config_file.write_text("\n".join(values) + "\n", encoding="utf-8")
    layout.config_file.chmod(0o600)

    # Initialize selection pointing to non-existent model
    store = ProfileStore(app_home)
    store.initialize(_make_selection(asr="asr-1.7b-q8"))

    monkeypatch.setattr("speechrail.service.preflight.shutil.which", lambda _: sys.executable)

    result = run_preflight(layout, require_tts=False)
    assert result.ok is False
    settings_check = next(c for c in result.checks if c.name == "settings")
    assert settings_check.ok is False
    assert "configuration validation failed" in settings_check.message

