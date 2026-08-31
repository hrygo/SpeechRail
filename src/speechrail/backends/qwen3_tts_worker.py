"""Private, offline protocol host for one local Qwen3-TTS model process."""

from __future__ import annotations

import argparse
import base64
import importlib
import inspect
import sys
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any, BinaryIO, Literal, Protocol

from speechrail.runtime.worker_protocol import (
    PROTOCOL_VERSION,
    ProtocolError,
    read_frame,
    write_frame,
)


@dataclass(frozen=True, slots=True)
class TtsWorkerIdentity:
    device: str
    dtype: str
    sample_rate: int


class TtsWorkerEngine(Protocol):
    identity: TtsWorkerIdentity

    def synthesize(self, text: str, *, voice: str, speed: float) -> Iterator[bytes]: ...


EngineFactory = Callable[[Path], TtsWorkerEngine]


class _Qwen3CustomVoiceEngine:  # pragma: no cover - requires separately authorized model runtime.
    """Minimal Qwen3-TTS CustomVoice bridge, isolated in the worker process."""

    def __init__(self, model_dir: Path, *, device: Literal["mps", "cpu"]) -> None:
        try:
            torch = importlib.import_module("torch")
            qwen_tts = importlib.import_module("qwen_tts")
            model_class = qwen_tts.Qwen3TTSModel
            dtype = torch.float16 if device == "mps" else torch.float32
            self._model: Any = model_class.from_pretrained(
                str(model_dir), device_map=device, dtype=dtype
            )
            self._numpy: Any = importlib.import_module("numpy")
        except Exception as exc:
            raise RuntimeError("qwen3_tts_runtime_unavailable") from exc
        self.identity = TtsWorkerIdentity(
            device=device,
            dtype="float16" if device == "mps" else "float32",
            sample_rate=24_000,
        )

    def synthesize(self, text: str, *, voice: str, speed: float) -> Iterator[bytes]:
        generate = self._model.generate_custom_voice
        parameters = inspect.signature(generate).parameters
        kwargs: dict[str, object] = {
            "text": text,
            "language": "Auto",
            "speaker": voice,
        }
        if "speed" in parameters:
            kwargs["speed"] = speed
        elif speed != 1.0:
            raise RuntimeError("speed_not_supported")
        wavs, sample_rate = generate(**kwargs)
        if sample_rate != self.identity.sample_rate or not wavs:
            raise RuntimeError("qwen3_tts_output_invalid")
        waveform = self._numpy.asarray(wavs[0], dtype=self._numpy.float32).reshape(-1)
        if waveform.size == 0:
            raise RuntimeError("qwen3_tts_output_invalid")
        pcm = (self._numpy.clip(waveform, -1.0, 1.0) * 32767.0).astype("<i2").tobytes()
        for offset in range(0, len(pcm), 9_600):
            yield pcm[offset : offset + 9_600]


def _default_engine_factory(  # pragma: no cover - requires separately authorized model runtime.
    device: Literal["mps", "cpu"],
) -> EngineFactory:
    return lambda model_dir: _Qwen3CustomVoiceEngine(model_dir, device=device)


def serve(
    input_stream: BinaryIO,
    output_stream: BinaryIO,
    *,
    model_dir: Path,
    device: Literal["mps", "cpu"],
    sample_rate: int,
    engine_factory: EngineFactory,
) -> None:
    """Serve only framed local IPC; no request can select a model or URL."""
    start = read_frame(input_stream)
    if (
        start is None
        or start.get("version") != PROTOCOL_VERSION
        or start.get("type") != "start"
        or start.get("model_dir") != str(model_dir)
        or start.get("device") != device
        or start.get("sample_rate") != sample_rate
    ):
        write_frame(
            output_stream,
            {"version": PROTOCOL_VERSION, "type": "error", "code": "worker_invalid_start"},
        )
        return
    try:
        engine = engine_factory(model_dir)
    except Exception:
        write_frame(
            output_stream,
            {"version": PROTOCOL_VERSION, "type": "error", "code": "worker_load_error"},
        )
        return
    identity = engine.identity
    expected_dtype = "float16" if device == "mps" else "float32"
    if (
        identity.device != device
        or identity.dtype != expected_dtype
        or identity.sample_rate != sample_rate
    ):
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
            "sample_rate": identity.sample_rate,
            "model_loaded": True,
        },
    )
    while frame := read_frame(input_stream):
        request_id = frame.get("request_id") if isinstance(frame.get("request_id"), str) else None
        try:
            request_id, text, voice, speed = _decode_synthesis_request(frame)
            for index, pcm in enumerate(engine.synthesize(text, voice=voice, speed=speed)):
                if not pcm or len(pcm) % 2:
                    raise ProtocolError("invalid PCM chunk")
                write_frame(
                    output_stream,
                    {
                        "version": PROTOCOL_VERSION,
                        "type": "audio",
                        "request_id": request_id,
                        "chunk_index": index,
                        "pcm_b64": base64.b64encode(pcm).decode("ascii"),
                    },
                )
            write_frame(
                output_stream,
                {"version": PROTOCOL_VERSION, "type": "completed", "request_id": request_id},
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


def _decode_synthesis_request(frame: dict[str, object]) -> tuple[str, str, str, float]:
    request_id = frame.get("request_id")
    text = frame.get("text")
    voice = frame.get("voice")
    speed = frame.get("speed")
    if (
        frame.get("version") != PROTOCOL_VERSION
        or frame.get("type") != "synthesize"
        or not isinstance(request_id, str)
        or not request_id
        or not isinstance(text, str)
        or not text.strip()
        or not isinstance(voice, str)
        or not voice.strip()
        or not isinstance(speed, (float, int))
        or not 0.25 <= float(speed) <= 4.0
    ):
        raise ProtocolError("invalid synthesize request")
    return request_id, text, voice, float(speed)


def main(argv: list[str] | None = None, *, engine_factory: EngineFactory | None = None) -> None:
    """Run the private local IPC service; public ASGI workers never import Qwen TTS."""

    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--device", choices=("mps", "cpu"), required=True)
    parser.add_argument("--sample-rate", type=int, required=True)
    args = parser.parse_args(argv)
    model_dir = Path(args.model_dir).resolve(strict=True)
    device: Literal["mps", "cpu"] = args.device
    selected_factory = engine_factory or _default_engine_factory(device)
    serve(
        sys.stdin.buffer,
        sys.stdout.buffer,
        model_dir=model_dir,
        device=device,
        sample_rate=args.sample_rate,
        engine_factory=selected_factory,
    )


if __name__ == "__main__":  # pragma: no cover - subprocess entrypoint.
    main()
