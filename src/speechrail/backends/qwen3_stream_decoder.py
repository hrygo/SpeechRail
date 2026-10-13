"""Cumulative-audio decoder bound to one loaded Qwen3-ASR session."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any, Protocol, cast


class _GenerationResult(Protocol):
    tokens: list[int]
    finish_reason: str
    truncated: bool


@dataclass(frozen=True, slots=True)
class DecoderRuntime:
    """Small vendor seam used by the worker and deterministic fake tests."""

    compute_features: Callable[[Any], tuple[Any, Any]]
    array: Callable[[list[list[int]]], Any]
    arange: Callable[[int], Any]
    stack: Callable[..., Any]
    generation_config: Callable[..., Any]
    generate: Callable[..., Any]
    coerce_generation_result: Callable[[Any, Any], _GenerationResult]
    canonicalize_language: Callable[[str | None], str | None]
    parse_asr_output: Callable[..., tuple[str, str]]


@dataclass(slots=True)
class StreamingDecodeState:
    """Transient decoder state for one bounded PCM segment."""

    raw_tokens: list[int] = field(default_factory=list)
    preview_updates: int = 0
    revision: int = 0
    decoded_samples: int = 0
    text: str = ""
    language: str = ""
    finish_reason: str = ""
    truncated: bool = False


@dataclass(frozen=True, slots=True)
class Qwen3DecodeResult:
    text: str
    language: str
    raw_tokens: tuple[int, ...]
    revision: int
    sample_watermark: int
    finish_reason: str
    truncated: bool


class BoundQwen3Decoder:
    """Re-decode cumulative audio while retaining only a revisable token prefix.

    The decoder owns no model weights. It binds to the already loaded ``Session``
    and starts a fresh vendor generation (and therefore a fresh KV cache) for
    every audio watermark.
    """

    def __init__(
        self,
        session: object,
        *,
        max_new_tokens: int,
        initial_unfixed_samples: int = 64_000,
        rollback_tokens: int = 5,
        runtime: DecoderRuntime | None = None,
    ) -> None:
        if type(max_new_tokens) is not int or max_new_tokens <= 0:
            raise ValueError("max_new_tokens must be a positive integer")
        if type(initial_unfixed_samples) is not int or initial_unfixed_samples < 0:
            raise ValueError("initial_unfixed_samples must be a non-negative integer")
        if type(rollback_tokens) is not int or rollback_tokens < 0:
            raise ValueError("rollback_tokens must be a non-negative integer")
        self._session = session
        model = getattr(session, "model", None)
        tokenizer = getattr(session, "tokenizer", None)
        self._dtype = getattr(session, "dtype", None)
        if model is None or tokenizer is None or self._dtype is None:
            raise ValueError("session must expose its loaded model, tokenizer, and dtype")
        self._model = cast(Any, model)
        self._tokenizer = cast(Any, tokenizer)
        self._max_new_tokens = max_new_tokens
        # Audio arrives at 16 kHz. Keep the first four seconds revisable even
        # when previews are frequent or latest-wins scheduling skips updates.
        self._initial_unfixed_samples = initial_unfixed_samples
        self._rollback_tokens = rollback_tokens
        self._runtime = runtime

    def decode(
        self,
        audio: Any,
        state: StreamingDecodeState,
        *,
        language: str,
        context: str,
        sample_watermark: int,
        max_new_tokens: int | None = None,
        rollback_tokens: int | None = None,
        final: bool = False,
    ) -> Qwen3DecodeResult:
        """Decode one cumulative waveform snapshot and update its revision state."""
        if type(sample_watermark) is not int or sample_watermark <= 0:
            raise ValueError("sample_watermark must be a positive integer")
        if sample_watermark < state.decoded_samples:
            raise ValueError("sample_watermark cannot move backwards")
        token_budget = self._max_new_tokens if max_new_tokens is None else max_new_tokens
        if type(token_budget) is not int or token_budget <= 0:
            raise ValueError("max_new_tokens must be a positive integer")
        if rollback_tokens is not None and (
            type(rollback_tokens) is not int or rollback_tokens < 0
        ):
            raise ValueError("rollback_tokens must be a non-negative integer")

        runtime = self._get_runtime()
        forced_language = runtime.canonicalize_language(
            None if language.strip().lower() in {"", "auto"} else language
        )
        mel, feature_lens = runtime.compute_features(audio)
        audio_features, _ = self._model.audio_tower(mel.astype(self._dtype), feature_lens)
        prompt_tokens = self._tokenizer.build_prompt_tokens(
            n_audio_tokens=int(audio_features.shape[1]),
            language=forced_language,
            context=context,
        )
        # A preview prefix is only a latency heuristic. Formal finalization
        # must be able to correct every token from the complete bounded audio.
        prefix_tokens = [] if final else self._rollback_prefix(
            state.raw_tokens,
            decoded_samples=state.decoded_samples,
            preserve_language_header=forced_language is None,
            rollback_tokens=rollback_tokens,
        )
        if len(prefix_tokens) >= token_budget:
            # A stale or externally restored state must not consume the whole
            # segment budget. Rebuild the hypothesis from audio with no prefix.
            prefix_tokens = []
        remaining_tokens = token_budget - len(prefix_tokens)
        prompt_tokens.extend(prefix_tokens)
        input_ids = runtime.array([prompt_tokens])
        sequence_length = int(input_ids.shape[1])
        positions = runtime.arange(sequence_length)[None, :]
        position_ids = runtime.stack([positions, positions, positions], axis=1)
        config = runtime.generation_config(
            max_new_tokens=remaining_tokens,
            temperature=0.0,
            num_draft_tokens=4,
        )
        generation = runtime.coerce_generation_result(
            runtime.generate(
                model=self._model,
                input_ids=input_ids,
                audio_features=audio_features,
                position_ids=position_ids,
                config=config,
            ),
            config,
        )
        if len(generation.tokens) > remaining_tokens:
            raise RuntimeError("Qwen3-ASR generation exceeded the segment token budget")
        finish_reason = str(generation.finish_reason)
        truncated = bool(generation.truncated)
        if final:
            self._validate_final(finish_reason, truncated)

        generated_tokens = list(generation.tokens)
        if forced_language is not None:
            generated_tokens = self._strip_language_header(generated_tokens)
        raw_tokens = [*prefix_tokens, *generated_tokens]
        raw_text = self._tokenizer.decode(raw_tokens)
        detected_language, text = runtime.parse_asr_output(
            raw_text,
            user_language=forced_language,
        )
        canonical_language = runtime.canonicalize_language(detected_language)
        if not canonical_language:
            canonical_language = detected_language

        if sample_watermark > state.decoded_samples:
            state.preview_updates += 1
        state.raw_tokens = raw_tokens
        state.revision += 1
        state.decoded_samples = sample_watermark
        state.text = text.strip()
        state.language = canonical_language or ""
        state.finish_reason = finish_reason
        state.truncated = truncated
        return Qwen3DecodeResult(
            text=state.text,
            language=state.language,
            raw_tokens=tuple(raw_tokens),
            revision=state.revision,
            sample_watermark=sample_watermark,
            finish_reason=finish_reason,
            truncated=truncated,
        )

    def _rollback_prefix(
        self,
        raw_tokens: list[int],
        *,
        decoded_samples: int,
        preserve_language_header: bool,
        rollback_tokens: int | None = None,
    ) -> list[int]:
        if not raw_tokens or decoded_samples < self._initial_unfixed_samples:
            return []
        if preserve_language_header:
            decoded = self._tokenizer.decode(raw_tokens)
            if decoded.lstrip().startswith("language ") and "<asr_text>" not in decoded:
                return []
        rollback = self._rollback_tokens if rollback_tokens is None else rollback_tokens
        if type(rollback) is not int or rollback < 0:
            raise ValueError("rollback_tokens must be a non-negative integer")
        prefix_end = max(0, len(raw_tokens) - rollback)
        if preserve_language_header:
            prefix_end = max(prefix_end, self._language_header_end(raw_tokens))
        candidate = raw_tokens[:prefix_end]
        while candidate and "\ufffd" in self._tokenizer.decode(candidate):
            if preserve_language_header and prefix_end <= self._language_header_end(raw_tokens):
                return []
            prefix_end -= 1
            candidate = raw_tokens[:prefix_end]
        return candidate

    def _strip_language_header(self, raw_tokens: list[int]) -> list[int]:
        header_end = self._language_header_end(raw_tokens)
        return raw_tokens[header_end:] if header_end else raw_tokens

    def _language_header_end(self, raw_tokens: list[int]) -> int:
        raw_text = self._tokenizer.decode(raw_tokens)
        marker = "<asr_text>"
        marker_end = raw_text.find(marker)
        if marker_end < 0:
            return 0
        header_tokens = self._tokenizer.encode(raw_text[: marker_end + len(marker)])
        if raw_tokens[: len(header_tokens)] == header_tokens:
            return len(header_tokens)
        for end in range(1, len(raw_tokens) + 1):
            if marker in self._tokenizer.decode(raw_tokens[:end]):
                return end
        return 0

    @staticmethod
    def _validate_final(finish_reason: str, truncated: bool) -> None:
        if truncated or finish_reason == "length":
            raise RuntimeError("Qwen3-ASR final decode was truncated by the token budget")
        if finish_reason != "eos":
            raise RuntimeError(
                f"Qwen3-ASR final decode ended with unsupported finish reason: {finish_reason}"
            )

    def _get_runtime(self) -> DecoderRuntime:
        if self._runtime is None:
            self._runtime = _load_vendor_runtime()
        return self._runtime


def _load_vendor_runtime() -> DecoderRuntime:
    """Import optional MLX/vendor dependencies only inside the isolated worker."""
    import mlx.core as mx  # type: ignore[import-not-found]
    from mlx_qwen3_asr.audio import compute_features  # type: ignore[import-not-found]
    from mlx_qwen3_asr.generate import (  # type: ignore[import-not-found]
        GenerationConfig,
        coerce_generation_result,
        generate_with_info,
    )
    from mlx_qwen3_asr.tokenizer import (  # type: ignore[import-not-found]
        canonicalize_language,
        parse_asr_output,
    )

    return DecoderRuntime(
        compute_features=compute_features,
        array=mx.array,
        arange=mx.arange,
        stack=mx.stack,
        generation_config=GenerationConfig,
        generate=generate_with_info,
        coerce_generation_result=coerce_generation_result,
        canonicalize_language=canonicalize_language,
        parse_asr_output=parse_asr_output,
    )
