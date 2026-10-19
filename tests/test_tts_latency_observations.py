"""Latency observations are published, optional, and never gate anything.

The same three field names travel in the Realtime terminal and in the HTTP
response headers, so these tests pin the shared vocabulary in one place.
"""

from __future__ import annotations

import math
from collections.abc import AsyncIterator

from fastapi.testclient import TestClient

from speechrail.app import create_app
from speechrail.compatibility.openai_realtime import tts_completed
from speechrail.config import Settings
from speechrail.domain.ports import AudioChunk, SpeechRequest
from speechrail.observability.latency import (
    LATENCY_HEADERS,
    latency_fields,
    latency_headers,
)

_SAMPLE_RATE = 24_000
_SAMPLES = 2_400  # 100 ms of PCM16 at the wire rate.


class _Synthesizer:
    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        async def stream() -> AsyncIterator[AudioChunk]:
            yield AudioChunk(
                response_id="resp-latency",
                chunk_index=0,
                audio=b"\x00\x00" * _SAMPLES,
            )

        return stream()


def _client() -> TestClient:
    return TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=_Synthesizer(),
        )
    )


def _payload(response_format: str) -> dict[str, object]:
    return {
        "model": "speechrail/qwen3-tts",
        "input": "你好。",
        "voice": "default",
        "response_format": response_format,
    }


def test_observations_degrade_to_absence_not_to_a_wrong_number() -> None:
    assert latency_fields(ttfa_sec=None, audio_sec=0.0, inference_sec=0.0) == {}
    # A clock that steps backwards must not publish a negative measurement.
    assert latency_fields(ttfa_sec=-1.0, audio_sec=-1.0, inference_sec=-1.0) == {}
    assert latency_fields(ttfa_sec=math.nan, audio_sec=math.nan, inference_sec=0.0) == {}
    # A zero-length render has no ratio to report, but it still has a TTFA.
    assert latency_fields(ttfa_sec=0.25, audio_sec=0.0, inference_sec=1.0) == {"ttfa_ms": 250}


def test_observations_use_one_rounding_and_one_unit_system() -> None:
    fields = latency_fields(ttfa_sec=0.1234, audio_sec=2.0, inference_sec=1.0)

    assert fields == {"ttfa_ms": 123, "audio_ms": 2000, "rtf": 0.5}
    assert latency_headers(fields) == {
        "SpeechRail-Ttfa-Ms": "123",
        "SpeechRail-Audio-Ms": "2000",
        "SpeechRail-Rtf": "0.5",
    }
    # Field names stay snake_case in JSON; only headers change shape.
    assert set(LATENCY_HEADERS) == {"ttfa_ms", "audio_ms", "rtf"}


def test_completed_event_stays_backward_compatible_without_observations() -> None:
    bare = tts_completed(task_id="t", request_id="r", generated_samples=3)
    assert bare == {
        "type": "speechrail.tts.completed",
        "task_id": "t",
        "request_id": "r",
        "generated_samples": 3,
    }

    measured = tts_completed(
        task_id="t",
        request_id="r",
        generated_samples=3,
        latency={"ttfa_ms": 120, "audio_ms": 4000, "rtf": 0.25},
    )
    assert measured["ttfa_ms"] == 120
    assert measured["audio_ms"] == 4000
    assert measured["rtf"] == 0.25
    assert measured["generated_samples"] == 3


def test_streamed_speech_publishes_only_the_observation_it_can_know() -> None:
    response = _client().post("/v1/audio/speech", json=_payload("pcm"))

    assert response.status_code == 200
    assert response.headers["Content-Type"] == "audio/x-pcm"
    # TTFA exists before the body starts; the audio duration does not.
    assert int(response.headers["SpeechRail-Ttfa-Ms"]) >= 0
    assert "SpeechRail-Audio-Ms" not in response.headers
    assert "SpeechRail-Rtf" not in response.headers


def test_buffered_speech_publishes_every_observation() -> None:
    response = _client().post("/v1/audio/speech", json=_payload("wav"))

    assert response.status_code == 200
    assert response.headers["Content-Type"] == "audio/wav"
    assert int(response.headers["SpeechRail-Ttfa-Ms"]) >= 0
    assert response.headers["SpeechRail-Audio-Ms"] == str(_SAMPLES * 1000 // _SAMPLE_RATE)
    assert float(response.headers["SpeechRail-Rtf"]) >= 0
