from io import BytesIO

import pytest

from speechrail.runtime.worker_protocol import ProtocolError, read_frame, write_frame


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
