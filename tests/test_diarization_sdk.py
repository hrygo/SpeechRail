"""Official OpenAI Python SDK contract tests for native file diarization."""

from __future__ import annotations

import httpx
import pytest
from openai import OpenAI, UnprocessableEntityError

from test_openai_diarized_batch import FakeDiarizationEngine, _client, _pcm16_wav


def _sdk_client(app_client) -> OpenAI:
    """Route an official SDK request through the ASGI test application."""

    def handle(request: httpx.Request) -> httpx.Response:
        response = app_client.request(
            request.method,
            request.url.path,
            content=request.content,
            headers=dict(request.headers),
        )
        return httpx.Response(
            response.status_code,
            headers=response.headers,
            content=response.content,
            request=request,
        )

    return OpenAI(
        base_url="http://speechrail.test/v1",
        api_key="local",
        http_client=httpx.Client(transport=httpx.MockTransport(handle)),
    )


def test_native_diarized_sdk_uses_standard_object_chunking_strategy() -> None:
    app_client = _client(diarization_engine=FakeDiarizationEngine())
    sdk = _sdk_client(app_client)
    try:
        result = sdk.audio.transcriptions.create(
            model="gpt-4o-transcribe-diarize",
            file=("clip.wav", _pcm16_wav(2), "audio/wav"),
            response_format="diarized_json",
            chunking_strategy={"type": "auto"},
        )
    finally:
        sdk.close()
        app_client.close()

    payload = result.model_dump()
    assert payload["task"] == "transcribe"
    assert [segment["id"] for segment in payload["segments"]] == ["seg_0", "seg_1"]
    assert all(isinstance(segment["id"], str) for segment in payload["segments"])
    assert all(segment["type"] == "transcript.text.segment" for segment in payload["segments"])
    assert "confidence" not in payload["segments"][0]
    assert "".join(segment["text"] for segment in payload["segments"]) == payload["text"]


def test_native_diarized_sdk_uses_scalar_chunking_strategy() -> None:
    app_client = _client(diarization_engine=FakeDiarizationEngine())
    sdk = _sdk_client(app_client)
    try:
        result = sdk.audio.transcriptions.create(
            model="gpt-4o-transcribe-diarize",
            file=("clip.wav", _pcm16_wav(2), "audio/wav"),
            response_format="diarized_json",
            chunking_strategy="auto",
        )
    finally:
        sdk.close()
        app_client.close()

    assert result.text == "你好 世界"


def test_native_diarized_sdk_rejects_known_speaker_references() -> None:
    app_client = _client(diarization_engine=FakeDiarizationEngine())
    sdk = _sdk_client(app_client)
    try:
        with pytest.raises(UnprocessableEntityError) as excinfo:
            sdk.audio.transcriptions.create(
                model="gpt-4o-transcribe-diarize",
                file=("clip.wav", _pcm16_wav(2), "audio/wav"),
                response_format="diarized_json",
                known_speaker_names=["opaque-client-name"],
            )
    finally:
        sdk.close()
        app_client.close()

    assert excinfo.value.code == "unsupported_parameter"
    assert excinfo.value.param == "known_speaker_names"


def test_native_diarized_sdk_stream_uses_standard_sse_events() -> None:
    app_client = _client(diarization_engine=FakeDiarizationEngine())
    sdk = _sdk_client(app_client)
    try:
        stream = sdk.audio.transcriptions.create(
            model="gpt-4o-transcribe-diarize",
            file=("clip.wav", _pcm16_wav(2), "audio/wav"),
            response_format="diarized_json",
            chunking_strategy={"type": "auto"},
            stream=True,
        )
        events = list(stream)
    finally:
        sdk.close()
        app_client.close()

    assert [event.type for event in events] == [
        "transcript.text.delta",
        "transcript.text.segment",
        "transcript.text.delta",
        "transcript.text.segment",
        "transcript.text.done",
    ]
    segments = [event for event in events if event.type == "transcript.text.segment"]
    done = events[-1]
    assert "".join(event.text for event in segments) == done.text
