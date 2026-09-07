"""Contract tests for the SpeechRail REST client (proxy side).

These lock the exact request shapes the proxy must send against the real
route handlers in ``speechrail.http.routes`` (multipart field names, JSON body
keys, URL prefixes) and the parsing of the unified error envelope
(``speechrail.http.errors``).
"""

from __future__ import annotations

import json
from typing import Any

import httpx

from speechrail.mcp.client import SpeechRailError, parse_error_response

_FAKE_WAV = b"RIFF-fake-wav-data-for-contract-tests"


def test_models_and_voices_are_read_under_v1(
    make_client: Any, run_async: Any, json_response: Any
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/v1/models":
            return json_response({"object": "list", "data": [{"id": "m1"}]})
        if request.url.path == "/v1/voices":
            return json_response({"object": "list", "data": [{"id": "serena"}]})
        raise AssertionError(f"unexpected request {request.method} {request.url}")

    client, requests = make_client(handler)

    models = run_async(client.fetch_models())
    voices = run_async(client.fetch_voices())

    assert models == [{"id": "m1"}]
    assert voices == [{"id": "serena"}]
    assert requests[0].url.path == "/v1/models"
    assert requests[1].url.path == "/v1/voices"
    assert all(request.method == "GET" for request in requests)


def test_health_is_read_from_server_root(
    make_client: Any, run_async: Any, json_response: Any
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/health"
        return json_response({"status": "ok", "profile": "quality"})

    client, requests = make_client(handler)
    health = run_async(client.fetch_health())
    assert health["profile"] == "quality"
    assert requests[0].url.path == "/health"


def test_bearer_header_is_sent_only_when_key_is_configured(
    make_client: Any, run_async: Any, json_response: Any
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return json_response({"object": "list", "data": []})

    keyed_client, keyed_requests = make_client(handler, api_key="secret")
    run_async(keyed_client.fetch_models())
    assert keyed_requests[0].headers["Authorization"] == "Bearer secret"

    keyless_client, keyless_requests = make_client(handler)
    run_async(keyless_client.fetch_models())
    assert "Authorization" not in keyless_requests[0].headers


def test_transcription_is_a_multipart_upload_with_exact_fields(
    make_client: Any, run_async: Any, json_response: Any
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.method == "POST"
        assert request.url.path == "/v1/audio/transcriptions"
        content_type = request.headers["content-type"]
        assert content_type.startswith("multipart/form-data; boundary=")
        body = request.content
        assert b'name="file"' in body
        assert b'filename="meeting.wav"' in body
        assert b'name="response_format"' in body
        assert b"verbose_json" in body
        assert b'name="language"' in body
        assert b"zh" in body
        assert b'name="model"' not in body
        assert _FAKE_WAV in body
        return json_response({"text": "ok", "segments": []})

    client, requests = make_client(handler)
    result = run_async(
        client.transcribe(
            content=_FAKE_WAV,
            filename="meeting.wav",
            response_format="verbose_json",
            language="zh",
        )
    )
    assert result["text"] == "ok"
    assert len(requests) == 1


def test_synthesis_is_a_json_post_with_openai_body_keys(
    make_client: Any, run_async: Any
) -> None:
    audio = b"ID3-fake-mp3-bytes"

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.method == "POST"
        assert request.url.path == "/v1/audio/speech"
        assert request.headers["content-type"].startswith("application/json")
        payload = json.loads(request.content)
        assert payload == {
            "model": "speechrail/qwen3-tts",
            "input": "你好",
            "voice": "serena",
            "response_format": "mp3",
            "speed": 1.0,
        }
        return httpx.Response(status_code=200, content=audio)

    client, requests = make_client(handler)
    content = run_async(
        client.synthesize(
            model="speechrail/qwen3-tts",
            text="你好",
            voice="serena",
            response_format="mp3",
            speed=1.0,
        )
    )
    assert content == audio
    assert len(requests) == 1


def test_voice_preview_json_body_and_raw_audio_response(
    make_client: Any, run_async: Any
) -> None:
    audio = b"RIFF-fake-preview-wav"

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.method == "POST"
        assert request.url.path == "/v1/voices/previews"
        body = json.loads(request.content)
        assert body == {
            "model": "speechrail/qwen3-tts",
            "input": "试听这一句。",
            "instruction": "温暖自然的中文女声。",
            "response_format": "wav",
        }
        return httpx.Response(status_code=200, content=audio)

    client, _requests = make_client(handler)
    content = run_async(
        client.voice_preview(
            model="speechrail/qwen3-tts",
            text="试听这一句。",
            instruction="温暖自然的中文女声。",
        )
    )
    assert content == audio


def test_job_lifecycle_verbs_and_bodies(
    make_client: Any, run_async: Any, json_response: Any
) -> None:
    job = {"id": "job_abc", "kind": "transcription", "state": "queued"}

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "POST" and request.url.path == "/v1/jobs":
            body = json.loads(request.content)
            assert body == {"kind": "transcription", "input_ref": "/tmp/in.wav"}
            return json_response(job, status=202)
        if request.method == "GET" and request.url.path == "/v1/jobs/job_abc":
            return json_response({"id": "job_abc", "state": "running"})
        if request.method == "DELETE" and request.url.path == "/v1/jobs/job_abc":
            return json_response({"id": "job_abc", "state": "cancelled"})
        raise AssertionError(f"unexpected request {request.method} {request.url}")

    client, requests = make_client(handler)
    assert run_async(client.create_job(kind="transcription", input_ref="/tmp/in.wav")) == job
    assert run_async(client.get_job(job_id="job_abc"))["state"] == "running"
    assert run_async(client.cancel_job(job_id="job_abc"))["state"] == "cancelled"
    methods = [request.method for request in requests]
    assert methods == ["POST", "GET", "DELETE"]


def test_error_envelope_is_parsed_into_speechrail_error(
    envelope_response: Any, make_client: Any, run_async: Any
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/v1/models":
            return envelope_response(
                status=429,
                code="queue_full",
                message="Inference queue is full",
                retryable=True,
            )
        raise AssertionError("unexpected call")

    client, _requests = make_client(handler)
    try:
        run_async(client.fetch_models())
    except SpeechRailError as exc:
        assert exc.status == 429
        assert exc.code == "queue_full"
        assert exc.message == "Inference queue is full"
        assert exc.retryable is True
        assert exc.error_type == "server_error"
        assert exc.request_id == "req_test"
        assert exc.hint is not None
        assert "backoff" in exc.hint
    else:
        raise AssertionError("expected SpeechRailError")


def test_voice_error_gets_describe_hint(
    envelope_response: Any, make_client: Any, run_async: Any
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return envelope_response(
            status=400,
            code="voice_not_available",
            message="Voice unavailable for the active TTS weights",
            retryable=False,
            param="voice",
        )

    client, _requests = make_client(handler)
    try:
        run_async(
            client.synthesize(
                model="m",
                text="hi",
                voice="clone_1",
                response_format="mp3",
                speed=1.0,
            )
        )
    except SpeechRailError as exc:
        assert exc.code == "voice_not_available"
        assert exc.retryable is False
        assert exc.error_type == "invalid_request_error"
        assert exc.param == "voice"
        assert "describe()" in (exc.hint or "")
    else:
        raise AssertionError("expected SpeechRailError")


def test_parse_error_response_falls_back_for_non_envelope_body(
    envelope_response: Any,
) -> None:
    response = httpx.Response(status_code=502, text="<html>bad gateway</html>")
    error = parse_error_response(response)
    assert error.code == "http_502"
    assert error.retryable is False
    assert error.status == 502
    assert "<html>" in error.message


def test_connection_errors_map_to_retryable_speechrail_error(
    make_client: Any, run_async: Any
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("refused", request=request)

    client, _requests = make_client(handler)
    try:
        run_async(client.fetch_health())
    except SpeechRailError as exc:
        assert exc.code == "connection_error"
        assert exc.retryable is True
        assert "cannot reach SpeechRail" in exc.message
    else:
        raise AssertionError("expected SpeechRailError")
