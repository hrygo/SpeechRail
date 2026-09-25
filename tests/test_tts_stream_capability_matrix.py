"""W10: the four-tier incremental-TTS capability matrix.

One profile-independent resolver must publish the same verdict on ``/v1/models``,
``/v1/voices`` and the Realtime handshake.  These tests pin that agreement for
every shipped profile and for the two voice shapes that actually reach the
incremental path (a CustomVoice system speaker and a Base clone reference), plus
the VoiceDesign instruction voice that must never be promoted.

Everything here is deterministic: a fake incremental synthesizer stands in for
the vendor adapter, so no model, MLX, download or real audio is involved.
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
from speechrail.config.model_catalog import load_catalog
from speechrail.domain.tts import VoiceRegistry
from test_realtime_tts_incremental import FakeIncrementalSynthesizer

# Preset -> (system voice, clone voice, design voice) incremental expectation.
_PROFILE_MATRIX: dict[str, tuple[bool, bool, bool]] = {
    "light": (True, False, False),
    "balanced": (True, False, False),
    "quality": (False, True, False),
    "extreme": (False, True, False),
}

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


def _register_clone(tmp_path: Path) -> VoiceRegistry:
    registry = VoiceRegistry(tmp_path / "custom_voices.json")
    registry.create_cloned_profile(
        name="W10 clone",
        ref_text="这是一段用于分档能力矩阵的参考文本。",
        audio_bytes=_wav_bytes(),
        voice_id=_CLONE_ID,
        duration_seconds=1.0,
    )
    return registry


def _preset_kwargs(preset_id: str, tmp_path: Path) -> dict[str, Any]:
    """Resolve the active catalog from the managed directory *names* only.

    ``active_model_catalog`` matches on ``Path.name``, so the directories never
    have to exist; they only have to carry the packaged artifact key.
    """

    catalog = load_catalog()
    preset = catalog.preset(preset_id)
    kwargs: dict[str, Any] = {
        "qwen3_model_dir": tmp_path / preset.asr,
        "qwen3_python": None,
        "qwen3_tts_model_dir": tmp_path / preset.tts,
    }
    if preset.tts_clone is not None:
        kwargs["qwen3_tts_clone_model_dir"] = tmp_path / preset.tts_clone
    return kwargs


@pytest.mark.parametrize("preset", sorted(_PROFILE_MATRIX))
def test_realtime_handshake_reports_the_tier_matrix(
    preset: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The handshake verdict must match the tier, not the profile name."""

    monkeypatch.setattr("speechrail.domain.tts._GLOBAL_VOICE_REGISTRY", _register_clone(tmp_path))
    synthesizer = FakeIncrementalSynthesizer()
    client = TestClient(
        create_app(Settings(**_preset_kwargs(preset, tmp_path)), tts_synthesizer=synthesizer)
    )
    system_supported, _, _ = _PROFILE_MATRIX[preset]

    with client.websocket_connect("/v1/realtime") as socket:
        created = socket.receive_json()
        handshake = created["session"]["speech_capabilities"]["streaming_tts"]

    # The handshake answers for the default voice, so it tracks the system voice.
    assert handshake["supported"] is system_supported


@pytest.mark.parametrize("preset", sorted(_PROFILE_MATRIX))
def test_public_voice_list_reports_each_voice_shape_for_the_tier(
    preset: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """``light``/``balanced`` bind CustomVoice; ``quality``/``extreme`` bind Base."""

    monkeypatch.setattr("speechrail.domain.tts._GLOBAL_VOICE_REGISTRY", _register_clone(tmp_path))
    client = TestClient(
        create_app(
            Settings(**_preset_kwargs(preset, tmp_path)),
            tts_synthesizer=FakeIncrementalSynthesizer(),
        )
    )
    voices = {voice["id"]: voice for voice in client.get("/v1/voices").json()["data"]}
    system_supported, clone_supported, _ = _PROFILE_MATRIX[preset]

    system = voices["serena"]["streaming"]
    if system_supported:
        assert system["supported"] is True
        assert system["reason"] is None
        assert system["voice_variant"] == "custom_voice"
        assert system["axes"]["variant_supported"] is True
        assert system["axes"]["reference_ready"] is True
        assert system["limits"]["max_total_codepoints"] == 4096
    else:
        assert system["supported"] is False
        assert system["reason"] == "variant_not_supported"
        assert system["voice_variant"] == "voice_design"
        assert system["axes"]["variant_supported"] is False
        assert system["limits"] is None

    clone = voices[_CLONE_ID]["streaming"]
    assert clone["supported"] is clone_supported
    if clone_supported:
        # quality/extreme carry the Base artifact, so a clone reference is the
        # only incremental identity available on those tiers.
        assert clone["voice_variant"] == "base"
        assert clone["axes"]["artifact_available"] is True
        assert clone["axes"]["reference_ready"] is True
        assert clone["reason"] is None
    else:
        # light/balanced ship no Base artifact at all; the clone asset is kept
        # but this tier must refuse rather than map it onto a CustomVoice speaker.
        assert clone["voice_variant"] is None
        assert clone["axes"]["artifact_available"] is False
        assert clone["reason"] == "voice_disabled"
        assert clone["limits"] is None


@pytest.mark.parametrize("preset", sorted(_PROFILE_MATRIX))
def test_model_scope_never_claims_every_voice_streams(
    preset: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The model surface only reports the voice-independent implementation axis."""

    monkeypatch.setattr("speechrail.domain.tts._GLOBAL_VOICE_REGISTRY", _register_clone(tmp_path))
    client = TestClient(
        create_app(
            Settings(**_preset_kwargs(preset, tmp_path)),
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


def test_voice_design_is_never_advertised_as_an_incremental_role(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A VoiceDesign instruction voice stays complete-text only on every tier."""

    monkeypatch.setattr("speechrail.domain.tts._GLOBAL_VOICE_REGISTRY", _register_clone(tmp_path))
    for preset in sorted(_PROFILE_MATRIX):
        client = TestClient(
            create_app(
                Settings(**_preset_kwargs(preset, tmp_path)),
                tts_synthesizer=FakeIncrementalSynthesizer(),
            )
        )
        voices = {voice["id"]: voice for voice in client.get("/v1/voices").json()["data"]}
        # ``serena`` is a VoiceDesign instruction on quality/extreme and a
        # CustomVoice speaker on light/balanced; only the former may never stream.
        variant = voices["serena"]["streaming"]["voice_variant"]
        if variant == "voice_design":
            assert voices["serena"]["streaming"]["supported"] is False
