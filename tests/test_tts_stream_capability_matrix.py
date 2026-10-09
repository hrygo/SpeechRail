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

from realtime_wire import session_update, tts_cancel, tts_start
from speechrail.app import create_app
from speechrail.config import Settings
from speechrail.domain.model_spec import required_spec_artifact
from speechrail.infrastructure.voice_registry import FileVoiceRegistry as VoiceRegistry
from test_realtime_tts_incremental import FakeIncrementalSynthesizer, _until

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
    registry = VoiceRegistry.open(
        tmp_path / "custom_voices.json",
        voices_dir=(tmp_path / "custom_voices.json").parent / "audio",
    )
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
def test_each_utterance_binds_its_own_voice_and_model_revision(
    tier: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    voice_store = _register_voices(tmp_path)
    synthesizer = FakeIncrementalSynthesizer()
    client = TestClient(
        create_app(
            Settings(**_tier_kwargs(tier, tmp_path)),
            tts_synthesizer=synthesizer,
            voice_store=voice_store,
        )
    )
    snapshot = client.get("/v1/speechrail/capabilities").json()
    voices = {voice["id"]: voice for voice in snapshot["voices"]}
    system_revision = voices["serena"]["model"]["catalog_revision"]
    clone_revision = voices[_CLONE_ID]["model"]["catalog_revision"]
    assert system_revision != clone_revision

    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            session_update(
                tts={"enabled": True},
                expected_asr_revision=snapshot["models"]["asr"]["catalog_revision"],
            )
        )
        assert socket.receive_json()["type"] == "session.updated"

        for request_id, voice, revision in (
            ("system-first", "serena", system_revision),
            ("clone-next", _CLONE_ID, clone_revision),
            ("system-again", "serena", system_revision),
            ("clone-unpinned", _CLONE_ID, None),
        ):
            socket.send_json(
                tts_start(
                    request_id=request_id,
                    voice=voice,
                    voice_revision=voices[voice]["voice_revision"],
                    expected_model_revision=revision,
                )
            )
            started = _until(socket, "speechrail.tts.started")[-1]
            assert started["request_id"] == request_id
            assert started.get("voice_revision") == voices[voice]["voice_revision"]
            options = synthesizer.sessions[-1].options
            assert options.voice == voice
            assert options.expected_voice_revision == voices[voice]["voice_revision"]
            assert options.expected_model_revision == revision
            socket.send_json(tts_cancel(request_id=request_id))
            assert _until(socket, "speechrail.tts.cancelled")[-1]["request_id"] == request_id

        for request_id, model_revision, voice_revision, expected_code in (
            (
                "wrong-role",
                system_revision,
                voices[_CLONE_ID]["voice_revision"],
                "model_revision_conflict",
            ),
            (
                "stale-model",
                "0" * 40,
                voices[_CLONE_ID]["voice_revision"],
                "model_revision_conflict",
            ),
            ("stale-voice", clone_revision, "vr_" + "0" * 32, "voice_revision_conflict"),
        ):
            open_calls = synthesizer.open_calls
            socket.send_json(
                tts_start(
                    request_id=request_id,
                    voice=_CLONE_ID,
                    voice_revision=voice_revision,
                    expected_model_revision=model_revision,
                )
            )
            error = socket.receive_json()
            assert error["type"] == "error"
            assert error["error"]["code"] == expected_code
            assert synthesizer.open_calls == open_calls

        socket.send_json(
            tts_start(
                request_id="clone-recovered",
                voice=_CLONE_ID,
                voice_revision=voices[_CLONE_ID]["voice_revision"],
                expected_model_revision=clone_revision,
            )
        )
        assert _until(socket, "speechrail.tts.started")[-1]["request_id"] == "clone-recovered"
        socket.send_json(tts_cancel(request_id="clone-recovered"))
        _until(socket, "speechrail.tts.cancelled")
    assert synthesizer.open_calls == 5
    assert all(session.closed for session in synthesizer.sessions)


@pytest.mark.parametrize("tier", _TIERS)
def test_realtime_handshake_reports_the_runtime_role_matrix(
    tier: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The Realtime session object advertises no capability; REST owns discovery.

    The single current wire removed ``speech_capabilities`` from the session so
    that one runtime fact has one home.  The Realtime handshake must therefore
    stay silent about roles while the REST capability snapshot reports the two
    TTS roles the active tier actually routes to.
    """

    voice_store = _register_voices(tmp_path)
    client = TestClient(
        create_app(
            Settings(**_tier_kwargs(tier, tmp_path)),
            tts_synthesizer=FakeIncrementalSynthesizer(),
            voice_store=voice_store,
        )
    )

    with client.websocket_connect("/v1/realtime") as socket:
        created = socket.receive_json()
        assert created["type"] == "session.created"
        assert "speech_capabilities" not in created["session"]

    snapshot = client.get("/v1/speechrail/capabilities")
    assert snapshot.status_code == 200
    models = snapshot.json()["models"]
    # System speakers resolve to CustomVoice and clone references to Base on
    # every target tier; discovery reports both roles from the same plan.
    assert models["tts"]["variant"] == "custom_voice"
    assert models["tts_clone"]["variant"] == "base"
    assert models["tts"]["artifact"] != models["tts_clone"]["artifact"]


@pytest.mark.parametrize("tier", _TIERS)
def test_public_voice_list_reports_each_runtime_role_for_the_tier(
    tier: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    voice_store = _register_voices(tmp_path)
    client = TestClient(
        create_app(
            Settings(**_tier_kwargs(tier, tmp_path)),
            tts_synthesizer=FakeIncrementalSynthesizer(),
            voice_store=voice_store,
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
    voice_store = _register_voices(tmp_path)
    client = TestClient(
        create_app(
            Settings(**_tier_kwargs(tier, tmp_path)),
            tts_synthesizer=FakeIncrementalSynthesizer(),
            voice_store=voice_store,
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

    voice_store = _register_voices(tmp_path)
    client = TestClient(
        create_app(
            Settings(**_tier_kwargs(tier, tmp_path)),
            tts_synthesizer=FakeIncrementalSynthesizer(),
            voice_store=voice_store,
        )
    )
    voices = {voice["id"]: voice for voice in client.get("/v1/voices").json()["data"]}
    streaming = voices["w10_design_fixture"]["streaming"]

    assert streaming["supported"] is False
    assert streaming["reason"] == "voice_design_task_required"
    assert streaming["axes"]["variant_supported"] is False
    assert streaming["limits"] is None
