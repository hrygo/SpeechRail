"""Private, offline protocol host for one local Qwen3-TTS model process."""

from __future__ import annotations

import base64
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Literal, Protocol

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
