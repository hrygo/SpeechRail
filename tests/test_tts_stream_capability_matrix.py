"""T07: one role-aware incremental-TTS capability matrix.

``/v1/models``, ``/v1/voices`` and the Realtime handshake must agree about what
the active spec can do.  System speakers resolve to CustomVoice, clone
references resolve to Base, and instruction voices stay design-only on every
tier.  The fake synthesizer keeps this deterministic: no model, MLX, download or
real audio is involved.
"""

from __future__ import annotations

import io
import math
import wave
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from speechrail.app import create_app
from speechrail.config import Settings
from speechrail.domain.model_spec import required_spec_artifact
from speechrail.domain.tts import VoiceRegistry
from test_realtime_tts_incremental import FakeIncrementalSynthesizer

_TIERS = ("fast", "quality", "reference")
_CLONE_ID = "w10_clone_fixture"


def _wav_bytes(duration_seconds: float = 1.0, sample_rate: int = 24_000) -> bytes:
    """Deterministic mono PCM16 WAV, independent of numpy."""

    frames = bytearray()
    for index in range(int(duration_seconds * sample_rate)):
        sample = int(0.12 * 32767 * math.sin(2 * math.pi * 220 * index / sample_rate))
        frames += int(sample).to_bytes(2, "little", signed=True)
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        handle.writeframes(bytes(frames))
    return buffer.getvalue()


def _register_voices(tmp_path: Path) -> VoiceRegistry:
    registry = VoiceRegistry(tmp_path / "custom_voices.json")
    registry.create_cloned_profile(
        name="W10 clone",
        ref_text="这是一段用于分档能力矩阵的参考文本。",
        audio_bytes=_wav_bytes(),
        voice_id=_CLONE_ID,
        duration_seconds=1.0,
    )
    registry.create_custom_profile(
        name="W10 design",
        instruction="自然清晰的中文女声，用于设计任务。",
        voice_id="w10_design_fixture",
    )
    return registry


def _tier_kwargs(tier: str, tmp_path: Path) -> dict[str, Any]:
    """Build one explicit v2 selection; directory names never imply identity."""

    asr_key = required_spec_artifact(tier, "asr")  # type: ignore[arg-type]
    tts_key = required_spec_artifact(tier, "tts_custom_voice")  # type: ignore[arg-type]
    base_key = required_spec_artifact(tier, "tts_base")  # type: ignore[arg-type]
    design_key = required_spec_artifact(tier, "voice_design")  # type: ignore[arg-type]
    assert asr_key is not None and tts_key is not None and base_key is not None
    return {
        "qwen3_model_dir": tmp_path / asr_key,
        "qwen3_python": None,
        "qwen3_tts_model_dir": tmp_path / tts_key,
        "qwen3_tts_clone_model_dir": tmp_path / base_key,
        "qwen3_tts_python": None,
        "selection_schema_version": 2,
        "selection_asr_spec": tier,
        "selection_tts_spec": tier,
        "asr_artifact_key": asr_key,
        "tts_artifact_key": tts_key,
        "tts_base_artifact_key": base_key,
        "voice_design_artifact_key": design_key,
    }


@pytest.mark.parametrize("tier", _TIERS)
def test_realtime_handshake_reports_the_runtime_role_matrix(
    tier: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(
        "speechrail.domain.tts._GLOBAL_VOICE_REGISTRY", _register_voices(tmp_path)
    )
    client = TestClient(
        create_app(
            Settings(**_tier_kwargs(tier, tmp_path)),
            tts_synthesizer=FakeIncrementalSynthesizer(),
        )
    )

    with client.websocket_connect("/v1/realtime") as socket:
        created = socket.receive_json()
        handshake = created["session"]["speech_capabilities"]["streaming_tts"]

    # The handshake answers for the default system voice, which always has the
    # CustomVoice role on every target tier.
    assert handshake["supported"] is True
    assert handshake["voice_mode"] == "system"
    assert handshake["voice_variant"] == "custom_voice"


@pytest.mark.parametrize("tier", _TIERS)
def test_public_voice_list_reports_each_runtime_role_for_the_tier(
    tier: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(
        "speechrail.domain.tts._GLOBAL_VOICE_REGISTRY", _register_voices(tmp_path)
    )
    client = TestClient(
        create_app(
            Settings(**_tier_kwargs(tier, tmp_path)),
            tts_synthesizer=FakeIncrementalSynthesizer(),
        )
    )
    voices = {voice["id"]: voice for voice in client.get("/v1/voices").json()["data"]}

    system = voices["serena"]["streaming"]
    assert system["supported"] is True
    assert system["reason"] is None
    assert system["voice_variant"] == "custom_voice"
    assert system["axes"]["variant_supported"] is True
    assert system["axes"]["reference_ready"] is True
    assert system["limits"]["max_total_codepoints"] == 4096

    clone = voices[_CLONE_ID]["streaming"]
    assert clone["supported"] is True
    assert clone["voice_variant"] == "base"
    assert clone["axes"]["artifact_available"] is True
    assert clone["axes"]["reference_ready"] is True
    assert clone["reason"] is None


@pytest.mark.parametrize("tier", _TIERS)
def test_model_scope_never_claims_every_voice_streams(
    tier: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(
        "speechrail.domain.tts._GLOBAL_VOICE_REGISTRY", _register_voices(tmp_path)
    )
    client = TestClient(
        create_app(
            Settings(**_tier_kwargs(tier, tmp_path)),
            tts_synthesizer=FakeIncrementalSynthesizer(),
        )
    )
    models = client.get("/v1/models").json()["data"]
    tts_model = next(item for item in models if item.get("family") == "qwen3_tts")
    streaming_input = tts_model["capabilities"]["streaming_input"]

    assert streaming_input["scope"] == "per_voice"
    assert "supported" not in streaming_input
    assert streaming_input["axes"]["implementation_supported"] is True
    assert streaming_input["axes"]["protocol_negotiated"] is True


@pytest.mark.parametrize("tier", _TIERS)
def test_voice_design_is_never_advertised_as_an_incremental_role(
    tier: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A VoiceDesign instruction voice stays complete-text/design-task only."""

    monkeypatch.setattr(
        "speechrail.domain.tts._GLOBAL_VOICE_REGISTRY", _register_voices(tmp_path)
    )
    client = TestClient(
        create_app(
            Settings(**_tier_kwargs(tier, tmp_path)),
            tts_synthesizer=FakeIncrementalSynthesizer(),
        )
    )
    voices = {voice["id"]: voice for voice in client.get("/v1/voices").json()["data"]}
    streaming = voices["w10_design_fixture"]["streaming"]

    assert streaming["supported"] is False
    assert streaming["reason"] == "voice_design_task_required"
    assert streaming["axes"]["variant_supported"] is False
    assert streaming["limits"] is None
