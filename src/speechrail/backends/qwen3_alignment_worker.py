"""Isolated Qwen3-ForcedAligner worker.

The process only ever maps *supplied* text onto *supplied* PCM16.  It never
loads an ASR session, never decodes audio, and never accepts a streaming
session; a caller that wants timestamps must already own the frozen text.
"""

from __future__ import annotations

import argparse
import sys
import traceback
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Final, Protocol

from speechrail.backends.mlx_precision import mlx_dtype, resolve_load_dtype
from speechrail.backends.model_identity import inspect_model
from speechrail.runtime.worker_protocol import (
    PROTOCOL_VERSION,
    ProtocolError,
    read_frame,
    write_frame,
)

ALIGNMENT_BACKEND_ID = "mlx-qwen3-forced-aligner"
ALIGNMENT_SAMPLE_RATE = 16_000

_DTYPE_ALIASES: Final = {
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


def _normalize_dtype(value: object) -> str | None:
    """把 aligner 自报的 dtype 规范化为 SpeechRail 精度名。缺失时返回 ``None``。"""

    if not isinstance(value, str):
        return None
    return _DTYPE_ALIASES.get(value.removeprefix("mlx.core.").strip().lower())


@dataclass(frozen=True, slots=True)
class AlignmentIdentity:
    """Observable identity of one loaded aligner worker."""

    device: str
    dtype: str
    quantization_format: str
    engine_revision: str | None = None
    family: str | None = None
    model_variant: str | None = None
    quantization_bits: int | None = None
    quantization_group_size: int | None = None
    weight_fingerprint: str | None = None
    backend: str = ALIGNMENT_BACKEND_ID
    sample_rate: int = ALIGNMENT_SAMPLE_RATE


class AlignerEngine(Protocol):
    identity: AlignmentIdentity

    def align_text(
        self, audio: bytes, *, text: str, language: str
    ) -> list[dict[str, object]]: ...


def _ready_identity_fields(identity: AlignmentIdentity) -> dict[str, object]:
    fields: dict[str, object] = {}
    for attribute in (
        "backend",
        "sample_rate",
        "family",
        "model_variant",
        "quantization_format",
        "quantization_bits",
        "quantization_group_size",
        "engine_revision",
        "weight_fingerprint",
    ):
        value = getattr(identity, attribute, None)
        if value is not None:
            fields[attribute] = value
    return fields


def _decode_align_request(frame: dict[str, object]) -> tuple[str, bytes, str, str]:
    request_id = frame.get("request_id")
    raw_binary = frame.get("_binary")
    encoded = frame.get("pcm_b64")
    language = frame.get("language")
    text = frame.get("text")
    if (
        not isinstance(request_id, str)
        or not request_id
        or frame.get("sample_rate") != ALIGNMENT_SAMPLE_RATE
        or frame.get("channels") != 1
        or frame.get("sample_width_bytes") != 2
        or not isinstance(language, str)
        or not isinstance(text, str)
        or not text
    ):
        raise ProtocolError("invalid fixed-text alignment request")
    pcm: bytes
    if isinstance(raw_binary, bytes) and raw_binary:
        pcm = raw_binary
    elif isinstance(encoded, str) and encoded:
        import base64
        import binascii

        try:
            pcm = base64.b64decode(encoded, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise ProtocolError("invalid alignment payload") from exc
    else:
        raise ProtocolError("alignment request requires PCM16 audio")
    if not pcm or len(pcm) % 2:
        raise ProtocolError("alignment request requires whole PCM16 samples")
    return request_id, pcm, language, text


def _handle_align_text(
    frame: dict[str, object], output_stream: BinaryIO, engine: AlignerEngine
) -> None:
    raw_request_id = frame.get("request_id")
    request_id: str | None = raw_request_id if isinstance(raw_request_id, str) else None
    try:
        request_id, pcm, language, text = _decode_align_request(frame)
        tokens = engine.align_text(pcm, text=text, language=language)
    except ProtocolError:
        _write_error(output_stream, "worker_invalid_request", request_id=request_id)
        return
    except Exception:
        traceback.print_exc(file=sys.stderr)
        _write_error(output_stream, "worker_alignment_error", request_id=request_id)
        return
    write_frame(
        output_stream,
        {
            "version": PROTOCOL_VERSION,
            "type": "align_result",
            "request_id": request_id,
            "tokens": tokens,
        },
    )


def _write_error(output_stream: BinaryIO, code: str, *, request_id: str | None = None) -> None:
    payload: dict[str, object] = {"version": PROTOCOL_VERSION, "type": "error", "code": code}
    if request_id is not None:
        payload["request_id"] = request_id
    write_frame(output_stream, payload)


def serve(
    input_stream: BinaryIO,
    output_stream: BinaryIO,
    *,
    model_dir: Path,
    device: str,
    dtype: str = "float16",
    engine_factory: Callable[[Path, str, str], AlignerEngine] | None = None,
) -> None:
    """Serve fixed-text alignment frames until stdin closes."""

    if engine_factory is None:
        engine_factory = Qwen3AlignerEngine
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
        _write_error(output_stream, "worker_invalid_start")
        return
    try:
        engine = engine_factory(model_dir, device, dtype)
    except Exception:
        traceback.print_exc(file=sys.stderr)
        _write_error(output_stream, "worker_load_error")
        return
    identity = engine.identity
    if identity.device != device or identity.dtype != dtype:
        _write_error(output_stream, "backend_identity_mismatch")
        return
    ready: dict[str, object] = {
        "version": PROTOCOL_VERSION,
        "type": "ready",
        "device": identity.device,
        "dtype": identity.dtype,
        "model_loaded": True,
    }
    ready.update(_ready_identity_fields(identity))
    write_frame(output_stream, ready)
    while True:
        try:
            frame = read_frame(input_stream)
        except ProtocolError:
            _write_error(output_stream, "worker_invalid_frame")
            return
        if frame is None:
            return
        if frame.get("version") != PROTOCOL_VERSION:
            _write_error(output_stream, "worker_invalid_version")
            return
        kind = frame.get("type")
        if kind == "align_text":
            _handle_align_text(frame, output_stream, engine)
        elif kind == "shutdown":
            return
        elif kind == "trim_memory":
            _clear_metal_cache()
        else:
            _write_error(output_stream, "worker_invalid_frame_type")


def _clear_metal_cache() -> None:
    import gc

    try:
        import mlx.core as mx  # type: ignore[import-not-found]

        if hasattr(mx, "clear_cache"):  # pragma: no cover - requires mlx runtime.
            mx.clear_cache()
    except Exception:  # pragma: no cover - mlx is optional at import time.
        return
    gc.collect()


class Qwen3AlignerEngine:  # pragma: no cover - requires an external aligner snapshot.
    """Adapter over ``mlx_qwen3_asr.ForcedAligner`` with explicit load identity."""

    def __init__(self, model_dir: Path, device: str, dtype: str) -> None:
        import mlx_qwen3_asr  # type: ignore[import-not-found]

        snapshot = inspect_model(model_dir)
        quantized = snapshot.quantization.bits is not None
        if dtype == "int8" and not quantized:
            raise RuntimeError(
                "backend_quantization_unavailable: non-quantized snapshot cannot be int8"
            )
        # Never leave the precision implicit: the vendor default is float16, which
        # would silently downgrade a bf16 aligner while still reporting bfloat16.
        self._aligner = mlx_qwen3_asr.ForcedAligner(
            model_path=str(model_dir),
            dtype=mlx_dtype(resolve_load_dtype(dtype, snapshot_quantized=quantized)),
        )
        observed_dtype = _normalize_dtype(getattr(self._aligner, "dtype", None))
        if quantized:
            effective_dtype = "int8"
        elif observed_dtype is None:
            raise RuntimeError("backend_identity_mismatch: aligner reported no dtype")
        elif observed_dtype != dtype:
            raise RuntimeError(
                f"backend_identity_mismatch: aligner reported {observed_dtype}, requested {dtype}"
            )
        else:
            effective_dtype = observed_dtype
        self.identity = AlignmentIdentity(
            device=device,
            dtype=effective_dtype,
            quantization_format=snapshot.quantization.format,
            engine_revision=_engine_revision(),
            family=snapshot.family,
            model_variant=snapshot.variant,
            quantization_bits=snapshot.quantization.bits,
            quantization_group_size=snapshot.quantization.group_size,
            weight_fingerprint=snapshot.weight_fingerprint,
        )

    def align_text(self, audio: bytes, *, text: str, language: str) -> list[dict[str, object]]:
        import numpy as np

        waveform = np.frombuffer(audio, dtype="<i2").astype(np.float32) / np.float32(32768)
        aligned = self._aligner.align(waveform, text, language=language or "auto")
        raw: list[dict[str, object]] = []
        for item in aligned:
            token = getattr(item, "text", None)
            start = getattr(item, "start_time", None)
            end = getattr(item, "end_time", None)
            if (
                not isinstance(token, str)
                or isinstance(start, bool)
                or not isinstance(start, (int, float))
                or isinstance(end, bool)
                or not isinstance(end, (int, float))
            ):
                return []
            # The forced aligner uses a coarse timestamp grid for some
            # character-level tokens, so a token can collapse to start == end.
            # Dropping it keeps the remaining alignment valid; the validator
            # re-attaches that token's code points to the next valid token.
            if end <= start:
                continue
            raw.append({"text": token, "start": start, "end": end})
        return raw


def _engine_revision() -> str | None:
    """Return the installed engine package version, or ``None`` when undiscoverable."""

    try:
        from importlib.metadata import version

        return version("mlx-qwen3-asr")
    except Exception:  # pragma: no cover - defensive.
        return None


def main(argv: Sequence[str] | None = None) -> int:  # pragma: no cover - process entry point.
    parser = argparse.ArgumentParser(description="SpeechRail Qwen3-ForcedAligner worker")
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--device", choices=("mps", "cpu"), required=True)
    parser.add_argument(
        "--dtype",
        choices=("float16", "float32", "bfloat16", "int8"),
        default="float16",
    )
    args = parser.parse_args(argv)
    serve(
        sys.stdin.buffer,
        sys.stdout.buffer,
        model_dir=Path(args.model_dir),
        device=args.device,
        dtype=args.dtype,
    )
    return 0


if __name__ == "__main__":  # pragma: no cover - process entry point.
    raise SystemExit(main())


__all__ = [
    "ALIGNMENT_BACKEND_ID",
    "ALIGNMENT_SAMPLE_RATE",
    "AlignerEngine",
    "AlignmentIdentity",
    "Qwen3AlignerEngine",
    "main",
    "serve",
]
