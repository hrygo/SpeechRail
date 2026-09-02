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
from typing import BinaryIO

from speechrail.runtime.worker_protocol import (
    PROTOCOL_VERSION,
    ProtocolError,
    read_frame,
    write_frame,
)

_MAX_PCM_BYTES = 40 * 1024 * 1024
_MODE_NAMES = ("windowed", "causal")


class StreamingEngine:
    """One MLX ``mlx_qwen3_asr.Session`` plus a current streaming state.

    ``mlx-qwen3-asr`` provides a native Apple-Silicon streaming ASR runtime
    (no PyTorch, no ``qwen_asr``/``qwen3_asr_causal``); the worker keeps a
    single long-lived ``Session`` and a ``StreamingState`` per open session.
    """

    def __init__(
        self, *, model_dir: Path, device: str, mode: str, kwargs: dict[str, object]
    ) -> None:
        import mlx_qwen3_asr  # type: ignore[import-not-found]

        if mode not in _MODE_NAMES:
            raise ValueError("invalid streaming mode")
        self._session = mlx_qwen3_asr.Session(model=str(model_dir))
        chunk_sec = kwargs.get("qwen3_streaming_chunk_sec", 2.0)
        left = kwargs.get("qwen3_streaming_left_context_sec", 12.0)
        right_ms = kwargs.get("qwen3_streaming_right_context_ms", 640)
        max_new = kwargs.get("qwen3_streaming_max_new_tokens", 256)
        self._chunk_size_sec = float(chunk_sec) if isinstance(chunk_sec, (int, float)) else 2.0
        left_f = float(left) if isinstance(left, (int, float)) else 12.0
        right_f = int(right_ms) if isinstance(right_ms, (int, float)) else 640
        self._max_context_sec = left_f + right_f / 1000.0
        self._max_new_tokens = int(max_new) if isinstance(max_new, (int, float)) else 256
        self._state: object | None = None
        self.identity = (device, "float16" if device == "mps" else "float32")

    def open_session(self, *, language: str, context: str) -> None:
        streaming_language = None if language in {"auto", ""} else language
        self._state = self._session.init_streaming(
            context=context,
            language=streaming_language,
            chunk_size_sec=self._chunk_size_sec,
            max_context_sec=self._max_context_sec,
            max_new_tokens=self._max_new_tokens,
        )

    def append_audio(self, audio: bytes) -> str:
        import numpy as np

        state = self._require_state()
        waveform = np.frombuffer(audio, dtype="<i2").astype(np.float32) / np.float32(32768)
        self._state = self._session.feed_audio(waveform, state)
        current = getattr(self._state, "text", "") or ""
        return current if isinstance(current, str) else ""

    def partial_text(self) -> str:
        state = self._require_state()
        text = getattr(state, "text", "") or ""
        return text if isinstance(text, str) else ""

    def finish(self) -> tuple[str, str]:
        state = self._require_state()
        final = self._session.finish_streaming(state)
        self._state = final
        text = getattr(final, "text", "") or ""
        language = getattr(final, "language", None) or ""
        return (text if isinstance(text, str) else ""), (
            language if isinstance(language, str) else ""
        )

    def _require_state(self) -> object:
        if self._state is None:
            raise RuntimeError("no active session")
        return self._state

    def close_session(self) -> None:
        self._state = None

    def close(self) -> None:
        self.close_session()


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
        text = engine.partial_text()
    except Exception:
        write_frame(
            output_stream,
            {"version": PROTOCOL_VERSION, "type": "error", "code": "worker_inference_error"},
        )
        return
    if not text:
        return
    write_frame(
        output_stream,
        {
            "version": PROTOCOL_VERSION,
            "type": "event",
            "kind": "partial",
            "text": text,
            "language": None,
            "segments": [],
        },
    )


def _handle_commit(
    frame: dict[str, object],
    output_stream: BinaryIO,
    engine: StreamingEngine,
) -> None:
    try:
        text, language = engine.finish()
    except Exception:
        write_frame(
            output_stream,
            {"version": PROTOCOL_VERSION, "type": "error", "code": "worker_inference_error"},
        )
        return
    if text:
        write_frame(
            output_stream,
            {
                "version": PROTOCOL_VERSION,
                "type": "event",
                "kind": "completed",
                "text": text,
                "language": language or None,
                "segments": [],
            },
        )
    write_frame(
        output_stream,
        {"version": PROTOCOL_VERSION, "type": "finished", "final": True},
    )


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
