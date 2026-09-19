from __future__ import annotations

from collections.abc import AsyncIterator
from pathlib import Path

import jsonschema
import yaml
from fastapi.testclient import TestClient

from speechrail.app import create_app
from speechrail.config import Settings
from speechrail.domain.ports import AudioChunk, SpeechRequest
from speechrail.domain.tts import normalize_tts_text
from speechrail.domain.tts_text_planner import TtsTextPlanner
from speechrail.domain.tts_timing import TtsTimingChunk, TtsTimingSidecar


class TimedSpeechSynthesizer:
    def __init__(self) -> None:
        self._timings: dict[str, TtsTimingSidecar] = {}

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        assert request.timing_mode == "chunk"
        response_id = "resp-timing"
        normalized = normalize_tts_text(request.text)
        plan = TtsTextPlanner().plan(normalized)
        cursor = 0
        chunks: list[TtsTimingChunk] = []
        for planned in plan.chunks:
            sample_count = max(1, len(planned.spoken_text))
            chunks.append(
                TtsTimingChunk(
                    planner_chunk=planned.index,
                    text_start=planned.source_start,
                    text_end=planned.source_end,
                    audio_start_sample=cursor,
                    audio_end_sample=cursor + sample_count,
                )
            )
            cursor += sample_count
        self._timings[response_id] = TtsTimingSidecar(
            sample_rate=24_000,
            text_length=len(normalized),
            total_samples=cursor,
            chunks=tuple(chunks),
        )

        async def stream() -> AsyncIterator[AudioChunk]:
            yield AudioChunk(
                response_id=response_id,
                chunk_index=0,
                audio=b"\x00\x00" * cursor,
            )

        return stream()

    def take_timing_sidecar(self, response_id: str) -> TtsTimingSidecar | None:
        return self._timings.pop(response_id, None)


class UntimedSpeechSynthesizer:
    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        assert request.timing_mode == "chunk"

        async def stream() -> AsyncIterator[AudioChunk]:
            yield AudioChunk(
                response_id="resp-untimed",
                chunk_index=0,
                audio=b"\x00\x00",
            )

        return stream()


def _client(synthesizer: object) -> TestClient:
    return TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=synthesizer,
        )
    )


def _payload(text: str) -> dict[str, object]:
    return {
        "model": "speechrail/qwen3-tts",
        "input": text,
        "voice": "default",
        "response_format": "pcm",
    }


def test_chunk_timing_is_separate_resource_and_preserves_openai_audio_body() -> None:
    client = _client(TimedSpeechSynthesizer())

    response = client.post(
        "/v1/audio/speech",
        headers={"SpeechRail-Timing-Mode": "chunk"},
        json=_payload("你好。"),
    )

    assert response.status_code == 200
    assert response.content == b"\x00\x00" * 3
    timing_id = response.headers["SpeechRail-Timing-Id"]
    timing = client.get(f"/v1/speechrail/audio/timings/{timing_id}").json()
    assert timing["status"] == "completed"
    assert timing["timing_quality"] == "chunk"
    assert timing["sample_rate"] == 24_000
    assert timing["total_samples"] == 3
    assert timing["display_mapping"] == {"status": "identity", "reason": None}
    assert timing["chunks"] == [
        {
            "planner_chunk": 0,
            "text_start": 0,
            "text_end": 3,
            "audio_start_sample": 0,
            "audio_end_sample": 3,
            "timing_quality": "chunk",
            "display_start": 0,
            "display_end": 3,
        }
    ]

    spec = yaml.safe_load(Path("contracts/openapi.yaml").read_text(encoding="utf-8"))
    schema = {
        "$ref": "#/components/schemas/TtsTimingResource",
        "components": spec["components"],
    }
    jsonschema.Draft202012Validator(schema).validate(timing)


def test_normalization_change_does_not_fake_display_coordinates() -> None:
    client = _client(TimedSpeechSynthesizer())

    response = client.post(
        "/v1/audio/speech",
        headers={"SpeechRail-Timing-Mode": "chunk"},
        json=_payload("你好"),
    )

    assert response.status_code == 200
    timing_id = response.headers["SpeechRail-Timing-Id"]
    timing = client.get(f"/v1/speechrail/audio/timings/{timing_id}").json()
    assert timing["status"] == "completed"
    assert timing["display_mapping"] == {
        "status": "unavailable",
        "reason": "normalization_changed_display_coordinates",
    }
    assert timing["chunks"][0]["display_start"] is None
    assert timing["chunks"][0]["display_end"] is None


def test_backend_without_timing_support_does_not_fail_audio() -> None:
    client = _client(UntimedSpeechSynthesizer())

    response = client.post(
        "/v1/audio/speech",
        headers={"SpeechRail-Timing-Mode": "chunk"},
        json=_payload("你好。"),
    )

    assert response.status_code == 200
    assert response.content == b"\x00\x00"
    timing_id = response.headers["SpeechRail-Timing-Id"]
    timing = client.get(f"/v1/speechrail/audio/timings/{timing_id}").json()
    assert timing["status"] == "unavailable"
    assert timing["timing_quality"] == "unavailable"
    assert timing["reason"] == "backend_timing_metadata_unavailable"


def test_plain_openai_speech_does_not_create_timing_resource() -> None:
    class PlainSynth:
        def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
            assert request.timing_mode is None

            async def stream() -> AsyncIterator[AudioChunk]:
                yield AudioChunk(
                    response_id="resp-plain",
                    chunk_index=0,
                    audio=b"\x00\x00",
                )

            return stream()

    response = _client(PlainSynth()).post(
        "/v1/audio/speech",
        json=_payload("你好。"),
    )
    assert response.status_code == 200
    assert "SpeechRail-Timing-Id" not in response.headers
