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
from pathlib import Path
from typing import BinaryIO, Protocol

from speechrail.backends.model_identity import SnapshotIdentity, inspect_model, read_quantization
from speechrail.config.model_catalog import QuantizationSpec
from speechrail.runtime.worker_protocol import (
    MAX_FRAME_BYTES,
    PROTOCOL_VERSION,
    ProtocolError,
    read_frame,
    write_frame,
)

MAX_PCM_BYTES = 40 * 1024 * 1024
# Batch requests are bounded by the shared framed IPC payload; keep a small
# margin for the JSON header and length prefix.
MAX_BATCH_PCM_BYTES = MAX_FRAME_BYTES - 4096
# Defense-in-depth bound for concurrent streaming sessions inside one worker
# process. The main-process NativeRealtimeFactory enforces the configurable
# SPEECHRAIL_REALTIME_MAX_SESSIONS (default 3) before frames reach the worker;
# this constant only guards against a misbehaving protocol peer.
MAX_ACTIVE_STREAMING_SESSIONS = 8
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


def _resolve_engine_dtype(
    *,
    snapshot_quantized: bool,
    requested_dtype: str,
    loaded_dtype: str,
    default_dtype: str,
    quantize_raised: bool,
) -> str:
    """Resolve the honest worker identity dtype from the actual load state.

    A pre-quantized ``-8bit`` snapshot loads int8 weights directly and is never
    re-quantized at load time. A requested in-memory int8 that raised an exception
    is NOT claimed as int8 (fail-closed on truth): the identity reports the
    precision the model actually loaded, so an unachievable int8 request surfaces
    as a clear ``backend_identity_mismatch`` instead of silently running fp16
    under an int8 label.
    """
    if snapshot_quantized:
        return "int8"
    if requested_dtype == "int8" and not quantize_raised:
        return "int8"
    return loaded_dtype or default_dtype


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
    device: str
    dtype: str
    family: str | None = None
    model_variant: str | None = None
    quantization_bits: int | None = None
    quantization_group_size: int | None = None
    weight_fingerprint: str | None = None


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
        chunk_sec: float = 2.0,
        left_context_sec: float = 12.0,
        right_context_ms: int = 640,
        max_new_tokens: int = 256,
    ) -> None: ...

    def append_audio(self, session_id: str, audio: bytes) -> str: ...

    def partial_text(self, session_id: str) -> str: ...

    def finish_streaming(self, session_id: str) -> tuple[str, str]: ...

    def align_session_audio(self, session_id: str) -> list[dict[str, object]]: ...

    def close_session(self, session_id: str) -> None: ...

    def active_session_count(self) -> int: ...

    def has_session(self, session_id: str) -> bool: ...


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
    try:
        chunk_sec = _coerce_session_float(frame.get("chunk_sec", 2.0))
        left_context_sec = _coerce_session_float(frame.get("left_context_sec", 12.0))
        right_context_ms = _coerce_session_int(frame.get("right_context_ms", 640))
        max_new_tokens = _coerce_session_int(frame.get("max_new_tokens", 256))
        if chunk_sec <= 0 or left_context_sec < 0 or right_context_ms < 0 or max_new_tokens <= 0:
            raise ValueError("invalid session option")
    except (OverflowError, TypeError, ValueError):
        _write_error(output_stream, "session_open_failed", session_id=session_id)
        return
    if engine.active_session_count() >= MAX_ACTIVE_STREAMING_SESSIONS:
        _write_error(output_stream, "session_limit_reached", session_id=session_id)
        return
    try:
        engine.open_session(
            session_id=session_id,
            language=language,
            context=context,
            chunk_sec=chunk_sec,
            left_context_sec=left_context_sec,
            right_context_ms=right_context_ms,
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
    except Exception:
        traceback.print_exc(file=sys.stderr)
        _write_error(output_stream, "worker_inference_error", session_id=session_id)
        return
    if not text:
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
    want_segments = bool(frame.get("want_segments", False))
    try:
        text, language = engine.finish_streaming(session_id)
        segments: list[dict[str, object]] = []
        if want_segments and text:
            segments = engine.align_session_audio(session_id)
        if text:
            write_frame(
                output_stream,
                {
                    "version": PROTOCOL_VERSION,
                    "type": "event",
                    "session_id": session_id,
                    "kind": "completed",
                    "text": text,
                    "language": language or None,
                    "segments": segments,
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
    if family is not None and family != "qwen3_asr":
        return False
    if variant is not None and variant != "asr":
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
        "family",
        "model_variant",
        "quantization_bits",
        "quantization_group_size",
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


_SENTENCE_ENDINGS = frozenset("。？！；…!?;")


def _should_separate_words(prev: str, next_s: str) -> bool:
    if not prev or not next_s:
        return False
    return (
        prev[-1].isascii()
        and prev[-1].isalnum()
        and next_s[0].isascii()
        and next_s[0].isalnum()
    )


def _to_streaming_segments(raw: list[dict[str, object]]) -> list[dict[str, object]]:
    """Convert batch seconds to consolidated streaming millisecond segments.

    Consolidates contiguous short tokens (such as character-level tokens emitted by
    MLX alignment), ensures every segment lasts at least 20 ms, and splits on pauses
    over 500 ms, sentence punctuation, or a 40-character clause limit.
    """
    if not raw:
        return []

    streaming: list[dict[str, object]] = []
    current_text: str | None = None
    current_start_ms = 0
    current_end_ms = 0

    for item in raw:
        if not isinstance(item, dict):
            continue
        raw_text = item.get("text")
        if not isinstance(raw_text, str):
            continue
        text = raw_text.strip()
        if not text:
            continue
        start_s = _timestamp_seconds(item.get("start"))
        end_s = _timestamp_seconds(item.get("end"))
        if start_s is None or end_s is None:
            continue

        try:
            start_ms = round(start_s * 1000)
            end_ms = round(end_s * 1000)
        except (OverflowError, ValueError):
            continue
        if end_ms - start_ms < 20:
            end_ms = start_ms + 20

        if current_text is None:
            current_text = text
            current_start_ms = start_ms
            current_end_ms = end_ms
            continue

        gap_ms = start_ms - current_end_ms
        is_pause = gap_ms > 500
        ends_sentence = current_text[-1] in _SENTENCE_ENDINGS
        sep = " " if _should_separate_words(current_text, text) else ""
        is_too_long = (
            len(current_text) + len(sep) + len(text) > 40
            or end_ms - current_start_ms > 10_000
        )

        if not is_pause and not ends_sentence and not is_too_long:
            current_text = f"{current_text}{sep}{text}"
            current_end_ms = max(current_end_ms, end_ms)
        else:
            streaming.append(
                {"text": current_text, "start_ms": current_start_ms, "end_ms": current_end_ms}
            )
            current_text = text
            current_start_ms = start_ms
            current_end_ms = end_ms

    if current_text is not None:
        streaming.append(
            {"text": current_text, "start_ms": current_start_ms, "end_ms": current_end_ms}
        )

    return streaming


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
        import mlx_qwen3_asr  # type: ignore[import-not-found]

        self._session = mlx_qwen3_asr.Session(model=str(model_dir))
        loader_sources = _check_loader_identity(self._session, expected)
        snapshot_quantized = expected.quantization.bits is not None

        # In-memory INT8 quantization when requested on a non-quantized snapshot.
        # A snapshot that already ships quantized weights (e.g. an ``-8bit`` MLX
        # snapshot) must NOT be re-quantized: it is loaded directly as int8.
        quantize_raised = False
        runtime_quantized = False
        if dtype == "int8" and not snapshot_quantized:
            try:
                from mlx_qwen3_asr.convert import quantize_model  # type: ignore[import-not-found]

                quantize_model(self._session.model, bits=8, group_size=64)
            except Exception as exc:
                quantize_raised = True
                print(f"Warning: in-memory INT8 quantization failed: {exc}", file=sys.stderr)
                raise RuntimeError("backend_quantization_failed") from exc
            runtime_quantized = True
            _clear_metal_cache()

        info_dtype = _loader_value(loader_sources, ("dtype",))
        loaded_dtype = "" if info_dtype is _MISSING else str(info_dtype)
        if loaded_dtype.startswith("mlx.core."):
            loaded_dtype = loaded_dtype.removeprefix("mlx.core.")
        default_dtype = "float16" if device == "mps" else "float32"
        resolved_dtype = _resolve_engine_dtype(
            snapshot_quantized=snapshot_quantized,
            requested_dtype=dtype,
            loaded_dtype=loaded_dtype,
            default_dtype=default_dtype,
            quantize_raised=quantize_raised,
        )
        quantization = expected.quantization
        if runtime_quantized:
            quantization = QuantizationSpec(bits=8, group_size=64, format="affine")
        self._max_new_tokens = max_new_tokens
        self.identity = WorkerIdentity(
            device=device,
            dtype=resolved_dtype,
            family=expected.family,
            model_variant=expected.variant,
            quantization_bits=quantization.bits,
            quantization_group_size=quantization.group_size,
            weight_fingerprint=expected.weight_fingerprint,
        )
        self._streaming_states: dict[str, object] = {}
        self._align_buffers: dict[str, bytearray] = {}
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
        chunk_sec: float = 2.0,
        left_context_sec: float = 12.0,
        right_context_ms: int = 640,
        max_new_tokens: int = 256,
    ) -> None:
        if not session_id:
            raise ValueError("session_id is required")
        if session_id in self._streaming_states:
            raise RuntimeError(f"session already open: {session_id}")
        streaming_language = None if language in {"auto", ""} else language
        max_context_sec = left_context_sec + right_context_ms / 1000.0
        self._streaming_states[session_id] = self._session.init_streaming(
            context=context,
            language=streaming_language,
            chunk_size_sec=chunk_sec,
            max_context_sec=max_context_sec,
            max_new_tokens=max_new_tokens,
        )
        self._align_buffers[session_id] = bytearray()

    def append_audio(self, session_id: str, audio: bytes) -> str:
        import numpy as np

        state = self._streaming_states.get(session_id)
        if state is None:
            raise RuntimeError(f"no active session: {session_id}")
        align = self._align_buffers.get(session_id)
        if align is not None:
            if len(align) + len(audio) > MAX_PCM_BYTES:
                raise ValueError("align buffer limit exceeded")
            align.extend(audio)
        waveform = np.frombuffer(audio, dtype="<i2").astype(np.float32) / np.float32(32768)
        state = self._session.feed_audio(waveform, state)
        self._streaming_states[session_id] = state
        current = getattr(state, "text", "") or ""
        return current if isinstance(current, str) else ""

    def partial_text(self, session_id: str) -> str:
        state = self._streaming_states.get(session_id)
        if state is None:
            raise RuntimeError(f"no active session: {session_id}")
        text = getattr(state, "text", "") or ""
        return text if isinstance(text, str) else ""

    def finish_streaming(self, session_id: str) -> tuple[str, str]:
        state = self._streaming_states.get(session_id)
        if state is None:
            raise RuntimeError(f"no active session: {session_id}")
        final = self._session.finish_streaming(state)
        del self._streaming_states[session_id]
        text = getattr(final, "text", "") or ""
        language = getattr(final, "language", None) or ""
        return (text if isinstance(text, str) else ""), (
            language if isinstance(language, str) else ""
        )

    def align_session_audio(self, session_id: str) -> list[dict[str, object]]:
        audio = self._align_buffers.pop(session_id, None)
        if not audio:
            return []
        try:
            text, _language, raw = self.transcribe(
                bytes(audio), language="auto", prompt="", include_timestamps=True
            )
        except Exception:
            traceback.print_exc(file=sys.stderr)
            return []
        if not text:
            return []
        return _to_streaming_segments(raw)

    def close_session(self, session_id: str) -> None:
        self._streaming_states.pop(session_id, None)
        self._align_buffers.pop(session_id, None)

    def active_session_count(self) -> int:
        return len(self._streaming_states)

    def has_session(self, session_id: str) -> bool:
        return session_id in self._streaming_states


def main(argv: Sequence[str] | None = None) -> int:  # pragma: no cover - process entry point.
    parser = argparse.ArgumentParser(description="SpeechRail Unified Qwen3-ASR worker")
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--device", choices=("mps", "cpu"), required=True)
    parser.add_argument("--dtype", choices=("float16", "float32", "int8"), default="float16")
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
