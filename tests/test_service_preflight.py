from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

from speechrail.backends.qwen3_native import MODEL_FILES
from speechrail.service.paths import ServiceLayout
from speechrail.service.preflight import run_preflight


def _write_env(
    layout: ServiceLayout, *, asr: tuple[Path, Path], tts: tuple[Path, Path] | None
) -> None:
    asr_model, asr_python = asr
    values = [
        f"SPEECHRAIL_QWEN3_MODEL_DIR={asr_model}",
        f"SPEECHRAIL_QWEN3_PYTHON={asr_python}",
        "SPEECHRAIL_ALLOW_MODEL_DOWNLOADS=false",
        "SPEECHRAIL_TTS_ALLOW_MODEL_DOWNLOADS=false",
    ]
    if tts is not None:
        tts_model, tts_python = tts
        values.extend(
            [
                f"SPEECHRAIL_QWEN3_TTS_MODEL_DIR={tts_model}",
                f"SPEECHRAIL_QWEN3_TTS_PYTHON={tts_python}",
            ]
        )
    layout.config_file.write_text("\n".join(values) + "\n", encoding="utf-8")
    layout.config_file.chmod(0o600)


def _complete_snapshot(path: Path) -> None:
    path.mkdir(parents=True)
    for name in (*MODEL_FILES, "model.safetensors"):
        (path / name).touch()


def _complete_tts_snapshot(path: Path) -> None:
    path.mkdir(parents=True)
    (path / "config.json").write_text("{}", encoding="utf-8")


def _successful_runner(command: tuple[str, ...]) -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(command, 0, stdout="", stderr="")


def test_preflight_accepts_complete_asr_and_tts_layout(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    layout = ServiceLayout.for_app_home(tmp_path / "SpeechRail")
    layout.ensure_directories()
    asr_model = tmp_path / "asr-model"
    tts_model = tmp_path / "tts-model"
    _complete_snapshot(asr_model)
    _complete_tts_snapshot(tts_model)
    monkeypatch.setattr("speechrail.service.preflight.shutil.which", lambda _: sys.executable)
    _write_env(
        layout, asr=(asr_model, Path(sys.executable)), tts=(tts_model, Path(sys.executable))
    )

    result = run_preflight(layout, require_tts=True, runner=_successful_runner)

    assert result.ok is True
    assert all(check.ok for check in result.checks)


def test_preflight_requires_tts_for_full_install(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    layout = ServiceLayout.for_app_home(tmp_path / "SpeechRail")
    layout.ensure_directories()
    asr_model = tmp_path / "asr-model"
    _complete_snapshot(asr_model)
    monkeypatch.setattr("speechrail.service.preflight.shutil.which", lambda _: sys.executable)
    _write_env(layout, asr=(asr_model, Path(sys.executable)), tts=None)

    result = run_preflight(layout, require_tts=True, runner=_successful_runner)

    assert result.ok is False
    assert next(check for check in result.checks if check.name == "tts_config").ok is False


def test_preflight_allows_explicit_asr_only_mode(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    layout = ServiceLayout.for_app_home(tmp_path / "SpeechRail")
    layout.ensure_directories()
    asr_model = tmp_path / "asr-model"
    _complete_snapshot(asr_model)
    monkeypatch.setattr("speechrail.service.preflight.shutil.which", lambda _: sys.executable)
    _write_env(layout, asr=(asr_model, Path(sys.executable)), tts=None)

    result = run_preflight(layout, require_tts=False, runner=_successful_runner)

    assert result.ok is True
    assert next(check for check in result.checks if check.name == "tts_config").ok is True


def test_preflight_rejects_insecure_config_permissions(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    layout = ServiceLayout.for_app_home(tmp_path / "SpeechRail")
    layout.ensure_directories()
    asr_model = tmp_path / "asr-model"
    _complete_snapshot(asr_model)
    monkeypatch.setattr("speechrail.service.preflight.shutil.which", lambda _: sys.executable)
    _write_env(layout, asr=(asr_model, Path(sys.executable)), tts=None)
    layout.config_file.chmod(0o644)

    result = run_preflight(layout, require_tts=False, runner=_successful_runner)

    assert result.ok is False
    assert next(check for check in result.checks if check.name == "config_permissions").ok is False


def test_preflight_uses_absolute_ffmpeg_fallback(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    layout = ServiceLayout.for_app_home(tmp_path / "SpeechRail")
    layout.ensure_directories()
    asr_model = tmp_path / "asr-model"
    _complete_snapshot(asr_model)
    _write_env(layout, asr=(asr_model, Path(sys.executable)), tts=None)
    ffmpeg = tmp_path / "bin" / "ffmpeg"
    ffmpeg.parent.mkdir()
    ffmpeg.touch()
    ffmpeg.chmod(0o755)
    monkeypatch.setattr("speechrail.service.preflight.shutil.which", lambda _: None)
    monkeypatch.setattr("speechrail.service.preflight.FFMPEG_FALLBACKS", (ffmpeg,))

    result = run_preflight(layout, require_tts=False, runner=_successful_runner)

    assert next(check for check in result.checks if check.name == "ffmpeg").ok is True


def test_preflight_checks_configured_diarization_profile(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    layout = ServiceLayout.for_app_home(tmp_path / "SpeechRail")
    layout.ensure_directories()
    asr_model = tmp_path / "asr-model"
    _complete_snapshot(asr_model)
    sortformer = tmp_path / "sortformer.nemo"
    sortformer.touch()
    monkeypatch.setattr("speechrail.service.preflight.shutil.which", lambda _: sys.executable)
    _write_env(layout, asr=(asr_model, Path(sys.executable)), tts=None)
    with layout.config_file.open("a", encoding="utf-8") as stream:
        stream.write(f"SPEECHRAIL_DIARIZATION_MODEL_PATH={sortformer}\n")

    result = run_preflight(layout, require_tts=False, runner=_successful_runner)

    assert result.ok is True
    assert next(check for check in result.checks if check.name == "diarization_config").ok is True
    assert next(check for check in result.checks if check.name == "diarization_snapshot").ok is True
    assert next(check for check in result.checks if check.name == "diarization_runtime").ok is True
