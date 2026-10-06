"""Isolated native Qwen3-ASR worker; supports both batch and streaming transcription."""

from __future__ import annotations

import argparse
import base64
import binascii
import math
import os
import sys
import traceback
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from dataclasses import field as dataclass_field
from pathlib import Path
from typing import BinaryIO, Final, Protocol

from speechrail.backends.mlx_precision import mlx_dtype, resolve_load_dtype
from speechrail.backends.model_identity import SnapshotIdentity, inspect_model, read_quantization
from speechrail.backends.qwen3_stream_decoder import (
    BoundQwen3Decoder,
    Qwen3DecodeResult,
    StreamingDecodeState,
)
from speechrail.config.model_catalog import QuantizationSpec
from speechrail.domain.asr_policy import ASRPolicy
from speechrail.runtime.limits import MAX_PCM_BYTES
from speechrail.runtime.worker_protocol import (
    MAX_FRAME_BYTES,
    PROTOCOL_VERSION,
    ProtocolError,
    read_frame,
    write_frame,
)

ASR_BACKEND_ID = "mlx-qwen3-asr"
ASR_SAMPLE_RATE = 16_000

# Batch requests are bounded by the shared framed IPC payload; keep a small
# margin for the JSON header and length prefix.
MAX_BATCH_PCM_BYTES = MAX_FRAME_BYTES - 4096
# Defense-in-depth bound for concurrent streaming sessions inside one worker
# process. The main-process NativeRealtimeFactory enforces the configurable
# SPEECHRAIL_REALTIME_MAX_SESSIONS (default 3) before frames reach the worker;
# this constant only guards against a misbehaving protocol peer.
MAX_ACTIVE_STREAMING_SESSIONS = 8
MAX_STREAMING_SEGMENT_MS = MAX_PCM_BYTES * 1_000 // (ASR_SAMPLE_RATE * 2)
LANGUAGES = {
    "auto": "auto",
    "zh": "Chinese", "chinese": "Chinese",
    "en": "English", "english": "English",
    "yue": "Cantonese", "cantonese": "Cantonese",
    "ja": "Japanese", "japanese": "Japanese",
    "ko": "Korean", "korean": "Korean",
    "ar": "Arabic", "arabic": "Arabic",
    "de": "German", "german": "German",
    "fr": "French", "french": "French",
    "es": "Spanish", "spanish": "Spanish",
    "pt": "Portuguese", "portuguese": "Portuguese",
    "id": "Indonesian", "indonesian": "Indonesian",
    "it": "Italian", "italian": "Italian",
    "ru": "Russian", "russian": "Russian",
    "th": "Thai", "thai": "Thai",
    "vi": "Vietnamese", "vietnamese": "Vietnamese",
    "tr": "Turkish", "turkish": "Turkish",
    "hi": "Hindi", "hindi": "Hindi",
    "ms": "Malay", "malay": "Malay",
    "nl": "Dutch", "dutch": "Dutch",
    "sv": "Swedish", "swedish": "Swedish",
    "da": "Danish", "danish": "Danish",
    "fi": "Finnish", "finnish": "Finnish",
    "pl": "Polish", "polish": "Polish",
    "cs": "Czech", "czech": "Czech",
    "fil": "Filipino", "filipino": "Filipino",
    "fa": "Persian", "persian": "Persian",
    "el": "Greek", "greek": "Greek",
    "hu": "Hungarian", "hungarian": "Hungarian",
    "mk": "Macedonian", "macedonian": "Macedonian",
    "ro": "Romanian", "romanian": "Romanian",
}


def _clear_metal_cache() -> None:
    import gc
    try:
        import mlx.core as mx  # type: ignore[import-not-found]

        # Prefer the non-deprecated API; mx.metal.clear_cache is deprecated on mlx>=0.32.
        if hasattr(mx, "clear_cache"):
            mx.clear_cache()
        elif hasattr(mx, "metal") and hasattr(mx.metal, "clear_cache"):
            mx.metal.clear_cache()
    except Exception:
        pass
    gc.collect()


def _dynamic_budget(audio_sec: float, max_new_tokens: int) -> int:
    """Bound the batch decode token budget with linear growth and a hard cap.

    A linear ``audio_sec * 8`` multiplier drives very long inputs toward the hard
    cap for a large decoder tail that adds little transcription value. The lower
    multiplier keeps that tail smaller while a floor keeps short clips transcribable.
    """
    cap = max_new_tokens or 512
    return min(cap, max(32, int(audio_sec * 6) + 24))


def _require_complete_final(result: object) -> None:
    finish_reason = getattr(result, "finish_reason", None)
    truncated = getattr(result, "truncated", False)
    if truncated is True or finish_reason == "length":
        raise RuntimeError("Qwen3-ASR full-segment final was truncated by the token budget")
    if finish_reason != "eos":
        raise RuntimeError(
            f"Qwen3-ASR full-segment final ended with unsupported finish reason: {finish_reason}"
        )


_ENGINE_DTYPE_ALIASES: Final = {
    "float16": "float16",
    "fp16": "float16",
    "f16": "float16",
    "float32": "float32",
    "fp32": "float32",
    "f32": "float32",
    "bfloat16": "bfloat16",
    "bf16": "bfloat16",
    "int8": "int8",
}
_WEIGHT_DTYPE_ALIASES: Final = {
    "BF16": "bfloat16",
    "F16": "float16",
    "F32": "float32",
}
_ENGINE_DTYPE_VALUES: Final = frozenset(_ENGINE_DTYPE_ALIASES.values())
_NON_QUANTIZED_DTYPE_VALUES: Final = frozenset({"float16", "float32", "bfloat16"})
_QUANTIZATION_FORMATS: Final = frozenset({"none", "affine", "mlx"})


def _normalize_engine_dtype(value: object) -> str | None:
    """Normalize the vendor loader's runtime dtype report, or ``None`` when absent."""

    if not isinstance(value, str):
        return None
    return _ENGINE_DTYPE_ALIASES.get(value.removeprefix("mlx.core.").strip().lower())


def _resolve_engine_dtype(
    *,
    snapshot_quantized: bool,
    requested_dtype: str,
    loaded_dtype: object,
) -> str:
    """Return the verified effective weight dtype, never a fallback guess.

    A pre-quantized snapshot carries int8 weights in the artifact itself and is
    loaded directly: it is never re-quantized, and its identity comes from the
    inspected snapshot. A non-quantized snapshot has to be requested at, and
    report, the same precision; when the loader does not report a dtype the worker
    fails closed instead of claiming the device default. An ``int8`` request on a
    non-quantized snapshot is refused outright, because quantizing BF16 weights in
    memory yields weights that are not the certified Q8 artifact and must never be
    labeled as one.
    """

    if snapshot_quantized:
        return "int8"
    if requested_dtype == "int8":
        raise RuntimeError(
            "backend_quantization_unavailable: non-quantized snapshot cannot be int8"
        )
    observed = _normalize_engine_dtype(loaded_dtype)
    if observed is None:
        raise RuntimeError("backend_identity_mismatch: loader reported no dtype")
    if observed != requested_dtype:
        raise RuntimeError(
            f"backend_identity_mismatch: loader reported {observed}, requested {requested_dtype}"
        )
    return observed


def _declared_tensor_dtype(
    identity: SnapshotIdentity, *names: str
) -> str | None:
    """Return the declared safetensors dtype of the first matching tensor group."""

    for name in names:
        for group, dtype in identity.mixed_precision:
            if group == name:
                return _WEIGHT_DTYPE_ALIASES.get(dtype)
    return None


def _resolved_engine_revision() -> str | None:
    """Return the installed engine package version, or ``None`` when undiscoverable."""

    try:
        from importlib.metadata import version

        return version("mlx-qwen3-asr")
    except Exception:
        return None


def _apply_metal_limits(cache_limit_mb: int = 256, memory_limit_mb: int = 0) -> None:
    try:
        import mlx.core as mx

        if cache_limit_mb > 0:
            if hasattr(mx, "metal") and hasattr(mx.metal, "set_cache_limit"):
                mx.metal.set_cache_limit(cache_limit_mb * 1024 * 1024)
            elif hasattr(mx, "set_cache_limit"):
                mx.set_cache_limit(cache_limit_mb * 1024 * 1024)
        if memory_limit_mb > 0:
            if hasattr(mx, "metal") and hasattr(mx.metal, "set_memory_limit"):
                mx.metal.set_memory_limit(memory_limit_mb * 1024 * 1024)
            elif hasattr(mx, "set_memory_limit"):
                mx.set_memory_limit(memory_limit_mb * 1024 * 1024)
    except Exception:
        pass


@dataclass(frozen=True, slots=True)
class WorkerIdentity:
    """Observable identity of one loaded ASR worker.

    ``dtype`` is the effective weight dtype (``int8`` when the artifact ships
    quantized weights). ``compute_dtype`` records the non-quantized weight
    precision the snapshot declares, ``quantization_format`` how the weights are
    quantized, ``compute_config`` the device-scoped compute configuration,
    ``engine_revision`` the installed engine build and ``codec_dtype`` the
    codec/speech-tokenizer precision when the snapshot declares one.
    """

    device: str
    dtype: str
    compute_dtype: str
    compute_config: str
    quantization_format: str
    engine_revision: str | None = None
    codec_dtype: str | None = None
    family: str | None = None
    model_variant: str | None = None
    quantization_bits: int | None = None
    quantization_group_size: int | None = None
    weight_fingerprint: str | None = None
    backend: str = ASR_BACKEND_ID
    sample_rate: int = ASR_SAMPLE_RATE


class WorkerEngine(Protocol):
    identity: WorkerIdentity

    def transcribe(
        self,
        audio: bytes,
        *,
        language: str,
        prompt: str,
        include_timestamps: bool = False,
    ) -> tuple[str, str, list[dict[str, object]]]: ...

    def open_session(
        self,
        *,
        session_id: str,
        language: str,
        context: str,
        chunk_duration_ms: int = 1_000,
        max_context_sec: float = 12.64,
        max_new_tokens: int = 256,
        asr_policy: ASRPolicy | None = None,
        effective_max_segment_ms: int | None = None,
    ) -> None: ...

    def append_audio(self, session_id: str, audio: bytes) -> str: ...

    def partial_text(self, session_id: str) -> str: ...

    def decoded_samples(self, session_id: str) -> int: ...

    def preview_revision(self, session_id: str) -> int: ...

    def finish_streaming(self, session_id: str) -> tuple[str, str]: ...

    def close_session(self, session_id: str) -> None: ...

    def active_session_count(self) -> int: ...

    def has_session(self, session_id: str) -> bool: ...


class ASRBufferOverflowError(RuntimeError):
    """An append would exceed the session's effective PCM budget."""


@dataclass(slots=True)
class _BufferedASRSession:
    language: str
    context: str
    max_new_tokens: int
    policy: ASRPolicy
    effective_max_segment_ms: int
    max_buffer_bytes: int
    pcm: bytearray = dataclass_field(default_factory=bytearray)
    decoder_state: StreamingDecodeState = dataclass_field(default_factory=StreamingDecodeState)
    preview: Qwen3DecodeResult | None = None


EngineFactory = Callable[[Path, str, str, int], WorkerEngine]


def _decode_request(frame: dict[str, object]) -> tuple[str, bytes, str, str, bool]:
    request_id = frame.get("request_id")
    raw_binary = frame.get("_binary")
    encoded = frame.get("pcm_b64")
    language = frame.get("language")
    prompt = frame.get("prompt")
    raw_timestamps = frame.get("include_timestamps", False)
    if (
        not isinstance(request_id, str)
        or not request_id
        or frame.get("sample_rate") != 16_000
        or frame.get("channels") != 1
        or frame.get("sample_width_bytes") != 2
        or not isinstance(language, str)
        or not isinstance(prompt, str)
        or not isinstance(raw_timestamps, bool)
    ):
        raise ProtocolError("invalid transcribe request")
    pcm: bytes
    if isinstance(raw_binary, bytes) and raw_binary:
        pcm = raw_binary
    elif isinstance(encoded, str):
        try:
            pcm = base64.b64decode(encoded, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise ProtocolError("invalid PCM payload") from exc
    else:
        raise ProtocolError("invalid transcribe request")
    if not pcm or len(pcm) % 2 or len(pcm) > MAX_BATCH_PCM_BYTES:
        raise ProtocolError("invalid PCM length")
    canonical_language = LANGUAGES.get(language.strip().lower())
    if canonical_language is None:
        raise ProtocolError("unsupported language")
    return request_id, pcm, canonical_language, prompt, raw_timestamps


def _handle_transcribe(
    frame: dict[str, object],
    output_stream: BinaryIO,
    engine: WorkerEngine,
    identity: WorkerIdentity,
) -> None:
    request_id = frame.get("request_id") if isinstance(frame.get("request_id"), str) else None
    try:
        request_id, pcm, language, prompt, include_timestamps = _decode_request(frame)
        text, detected_language, segments = engine.transcribe(
            pcm, language=language, prompt=prompt, include_timestamps=include_timestamps
        )
        write_frame(
            output_stream,
            {
                "version": PROTOCOL_VERSION,
                "type": "result",
                "request_id": request_id,
                "text": text,
                "language": detected_language,
                "segments": segments,
                "device": identity.device,
                "dtype": identity.dtype,
            },
        )
    except ProtocolError:
        write_frame(
            output_stream,
            {
                "version": PROTOCOL_VERSION,
                "type": "error",
                "code": "worker_invalid_request",
                "request_id": request_id,
            },
        )
    except Exception:
        traceback.print_exc(file=sys.stderr)
        write_frame(
            output_stream,
            {
                "version": PROTOCOL_VERSION,
                "type": "error",
                "code": "worker_inference_error",
                "request_id": request_id,
            },
        )


def _session_id_of(frame: dict[str, object]) -> str | None:
    raw = frame.get("session_id")
    return raw if isinstance(raw, str) and raw else None


def _write_error(
    output_stream: BinaryIO,
    code: str,
    *,
    session_id: str | None = None,
) -> None:
    payload: dict[str, object] = {
        "version": PROTOCOL_VERSION,
        "type": "error",
        "code": code,
    }
    if session_id is not None:
        payload["session_id"] = session_id
    write_frame(output_stream, payload)


def _coerce_session_float(value: object) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float, str)):
        raise ValueError("invalid session option")
    try:
        result = float(value)
    except (OverflowError, TypeError, ValueError) as exc:
        raise ValueError("invalid session option") from exc
    if not math.isfinite(result):
        raise ValueError("invalid session option")
    return result


def _coerce_session_int(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, float, str)):
        raise ValueError("invalid session option")
    if isinstance(value, float) and (not math.isfinite(value) or not value.is_integer()):
        raise ValueError("invalid session option")
    try:
        return int(value)
    except (OverflowError, TypeError, ValueError) as exc:
        raise ValueError("invalid session option") from exc


def _parse_asr_policy(raw: object) -> tuple[ASRPolicy, int]:
    if raw is _MISSING:
        policy = ASRPolicy()
        effective_max_segment_ms = policy.max_segment_ms
    else:
        if not isinstance(raw, Mapping):
            raise ValueError("ASR policy must be an object")
        if any(not isinstance(key, str) for key in raw):
            raise ValueError("ASR policy keys must be strings")
        required = {
            "preview_interval_ms",
            "max_segment_ms",
            "finalization",
            "rollback_tokens",
            "effective_max_segment_ms",
        }
        allowed = required | {"final_deadline_ms"}
        keys = set(raw)
        if not required.issubset(keys) or keys - allowed:
            raise ValueError("ASR policy has missing or unsupported fields")
        raw_effective = raw["effective_max_segment_ms"]
        if type(raw_effective) is not int:
            raise ValueError("effective_max_segment_ms must be an integer")
        effective_max_segment_ms = raw_effective
        policy_fields = {
            key: value for key, value in raw.items() if key != "effective_max_segment_ms"
        }
        policy = ASRPolicy.from_mapping(policy_fields)

    if (
        type(effective_max_segment_ms) is not int
        or effective_max_segment_ms < 1_000
        or effective_max_segment_ms > policy.max_segment_ms
        or effective_max_segment_ms > MAX_STREAMING_SEGMENT_MS
    ):
        raise ValueError("effective_max_segment_ms is outside the supported buffer range")
    return policy, effective_max_segment_ms


def _handle_session_open(
    frame: dict[str, object],
    output_stream: BinaryIO,
    engine: WorkerEngine,
) -> None:
    session_id = _session_id_of(frame)
    if session_id is None:
        _write_error(output_stream, "session_open_failed")
        return
    language = frame.get("language")
    if not isinstance(language, str):
        _write_error(output_stream, "session_open_failed", session_id=session_id)
        return
    raw_context = frame.get("context")
    context = raw_context if isinstance(raw_context, str) else ""
    has_asr_policy = "asr_policy" in frame
    asr_policy: ASRPolicy | None = None
    effective_max_segment_ms: int | None = None
    if has_asr_policy:
        try:
            asr_policy, effective_max_segment_ms = _parse_asr_policy(frame["asr_policy"])
        except (TypeError, ValueError):
            _write_error(output_stream, "asr_policy_invalid", session_id=session_id)
            return
    try:
        chunk_duration_ms = _coerce_session_int(frame.get("chunk_duration_ms", 1_000))
        max_context_sec = _coerce_session_float(frame.get("max_context_sec", 12.64))
        max_new_tokens = _coerce_session_int(frame.get("max_new_tokens", 256))
        if chunk_duration_ms <= 0 or max_context_sec <= 0 or max_new_tokens <= 0:
            raise ValueError("invalid session option")
    except (OverflowError, TypeError, ValueError):
        _write_error(output_stream, "session_open_failed", session_id=session_id)
        return
    if engine.active_session_count() >= MAX_ACTIVE_STREAMING_SESSIONS:
        _write_error(output_stream, "session_limit_reached", session_id=session_id)
        return
    try:
        if has_asr_policy:
            assert asr_policy is not None and effective_max_segment_ms is not None
            engine.open_session(
                session_id=session_id,
                language=language,
                context=context,
                chunk_duration_ms=chunk_duration_ms,
                max_context_sec=max_context_sec,
                max_new_tokens=max_new_tokens,
                asr_policy=asr_policy,
                effective_max_segment_ms=effective_max_segment_ms,
            )
        else:
            engine.open_session(
                session_id=session_id,
                language=language,
                context=context,
                chunk_duration_ms=chunk_duration_ms,
                max_context_sec=max_context_sec,
                max_new_tokens=max_new_tokens,
            )
    except Exception:
        traceback.print_exc(file=sys.stderr)
        _write_error(output_stream, "session_open_failed", session_id=session_id)
        return
    write_frame(
        output_stream,
        {
            "version": PROTOCOL_VERSION,
            "type": "session.opened",
            "session_id": session_id,
            "language": language,
        },
    )


def _handle_audio_append(
    frame: dict[str, object],
    output_stream: BinaryIO,
    engine: WorkerEngine,
) -> None:
    session_id = _session_id_of(frame)
    if session_id is None:
        _write_error(output_stream, "session_invalid")
        return
    raw_binary = frame.get("_binary")
    encoded = frame.get("pcm_b64")
    audio: bytes
    if isinstance(raw_binary, bytes) and raw_binary:
        audio = raw_binary
    elif isinstance(encoded, str):
        try:
            audio = base64.b64decode(encoded, validate=True)
        except Exception:
            _write_error(output_stream, "session_invalid", session_id=session_id)
            return
    else:
        _write_error(output_stream, "session_invalid", session_id=session_id)
        return
    if not audio or len(audio) % 2 or len(audio) > MAX_PCM_BYTES:
        _write_error(output_stream, "session_invalid", session_id=session_id)
        return
    try:
        engine.append_audio(session_id, audio)
    except ASRBufferOverflowError:
        engine.close_session(session_id)
        _write_error(output_stream, "asr_buffer_overflow", session_id=session_id)
        return
    except Exception:
        traceback.print_exc(file=sys.stderr)
        _write_error(output_stream, "session_invalid", session_id=session_id)
        return
    write_frame(
        output_stream,
        {
            "version": PROTOCOL_VERSION,
            "type": "audio.acked",
            "session_id": session_id,
            "bytes": len(audio),
        },
    )


def _handle_flush(
    frame: dict[str, object],
    output_stream: BinaryIO,
    engine: WorkerEngine,
) -> None:
    session_id = _session_id_of(frame)
    if session_id is None or not engine.has_session(session_id):
        _write_error(output_stream, "session_invalid", session_id=session_id)
        return
    try:
        text = engine.partial_text(session_id)
        decoded_samples = engine.decoded_samples(session_id)
        revision = engine.preview_revision(session_id)
    except Exception:
        traceback.print_exc(file=sys.stderr)
        _write_error(output_stream, "worker_inference_error", session_id=session_id)
        return
    write_frame(
        output_stream,
        {
            "version": PROTOCOL_VERSION,
            "type": "event",
            "session_id": session_id,
            "kind": "partial",
            "text": text,
            "language": None,
            "segments": [],
            "sample_watermark": decoded_samples,
            "revision": revision,
        },
    )
    write_frame(
        output_stream,
        {
            "version": PROTOCOL_VERSION,
            "type": "flushed",
            "session_id": session_id,
            "sample_watermark": decoded_samples,
            "revision": revision,
        },
    )


def _handle_commit(
    frame: dict[str, object],
    output_stream: BinaryIO,
    engine: WorkerEngine,
) -> None:
    session_id = _session_id_of(frame)
    if session_id is None or not engine.has_session(session_id):
        _write_error(output_stream, "session_invalid", session_id=session_id)
        return
    try:
        text, language = engine.finish_streaming(session_id)
        write_frame(
            output_stream,
            {
                "version": PROTOCOL_VERSION,
                "type": "event",
                "session_id": session_id,
                "kind": "completed",
                "text": text,
                "language": language or None,
            },
        )
        write_frame(
            output_stream,
            {
                "version": PROTOCOL_VERSION,
                "type": "finished",
                "session_id": session_id,
                "final": True,
            },
        )
    except Exception:
        traceback.print_exc(file=sys.stderr)
        _write_error(output_stream, "worker_inference_error", session_id=session_id)
    finally:
        engine.close_session(session_id)


_MISSING = object()


def _loader_sources(session: object) -> tuple[object, ...]:
    model = getattr(session, "model", None)
    return (
        getattr(session, "model_info", None),
        getattr(session, "config", None),
        model,
        getattr(model, "config", None),
    )


def _loader_value(sources: tuple[object, ...], names: tuple[str, ...]) -> object:
    for source in sources:
        if source is None:
            continue
        for name in names:
            if isinstance(source, Mapping):
                value = source.get(name, _MISSING)
            else:
                value = getattr(source, name, _MISSING)
            if value is not _MISSING and value is not None:
                return value
    return _MISSING


def _loader_quantization(sources: tuple[object, ...]) -> QuantizationSpec | None:
    declarations: list[QuantizationSpec] = []
    for source in sources:
        if source is None:
            continue
        for field_name in ("quantization", "quantization_config"):
            if isinstance(source, Mapping):
                raw = source.get(field_name, _MISSING)
            else:
                raw = getattr(source, field_name, _MISSING)
            if raw is _MISSING or raw is None:
                continue
            if isinstance(raw, QuantizationSpec):
                declarations.append(raw)
            elif isinstance(raw, Mapping):
                declarations.append(
                    read_quantization({field_name: raw})
                )
            else:
                raise RuntimeError("backend_identity_mismatch: invalid loader quantization")

        if isinstance(source, Mapping):
            bits = source.get("quantization_bits", _MISSING)
        else:
            bits = getattr(source, "quantization_bits", _MISSING)
        group_size = (
            source.get("quantization_group_size", _MISSING)
            if isinstance(source, Mapping)
            else getattr(source, "quantization_group_size", _MISSING)
        )
        if bits is not _MISSING or group_size is not _MISSING:
            if bits is _MISSING:
                bits = None
            if group_size is _MISSING:
                group_size = None
            declarations.append(
                read_quantization(
                    {
                        "quantization": {
                            "bits": bits,
                            "group_size": group_size,
                        }
                    }
                )
            )

    if not declarations:
        return None
    first = declarations[0]
    if any(
        (item.bits, item.group_size) != (first.bits, first.group_size)
        for item in declarations[1:]
    ):
        raise RuntimeError("backend_identity_mismatch: loader quantization conflict")
    return first


def _check_loader_identity(
    session: object, expected: SnapshotIdentity
) -> tuple[object, ...]:
    sources = _loader_sources(session)
    family = _loader_value(sources, ("family", "model_type"))
    if family is not _MISSING and family != expected.family:
        raise RuntimeError("backend_identity_mismatch: loader family mismatch")
    variant = _loader_value(sources, ("model_variant", "variant"))
    if variant is not _MISSING and variant != expected.variant:
        raise RuntimeError("backend_identity_mismatch: loader variant mismatch")
    loaded_quantization = _loader_quantization(sources)
    if loaded_quantization is not None and (
        loaded_quantization.bits,
        loaded_quantization.group_size,
    ) != (expected.quantization.bits, expected.quantization.group_size):
        raise RuntimeError("backend_identity_mismatch: loader quantization mismatch")
    return sources


def _identity_quantization(identity: object) -> tuple[int | None, int | None]:
    bits = getattr(identity, "quantization_bits", None)
    group_size = getattr(identity, "quantization_group_size", None)
    if bits is not None and (
        not isinstance(bits, int) or isinstance(bits, bool) or bits not in {4, 8}
    ):
        raise ValueError("invalid worker quantization bits")
    if group_size is not None and (
        not isinstance(group_size, int) or isinstance(group_size, bool) or group_size <= 0
    ):
        raise ValueError("invalid worker quantization group size")
    if bits is None and group_size is not None:
        raise ValueError("unquantized worker cannot report group size")
    if bits is not None and group_size is None:
        raise ValueError("quantized worker must report group size")
    return bits, group_size


def _identity_matches_asr(identity: object, *, device: str, dtype: str) -> bool:
    try:
        bits, _ = _identity_quantization(identity)
    except ValueError:
        return False
    family = getattr(identity, "family", None)
    variant = getattr(identity, "model_variant", None)
    backend = getattr(identity, "backend", None)
    sample_rate = getattr(identity, "sample_rate", None)
    if backend is not None and backend != ASR_BACKEND_ID:
        return False
    if sample_rate is not None and sample_rate != ASR_SAMPLE_RATE:
        return False
    if family is not None and family != "qwen3_asr":
        return False
    if variant is not None and variant != "asr":
        return False
    compute_config = getattr(identity, "compute_config", None)
    if compute_config is not None and compute_config != device:
        return False
    compute_dtype = getattr(identity, "compute_dtype", None)
    if compute_dtype is not None and compute_dtype not in _NON_QUANTIZED_DTYPE_VALUES:
        return False
    quantization_format = getattr(identity, "quantization_format", None)
    if quantization_format is not None:
        if quantization_format not in _QUANTIZATION_FORMATS:
            return False
        if (bits is None) != (quantization_format == "none"):
            return False
    codec_dtype = getattr(identity, "codec_dtype", None)
    if codec_dtype is not None and codec_dtype not in _ENGINE_DTYPE_VALUES:
        return False
    engine_revision = getattr(identity, "engine_revision", None)
    if engine_revision is not None and (
        not isinstance(engine_revision, str) or not engine_revision
    ):
        return False
    expected_dtype = "int8" if bits is not None else (dtype or (
        "float16" if device == "mps" else "float32"
    ))
    return getattr(identity, "device", None) == device and getattr(
        identity, "dtype", None
    ) == expected_dtype


def _ready_identity_fields(identity: object) -> dict[str, object]:
    fields: dict[str, object] = {}
    for attribute in (
        "backend",
        "sample_rate",
        "family",
        "model_variant",
        "compute_dtype",
        "compute_config",
        "quantization_format",
        "quantization_bits",
        "quantization_group_size",
        "engine_revision",
        "codec_dtype",
        "weight_fingerprint",
    ):
        value = getattr(identity, attribute, None)
        if value is not None:
            fields[attribute] = value
    return fields


def serve(
    input_stream: BinaryIO,
    output_stream: BinaryIO,
    *,
    model_dir: Path,
    device: str,
    dtype: str = "float16",
    max_new_tokens: int = 512,
    engine_factory: EngineFactory | None = None,
) -> None:
    if engine_factory is None:
        engine_factory = Qwen3Engine
    try:
        start = read_frame(input_stream)
    except ProtocolError:
        _write_error(output_stream, "worker_invalid_start")
        return
    if (
        start is None
        or start.get("version") != PROTOCOL_VERSION
        or start.get("type") != "start"
        or start.get("model_dir") != str(model_dir)
        or start.get("device") != device
    ):
        write_frame(
            output_stream,
            {"version": PROTOCOL_VERSION, "type": "error", "code": "worker_invalid_start"},
        )
        return
    try:
        engine: WorkerEngine
        if engine_factory is Qwen3Engine:
            engine = Qwen3Engine(model_dir, device, dtype, max_new_tokens)
        else:
            engine = engine_factory(model_dir, device, dtype, max_new_tokens)
    except Exception:
        traceback.print_exc(file=sys.stderr)
        write_frame(
            output_stream,
            {"version": PROTOCOL_VERSION, "type": "error", "code": "worker_load_error"},
        )
        return
    identity = engine.identity
    if not _identity_matches_asr(identity, device=device, dtype=dtype):
        write_frame(
            output_stream,
            {"version": PROTOCOL_VERSION, "type": "error", "code": "backend_identity_mismatch"},
        )
        return
    ready: dict[str, object] = {
        "version": PROTOCOL_VERSION,
        "type": "ready",
        "device": identity.device,
        "dtype": identity.dtype,
        "model_loaded": True,
    }
    ready.update(_ready_identity_fields(identity))
    write_frame(
        output_stream,
        ready,
    )
    while True:
        try:
            frame = read_frame(input_stream)
        except ProtocolError:
            write_frame(
                output_stream,
                {"version": PROTOCOL_VERSION, "type": "error", "code": "worker_invalid_frame"},
            )
            return
        if frame is None:
            return
        if frame.get("version") != PROTOCOL_VERSION:
            write_frame(
                output_stream,
                {"version": PROTOCOL_VERSION, "type": "error", "code": "worker_invalid_version"},
            )
            return
        kind = frame.get("type")
        if kind == "transcribe":
            _handle_transcribe(frame, output_stream, engine, identity)
            _clear_metal_cache()
        elif kind == "session.open":
            _handle_session_open(frame, output_stream, engine)
        elif kind == "audio.append":
            _handle_audio_append(frame, output_stream, engine)
        elif kind == "flush":
            _handle_flush(frame, output_stream, engine)
        elif kind == "commit":
            _handle_commit(frame, output_stream, engine)
            _clear_metal_cache()
        elif kind == "cancel":
            session_id = _session_id_of(frame)
            if session_id is not None:
                engine.close_session(session_id)
            _clear_metal_cache()
        elif kind == "trim_memory":
            # Fire-and-forget: the client never waits for a confirmation frame.
            # Writing one would pollute the request/response framing of the next
            # transcribe/synthesize on the same transport.
            _clear_metal_cache()
        else:
            write_frame(
                output_stream,
                {"version": PROTOCOL_VERSION, "type": "error", "code": "worker_invalid_frame_type"},
            )


def _timestamp_seconds(value: object) -> float | None:
    """Normalize a segment timestamp, preserving the legacy missing-value default."""
    if value is None:
        return 0.0
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        seconds = float(value)
    except (OverflowError, TypeError, ValueError):
        return None
    if not math.isfinite(seconds) or seconds < 0:
        return None
    return seconds


def _segments(result: object) -> list[dict[str, object]]:
    raw = getattr(result, "segments", None)
    segments: list[dict[str, object]] = []
    if not isinstance(raw, list):
        return segments
    for item in raw:
        if not isinstance(item, dict):
            continue
        text = item.get("text")
        if not isinstance(text, str) or not text.strip():
            continue
        start_s = _timestamp_seconds(item.get("start"))
        end_s = _timestamp_seconds(item.get("end"))
        if start_s is None or end_s is None:
            continue
        segments.append(
            {
                "text": text.strip(),
                "start": start_s,
                "end": end_s,
            }
        )
    return segments


class Qwen3Engine:  # pragma: no cover - requires an external Qwen snapshot and isolated runtime.
    """Unified native MLX Qwen3-ASR engine for batch & streaming via ``mlx_qwen3_asr.Session``."""

    def __init__(
        self,
        model_dir: Path,
        device: str,
        dtype: str = "float16",
        max_new_tokens: int = 512,
    ) -> None:
        expected = inspect_model(model_dir)
        if expected.family != "qwen3_asr" or expected.variant != "asr":
            raise RuntimeError("backend_identity_mismatch: unsupported ASR snapshot identity")
        snapshot_quantized = expected.quantization.bits is not None
        # The certified Q8 artifact is a distinct snapshot. Refuse an in-memory
        # int8 request on unquantized weights before loading anything: BF16
        # weights quantized at load time are not that artifact and must never be
        # reported under its identity.
        if dtype == "int8" and not snapshot_quantized:
            raise RuntimeError(
                "backend_quantization_unavailable: non-quantized snapshot cannot be int8"
            )
        import mlx_qwen3_asr  # type: ignore[import-not-found]

        # The session must be constructed at the requested precision: the vendor
        # default is float16, so an implicit load would silently rewrite a bf16
        # request and then be reported (and rejected) as an identity mismatch.
        self._session = mlx_qwen3_asr.Session(
            model=str(model_dir),
            dtype=mlx_dtype(resolve_load_dtype(dtype, snapshot_quantized=snapshot_quantized)),
        )
        loader_sources = _check_loader_identity(self._session, expected)

        info_dtype = _loader_value(loader_sources, ("dtype",))
        resolved_dtype = _resolve_engine_dtype(
            snapshot_quantized=snapshot_quantized,
            requested_dtype=dtype,
            loaded_dtype=None if info_dtype is _MISSING else info_dtype,
        )
        declared = expected.quantization.dtype
        compute_dtype = (
            (_WEIGHT_DTYPE_ALIASES.get(declared) if declared is not None else None)
            or _declared_tensor_dtype(expected, "weights", "embedding")
            or resolved_dtype
        )
        self._max_new_tokens = max_new_tokens
        self.identity = WorkerIdentity(
            device=device,
            dtype=resolved_dtype,
            compute_dtype=compute_dtype,
            compute_config=device,
            quantization_format=expected.quantization.format,
            engine_revision=_resolved_engine_revision(),
            codec_dtype=_declared_tensor_dtype(expected, "codec"),
            family=expected.family,
            model_variant=expected.variant,
            quantization_bits=expected.quantization.bits,
            quantization_group_size=expected.quantization.group_size,
            weight_fingerprint=expected.weight_fingerprint,
        )
        self._decoder: BoundQwen3Decoder | None = None
        self._streaming_states: dict[str, _BufferedASRSession] = {}
        _clear_metal_cache()

    def transcribe(
        self,
        audio: bytes,
        *,
        language: str,
        prompt: str,
        include_timestamps: bool = False,
    ) -> tuple[str, str, list[dict[str, object]]]:
        import numpy as np

        waveform = np.frombuffer(audio, dtype="<i2").astype(np.float32) / np.float32(32768)
        kwargs: dict[str, object] = {"context": prompt}
        if language != "auto":
            kwargs["language"] = language
        audio_sec = len(audio) / 32_000.0
        kwargs["max_new_tokens"] = _dynamic_budget(audio_sec, self._max_new_tokens)
        if include_timestamps:
            kwargs["return_timestamps"] = True
        result = self._session.transcribe((waveform, 16_000), **kwargs)
        text = getattr(result, "text", "") or ""
        text = text.strip() if isinstance(text, str) else ""
        detected = getattr(result, "language", None) or ("" if language == "auto" else language)
        detected = str(detected) if detected else ""
        return text, detected, _segments(result)

    def open_session(
        self,
        *,
        session_id: str,
        language: str,
        context: str,
        chunk_duration_ms: int = 1_000,
        max_context_sec: float = 12.64,
        max_new_tokens: int = 256,
        asr_policy: ASRPolicy | None = None,
        effective_max_segment_ms: int | None = None,
    ) -> None:
        if not session_id:
            raise ValueError("session_id is required")
        if session_id in self._streaming_states:
            raise RuntimeError(f"session already open: {session_id}")
        if chunk_duration_ms <= 0:
            raise ValueError("chunk_duration_ms must be positive")
        if max_context_sec <= 0:
            raise ValueError("max_context_sec must be positive")
        if max_new_tokens <= 0:
            raise ValueError("max_new_tokens must be positive")
        policy = asr_policy or ASRPolicy()
        effective = (
            policy.max_segment_ms
            if effective_max_segment_ms is None
            else effective_max_segment_ms
        )
        if (
            type(effective) is not int
            or effective < 1_000
            or effective > policy.max_segment_ms
            or effective > MAX_STREAMING_SEGMENT_MS
        ):
            raise ValueError("effective_max_segment_ms is outside the supported buffer range")
        max_buffer_bytes = (effective * ASR_SAMPLE_RATE // 1_000) * 2
        self._streaming_states[session_id] = _BufferedASRSession(
            language=language,
            context=context,
            max_new_tokens=max_new_tokens,
            policy=policy,
            effective_max_segment_ms=effective,
            max_buffer_bytes=max_buffer_bytes,
        )

    def append_audio(self, session_id: str, audio: bytes) -> str:
        state = self._streaming_states.get(session_id)
        if state is None:
            raise RuntimeError(f"no active session: {session_id}")
        if not audio or len(audio) % 2:
            raise ValueError("streaming PCM must contain complete PCM16 samples")
        if len(state.pcm) + len(audio) > state.max_buffer_bytes:
            raise ASRBufferOverflowError("session PCM exceeds effective segment budget")
        state.pcm.extend(audio)
        return ""

    def partial_text(self, session_id: str) -> str:
        state = self._streaming_states.get(session_id)
        if state is None:
            raise RuntimeError(f"no active session: {session_id}")
        sample_count = len(state.pcm) // 2
        if sample_count == 0:
            return ""
        if (
            state.preview is not None
            and state.preview.sample_watermark == sample_count
        ):
            return state.preview.text
        import numpy as np

        waveform = np.frombuffer(state.pcm, dtype="<i2").astype(np.float32)
        waveform /= np.float32(32768)
        state.preview = self._bound_decoder().decode(
            waveform,
            state.decoder_state,
            language=state.language,
            context=state.context,
            sample_watermark=sample_count,
            rollback_tokens=state.policy.rollback_tokens,
            max_new_tokens=_dynamic_budget(
                sample_count / ASR_SAMPLE_RATE,
                state.max_new_tokens,
            ),
        )
        return state.preview.text

    def decoded_samples(self, session_id: str) -> int:
        state = self._streaming_states.get(session_id)
        if state is None:
            raise RuntimeError(f"no active session: {session_id}")
        return state.preview.sample_watermark if state.preview is not None else 0

    def preview_revision(self, session_id: str) -> int:
        state = self._streaming_states.get(session_id)
        if state is None:
            raise RuntimeError(f"no active session: {session_id}")
        return state.preview.revision if state.preview is not None else 0

    def finish_streaming(self, session_id: str) -> tuple[str, str]:
        state = self._streaming_states.get(session_id)
        if state is None:
            raise RuntimeError(f"no active session: {session_id}")
        sample_count = len(state.pcm) // 2
        if sample_count == 0:
            return "", "" if state.language in {"", "auto"} else state.language
        import numpy as np

        waveform = np.frombuffer(state.pcm, dtype="<i2").astype(np.float32)
        waveform /= np.float32(32768)
        if state.policy.finalization == "full_segment":
            kwargs: dict[str, object] = {
                "context": state.context,
                "max_new_tokens": _dynamic_budget(
                    sample_count / ASR_SAMPLE_RATE,
                    state.max_new_tokens,
                ),
            }
            if state.language not in {"", "auto"}:
                kwargs["language"] = state.language
            final = self._session.transcribe((waveform, ASR_SAMPLE_RATE), **kwargs)
            _require_complete_final(final)
            text = getattr(final, "text", "") or ""
            language = getattr(final, "language", None) or ""
            return (
                text.strip() if isinstance(text, str) else "",
                str(language) if language else (
                    "" if state.language in {"", "auto"} else state.language
                ),
            )

        final = self._bound_decoder().decode(
            waveform,
            state.decoder_state,
            language=state.language,
            context=state.context,
            sample_watermark=sample_count,
            rollback_tokens=state.policy.rollback_tokens,
            max_new_tokens=_dynamic_budget(
                sample_count / ASR_SAMPLE_RATE,
                state.max_new_tokens,
            ),
            final=True,
        )
        return final.text, final.language

    def close_session(self, session_id: str) -> None:
        self._streaming_states.pop(session_id, None)

    def active_session_count(self) -> int:
        return len(self._streaming_states)

    def has_session(self, session_id: str) -> bool:
        return session_id in self._streaming_states

    def _bound_decoder(self) -> BoundQwen3Decoder:
        if self._decoder is None:
            self._decoder = BoundQwen3Decoder(
                self._session,
                max_new_tokens=self._max_new_tokens,
            )
        return self._decoder


def main(argv: Sequence[str] | None = None) -> int:  # pragma: no cover - process entry point.
    parser = argparse.ArgumentParser(description="SpeechRail Unified Qwen3-ASR worker")
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--device", choices=("mps", "cpu"), required=True)
    parser.add_argument(
        "--dtype",
        choices=("float16", "float32", "bfloat16", "int8"),
        default="float16",
    )
    parser.add_argument("--max-new-tokens", type=int, default=512)
    parser.add_argument("--cache-limit-mb", type=int, default=256)
    parser.add_argument("--memory-limit-mb", type=int, default=0)
    # process self-description tag; serve() ignores it, tooling reads it
    parser.add_argument(
        "--worker-role", choices=("batch", "streaming"), default="batch"
    )
    args = parser.parse_args(argv)
    os.environ.update(
        {
            "HF_HUB_OFFLINE": "1",
            "TRANSFORMERS_OFFLINE": "1",
            "HF_DATASETS_OFFLINE": "1",
            "PYTORCH_ENABLE_MPS_FALLBACK": "0",
            "TOKENIZERS_PARALLELISM": "false",
        }
    )
    _apply_metal_limits(args.cache_limit_mb, args.memory_limit_mb)
    protocol = os.fdopen(os.dup(sys.stdout.fileno()), "wb", buffering=0)
    sys.stdout = sys.stderr
    try:
        serve(
            sys.stdin.buffer,
            protocol,
            model_dir=Path(args.model_dir).resolve(strict=True),
            device=args.device,
            dtype=args.dtype,
            max_new_tokens=args.max_new_tokens,
            engine_factory=Qwen3Engine,
        )
    finally:
        protocol.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
