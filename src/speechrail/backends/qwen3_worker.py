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
from typing import Any, BinaryIO, Literal, Protocol

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
    "zh": "Chinese",
    "chinese": "Chinese",
    "en": "English",
    "english": "English",
    "yue": "Cantonese",
    "cantonese": "Cantonese",
    "ja": "Japanese",
    "japanese": "Japanese",
    "ko": "Korean",
    "korean": "Korean",
}


@dataclass(frozen=True, slots=True)
class WorkerIdentity:
    device: str
    dtype: str


class WorkerEngine(Protocol):
    identity: WorkerIdentity

    def transcribe(self, audio: bytes, *, language: str, prompt: str) -> tuple[str, str]: ...


EngineFactory = Callable[[Path, Literal["mps", "cpu"], int], WorkerEngine]


def _decode_request(frame: dict[str, object]) -> tuple[str, bytes, str, str]:
    request_id = frame.get("request_id")
    encoded = frame.get("pcm_b64")
    language = frame.get("language")
    prompt = frame.get("prompt")
    if (
        not isinstance(request_id, str)
        or not request_id
        or frame.get("sample_rate") != 16_000
        or frame.get("channels") != 1
        or frame.get("sample_width_bytes") != 2
        or not isinstance(encoded, str)
        or not isinstance(language, str)
        or not isinstance(prompt, str)
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
    return request_id, pcm, canonical_language, prompt


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
            request_id, pcm, language, prompt = _decode_request(frame)
            text, detected_language = engine.transcribe(pcm, language=language, prompt=prompt)
            write_frame(
                output_stream,
                {
                    "version": PROTOCOL_VERSION,
                    "type": "result",
                    "request_id": request_id,
                    "text": text,
                    "language": detected_language,
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


class Qwen3Engine:  # pragma: no cover - requires an external Qwen snapshot and isolated runtime.
    def __init__(self, model_dir: Path, device: Literal["mps", "cpu"], max_new_tokens: int) -> None:
        if any(not (model_dir / name).is_file() for name in MODEL_FILES):
            raise ValueError("model snapshot is incomplete")
        import torch

        qwen3_asr_model = _load_qwen3_asr_model()

        if device == "mps":
            if not torch.backends.mps.is_available() or not torch.backends.mps.is_built():
                raise RuntimeError("MPS unavailable")
            dtype = torch.float16
        else:
            dtype = torch.float32
        model = qwen3_asr_model.from_pretrained(
            str(model_dir),
            dtype=dtype,
            max_inference_batch_size=1,
            max_new_tokens=max_new_tokens,
            local_files_only=True,
        )
        model.model.to(torch.device(device), dtype=dtype).eval()
        parameters = tuple(model.model.parameters())
        if not parameters or any(parameter.device.type != device for parameter in parameters):
            raise RuntimeError("model device mismatch")
        self._model = model
        self.identity = WorkerIdentity(device, str(parameters[0].dtype).removeprefix("torch."))

    def transcribe(self, audio: bytes, *, language: str, prompt: str) -> tuple[str, str]:
        import numpy as np

        waveform = np.frombuffer(audio, dtype="<i2").astype(np.float32) / np.float32(32768)
        results = self._model.transcribe(
            audio=(waveform, 16_000),
            context=prompt,
            language=None if language == "auto" else language,
            return_time_stamps=False,
        )
        if not results:
            return "", language
        result = results[0]
        text, detected = getattr(result, "text", None), getattr(result, "language", None)
        if not isinstance(text, str) or not isinstance(detected, str):
            raise RuntimeError("invalid Qwen3 response")
        return text.strip(), detected


def _load_qwen3_asr_model() -> Any:
    """Import qwen-asr across its known Transformers decorator mismatch.

    qwen-asr 0.0.6 uses ``@check_model_inputs()`` while the published
    Transformers 4.57.x helper also accepts the bare decorator form.  The
    upstream package currently fails during import on the former spelling;
    normalize that call in this isolated worker process before importing the
    vendor package.  No global service process state is changed.
    """
    import transformers.utils.generic as transformers_generic

    original: Any = transformers_generic.check_model_inputs

    def compatible_check_model_inputs(
        func: Any = None, *, tie_last_hidden_states: bool = True
    ) -> Any:
        if func is None:
            return lambda decorated: original(
                decorated, tie_last_hidden_states=tie_last_hidden_states
            )
        return original(func, tie_last_hidden_states=tie_last_hidden_states)

    transformers_generic.check_model_inputs = compatible_check_model_inputs
    from qwen_asr import Qwen3ASRModel  # type: ignore[import-not-found]

    return Qwen3ASRModel


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
