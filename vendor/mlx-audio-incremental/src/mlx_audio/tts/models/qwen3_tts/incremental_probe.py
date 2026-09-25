"""Vendor entry point used by ``tools/probe_tts_incremental.py``.

The probe never imports SpeechRail and never imports MLX directly: it loads this
module by name, checks the pinned vendor identity, and drives the session it
returns.  Everything that decides whether append-after-first-PCM really happens
therefore lives behind this seam, in the same driver the production worker uses.

The vendor identity is a content digest over the driver and backend sources
rather than a git commit, because the extension ships as an additive overlay on
a hash-pinned upstream ``mlx-audio`` release: there is no fork commit to name.
Any change to the two logic modules changes the identity, which is exactly the
property the probe's report needs.
"""

from __future__ import annotations

import hashlib
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any, Final

from .incremental import IncrementalSessionDriver
from .incremental_backend import Qwen3TtsIncrementalBackend

_FALLBACK_VENDOR_COMMIT: Final[str] = "0000000000000000000000000000000000000000"
_IDENTITY_SOURCES: Final[tuple[str, ...]] = ("incremental.py", "incremental_backend.py")


def _vendor_commit() -> str:
    """Digest the incremental logic so the probe reports a content identity."""

    digest = hashlib.sha256()
    here = Path(__file__).resolve().parent
    try:
        for name in _IDENTITY_SOURCES:
            digest.update((here / name).read_bytes())
    except OSError:
        return _FALLBACK_VENDOR_COMMIT
    return digest.hexdigest()[:40]


__speechrail_vendor_commit__ = _vendor_commit()


class _ProbeSession:
    """Project the driver onto the probe's session contract."""

    def __init__(self, driver: IncrementalSessionDriver) -> None:
        self._driver = driver

    @property
    def generation_identity(self) -> str:
        return self._driver.generation_identity

    @property
    def initial_prefill_count(self) -> int:
        return self._driver.initial_prefill_count

    @property
    def prefill_target_tokens(self) -> int:
        return self._driver.prefill_target_tokens

    @property
    def sample_rate(self) -> int:
        return self._driver.sample_rate

    @property
    def peak_memory_bytes(self) -> int | None:
        return self._driver.peak_memory_bytes

    def append_text(self, text: str) -> Sequence[int]:
        return tuple(self._driver.append_text(text))

    def finish_input(self) -> None:
        self._driver.finish_input()

    def step(self, *, max_steps: int) -> Mapping[str, Any]:
        event = self._driver.step(max_steps=max_steps)
        return {
            "kind": event.kind,
            "pcm16": event.pcm16,
            "sample_rate": self._driver.sample_rate if event.kind == "pcm" else 0,
            "generation_identity": self._driver.generation_identity,
        }

    def cancel(self) -> None:
        self._driver.cancel()

    def close(self) -> None:
        self._driver.close()


def open_probe_session(
    *,
    model_dir: str,
    variant: str,
    precision: str,
    speaker: str | None,
    reference_audio_path: str | None,
    reference_text: str | None,
    seed: int,
    local_files_only: bool,
) -> _ProbeSession:
    """Load one model snapshot and open a real append-only generation."""

    del precision  # the snapshot already fixes the quantization
    import mlx.core as mx
    from mlx_audio.tts.models.qwen3_tts.qwen3_tts import load_audio
    from mlx_audio.tts.utils import load

    if variant not in {"custom_voice", "base"}:
        raise ValueError(f"unsupported probe variant: {variant}")
    if variant == "custom_voice" and not speaker:
        raise ValueError("custom_voice probe requires a speaker")
    if variant == "base" and not reference_audio_path:
        raise ValueError("base probe requires a reference audio path")

    model = load(str(model_dir), lazy=False)
    mx.random.seed(int(seed))

    ref_audio = None
    if reference_audio_path is not None:
        ref_audio = load_audio(
            reference_audio_path,
            sample_rate=int(getattr(model, "sample_rate", 24_000)),
        )

    backend = Qwen3TtsIncrementalBackend(
        model,
        variant=variant,
        speaker=speaker,
        language="auto",
        ref_audio=ref_audio,
        ref_text=reference_text,
    )
    driver = IncrementalSessionDriver(backend, backend.encode_target_text)
    return _ProbeSession(driver)


__all__ = ["__speechrail_vendor_commit__", "open_probe_session"]
