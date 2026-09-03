"""Isolated native Qwen3-ASR worker; supports both batch and streaming transcription."""

from __future__ import annotations

import argparse
import base64
import binascii
import os
import sys
import traceback
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Protocol

from speechrail.backends.qwen3_native import MODEL_FILES, snapshot_is_quantized
from speechrail.runtime.worker_protocol import (
    PROTOCOL_VERSION,
    ProtocolError,
    read_frame,
    write_frame,
)

MAX_PCM_BYTES = 40 * 1024 * 1024
# Defense-in-depth bound for concurrent streaming sessions inside one worker
# process. The main-process NativeRealtimeFactory enforces the configurable
# SPEECHRAIL_REALTIME_MAX_SESSIONS (default 2) before frames reach the worker;
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
    """Bound the batch decode token budget with sub-linear growth.

    A linear ``audio_sec * 8`` multiplier drives very long inputs toward the hard
    cap for a large decoder tail that adds little transcription value. Sub-linear
    growth keeps that tail small while a floor keeps short clips transcribable.
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
    if not pcm or len(pcm) % 2 or len(pcm) > MAX_PCM_BYTES:
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
    if engine.active_session_count() >= MAX_ACTIVE_STREAMING_SESSIONS:
        _write_error(output_stream, "session_limit_reached", session_id=session_id)
        return
    raw_context = frame.get("context")
    context = raw_context if isinstance(raw_context, str) else ""
    raw_chunk = frame.get("chunk_sec", 2.0)
    chunk_sec = float(raw_chunk) if isinstance(raw_chunk, (int, float, str)) else 2.0
    raw_left = frame.get("left_context_sec", 12.0)
    left_context_sec = float(raw_left) if isinstance(raw_left, (int, float, str)) else 12.0
    raw_right = frame.get("right_context_ms", 640)
    right_context_ms = int(raw_right) if isinstance(raw_right, (int, float, str)) else 640
    raw_max_tokens = frame.get("max_new_tokens", 256)
    max_new_tokens = int(raw_max_tokens) if isinstance(raw_max_tokens, (int, float, str)) else 256
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
    try:
        text, language = engine.finish_streaming(session_id)
    except Exception:
        traceback.print_exc(file=sys.stderr)
        _write_error(output_stream, "worker_inference_error", session_id=session_id)
        return
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
                "segments": [],
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
    start = read_frame(input_stream)
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
    expected_dtype = dtype or ("float16" if device == "mps" else "float32")
    if identity.device != device or identity.dtype != expected_dtype:
        write_frame(
            output_stream,
            {"version": PROTOCOL_VERSION, "type": "error", "code": "backend_identity_mismatch"},
        )
        return
    write_frame(
        output_stream,
        {
            "version": PROTOCOL_VERSION,
            "type": "ready",
            "device": identity.device,
            "dtype": identity.dtype,
            "model_loaded": True,
        },
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
        segments.append(
            {
                "text": text.strip(),
                "start": float(item.get("start") or 0),
                "end": float(item.get("end") or 0),
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
        if any(not (model_dir / name).is_file() for name in MODEL_FILES):
            raise ValueError("model snapshot is incomplete")
        import mlx_qwen3_asr  # type: ignore[import-not-found]

        self._session = mlx_qwen3_asr.Session(model=str(model_dir))
        snapshot_quantized = snapshot_is_quantized(model_dir)

        # In-memory INT8 quantization when requested on a non-quantized snapshot.
        # A snapshot that already ships quantized weights (e.g. an ``-8bit`` MLX
        # snapshot) must NOT be re-quantized: it is loaded directly as int8.
        quantize_raised = False
        if dtype == "int8" and not snapshot_quantized:
            try:
                from mlx_qwen3_asr.convert import quantize_model  # type: ignore[import-not-found]

                quantize_model(self._session.model, bits=8, group_size=64)
            except Exception as exc:
                quantize_raised = True
                print(f"Warning: in-memory INT8 quantization failed: {exc}", file=sys.stderr)
            _clear_metal_cache()

        info = getattr(self._session, "model_info", None) or {}
        loaded_dtype = str(info.get("dtype", ""))
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
        self._max_new_tokens = max_new_tokens
        self.identity = WorkerIdentity(device, resolved_dtype)
        self._streaming_states: dict[str, object] = {}
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

    def append_audio(self, session_id: str, audio: bytes) -> str:
        import numpy as np

        state = self._streaming_states.get(session_id)
        if state is None:
            raise RuntimeError(f"no active session: {session_id}")
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

    def close_session(self, session_id: str) -> None:
        self._streaming_states.pop(session_id, None)

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
