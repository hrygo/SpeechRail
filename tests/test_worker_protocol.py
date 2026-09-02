from io import BytesIO
from pathlib import Path

import pytest

from speechrail.backends.qwen3_worker import WorkerIdentity, serve
from speechrail.runtime.worker_protocol import (
    MAX_FRAME_BYTES,
    ProtocolError,
    decode_frame_body,
    encode_frame,
    read_frame,
    write_frame,
)


class _FakeEngine:
    identity = WorkerIdentity(device="mps", dtype="float16")

    def transcribe(
        self,
        audio: bytes,
        *,
        language: str,
        prompt: str,
        include_timestamps: bool = False,
    ) -> tuple[str, str, list[dict[str, object]]]:
        assert audio == b"\x00\x00"
        assert language == "Chinese"
        assert prompt == "names"
        return "hello", language, []


def test_framed_protocol_round_trips_versioned_request() -> None:
    stream = BytesIO()
    write_frame(stream, {"version": 1, "type": "transcribe", "request_id": "req_1"})
    stream.seek(0)

    assert read_frame(stream) == {"version": 1, "type": "transcribe", "request_id": "req_1"}


def test_framed_protocol_rejects_bad_length_and_eof() -> None:
    with pytest.raises(ProtocolError, match="truncated"):
        read_frame(BytesIO(b"\x00\x00"))
    with pytest.raises(ProtocolError, match="size"):
        read_frame(BytesIO(b"\xff\xff\xff\xff"))


def test_codec_round_trips_an_object_payload() -> None:
    frame = encode_frame({"version": 1, "type": "transcribe"})

    assert decode_frame_body(frame[4:]) == {"version": 1, "type": "transcribe"}
    assert len(frame) == 4 + len(frame[4:])


def test_codec_rejects_non_object_json() -> None:
    with pytest.raises(ProtocolError, match="object"):
        decode_frame_body(b"[1, 2, 3]")


def test_codec_rejects_empty_body() -> None:
    with pytest.raises(ProtocolError, match="size"):
        decode_frame_body(b"")


def test_codec_rejects_oversize_body() -> None:
    oversize = b"x" * (MAX_FRAME_BYTES + 1)
    with pytest.raises(ProtocolError, match="size"):
        decode_frame_body(oversize)
    with pytest.raises(ProtocolError, match="size"):
        encode_frame({"blob": "x" * (MAX_FRAME_BYTES + 1)})


def test_codec_rejects_invalid_utf8() -> None:
    with pytest.raises(ProtocolError, match="JSON"):
        decode_frame_body(b"\xff\xfe\xff")


def test_codec_rejects_truncated_json_body() -> None:
    with pytest.raises(ProtocolError, match="JSON"):
        decode_frame_body(b'{"type": "transcri')


def test_worker_reuses_one_loaded_engine_for_framed_requests() -> None:
    incoming = BytesIO()
    write_frame(
        incoming, {"version": 1, "type": "start", "model_dir": "/external/model", "device": "mps"}
    )
    write_frame(
        incoming,
        {
            "version": 1,
            "type": "transcribe",
            "request_id": "req_1",
            "sample_rate": 16000,
            "channels": 1,
            "sample_width_bytes": 2,
            "language": "zh",
            "prompt": "names",
            "pcm_b64": "AAA=",
        },
    )
    incoming.seek(0)
    outgoing = BytesIO()
    serve(
        incoming,
        outgoing,
        model_dir=Path("/external/model"),
        device="mps",
        max_new_tokens=64,
        engine_factory=lambda *_: _FakeEngine(),
    )
    outgoing.seek(0)
    assert read_frame(outgoing)["type"] == "ready"
    assert read_frame(outgoing) == {
        "version": 1,
        "type": "result",
        "request_id": "req_1",
        "text": "hello",
        "language": "Chinese",
        "segments": [],
        "device": "mps",
        "dtype": "float16",
    }
