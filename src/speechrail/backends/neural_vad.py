"""Neural VAD adapter for streaming speech activity detection using Silero VAD (ONNX).

Supports two Silero ONNX graph schemas, auto-detected at session open:

- ``v4`` (legacy): inputs ``{input, h, c, sr}`` with separate LSTM h/c state
  tensors of shape ``[2, 1, 64]``.
- ``v5/v6`` (current): inputs ``{input, state}`` with a single consolidated
  state tensor of shape ``[2, 1, 128]`` and a 64-sample context the caller must
  carry forward. ``input`` is ``[1, 576]`` = 512 current samples + 64 context.

The public ``score_frame`` contract is unchanged: one 16 kHz PCM16 frame of 512
samples (1024 bytes) in, one speech probability out.
"""

from __future__ import annotations

import importlib.util
import threading
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

# One InferenceSession per resolved model path, shared across detector
# instances. ORT documents ``InferenceSession.run`` as thread-safe; the
# recurrent h/c (or consolidated state + context) lives on each detector
# instance, so sharing the read-only weights never crosses streams. Creation is
# NOT thread-safe, hence the lock.
_shared_sessions: dict[str, Any] = {}
_shared_sessions_lock = threading.Lock()

_SileroSchema = Literal["v4", "v56"]


def _open_session(model_path: Path) -> Any:
    import onnxruntime as ort  # type: ignore[import-untyped]

    options = ort.SessionOptions()
    options.inter_op_num_threads = 1
    options.intra_op_num_threads = 1
    session = ort.InferenceSession(str(model_path), sess_options=options)
    SileroVadDetector._detect_schema(session)
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
        self._schema: _SileroSchema | None = None
        self._input_names: frozenset[str] = frozenset()
        # v4 recurrent state tensors
        self._state_h: Any = None
        self._state_c: Any = None
        # v5/v6 consolidated state + 64-sample context
        self._state: Any = None
        self._context: Any = None
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
            runtime_spec = importlib.util.find_spec("onnxruntime")
            if runtime_spec is None:
                return False, "onnxruntime is not installed in the environment"
            # A module spec alone does not prove that the native provider can be
            # loaded. Import through the ASGI interpreter so health and session
            # preflight agree on the capability that the first frame will use.
            importlib.import_module("onnxruntime")
        except (ImportError, ModuleNotFoundError, OSError, ValueError):
            return False, "onnxruntime is not installed in the environment"
        return True, None

    def reset(self) -> None:
        """Reset internal recurrent state and context tensors."""
        self._state_h = None
        self._state_c = None
        self._state = None
        self._context = None

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
        self._schema = self._detect_schema(self._session)
        self._input_names = frozenset(i.name for i in self._session.get_inputs())

    @staticmethod
    def _detect_schema(session: Any) -> _SileroSchema:
        """Classify a Silero ONNX graph schema from its input names.

        Fails closed on any schema that is neither the legacy v4 recurrent
        form nor the current v5/v6 consolidated-state form.
        """
        input_names = {item.name for item in session.get_inputs()}
        has_state = "state" in input_names
        has_h = "h" in input_names
        has_c = "c" in input_names
        if has_state and not (has_h or has_c):
            return "v56"
        if has_h and has_c and "input" in input_names:
            return "v4"
        raise RuntimeError(
            "Unsupported Silero VAD ONNX schema: got inputs "
            f"{sorted(input_names)}. Expected v4 (input/h/c/sr) or v5/v6 "
            "(input/state)."
        )

    def _infer_frame(self, frame: bytes) -> float:
        import numpy as np

        samples = np.frombuffer(frame, dtype="<i2").astype(np.float32) / 32768.0
        if self._schema == "v56":
            return self._infer_v56(samples)
        # v4, or a session not yet classified (test stubs default to v4).
        return self._infer_v4(samples)

    def _infer_v4(self, samples: Any) -> float:
        import numpy as np

        input_tensor = np.expand_dims(samples, axis=0)  # [1, 512]

        if self._state_h is None or self._state_c is None:
            self._state_h = np.zeros((2, 1, 64), dtype=np.float32)
            self._state_c = np.zeros((2, 1, 64), dtype=np.float32)

        sr_tensor = np.array(self._config.sample_rate, dtype=np.int64)

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

    def _infer_v56(self, samples: Any) -> float:
        import numpy as np

        chunk = np.expand_dims(samples, axis=0)  # [1, 512]

        if self._state is None:
            self._state = np.zeros((2, 1, 128), dtype=np.float32)
        if self._context is None:
            self._context = np.zeros((1, 64), dtype=np.float32)

        # v5/v6 input is [1, 576] = last-64 context + current 512 samples.
        x = np.concatenate([self._context, chunk], axis=1)

        inputs: dict[str, Any] = {"input": x, "state": self._state}
        if "sr" in self._input_names:
            inputs["sr"] = np.array(self._config.sample_rate, dtype=np.int64)

        outputs = self._session.run(None, inputs)
        out_names = [o.name for o in self._session.get_outputs()]
        named = dict(zip(out_names, outputs, strict=True))
        prob_tensor = named.get("output", outputs[0])
        state_tensor = named.get("stateN", named.get("state", outputs[1]))
        prob = float(np.asarray(prob_tensor).reshape(-1)[0])
        self._state = state_tensor
        self._context = x[:, -64:].copy()
        return prob


__all__ = ["SileroVadConfig", "SileroVadDetector"]
