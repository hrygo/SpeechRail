"""Vendor adapter for one append-only Qwen3-TTS generation.

The worker process owns exactly one MLX model and one utterance at a time.  This
module is the only place that imports ``mlx_audio``'s incremental driver, and it
maps the driver's four event kinds onto the worker-facing ``ModelStepEvent`` so
the IPC host never depends on vendor names.

The W4 model gate (``tts-incremental-w4``, vendor
``851f9567ecd27ad8f210cefc866c7d01525151e4``) was produced with the vendor
default sampling profile and the ``aligned`` Base ICL layout.  This adapter
therefore pins those values instead of inheriting the batch path's
planner-oriented settings; changing them requires a new model-gate run.
"""

from __future__ import annotations

from collections.abc import Sequence
from typing import Any, Final, Literal, cast

from speechrail.backends.qwen3_tts_stream_host import (
    IncrementalModelSession,
    ModelStepEvent,
)

# The streaming wire only carries registered domain codes; every vendor-level
# generation failure collapses onto this one so the public contract stays small.
_BACKEND_FAILED: Final[str] = "tts_backend_failed"
BASE_LAYOUT: Final[Literal["aligned"]] = "aligned"
DEFAULT_MAX_CHARS: Final[int] = 4_096
# Values used by the W4 probe; keep them explicit so a vendor default drift
# cannot silently invalidate the model gate.
_TEMPERATURE: Final[float] = 0.9
_TOP_K: Final[int] = 50
_TOP_P: Final[float] = 1.0
_REPETITION_PENALTY: Final[float] = 1.05


class Qwen3TtsIncrementalModelSession:
    """Adapt one vendor ``IncrementalSessionDriver`` to the worker seam."""

    def __init__(self, driver: Any) -> None:
        self._driver = driver

    @property
    def generation_identity(self) -> str:
        return cast(str, self._driver.generation_identity)

    @property
    def sample_rate(self) -> int:
        return cast(int, self._driver.sample_rate)

    @property
    def prefill_target_tokens(self) -> int:
        return cast(int, self._driver.prefill_target_tokens)

    @property
    def peak_memory_bytes(self) -> int | None:
        value = self._driver.peak_memory_bytes
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            return None
        return value

    def append_text(self, text: str) -> Sequence[int]:
        return cast(Sequence[int], self._driver.append_text(text))

    def finish_input(self) -> None:
        self._driver.finish_input()

    def step(self, *, max_steps: int) -> ModelStepEvent:
        event = self._driver.step(max_steps=max_steps)
        if event.kind == "pcm":
            return ModelStepEvent(kind="pcm", pcm16=bytes(event.pcm16))
        if event.kind == "waiting_for_text":
            return ModelStepEvent(kind="waiting_for_text")
        if event.kind == "finished":
            return ModelStepEvent(kind="finished")
        return ModelStepEvent(kind="error", error_code=_BACKEND_FAILED)

    def cancel(self) -> None:
        self._driver.cancel()

    def close(self) -> None:
        self._driver.close()


def open_vendor_incremental_session(
    model: Any,
    *,
    variant: Literal["custom_voice", "base"],
    speaker: str | None = None,
    instruct: str | None = None,
    language: str = "auto",
    ref_audio: Any | None = None,
    ref_text: str | None = None,
    max_chars: int = DEFAULT_MAX_CHARS,
) -> IncrementalModelSession:
    """Build one vendor driver; import errors surface as worker inference failure."""

    from mlx_audio.tts.models.qwen3_tts.incremental import (  # type: ignore[import-not-found]
        IncrementalSessionDriver,
    )
    from mlx_audio.tts.models.qwen3_tts.incremental_backend import (  # type: ignore[import-not-found]
        Qwen3TtsIncrementalBackend,
    )

    backend = Qwen3TtsIncrementalBackend(
        model,
        variant=variant,
        speaker=speaker,
        instruct=instruct,
        language=language,
        ref_audio=ref_audio,
        ref_text=ref_text,
        base_layout=BASE_LAYOUT,
        temperature=_TEMPERATURE,
        top_k=_TOP_K,
        top_p=_TOP_P,
        repetition_penalty=_REPETITION_PENALTY,
    )
    driver = IncrementalSessionDriver(
        backend,
        backend.encode_target_text,
        max_chars=max_chars,
    )
    return Qwen3TtsIncrementalModelSession(driver)


__all__ = [
    "Qwen3TtsIncrementalModelSession",
    "open_vendor_incremental_session",
]
