"""Tests for Silero Neural VAD adapter and runtime integration."""

from __future__ import annotations

import asyncio
import base64
import math
import os
from pathlib import Path
from typing import Any
from unittest.mock import patch

import numpy as np
import pytest
from pydantic import ValidationError

from speechrail.application.realtime_openai import OpenAIRealtimeSession
from speechrail.application.services import AppOverrides, build_app_services
from speechrail.backends.neural_vad import SileroVadDetector
from speechrail.config import Settings
from test_realtime_openai import (
    FakeSpeechSynthesizer,
    FakeStreamingFactory,
    FakeTranscriber,
    _client,
)


def test_neural_vad_fake_runner_and_reset() -> None:
    calls = []

    def fake_runner(frame: bytes) -> float:
        calls.append(len(frame))
        return 0.85

    detector = SileroVadDetector(runner=fake_runner)
    frame = b"\x00\x00" * 512  # exactly 1024 bytes
    prob = detector.score_frame(frame)
    assert prob == 0.85
    assert len(calls) == 1
    assert calls[0] == 1024

    detector.reset()
    assert detector._state_h is None
    assert detector._state_c is None


def test_neural_vad_frame_size_validation() -> None:
    detector = SileroVadDetector(runner=lambda f: 0.5)
    with pytest.raises(ValueError, match="expects exactly 1024 bytes"):
        detector.score_frame(b"\x00\x00" * 256)


def test_neural_vad_check_readiness() -> None:
    # 1. No path
    ready, reason = SileroVadDetector.check_readiness(None)
    assert not ready
    assert "not configured" in str(reason)

    # 2. Non-existent file
    ready, reason = SileroVadDetector.check_readiness(Path("/nonexistent/silero_vad.onnx"))
    assert not ready
    assert "does not exist" in str(reason)

    # 3. Existing file but runtime missing
    dummy_file = Path(__file__).resolve()
    with patch("importlib.util.find_spec", return_value=None):
        ready, reason = SileroVadDetector.check_readiness(dummy_file)
        assert not ready
        assert "onnxruntime is not installed" in str(reason)


def test_neural_vad_settings_validation(tmp_path: Path) -> None:
    model_file = tmp_path / "silero.onnx"
    model_file.touch()

    # 1. silero requires model_path
    with pytest.raises(
        ValidationError,
        match="realtime_vad_engine=silero requires realtime_vad_model_path",
    ):
        Settings(realtime_vad_engine="silero", realtime_vad_model_path=None)

    # 2. silero cannot be used with shadow_enabled
    with pytest.raises(
        ValidationError,
        match="realtime_vad_shadow_enabled is only supported with realtime_vad_engine='legacy'",
    ):
        Settings(
            realtime_vad_engine="silero",
            realtime_vad_model_path=model_file,
            realtime_vad_shadow_enabled=True,
        )

    # 3. relative path rejected
    with pytest.raises(ValidationError, match="model paths must be external absolute paths"):
        Settings(realtime_vad_model_path=Path("relative/path.onnx"))

    # 4. valid configuration
    settings = Settings(
        realtime_vad_engine="silero",
        realtime_vad_model_path=model_file,
        realtime_vad_shadow_enabled=False,
        realtime_speech_admission_enabled=True,
    )
    assert settings.realtime_vad_engine == "silero"
    assert settings.realtime_vad_model_path == model_file

    # 5. env var loading
    with patch.dict(
        os.environ,
        {
            "SPEECHRAIL_REALTIME_VAD_ENGINE": "silero",
            "SPEECHRAIL_REALTIME_VAD_MODEL_PATH": str(model_file),
        },
    ):
        env_settings = Settings()
        assert env_settings.realtime_vad_engine == "silero"
        assert env_settings.realtime_vad_model_path == model_file


def test_realtime_session_silero_preflight_failure_fails_explicitly() -> None:
    """R3: Explicit silero VAD engine with failed preflight reports backend_not_ready and
    does not fallback.
    """
    dummy_model_path = Path("/nonexistent/silero_vad.onnx")
    client, _ = _client(
        settings_kwargs={
            "realtime_vad_engine": "silero",
            "realtime_vad_model_path": dummy_model_path,
        }
    )
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {
                "type": "session.update",
                "session": {
                    "turn_detection": {
                        "type": "server_vad",
                        "threshold": 0.5,
                    }
                },
            }
        )
        err = socket.receive_json()
        assert err["type"] == "error"
        assert err["error"]["code"] == "backend_not_ready"
        assert "Silero VAD preflight failed" in err["error"]["message"]


def test_settings_silero_engine_requires_admission(tmp_path: Path) -> None:
    """Finding: engine=silero without admission routes appends through the
    legacy path and crashes on SileroVadDetector.process_chunk (missing)."""
    model_file = tmp_path / "silero.onnx"
    model_file.touch()
    with pytest.raises(
        ValidationError,
        match="realtime_vad_engine='silero' requires realtime_speech_admission_enabled",
    ):
        Settings(
            realtime_vad_engine="silero",
            realtime_vad_model_path=model_file,
            realtime_speech_admission_enabled=False,
        )


def test_detect_schema_v4_v56_and_reject_unsupported() -> None:
    """Schema detection accepts v4 and v5/v6, fails closed on anything else."""

    class _Input:
        def __init__(self, name: str) -> None:
            self.name = name

    class _Session:
        def __init__(self, names: tuple[str, ...]) -> None:
            self._names = names

        def get_inputs(self) -> list[_Input]:
            return [_Input(name) for name in self._names]

    assert SileroVadDetector._detect_schema(_Session(("input", "h", "c", "sr"))) == "v4"
    assert SileroVadDetector._detect_schema(_Session(("input", "state"))) == "v56"
    assert SileroVadDetector._detect_schema(_Session(("input", "state", "sr"))) == "v56"

    with pytest.raises(RuntimeError, match="Unsupported Silero VAD ONNX schema"):
        SileroVadDetector._detect_schema(_Session(("input", "foo")))


def test_silero_commit_with_subframe_remainder_does_not_error(tmp_path: Path) -> None:
    """Finding: _commit_audio scored the <1024B raw-buffer remainder through the
    512-sample-strict Silero scorer, raising ValueError and aborting the commit."""

    class _FakeOrtSession:
        def run(self, _names: Any, _inputs: Any) -> list[Any]:
            zero_state = np.zeros((2, 1, 64), dtype=np.float32)
            return [np.zeros((1, 1), dtype=np.float32), zero_state, zero_state.copy()]

    def _fake_ensure(self: SileroVadDetector) -> None:
        self._session = _FakeOrtSession()  # type: ignore[assignment]

    def _fake_ready(cls: type[SileroVadDetector], _path: Path | None) -> tuple[bool, str | None]:
        return True, None

    model_path = tmp_path / "silero.onnx"
    model_path.write_bytes(b"stub")
    settings = Settings(
        qwen3_model_dir=None,
        qwen3_python=None,
        diarization_model_path=None,
        diarization_embedding_model_path=None,
        realtime_vad_engine="silero",
        realtime_vad_model_path=model_path,
        realtime_speech_admission_enabled=True,
    )
    services = build_app_services(
        settings,
        AppOverrides(
            batch_transcriber=FakeTranscriber(),
            tts_synthesizer=FakeSpeechSynthesizer(),
            realtime_asr_factory=FakeStreamingFactory(),
            diarization_engine=None,
        ),
    )
    sent: list[dict[str, Any]] = []

    async def send(event: dict[str, Any]) -> int | None:
        sent.append(event)
        return len(sent)

    with patch.object(SileroVadDetector, "_ensure_session", _fake_ensure), patch.object(
        SileroVadDetector, "check_readiness", classmethod(_fake_ready)
    ):

        async def run() -> None:
            session = OpenAIRealtimeSession(services, session_id="s", send=send)
            await session._update_session(
                {
                    "type": "session.update",
                    "session": {
                        "turn_detection": {"type": "server_vad", "threshold": 0.5}
                    },
                }
            )
            # 640 bytes (20ms) — below one 512-sample frame; commit must not
            # score it through Silero and must close out the empty turn cleanly.
            await session._append_audio(
                {
                    "type": "input_audio_buffer.append",
                    "audio": base64.b64encode(bytes(640)).decode("ascii"),
                }
            )
            await session._commit_audio("client")
            await session.close()

        asyncio.run(run())

    assert all(event["type"] != "error" for event in sent), sent
    committed = [e for e in sent if e["type"] == "input_audio_buffer.committed"]
    assert len(committed) == 1


def test_shared_ort_session_reused_across_detectors(monkeypatch, tmp_path: Path) -> None:
    """ORT InferenceSession is shared per model file across detector instances
    (Run() is thread-safe) while recurrent h/c state stays per-stream."""

    class _Input:
        def __init__(self, name: str) -> None:
            self.name = name

    class _StubSession:
        def get_inputs(self) -> list[_Input]:
            return [_Input(name) for name in ("input", "h", "c", "sr")]

        def run(self, _names: Any, _inputs: Any) -> list[Any]:
            zero_state = np.zeros((2, 1, 64), dtype=np.float32)
            return [np.zeros((1, 1), dtype=np.float32), zero_state, zero_state.copy()]

    import speechrail.backends.neural_vad as neural_vad_module

    model_path = tmp_path / "silero.onnx"
    model_path.write_bytes(b"stub")
    opened: list[Path] = []

    def _fake_open(path: Path) -> Any:
        opened.append(path)
        return _StubSession()

    monkeypatch.setattr(neural_vad_module, "_open_session", _fake_open)
    monkeypatch.setattr(
        SileroVadDetector,
        "check_readiness",
        classmethod(lambda cls, path: (True, None)),
    )

    detector_a = SileroVadDetector(model_path)
    detector_b = SileroVadDetector(model_path)
    prob_a = detector_a.score_frame(b"\x00\x00" * 512)
    detector_b.score_frame(b"\x00\x00" * 512)

    assert prob_a == 0.0
    assert opened == [model_path]
    assert detector_a._session is detector_b._session

    # Per-stream recurrent state: each instance owns separate h/c arrays.
    assert detector_a._state_h is not None
    assert detector_b._state_h is not None
    assert detector_a._state_h is not detector_b._state_h
    detector_a.reset()
    assert detector_a._state_h is None
    assert detector_b._state_h is not None


def test_shadow_vad_records_agreement_metrics(tmp_path: Path) -> None:
    """Shadow scoring is not dead weight: per-frame primary-vs-shadow agreement
    lands in speechrail_realtime_vad_shadow_frames_total."""

    class _StubOrtSession:
        def run(self, _names: Any, _inputs: Any) -> list[Any]:
            zero_state = np.zeros((2, 1, 64), dtype=np.float32)
            return [np.full((1, 1), 0.9, dtype=np.float32), zero_state, zero_state.copy()]

    def _fake_ensure(self: SileroVadDetector) -> None:
        self._session = _StubOrtSession()  # type: ignore[assignment]

    def _fake_ready(cls: type[SileroVadDetector], _path: Path | None) -> tuple[bool, str | None]:
        return True, None

    services = build_app_services(
        Settings(
            qwen3_model_dir=None,
            qwen3_python=None,
            diarization_model_path=None,
            diarization_embedding_model_path=None,
            realtime_speech_admission_enabled=True,
            realtime_vad_shadow_enabled=True,
        ),
        AppOverrides(
            batch_transcriber=FakeTranscriber(),
            tts_synthesizer=FakeSpeechSynthesizer(),
            realtime_asr_factory=FakeStreamingFactory(),
            diarization_engine=None,
        ),
    )
    sent: list[dict[str, Any]] = []

    async def send(event: dict[str, Any]) -> int | None:
        sent.append(event)
        return len(sent)

    sine = b"".join(
        int(5000 * math.sin(2 * math.pi * 200.0 * i / 16_000)).to_bytes(
            2, "little", signed=True
        )
        for i in range(512)
    )

    with patch.object(SileroVadDetector, "_ensure_session", _fake_ensure), patch.object(
        SileroVadDetector, "check_readiness", classmethod(_fake_ready)
    ):

        async def run() -> None:
            session = OpenAIRealtimeSession(services, session_id="s", send=send)
            await session._update_session(
                {
                    "type": "session.update",
                    "session": {
                        "turn_detection": {"type": "server_vad", "threshold": 0.5}
                    },
                }
            )
            # 3 speech frames (primary ~1.0, shadow 0.9 -> both_speech) and
            # 3 silence frames (primary 0.0, shadow 0.9 -> shadow_only).
            for pcm in [sine, sine, sine, bytes(1024), bytes(1024), bytes(1024)]:
                await session._append_audio(
                    {
                        "type": "input_audio_buffer.append",
                        "audio": base64.b64encode(pcm).decode("ascii"),
                    }
                )
            await session.close()

        asyncio.run(run())

    counters = services.metrics.render_json()["counters"]
    assert counters["speechrail_realtime_vad_shadow_frames_total{agreement=\"both_speech\"}"] == 3
    assert counters["speechrail_realtime_vad_shadow_frames_total{agreement=\"shadow_only\"}"] == 3


def test_v56_inference_carries_state_and_context(monkeypatch, tmp_path: Path) -> None:
    """v5/v6 path: [1,576] input (512+64 ctx), state [2,1,128], prob + stateN out."""

    import speechrail.backends.neural_vad as neural_vad_module

    class _Input:
        def __init__(self, name: str) -> None:
            self.name = name

    class _V56Session:
        def get_inputs(self) -> list[_Input]:
            return [_Input("input"), _Input("state")]

        def get_outputs(self) -> list[_Input]:
            return [_Input("output"), _Input("stateN")]

        def run(self, _names: Any, inputs: dict[str, Any]) -> list[Any]:
            assert inputs["input"].shape == (1, 576)
            assert inputs["state"].shape == (2, 1, 128)
            return [
                np.full((1, 1), 0.7, dtype=np.float32),
                np.zeros((2, 1, 128), dtype=np.float32),
            ]

    model_path = tmp_path / "silero_v56.onnx"
    model_path.write_bytes(b"stub")
    monkeypatch.setattr(neural_vad_module, "_open_session", lambda _p: _V56Session())
    monkeypatch.setattr(
        SileroVadDetector,
        "check_readiness",
        classmethod(lambda cls, path: (True, None)),
    )

    detector = SileroVadDetector(model_path)
    assert detector.score_frame(b"\x00\x00" * 512) == pytest.approx(0.7)
    assert detector._schema == "v56"
    assert detector._state is not None
    assert detector._context is not None and detector._context.shape == (1, 64)
    detector.reset()
    assert detector._state is None
    assert detector._context is None


def test_settings_auto_engine_resolution(tmp_path: Path) -> None:
    model_file = tmp_path / "silero.onnx"
    model_file.touch()

    assert Settings().realtime_vad_engine == "auto"
    assert Settings().resolves_to_silero_vad is False
    assert Settings(realtime_vad_engine="legacy").resolves_to_silero_vad is False
    assert (
        Settings(
            realtime_vad_engine="silero", realtime_vad_model_path=model_file
        ).resolves_to_silero_vad
        is True
    )
    assert (
        Settings(
            realtime_vad_engine="auto", realtime_vad_model_path=model_file
        ).resolves_to_silero_vad
        is True
    )
    assert Settings(realtime_vad_engine="auto").resolves_to_silero_vad is False


def test_settings_auto_with_model_requires_admission(tmp_path: Path) -> None:
    model_file = tmp_path / "silero.onnx"
    model_file.touch()
    with pytest.raises(
        ValidationError, match="realtime_vad_engine='auto' with a configured model"
    ):
        Settings(
            realtime_vad_engine="auto",
            realtime_vad_model_path=model_file,
            realtime_speech_admission_enabled=False,
        )


def test_bargein_cooldown_gates_repeat_cancel() -> None:
    """A speech onset inside the cooldown window must not re-cancel TTS."""

    services = build_app_services(
        Settings(
            qwen3_model_dir=None,
            qwen3_python=None,
            diarization_model_path=None,
            diarization_embedding_model_path=None,
            realtime_vad_bargein_cooldown_ms=250,
        ),
        AppOverrides(
            batch_transcriber=FakeTranscriber(),
            tts_synthesizer=FakeSpeechSynthesizer(),
            realtime_asr_factory=FakeStreamingFactory(),
            diarization_engine=None,
        ),
    )

    async def send(event: dict[str, Any]) -> int | None:
        return 0

    session = OpenAIRealtimeSession(services, session_id="s", send=send)

    with patch("speechrail.application.realtime_openai.time.monotonic", return_value=1000.0):
        session._mark_bargein_cooldown()
        assert session._bargein_allowed() is False

    with patch("speechrail.application.realtime_openai.time.monotonic", return_value=1000.3):
        assert session._bargein_allowed() is True

    with patch("speechrail.application.realtime_openai.time.monotonic", return_value=2000.0):
        session._bargein_cooldown_until = 0.0
        assert session._bargein_allowed() is True
