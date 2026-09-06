"""Tests for Silero Neural VAD adapter and runtime integration."""

from __future__ import annotations

import os
from pathlib import Path
from unittest.mock import patch

import pytest
from pydantic import ValidationError

from speechrail.backends.neural_vad import SileroVadDetector
from speechrail.config import Settings
from test_realtime_openai import _client


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
