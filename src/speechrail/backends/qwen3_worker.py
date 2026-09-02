"""Isolated native Qwen3-ASR worker; imports the vendor runtime only after preflight."""

from __future__ import annotations

import argparse
import base64
import binascii
import os
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Literal, Protocol

from speechrail.backends.qwen3_native import MODEL_FILES
from speechrail.runtime.worker_protocol import (
    PROTOCOL_VERSION,
    ProtocolError,
    read_frame,
    write_frame,
)

MAX_PCM_BYTES = 40 * 1024 * 1024
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


EngineFactory = Callable[[Path, Literal["mps", "cpu"], int], WorkerEngine]


def _decode_request(frame: dict[str, object]) -> tuple[str, bytes, str, str, bool]:
    request_id = frame.get("request_id")
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
        or not isinstance(encoded, str)
        or not isinstance(language, str)
        or not isinstance(prompt, str)
        or not isinstance(raw_timestamps, bool)
    ):
        raise ProtocolError("invalid transcribe request")
    try:
        pcm = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ProtocolError("invalid PCM payload") from exc
    if not pcm or len(pcm) % 2 or len(pcm) > MAX_PCM_BYTES:
        raise ProtocolError("invalid PCM length")
    canonical_language = LANGUAGES.get(language.strip().lower())
    if canonical_language is None:
        raise ProtocolError("unsupported language")
    return request_id, pcm, canonical_language, prompt, raw_timestamps


def serve(
    input_stream: BinaryIO,
    output_stream: BinaryIO,
    *,
    model_dir: Path,
    device: Literal["mps", "cpu"],
    max_new_tokens: int,
    engine_factory: EngineFactory,
) -> None:
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
        engine = engine_factory(model_dir, device, max_new_tokens)
    except Exception:
        write_frame(
            output_stream,
            {"version": PROTOCOL_VERSION, "type": "error", "code": "worker_load_error"},
        )
        return
    identity = engine.identity
    expected_dtype = "float16" if device == "mps" else "float32"
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
        request_id = frame.get("request_id") if isinstance(frame.get("request_id"), str) else None
        try:
            if frame.get("version") != PROTOCOL_VERSION or frame.get("type") != "transcribe":
                raise ProtocolError("invalid request")
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
            write_frame(
                output_stream,
                {
                    "version": PROTOCOL_VERSION,
                    "type": "error",
                    "code": "worker_inference_error",
                    "request_id": request_id,
                },
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
    """Native MLX Qwen3-ASR engine via ``mlx_qwen3_asr.Session``.

    ``mlx-qwen3-asr`` is a standalone Apple-Silicon MLX runtime (no PyTorch or
    vendor ``qwen-asr`` package).  ``load_model`` converts the ``thinker.*``
    checkpoint to MLX on load, so the worker never imports ``qwen_asr`` or
    transformers.  The main process never imports the vendor runtime.
    """

    def __init__(self, model_dir: Path, device: Literal["mps", "cpu"], max_new_tokens: int) -> None:
        if any(not (model_dir / name).is_file() for name in MODEL_FILES):
            raise ValueError("model snapshot is incomplete")
        import mlx_qwen3_asr  # type: ignore[import-not-found]

        self._session = mlx_qwen3_asr.Session(model=str(model_dir))
        info = getattr(self._session, "model_info", None) or {}
        loaded_dtype = str(info.get("dtype", ""))
        if loaded_dtype.startswith("mlx.core."):
            loaded_dtype = loaded_dtype.removeprefix("mlx.core.")
        loaded_dtype = loaded_dtype or ("float16" if device == "mps" else "float32")
        self._max_new_tokens = max_new_tokens
        self.identity = WorkerIdentity(device, loaded_dtype)

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
        if self._max_new_tokens:
            kwargs["max_new_tokens"] = self._max_new_tokens
        if include_timestamps:
            kwargs["return_timestamps"] = True
        result = self._session.transcribe((waveform, 16_000), **kwargs)
        text = getattr(result, "text", "") or ""
        text = text.strip() if isinstance(text, str) else ""
        detected = getattr(result, "language", None) or ("" if language == "auto" else language)
        detected = str(detected) if detected else ""
        return text, detected, _segments(result)


def main(argv: Sequence[str] | None = None) -> int:  # pragma: no cover - process entry point.
    parser = argparse.ArgumentParser(description="SpeechRail Qwen3-ASR worker")
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--device", choices=("mps", "cpu"), required=True)
    parser.add_argument("--max-new-tokens", type=int, default=512)
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
    protocol = os.fdopen(os.dup(sys.stdout.fileno()), "wb", buffering=0)
    sys.stdout = sys.stderr
    try:
        serve(
            sys.stdin.buffer,
            protocol,
            model_dir=Path(args.model_dir).resolve(strict=True),
            device=args.device,
            max_new_tokens=args.max_new_tokens,
            engine_factory=Qwen3Engine,
        )
    finally:
        protocol.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
