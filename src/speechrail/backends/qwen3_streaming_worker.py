"""Isolated native Qwen3 causal-streaming ASR worker.

The worker owns the qwen3_asr_causal model holder and one per-session online
processor.  It speaks a streaming frame dialect over the shared length-prefixed
worker framing:

  parent -> worker: start | session.open | audio.append | flush | commit | cancel
  worker -> parent: ready | session.opened | event | finished | error

The main process never imports qwen3_asr_causal; all model state stays in this
isolated subprocess behind the offline environment.
"""

from __future__ import annotations

import argparse
import base64
import sys
import traceback
from collections.abc import Sequence
from pathlib import Path
from typing import BinaryIO, Protocol, cast

from speechrail.runtime.worker_protocol import (
    PROTOCOL_VERSION,
    ProtocolError,
    read_frame,
    write_frame,
)

_MAX_PCM_BYTES = 40 * 1024 * 1024
_MODE_NAMES = ("windowed", "causal")
# qwen3_asr_causal refuses lan="auto" at construction ("flips accented audio
# to the wrong language mid-stream"); per-session language is applied in
# open_session() before the processor is built, so this is only a placeholder.
_DEFAULT_LANGUAGE = "zh"


class _AsrHolder(Protocol):
    device: object
    original_language: str
    _session_language: str
    qwen3_streaming_context: str


class _Token(Protocol):
    text: str
    start: float
    end: float
    detected_language: str | None


class _Processor(Protocol):
    end: float

    def insert_audio_chunk(self, audio: object, audio_stream_end_time: float) -> None: ...

    def process_iter(self, *, is_last: bool) -> tuple[list[_Token], float]: ...

    def finish(self) -> tuple[list[_Token], float]: ...


def _asr_factory(**kwargs: object) -> _AsrHolder:
    """Import and construct the causal-streaming model holder lazily (offline)."""
    from qwen3_asr_causal import Qwen3StreamingASR  # type: ignore[import-not-found]

    return cast(_AsrHolder, Qwen3StreamingASR(**kwargs))


def _processor_factory(asr: _AsrHolder) -> _Processor:
    from qwen3_asr_causal import Qwen3StreamingOnlineProcessor

    return cast(_Processor, Qwen3StreamingOnlineProcessor(asr))


def _pcm16(audio: bytes) -> object:
    import numpy as np

    return np.frombuffer(audio, dtype="<i2").astype(np.float32) / np.float32(32768)


class StreamingEngine:
    """One loaded Qwen3StreamingASR plus a current online processor."""

    def __init__(
        self, *, model_dir: Path, device: str, mode: str, kwargs: dict[str, object]
    ) -> None:
        import torch

        if mode not in _MODE_NAMES:
            raise ValueError("invalid streaming mode")
        dtype = "float16" if device == "mps" else "float32"
        self._asr = _asr_factory(
            lan=_DEFAULT_LANGUAGE,
            model_size=str(model_dir),
            qwen3_streaming_audio_backend=mode,
            qwen3_streaming_device=device,
            qwen3_streaming_dtype=dtype,
            **kwargs,
        )
        self._asr.device = torch.device(device)
        self.identity = (device, dtype)
        self._processor: _Processor | None = None

    def open_session(self, *, language: str, context: str) -> None:
        if self._processor is not None:
            raise RuntimeError("active session already open")
        self._asr.original_language = language
        self._asr._session_language = language
        self._asr.qwen3_streaming_context = context
        self._processor = _processor_factory(self._asr)

    def append_audio(self, audio: bytes) -> None:
        processor = self._require_processor()
        samples = _pcm16(audio)
        end = processor.end + len(audio) / 16_000
        processor.insert_audio_chunk(samples, end)

    def process(self, *, is_last: bool = False) -> list[dict[str, object]]:
        tokens, _ = self._require_processor().process_iter(is_last=is_last)
        return [_token_dict(t) for t in tokens]

    def finish(self) -> tuple[list[dict[str, object]], str]:
        tokens, _ = self._require_processor().finish()
        return [_token_dict(t) for t in tokens], ""

    def _require_processor(self) -> _Processor:
        processor = self._processor
        if processor is None:
            raise RuntimeError("no active session")
        return processor

    def close_session(self) -> None:
        self._processor = None

    def close(self) -> None:
        self.close_session()


def _token_dict(token: _Token) -> dict[str, object]:
    return {
        "text": token.text or "",
        "start": token.start if token.start is not None else 0.0,
        "end": token.end if token.end is not None else 0.0,
        "language": token.detected_language,
    }


def _valid_start(frame: dict[str, object] | None, *, model_dir: Path, device: str) -> bool:
    return (
        frame is not None
        and frame.get("version") == PROTOCOL_VERSION
        and frame.get("type") == "start"
        and frame.get("model_dir") == str(model_dir)
        and frame.get("device") == device
    )


def serve(
    input_stream: BinaryIO,
    output_stream: BinaryIO,
    *,
    model_dir: Path,
    device: str,
    mode: str,
    streaming_kwargs: dict[str, object],
) -> None:
    start = read_frame(input_stream)
    if not _valid_start(start, model_dir=model_dir, device=device):
        write_frame(
            output_stream,
            {"version": PROTOCOL_VERSION, "type": "error", "code": "worker_invalid_start"},
        )
        return
    try:
        engine = StreamingEngine(
            model_dir=model_dir, device=device, mode=mode, kwargs=streaming_kwargs
        )
    except Exception:
        traceback.print_exc(file=sys.stderr)
        write_frame(
            output_stream,
            {"version": PROTOCOL_VERSION, "type": "error", "code": "worker_load_error"},
        )
        return
    write_frame(
        output_stream,
        {
            "version": PROTOCOL_VERSION,
            "type": "ready",
            "device": engine.identity[0],
            "dtype": engine.identity[1],
            "model_loaded": True,
        },
    )
    try:
        _serve_loop(input_stream, output_stream, engine)
    except ProtocolError:
        write_frame(
            output_stream,
            {"version": PROTOCOL_VERSION, "type": "error", "code": "worker_invalid_frame"},
        )
    finally:
        engine.close()


def _serve_loop(
    input_stream: BinaryIO,
    output_stream: BinaryIO,
    engine: StreamingEngine,
) -> None:
    while True:
        frame = read_frame(input_stream)
        if frame is None:
            return
        if frame.get("version") != PROTOCOL_VERSION:
            raise ProtocolError("invalid version")
        kind = frame.get("type")
        if kind == "session.open":
            _handle_open(frame, output_stream, engine)
        elif kind == "audio.append":
            _handle_append(frame, output_stream, engine)
        elif kind == "flush":
            _handle_flush(frame, output_stream, engine)
        elif kind == "commit":
            _handle_commit(frame, output_stream, engine)
            # Keep the process alive for the next session.open: reloading the
            # model per session costs seconds and the parent leases one active
            # session at a time, so a long-lived worker is the intended design.
            engine.close_session()
        elif kind == "cancel":
            engine.close_session()
        else:
            raise ProtocolError("invalid frame type")


def _handle_open(
    frame: dict[str, object],
    output_stream: BinaryIO,
    engine: StreamingEngine,
) -> None:
    language = frame.get("language")
    if not isinstance(language, str):
        raise ProtocolError("session.open requires language")
    raw_context = frame.get("context")
    context = raw_context if isinstance(raw_context, str) else ""
    try:
        engine.open_session(language=language, context=context)
    except Exception:
        traceback.print_exc(file=sys.stderr)
        write_frame(
            output_stream,
            {"version": PROTOCOL_VERSION, "type": "error", "code": "session_open_failed"},
        )
        return
    write_frame(
        output_stream,
        {"version": PROTOCOL_VERSION, "type": "session.opened", "language": language},
    )


def _handle_append(
    frame: dict[str, object],
    output_stream: BinaryIO,
    engine: StreamingEngine,
) -> None:
    encoded = frame.get("pcm_b64")
    if not isinstance(encoded, str):
        raise ProtocolError("audio.append requires pcm_b64")
    try:
        audio = base64.b64decode(encoded, validate=True)
    except Exception as exc:
        raise ProtocolError("invalid PCM payload") from exc
    if not audio or len(audio) % 2 or len(audio) > _MAX_PCM_BYTES:
        raise ProtocolError("invalid PCM length")
    try:
        engine.append_audio(audio)
    except Exception:
        write_frame(
            output_stream,
            {"version": PROTOCOL_VERSION, "type": "error", "code": "session_invalid"},
        )
        return
    write_frame(
        output_stream,
        {"version": PROTOCOL_VERSION, "type": "audio.acked", "bytes": len(audio)},
    )


def _handle_flush(
    frame: dict[str, object],
    output_stream: BinaryIO,
    engine: StreamingEngine,
) -> None:
    try:
        tokens = engine.process(is_last=False)
    except Exception:
        write_frame(
            output_stream,
            {"version": PROTOCOL_VERSION, "type": "error", "code": "worker_inference_error"},
        )
        return
    _emit_events(output_stream, tokens)


def _handle_commit(
    frame: dict[str, object],
    output_stream: BinaryIO,
    engine: StreamingEngine,
) -> None:
    try:
        tokens, _ = engine.finish()
    except Exception:
        write_frame(
            output_stream,
            {"version": PROTOCOL_VERSION, "type": "error", "code": "worker_inference_error"},
        )
        return
    _emit_events(output_stream, tokens)
    write_frame(
        output_stream,
        {"version": PROTOCOL_VERSION, "type": "finished", "final": True},
    )


def _emit_events(output_stream: BinaryIO, tokens: list[dict[str, object]]) -> None:
    if not tokens:
        return
    texts: list[str] = []
    segments: list[dict[str, object]] = []
    for tok in tokens:
        text = tok.get("text")
        if not isinstance(text, str) or not text.strip():
            continue
        texts.append(text)
        start = tok.get("start")
        end = tok.get("end")
        start_ms = max(0, round(float(start) * 1000)) if isinstance(start, (int, float)) else 0
        end_ms = max(0, round(float(end) * 1000)) if isinstance(end, (int, float)) else 0
        segments.append({"text": text, "start_ms": start_ms, "end_ms": end_ms})
    text = " ".join(texts).strip()
    if not text:
        return
    write_frame(
        output_stream,
        {
            "version": PROTOCOL_VERSION,
            "type": "event",
            "kind": "completed",
            "text": text,
            "language": _first_language(tokens),
            "segments": segments,
        },
    )


def _first_language(tokens: list[dict[str, object]]) -> str | None:
    for tok in tokens:
        if tok.get("language"):
            return str(tok["language"])
    return None


def main(argv: Sequence[str] | None = None) -> int:  # pragma: no cover - process entry point.
    parser = argparse.ArgumentParser(description="SpeechRail Qwen3 causal-streaming ASR worker")
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--device", choices=("mps", "cpu"), required=True)
    parser.add_argument("--mode", choices=_MODE_NAMES, default="windowed")
    parser.add_argument("--chunk-sec", type=float, default=2.0)
    parser.add_argument("--left-context-sec", type=float, default=12.0)
    parser.add_argument("--right-context-ms", type=int, default=640)
    parser.add_argument("--hold-back-words", type=int, default=6)
    parser.add_argument("--stable-iterations", type=int, default=2)
    parser.add_argument("--max-new-tokens", type=int, default=256)
    args = parser.parse_args(argv)
    import os

    os.environ.update(
        {
            "HF_HUB_OFFLINE": "1",
            "TRANSFORMERS_OFFLINE": "1",
            "HF_DATASETS_OFFLINE": "1",
            "PYTORCH_ENABLE_MPS_FALLBACK": "0",
            "TOKENIZERS_PARALLELISM": "false",
        }
    )
    protocol = os.fdopen(os.dup(sys.stdout.fileno()), "wb", buffering=0)
    sys.stdout = sys.stderr
    try:
        serve(
            sys.stdin.buffer,
            protocol,
            model_dir=Path(args.model_dir).resolve(strict=True),
            device=args.device,
            mode=args.mode,
            streaming_kwargs={
                "qwen3_streaming_chunk_sec": args.chunk_sec,
                "qwen3_streaming_left_context_sec": args.left_context_sec,
                "qwen3_streaming_right_context_ms": args.right_context_ms,
                "qwen3_streaming_hold_back_words": args.hold_back_words,
                "qwen3_streaming_stable_iterations": args.stable_iterations,
                "qwen3_streaming_max_new_tokens": args.max_new_tokens,
            },
        )
    finally:
        protocol.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
