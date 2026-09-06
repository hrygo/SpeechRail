"""Neural VAD adapter for streaming speech activity detection using Silero VAD (ONNX)."""

from __future__ import annotations

import importlib.util
import threading
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

# One InferenceSession per resolved model path, shared across detector
# instances. ORT documents ``InferenceSession.run`` as thread-safe; the
# recurrent h/c state lives on each detector instance, so sharing the read-only
# weights never crosses streams. Creation is NOT thread-safe, hence the lock.
_shared_sessions: dict[str, Any] = {}
_shared_sessions_lock = threading.Lock()


def _open_session(model_path: Path) -> Any:
    import onnxruntime as ort  # type: ignore[import-untyped]

    options = ort.SessionOptions()
    options.inter_op_num_threads = 1
    options.intra_op_num_threads = 1
    session = ort.InferenceSession(str(model_path), sess_options=options)
    SileroVadDetector._validate_session(session)
    return session


def _shared_session(model_path: Path) -> Any:
    key = str(model_path)
    with _shared_sessions_lock:
        session = _shared_sessions.get(key)
        if session is None:
            session = _open_session(model_path)
            _shared_sessions[key] = session
        return session


@dataclass(frozen=True, slots=True)
class SileroVadConfig:
    threshold: float = 0.5
    sample_rate: int = 16_000
    frame_samples: int = 512  # 32ms at 16kHz


class SileroVadDetector:
    """Session-isolated Silero VAD detector supporting local ONNX runtime or test runners."""

    def __init__(
        self,
        model_path: Path | None = None,
        *,
        runner: Callable[[bytes], float] | None = None,
        config: SileroVadConfig | None = None,
    ) -> None:
        self._model_path = model_path
        self._runner = runner
        self._config = config or SileroVadConfig()
        self._session: Any = None
        self._state_h: Any = None
        self._state_c: Any = None
        self._initialized = False

    @property
    def threshold(self) -> float:
        return self._config.threshold

    @classmethod
    def check_readiness(cls, model_path: Path | None) -> tuple[bool, str | None]:
        if model_path is None:
            return False, "Silero VAD model path is not configured"
        if not model_path.is_file():
            return False, f"Silero VAD model file does not exist: {model_path}"
        try:
            runtime_available = importlib.util.find_spec("onnxruntime") is not None
        except (ImportError, ModuleNotFoundError, ValueError):
            runtime_available = False
        if not runtime_available:
            return False, "onnxruntime is not installed in the environment"
        return True, None

    def reset(self) -> None:
        """Reset internal recurrent state tensors."""
        self._state_h = None
        self._state_c = None

    def score_frame(self, frame: bytes) -> float:
        """Score a single 16kHz PCM16 frame (512 samples = 1024 bytes)."""
        expected_bytes = self._config.frame_samples * 2
        if len(frame) != expected_bytes:
            raise ValueError(
                f"Silero VAD expects exactly {expected_bytes} bytes "
                f"({self._config.frame_samples} samples), got {len(frame)} bytes"
            )

        if self._runner is not None:
            return float(self._runner(frame))

        self._ensure_session()
        return self._infer_frame(frame)

    def _ensure_session(self) -> None:
        if self._session is not None:
            return
        ready, reason = self.check_readiness(self._model_path)
        if not ready:
            raise RuntimeError(f"Silero VAD preflight failed: {reason}")

        assert self._model_path is not None
        self._session = _shared_session(self._model_path)

    @staticmethod
    def _validate_session(session: Any) -> None:
        """Fail closed on unsupported ONNX schemas.

        The adapter implements the Silero v4 recurrent schema (input/h/c/sr,
        hidden state [2, 1, 64]). Silero v5 exports rename the state inputs to
        a single ``state`` tensor and would crash mid-stream, so reject them
        here with an actionable message instead.
        """
        input_names = {item.name for item in session.get_inputs()}
        required = {"input", "h", "c", "sr"}
        if not required <= input_names:
            raise RuntimeError(
                "Unsupported Silero VAD ONNX schema: expected v4 inputs "
                f"{sorted(required)}, got {sorted(input_names)}. Silero v5 "
                "models (input/state/sr) are not supported; provide a v4 "
                "silero_vad.onnx."
            )

    def _infer_frame(self, frame: bytes) -> float:
        import numpy as np

        samples = np.frombuffer(frame, dtype="<i2").astype(np.float32) / 32768.0
        input_tensor = np.expand_dims(samples, axis=0)  # [1, 512]

        if self._state_h is None or self._state_c is None:
            # Silero v4/v5 hidden state shape: [2, 1, 64]
            self._state_h = np.zeros((2, 1, 64), dtype=np.float32)
            self._state_c = np.zeros((2, 1, 64), dtype=np.float32)

        sr_tensor = np.array(self._config.sample_rate, dtype=np.int64)

        # Silero VAD inputs
        inputs = {
            "input": input_tensor,
            "sr": sr_tensor,
            "h": self._state_h,
            "c": self._state_c,
        }
        outputs = self._session.run(None, inputs)
        prob = float(outputs[0][0][0])
        self._state_h = outputs[1]
        self._state_c = outputs[2]
        return prob


__all__ = ["SileroVadConfig", "SileroVadDetector"]
