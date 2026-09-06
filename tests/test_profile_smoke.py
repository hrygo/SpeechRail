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


def _health_payload(
    *,
    profile: str = "light",
    asr_ready: bool = True,
    tts_ready: bool = True,
) -> dict[str, object]:
    return {
        "status": "ok",
        "profile": profile,
        "asr_ready": asr_ready,
        "tts_ready": tts_ready,
        "ready": asr_ready or tts_ready,
    }


def _models_payload(prepared: PreparedModelSet) -> dict[str, object]:
    return {
        "data": [
            {
                "id": "asr-model",
                "profile": prepared.preset,
                "artifact": prepared.asr.key,
                "variant": prepared.asr.variant,
                "quantization": dict(prepared.asr.quantization),
            },
            {
                "id": "tts-model",
                "profile": prepared.preset,
                "artifact": prepared.tts.key,
                "variant": prepared.tts.variant,
                "quantization": dict(prepared.tts.quantization),
            },
            {"id": "whisper-1"},
            {"id": "tts-1"},
        ]
    }


def test_probe_uses_public_tts_then_transcription_with_stable_aliases() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        if request.url.path == "/health":
            return httpx.Response(200, json=_health_payload())
        if request.url.path == "/readyz":
            return httpx.Response(200, json={"ready": True})
        if request.url.path == "/v1/models":
            return httpx.Response(200, json=_models_payload(_prepared()))
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
            return httpx.Response(200, json=_health_payload())
        if request.url.path == "/readyz":
            ready_calls += 1
            return httpx.Response(
                200 if ready_calls == 2 else 503,
                json={"ready": ready_calls == 2},
            )
        if request.url.path == "/v1/models":
            return httpx.Response(200, json=_models_payload(_prepared()))
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


def test_probe_rejects_ready_service_for_a_different_profile() -> None:
    requests: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request.url.path)
        if request.url.path == "/health":
            return httpx.Response(
                200,
                json={
                    "status": "ok",
                    "profile": "quality",
                    "asr_ready": True,
                    "tts_ready": True,
                    "ready": True,
                },
            )
        if request.url.path == "/readyz":
            return httpx.Response(200, json={"ready": True})
        raise AssertionError("a profile mismatch must stop before public inference")

    with httpx.Client(
        base_url="http://127.0.0.1:8201", transport=httpx.MockTransport(handler)
    ) as client, pytest.raises(SmokeProbeError, match="profile mismatch"):
        PublicApiSmokeProbe(client=client).run(_prepared())

    assert requests == ["/health"]


def test_probe_rejects_ready_service_without_profile_identity() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/health":
            return httpx.Response(200, json={"status": "ok", "asr_ready": True, "tts_ready": True})
        if request.url.path == "/readyz":
            return httpx.Response(200, json={"ready": True})
        raise AssertionError("missing profile identity must stop before public inference")

    with httpx.Client(
        base_url="http://127.0.0.1:8201", transport=httpx.MockTransport(handler)
    ) as client, pytest.raises(SmokeProbeError, match="profile identity"):
        PublicApiSmokeProbe(client=client).run(_prepared())


def test_probe_rejects_public_catalog_for_a_different_prepared_artifact() -> None:
    prepared = _prepared()

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/health":
            return httpx.Response(200, json=_health_payload())
        if request.url.path == "/readyz":
            return httpx.Response(200, json={"ready": True})
        if request.url.path == "/v1/models":
            payload = _models_payload(prepared)
            assert isinstance(payload["data"], list)
            payload["data"][0]["artifact"] = "old-asr"
            return httpx.Response(200, json=payload)
        if request.url.path == "/v1/voices":
            return httpx.Response(200, json={"data": [{"id": "serena", "available": True}]})
        raise AssertionError("artifact mismatch must stop before public inference")

    with httpx.Client(
        base_url="http://127.0.0.1:8201", transport=httpx.MockTransport(handler)
    ) as client, pytest.raises(SmokeProbeError, match="prepared model identity"):
        PublicApiSmokeProbe(client=client).run(prepared)


def test_probe_rejects_readyz_when_required_tts_capability_is_not_ready() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/health":
            return httpx.Response(200, json=_health_payload(tts_ready=False))
        if request.url.path == "/readyz":
            return httpx.Response(200, json={"ready": True})
        raise AssertionError("incomplete capability readiness must stop before inference")

    with httpx.Client(
        base_url="http://127.0.0.1:8201", transport=httpx.MockTransport(handler)
    ) as client, pytest.raises(SmokeProbeError, match="smoke deadline"):
        PublicApiSmokeProbe(
            client=client,
            deadline_seconds=0.01,
            poll_interval_seconds=0.001,
            sleep=lambda _: None,
        ).run(_prepared())


def test_probe_retries_only_empty_asr_transcripts_with_fresh_tts_audio() -> None:
    tts_calls = 0
    asr_calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal asr_calls, tts_calls
        if request.url.path == "/health":
            return httpx.Response(200, json=_health_payload())
        if request.url.path == "/readyz":
            return httpx.Response(200, json={"ready": True})
        if request.url.path == "/v1/models":
            return httpx.Response(200, json=_models_payload(_prepared()))
        if request.url.path == "/v1/voices":
            return httpx.Response(200, json={"data": [{"id": "serena", "available": True}]})
        if request.url.path == "/v1/audio/speech":
            tts_calls += 1
            return httpx.Response(
                200,
                content=b"RIFF" + b"\x00" * 4 + b"WAVE" + bytes([tts_calls]) * 64,
                headers={"X-Request-ID": f"req-tts-{tts_calls}"},
            )
        if request.url.path == "/v1/audio/transcriptions":
            asr_calls += 1
            return httpx.Response(
                200,
                json={"text": "" if asr_calls == 1 else "切换验证通过"},
                headers={"X-Request-ID": f"req-asr-{asr_calls}"},
            )
        raise AssertionError(request.url.path)

    with httpx.Client(
        base_url="http://127.0.0.1:8201", transport=httpx.MockTransport(handler)
    ) as client:
        PublicApiSmokeProbe(client=client).run(_prepared())

    assert tts_calls == 2
    assert asr_calls == 2


@pytest.mark.parametrize("failure", ["missing_request_id", "oversized_audio", "empty_text"])
def test_probe_fails_closed_on_invalid_public_responses(failure: str) -> None:
    tts_calls = 0
    asr_calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal asr_calls, tts_calls
        if request.url.path == "/health":
            return httpx.Response(200, json=_health_payload())
        if request.url.path == "/readyz":
            return httpx.Response(200, json={"ready": True})
        if request.url.path == "/v1/models":
            return httpx.Response(200, json=_models_payload(_prepared()))
        if request.url.path == "/v1/voices":
            return httpx.Response(200, json={"data": [{"id": "serena", "available": True}]})
        if request.url.path == "/v1/audio/speech":
            tts_calls += 1
            padding = 9 * 1024 * 1024 if failure == "oversized_audio" else 64
            return httpx.Response(
                200,
                content=(b"RIFF" + b"\x00" * 4 + b"WAVE" + b"\x00" * padding),
                headers={} if failure == "missing_request_id" else {"X-Request-ID": "req-tts"},
            )
        asr_calls += 1
        return httpx.Response(
            200,
            json={"text": "" if failure == "empty_text" else "ok"},
            headers={"X-Request-ID": "req-asr"},
        )

    with httpx.Client(
        base_url="http://127.0.0.1:8201", transport=httpx.MockTransport(handler)
    ) as client, pytest.raises(SmokeProbeError):
        PublicApiSmokeProbe(client=client, max_audio_bytes=8 * 1024 * 1024).run(_prepared())

    expected_attempts = 3 if failure == "empty_text" else 1
    assert tts_calls == expected_attempts
    assert asr_calls == (3 if failure == "empty_text" else 0)


def test_probe_rejects_non_loopback_transport() -> None:
    with httpx.Client(base_url="http://192.0.2.1:8201") as client, pytest.raises(
        ValueError, match="loopback"
    ):
        PublicApiSmokeProbe(client=client)
