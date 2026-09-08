"""Regression tests for the availability/security/observability hardening.

Covers: voice mutating-route auth when api_key is configured, private voice
metadata/audio permissions, orphan WAV cleanup on a failed metadata write,
corrupt-registry fail-closed behavior, low-cardinality TTS metric labels and
the granular per-subsystem readiness state.
"""

from __future__ import annotations

import io
import logging
import wave
from collections.abc import AsyncIterator
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient

from speechrail.app import create_app
from speechrail.config import Settings
from speechrail.domain.ports import AudioChunk, SpeechRequest
from speechrail.domain.tts import (
    VoiceInUseError,
    VoiceRegistry,
    VoiceStoreUnavailableError,
    tts_voice_class,
)
from speechrail.observability.metrics import Metrics


def _generate_test_wav(duration_seconds: float = 3.0, sample_rate: int = 24_000) -> bytes:
    num_samples = int(duration_seconds * sample_rate)
    samples = np.zeros(num_samples, dtype="<i2")
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(samples.tobytes())
    return buf.getvalue()


class _CapturingSynth:
    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        async def chunks() -> AsyncIterator[AudioChunk]:
            yield AudioChunk(response_id="r", chunk_index=0, audio=b"\x00\x00")

        return chunks()


def _registry(tmp_path: Path) -> VoiceRegistry:
    return VoiceRegistry(
        storage_path=tmp_path / "custom_voices.json",
        voices_dir=tmp_path / "voices",
    )


def _authed_app(api_key: str = "s3cret") -> TestClient:
    return TestClient(
        create_app(
            Settings(
                api_key=api_key,
                qwen3_model_dir=None,
                qwen3_python=None,
                diarization_model_path=None,
                diarization_embedding_model_path=None,
            ),
            tts_synthesizer=_CapturingSynth(),
        )
    )


# --------------------------------------------------------------------------- #
# 1. Voice mutating routes require auth when api_key is configured
# --------------------------------------------------------------------------- #


def test_voice_mutation_routes_require_auth_when_api_key_set(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    registry = _registry(tmp_path)
    monkeypatch.setattr("speechrail.http.routes.system.get_voice_registry", lambda: registry)
    client = _authed_app()

    # Unauthenticated / wrong-key writes must be rejected with 401.
    assert client.post("/v1/voices", json={"name": "n", "instruction": "i"}).status_code == 401
    resp_wrong = client.post(
        "/v1/voices",
        json={"name": "n", "instruction": "i"},
        headers={"Authorization": "Bearer bad"},
    )
    assert resp_wrong.status_code == 401
    assert client.delete("/v1/voices/whatever").status_code == 401

    # clone: FastAPI binds a valid multipart body before the handler runs, so
    # the auth gate must still reject an unauth/wrong-key caller with 401.
    clone_files = {"audio": ("a.wav", b"\x00\x00", "audio/wav")}
    assert (
        client.post(
            "/v1/voices/clone",
            data={"name": "n", "ref_text": "t"},
            files=clone_files,
        ).status_code
        == 401
    )
    assert (
        client.post(
            "/v1/voices/clone",
            data={"name": "n", "ref_text": "t"},
            files=clone_files,
            headers={"Authorization": "Bearer bad"},
        ).status_code
        == 401
    )

    # Correct-key write succeeds.
    resp_ok = client.post(
        "/v1/voices",
        json={"name": "n", "instruction": "i"},
        headers={"Authorization": "Bearer s3cret"},
    )
    assert resp_ok.status_code == 201
    assert resp_ok.json()["id"].startswith("custom_")

    # Read-only discovery stays open (no key) per the loopback-first contract.
    assert client.get("/v1/voices").status_code == 200
    assert client.get("/v1/models").status_code == 200
    assert client.get("/health").status_code == 200
    assert client.get("/readyz").status_code == 200


# --------------------------------------------------------------------------- #
# 2. Voice metadata & audio permissions
# --------------------------------------------------------------------------- #


def test_voice_metadata_and_wav_files_are_private_0600(tmp_path: Path) -> None:
    registry = _registry(tmp_path)
    wav = _generate_test_wav(duration_seconds=4.0)
    profile = registry.create_cloned_profile(
        name="private voice",
        ref_text="参考文本",
        audio_bytes=wav,
        voice_id="sec_voice",
        duration_seconds=4.0,
    )

    storage = tmp_path / "custom_voices.json"
    assert storage.exists()
    assert (storage.stat().st_mode & 0o777) == 0o600
    assert (tmp_path / "voices").stat().st_mode & 0o777 == 0o700

    wav_path = Path(profile.audio_path)
    assert wav_path.exists()
    assert (wav_path.stat().st_mode & 0o777) == 0o600


# --------------------------------------------------------------------------- #
# 3. Orphan WAV cleanup when the metadata write fails
# --------------------------------------------------------------------------- #


def test_clone_metadata_save_failure_does_not_leave_orphan_wav(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    registry = _registry(tmp_path)

    def _boom(_self: object) -> None:
        raise RuntimeError("disk full")

    monkeypatch.setattr(VoiceRegistry, "_save_custom_voices", _boom)
    wav = _generate_test_wav(duration_seconds=3.0)

    with pytest.raises(RuntimeError, match="disk full"):
        registry.create_cloned_profile(
            name="n", ref_text="t", audio_bytes=wav, voice_id="orphan_check", duration_seconds=3.0
        )

    assert list((tmp_path / "voices").glob("*.wav")) == []
    assert "orphan_check" not in {p.id for p in registry.list_profiles()}


# --------------------------------------------------------------------------- #
# 4. Corrupt registry fails closed but preserves the source bytes
# --------------------------------------------------------------------------- #


def test_corrupt_registry_fails_closed_and_preserves_bytes(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    storage = tmp_path / "custom_voices.json"
    original = b"{ this is not valid json ]"
    storage.write_bytes(original)

    with caplog.at_level(logging.WARNING, logger="speechrail.domain.tts"):
        registry = VoiceRegistry(storage_path=storage, voices_dir=tmp_path / "voices")

    assert "failed to load custom voices" in caplog.text
    with pytest.raises(VoiceStoreUnavailableError):
        registry.list_profiles()
    with pytest.raises(VoiceStoreUnavailableError):
        registry.create_custom_profile(name="n", instruction="i", voice_id="x")
    assert storage.read_bytes() == original
    # Built-in profiles remain usable even while custom storage is unavailable.
    assert registry.get_profile("serena").is_system is True


def test_corrupt_registry_routes_return_stable_503_and_system_tts_survives(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    storage = tmp_path / "custom_voices.json"
    storage.write_bytes(b"{broken")
    registry = _registry(tmp_path)
    monkeypatch.setattr("speechrail.http.routes.system.get_voice_registry", lambda: registry)
    monkeypatch.setattr("speechrail.domain.tts._GLOBAL_VOICE_REGISTRY", registry)
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=_CapturingSynth(),
        )
    )

    listed = client.get("/v1/voices")
    assert listed.status_code == 503
    assert listed.json()["error"]["code"] == "voice_store_unavailable"

    created = client.post(
        "/v1/voices", json={"name": "n", "instruction": "i", "id": "custom_x"}
    )
    assert created.status_code == 503
    assert created.json()["error"]["code"] == "voice_store_unavailable"

    deleted = client.delete("/v1/voices/custom_x")
    assert deleted.status_code == 503
    assert deleted.json()["error"]["code"] == "voice_store_unavailable"

    custom_speech = client.post(
        "/v1/audio/speech",
        json={
            "model": "speechrail/qwen3-tts",
            "input": "测试",
            "voice": "custom_x",
            "response_format": "pcm",
        },
    )
    assert custom_speech.status_code == 503
    assert custom_speech.json()["error"]["code"] == "voice_store_unavailable"

    system_speech = client.post(
        "/v1/audio/speech",
        json={
            "model": "speechrail/qwen3-tts",
            "input": "测试",
            "voice": "serena",
            "response_format": "pcm",
        },
    )
    assert system_speech.status_code == 200


def test_voice_lease_blocks_delete_until_generation_finishes(tmp_path: Path) -> None:
    registry = _registry(tmp_path)
    profile = registry.create_cloned_profile(
        name="leased",
        ref_text="参考文本",
        audio_bytes=_generate_test_wav(3.0),
        voice_id="leased_voice",
        duration_seconds=3.0,
    )
    assert profile.audio_path is not None

    with registry.lease_profile("leased_voice") as leased:
        assert leased.audio_path == profile.audio_path
        with pytest.raises(VoiceInUseError):
            registry.delete_custom_profile("leased_voice")
        assert registry.get_profile("leased_voice").audio_path == profile.audio_path
        assert Path(profile.audio_path).is_file()

    registry.delete_custom_profile("leased_voice")
    assert not Path(profile.audio_path).exists()


# --------------------------------------------------------------------------- #
# 5. Low-cardinality TTS metric labels
# --------------------------------------------------------------------------- #


def test_record_tts_uses_bounded_voice_class_label() -> None:
    metrics = Metrics()
    metrics.record_tts(
        voice_class="system", char_count=10, audio_duration_sec=1.0, inference_duration_sec=2.0
    )
    prom = metrics.render_prometheus()

    assert 'voice_class="system"' in prom
    # No unbounded per-voice-ID label may leak into the exported series.
    assert "voice=" not in prom


def test_tts_voice_class_maps_to_bounded_categories(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    registry = _registry(tmp_path)
    monkeypatch.setattr("speechrail.domain.tts._GLOBAL_VOICE_REGISTRY", registry)

    assert tts_voice_class("serena") == "system"
    assert tts_voice_class("alloy") == "system"  # alias -> serena -> system

    registry.create_custom_profile(name="c", instruction="i", voice_id="custom_c")
    assert tts_voice_class("custom_c") == "custom"

    registry.create_cloned_profile(
        name="cl", ref_text="t", audio_bytes=_generate_test_wav(3.0), voice_id="clone_c",
        duration_seconds=3.0,
    )
    assert tts_voice_class("clone_c") == "clone"
    assert tts_voice_class("does_not_exist") == "custom"


# --------------------------------------------------------------------------- #
# 6. Granular readiness state exposure
# --------------------------------------------------------------------------- #


def test_health_exposes_per_subsystem_readiness_states() -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=_CapturingSynth(),
        )
    )
    payload = client.get("/health").json()
    assert payload["tts_ready"] is True
    assert payload["tts_state"] == "active"
    assert payload["asr_state"] == "unconfigured"
    assert payload["streaming_state"] == "unconfigured"
