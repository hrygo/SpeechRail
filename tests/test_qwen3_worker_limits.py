from __future__ import annotations

import base64

import pytest

import speechrail.backends.qwen3_worker as worker
from speechrail.runtime.worker_protocol import ProtocolError


def _request() -> dict[str, object]:
    return {
        "request_id": "req_limit",
        "sample_rate": 16_000,
        "channels": 1,
        "sample_width_bytes": 2,
        "language": "auto",
        "prompt": "",
        "include_timestamps": False,
    }


@pytest.mark.parametrize("encoding", ("binary", "base64"))
def test_decode_request_accepts_exact_batch_limit(
    monkeypatch: pytest.MonkeyPatch, encoding: str
) -> None:
    monkeypatch.setattr(worker, "MAX_BATCH_PCM_BYTES", 4)
    payload = b"\x01\x02\x03\x04"
    frame = _request()
    if encoding == "binary":
        frame["_binary"] = payload
    else:
        frame["pcm_b64"] = base64.b64encode(payload).decode("ascii")

    request_id, pcm, language, prompt, include_timestamps = worker._decode_request(frame)

    assert (request_id, pcm, language, prompt, include_timestamps) == (
        "req_limit",
        payload,
        "auto",
        "",
        False,
    )


def test_decode_request_rejects_batch_pcm_over_limit(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(worker, "MAX_BATCH_PCM_BYTES", 4)
    frame = _request()
    frame["_binary"] = b"\x01\x02\x03\x04\x05\x06"

    with pytest.raises(ProtocolError, match=r"^invalid PCM length$"):
        worker._decode_request(frame)


def test_batch_limit_covers_configured_default_audio_without_allocating_pcm() -> None:
    assert worker.MAX_PCM_BYTES == 40 * 1024 * 1024
    assert worker.MAX_BATCH_PCM_BYTES >= 3_600 * 32_000
