from __future__ import annotations

import json
from pathlib import Path

import httpx
import pytest

from speechrail.service.model_store import PreparedArtifact, PreparedModelSet
from speechrail.service.profile_smoke import PublicApiSmokeProbe, SmokeProbeError


def _prepared() -> PreparedModelSet:
    def artifact(key: str, family: str, variant: str) -> PreparedArtifact:
        return PreparedArtifact(
            key=key,
            path=Path(f"/models/{key}"),
            model_id=f"fixture/{key}",
            revision="a" * 40,
            family=family,
            variant=variant,
            quantization={},
            source={},
            sources=(),
            files=(),
        )

    return PreparedModelSet(
        prepared_id="prepared-light",
        preset="light",
        runtime_lock_id="runtime-v1",
        asr=artifact("asr", "qwen3_asr", "asr"),
        tts=artifact("tts", "qwen3_tts", "custom_voice"),
    )


def test_probe_uses_public_tts_then_transcription_with_stable_aliases() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        if request.url.path == "/health":
            return httpx.Response(200, json={"status": "ok"})
        if request.url.path == "/readyz":
            return httpx.Response(200, json={"ready": True})
        if request.url.path == "/v1/models":
            return httpx.Response(
                200,
                json={"data": [{"id": "whisper-1"}, {"id": "tts-1"}]},
            )
        if request.url.path == "/v1/voices":
            return httpx.Response(
                200,
                json={"data": [{"id": "serena", "available": True}]},
            )
        if request.url.path == "/v1/audio/speech":
            assert request.headers["authorization"] == "Bearer secret"
            assert b'"model":"tts-1"' in request.content
            assert b'"voice":"serena"' in request.content
            assert b'"language":"zh"' in request.content
            payload = json.loads(request.content)
            assert payload["input"] == "这是语音服务的切换验证，请清楚朗读这段普通话。"
            return httpx.Response(
                200,
                content=b"RIFF" + b"\x00" * 4 + b"WAVE" + b"\x00" * 64,
                headers={"X-Request-ID": "req-tts"},
            )
        if request.url.path == "/v1/audio/transcriptions":
            assert request.headers["authorization"] == "Bearer secret"
            assert b'filename="speechrail-smoke.wav"' in request.content
            assert b'name="model"' in request.content and b"whisper-1" in request.content
            return httpx.Response(
                200,
                json={"text": "speech rail smoke"},
                headers={"X-Request-ID": "req-asr"},
            )
        raise AssertionError(request.url.path)

    with httpx.Client(
        base_url="http://127.0.0.1:8201",
        transport=httpx.MockTransport(handler),
    ) as client:
        PublicApiSmokeProbe(client=client, api_key="secret").run(_prepared())

    assert [request.url.path for request in requests] == [
        "/health",
        "/readyz",
        "/v1/models",
        "/v1/voices",
        "/v1/audio/speech",
        "/v1/audio/transcriptions",
    ]


def test_probe_retries_readiness_without_repeating_inference() -> None:
    ready_calls = 0
    sleeps: list[float] = []

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal ready_calls
        if request.url.path == "/health":
            return httpx.Response(200, json={"status": "ok"})
        if request.url.path == "/readyz":
            ready_calls += 1
            return httpx.Response(
                200 if ready_calls == 2 else 503,
                json={"ready": ready_calls == 2},
            )
        if request.url.path == "/v1/models":
            return httpx.Response(200, json={"data": [{"id": "whisper-1"}, {"id": "tts-1"}]})
        if request.url.path == "/v1/voices":
            return httpx.Response(200, json={"data": [{"id": "serena", "available": True}]})
        if request.url.path == "/v1/audio/speech":
            return httpx.Response(
                200,
                content=b"RIFF" + b"\x00" * 4 + b"WAVE" + b"\x00" * 64,
                headers={"X-Request-ID": "req-tts"},
            )
        return httpx.Response(
            200,
            json={"text": "ok"},
            headers={"X-Request-ID": "req-asr"},
        )

    ticks = iter((0.0, 0.0, 0.1, 0.1))
    with httpx.Client(
        base_url="http://127.0.0.1:8201", transport=httpx.MockTransport(handler)
    ) as client:
        PublicApiSmokeProbe(
            client=client,
            deadline_seconds=1.0,
            clock=lambda: next(ticks),
            sleep=sleeps.append,
        ).run(_prepared())

    assert ready_calls == 2
    assert sleeps == [0.1]


@pytest.mark.parametrize("failure", ["missing_request_id", "oversized_audio", "empty_text"])
def test_probe_fails_closed_on_invalid_public_responses(failure: str) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/health":
            return httpx.Response(200, json={"status": "ok"})
        if request.url.path == "/readyz":
            return httpx.Response(200, json={"ready": True})
        if request.url.path == "/v1/models":
            return httpx.Response(200, json={"data": [{"id": "whisper-1"}, {"id": "tts-1"}]})
        if request.url.path == "/v1/voices":
            return httpx.Response(200, json={"data": [{"id": "serena", "available": True}]})
        if request.url.path == "/v1/audio/speech":
            padding = 9 * 1024 * 1024 if failure == "oversized_audio" else 64
            return httpx.Response(
                200,
                content=(b"RIFF" + b"\x00" * 4 + b"WAVE" + b"\x00" * padding),
                headers={} if failure == "missing_request_id" else {"X-Request-ID": "req-tts"},
            )
        return httpx.Response(
            200,
            json={"text": "" if failure == "empty_text" else "ok"},
            headers={"X-Request-ID": "req-asr"},
        )

    with httpx.Client(
        base_url="http://127.0.0.1:8201", transport=httpx.MockTransport(handler)
    ) as client, pytest.raises(SmokeProbeError):
        PublicApiSmokeProbe(client=client, max_audio_bytes=8 * 1024 * 1024).run(_prepared())


def test_probe_rejects_non_loopback_transport() -> None:
    with httpx.Client(base_url="http://192.0.2.1:8201") as client, pytest.raises(
        ValueError, match="loopback"
    ):
        PublicApiSmokeProbe(client=client)
