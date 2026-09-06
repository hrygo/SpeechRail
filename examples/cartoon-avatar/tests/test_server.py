from __future__ import annotations

import asyncio
import importlib.util
import io
import json
import wave
from pathlib import Path
from typing import Any

import httpx
import pytest
from fastapi.testclient import TestClient

MODULE_PATH = Path(__file__).parents[1] / "server.py"
MODULE_SPEC = importlib.util.spec_from_file_location("cartoon_avatar_server", MODULE_PATH)
assert MODULE_SPEC is not None and MODULE_SPEC.loader is not None
SERVER = importlib.util.module_from_spec(MODULE_SPEC)
MODULE_SPEC.loader.exec_module(SERVER)


def make_wav() -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(24_000)
        wav.writeframes(b"\x00\x00" * 240)
    return output.getvalue()


@pytest.fixture
def wav_bytes() -> bytes:
    return make_wav()


@pytest.fixture
def make_app() -> Any:
    return SERVER.create_app


def api_headers() -> dict[str, str]:
    return {
        "Host": "127.0.0.1:8202",
        "Origin": "http://127.0.0.1:8202",
    }


def call_app(app: Any, method: str, path: str, **kwargs: Any) -> httpx.Response:
    with TestClient(app, base_url="http://127.0.0.1:8202") as client:
        request_headers = kwargs.pop("headers", api_headers())
        return client.request(method, path, headers=request_headers, **kwargs)


def test_speech_uses_fixed_public_contract(make_app: Any, wav_bytes: bytes) -> None:
    def upstream(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/v1/audio/speech"
        assert request.headers["authorization"] == "Bearer test-only-key"
        assert json.loads(request.content) == {
            "model": "speechrail/qwen3-tts",
            "input": "你好",
            "voice": "demo",
            "response_format": "wav",
        }
        return httpx.Response(200, content=wav_bytes, headers={"Content-Type": "audio/wav"})

    app = make_app(transport=httpx.MockTransport(upstream), api_key="test-only-key")
    response = call_app(app, "POST", "/api/speech", json={"input": "你好", "voice": "demo"})
    assert response.status_code == 200
    assert response.content == wav_bytes
    assert response.headers["content-type"].startswith("audio/wav")
    assert response.headers["cache-control"] == "no-store"


def test_voices_expose_only_safe_fields(make_app: Any) -> None:
    def upstream(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/v1/voices"
        return httpx.Response(
            200,
            json={
                "data": [
                    {
                        "id": "demo",
                        "name": "演示",
                        "available": True,
                        "is_default": True,
                        "description": "do not forward",
                        "instruction": "do not forward",
                    }
                ]
            },
        )

    app = make_app(transport=httpx.MockTransport(upstream))
    response = call_app(app, "GET", "/api/voices")
    assert response.status_code == 200
    assert response.json() == {
        "data": [
            {"id": "demo", "name": "演示", "available": True, "is_default": True}
        ]
    }
    assert response.headers["cache-control"] == "no-store"


def test_static_index_is_served_without_exposing_repository(make_app: Any) -> None:
    app = make_app(transport=httpx.MockTransport(lambda _: httpx.Response(500)))
    with TestClient(app, base_url="http://127.0.0.1:8202") as client:
        index = client.get("/", headers={"Host": "127.0.0.1:8202"})
        module = client.get("/static/app.mjs", headers={"Host": "127.0.0.1:8202"})
        private = client.get("/static/../server.py", headers={"Host": "127.0.0.1:8202"})
    assert index.status_code == 200
    assert index.headers["content-type"].startswith("text/html")
    assert module.status_code == 200
    assert module.headers["content-type"].startswith("text/javascript")
    assert private.status_code == 404


@pytest.mark.parametrize(
    ("payload", "status"),
    [
        ({"input": "   ", "voice": "demo"}, 400),
        ({"input": "a" * 601, "voice": "demo"}, 400),
        ({"input": "你好", "voice": "   "}, 400),
        ({"input": "你好", "voice": "demo", "url": "http://evil"}, 400),
    ],
)
def test_speech_rejects_invalid_payloads(
    make_app: Any, payload: dict[str, str], status: int
) -> None:
    app = make_app(transport=httpx.MockTransport(lambda _: httpx.Response(500)))
    response = call_app(app, "POST", "/api/speech", json=payload)
    assert response.status_code == status
    assert response.json()["error"]["code"] == "invalid_request"
    assert "url" not in response.text
    assert "a" * 50 not in response.text


def test_speech_rejects_non_json(make_app: Any) -> None:
    app = make_app(transport=httpx.MockTransport(lambda _: httpx.Response(500)))
    response = call_app(
        app,
        "POST",
        "/api/speech",
        content=b"input=hello&voice=demo",
        headers={**api_headers(), "Content-Type": "application/x-www-form-urlencoded"},
    )
    assert response.status_code == 415
    assert response.json()["error"]["code"] == "unsupported_media_type"


def test_speech_rejects_body_over_eight_kib(make_app: Any) -> None:
    app = make_app(transport=httpx.MockTransport(lambda _: httpx.Response(500)))
    response = call_app(
        app,
        "POST",
        "/api/speech",
        content=b"{" + b'"input":"' + b"a" * 8_200 + b'","voice":"demo"}',
        headers={**api_headers(), "Content-Type": "application/json"},
    )
    assert response.status_code == 413
    assert response.json()["error"]["code"] == "request_too_large"
    assert "a" * 100 not in response.text


def test_speech_body_limit_counts_actual_chunks_without_content_length(make_app: Any) -> None:
    async def scenario() -> None:
        app = make_app(transport=httpx.MockTransport(lambda _: httpx.Response(500)))
        sent: list[dict[str, Any]] = []
        messages = [
            {"type": "http.request", "body": b"a" * 4_000, "more_body": True},
            {"type": "http.request", "body": b"b" * 4_300, "more_body": False},
        ]

        async def receive() -> dict[str, Any]:
            return messages.pop(0)

        async def send(message: dict[str, Any]) -> None:
            sent.append(message)

        scope: dict[str, Any] = {
            "type": "http",
            "asgi": {"version": "3.0", "spec_version": "2.0"},
            "http_version": "1.1",
            "method": "POST",
            "scheme": "http",
            "path": "/api/speech",
            "raw_path": b"/api/speech",
            "query_string": b"",
            "headers": [
                (b"host", b"127.0.0.1:8202"),
                (b"origin", b"http://127.0.0.1:8202"),
                (b"content-type", b"application/json"),
            ],
            "client": ("127.0.0.1", 12345),
            "server": ("127.0.0.1", 8202),
        }
        async with app.router.lifespan_context(app):
            await app(scope, receive, send)
        assert sent[0]["status"] == 413
        response_body = sent[1]["body"]
        assert json.loads(response_body)["error"]["code"] == "request_too_large"

    asyncio.run(scenario())


@pytest.mark.parametrize(
    "headers",
    [
        {"Host": "127.0.0.1:8202"},
        {"Host": "127.0.0.1:8202", "Origin": "http://127.0.0.1:8203"},
        {"Host": "127.0.0.1:8203", "Origin": "http://127.0.0.1:8202"},
    ],
)
def test_speech_requires_same_origin_and_host(make_app: Any, headers: dict[str, str]) -> None:
    app = make_app(transport=httpx.MockTransport(lambda _: httpx.Response(500)))
    response = call_app(
        app,
        "POST",
        "/api/speech",
        json={"input": "你好", "voice": "demo"},
        headers=headers,
    )
    expected_status = 400 if headers.get("Host") != "127.0.0.1:8202" else 403
    assert response.status_code == expected_status


def test_no_api_key_does_not_send_authorization(make_app: Any, wav_bytes: bytes) -> None:
    def upstream(request: httpx.Request) -> httpx.Response:
        assert "authorization" not in request.headers
        return httpx.Response(200, content=wav_bytes, headers={"Content-Type": "audio/wav"})

    app = make_app(transport=httpx.MockTransport(upstream))
    response = call_app(app, "POST", "/api/speech", json={"input": "你好", "voice": "demo"})
    assert response.status_code == 200


@pytest.mark.parametrize(
    ("status", "code", "request_id"),
    [
        (401, "unauthorized", "req-401"),
        (429, "rate_limited", "req-429"),
        (503, "backend_not_ready", "req-503"),
    ],
)
def test_upstream_errors_keep_status_code_and_request_id(
    make_app: Any, status: int, code: str, request_id: str
) -> None:
    def upstream(_: httpx.Request) -> httpx.Response:
        return httpx.Response(
            status,
            json={
                "error": {
                    "code": code,
                    "message": "sensitive upstream detail",
                    "request_id": request_id,
                }
            },
        )

    app = make_app(transport=httpx.MockTransport(upstream))
    response = call_app(app, "POST", "/api/speech", json={"input": "你好", "voice": "demo"})
    assert response.status_code == status
    assert response.json()["error"]["code"] == code
    assert response.json()["error"]["request_id"] == request_id
    assert response.headers["x-request-id"] == request_id
    assert "sensitive upstream detail" not in response.text


def test_upstream_error_without_json_gets_safe_envelope(make_app: Any) -> None:
    app = make_app(
        transport=httpx.MockTransport(
            lambda _: httpx.Response(
                500,
                text="secret response body",
                headers={"X-Request-ID": "upstream-500"},
            )
        )
    )
    response = call_app(app, "POST", "/api/speech", json={"input": "你好", "voice": "demo"})
    assert response.status_code == 502
    assert response.json()["error"]["code"] == "upstream_error"
    assert response.json()["error"]["request_id"] == "upstream-500"
    assert "secret response body" not in response.text


@pytest.mark.parametrize(
    ("exception", "code"),
    [
        (httpx.ConnectError("connection refused"), "upstream_unreachable"),
        (httpx.ReadTimeout("read timed out"), "upstream_timeout"),
    ],
)
def test_upstream_transport_failures_are_safe(
    make_app: Any, exception: Exception, code: str
) -> None:
    def upstream(request: httpx.Request) -> httpx.Response:
        raise exception

    app = make_app(transport=httpx.MockTransport(upstream))
    response = call_app(app, "POST", "/api/speech", json={"input": "你好", "voice": "demo"})
    assert response.status_code == (504 if code == "upstream_timeout" else 502)
    assert response.json()["error"]["code"] == code


def test_redirect_is_not_followed(make_app: Any) -> None:
    calls = 0

    def upstream(_: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(307, headers={"Location": "http://127.0.0.1:8201/v1/other"})

    app = make_app(transport=httpx.MockTransport(upstream))
    response = call_app(app, "POST", "/api/speech", json={"input": "你好", "voice": "demo"})
    assert response.status_code == 502
    assert response.json()["error"]["code"] == "upstream_error"
    assert calls == 1


def test_busy_lock_rejects_second_request_and_releases_after_success(
    make_app: Any, wav_bytes: bytes
) -> None:
    async def scenario() -> None:
        started = asyncio.Event()
        release = asyncio.Event()

        async def upstream(_: httpx.Request) -> httpx.Response:
            started.set()
            await release.wait()
            return httpx.Response(200, content=wav_bytes, headers={"Content-Type": "audio/wav"})

        app = make_app(transport=httpx.MockTransport(upstream))
        async with app.router.lifespan_context(app):
            transport = httpx.ASGITransport(app=app)
            async with httpx.AsyncClient(
                transport=transport, base_url="http://127.0.0.1:8202"
            ) as client:
                first_task = asyncio.create_task(
                    client.post(
                        "/api/speech",
                        json={"input": "你好", "voice": "demo"},
                        headers=api_headers(),
                    )
                )
                await asyncio.wait_for(started.wait(), timeout=1)
                second = await client.post(
                    "/api/speech",
                    json={"input": "你好", "voice": "demo"},
                    headers=api_headers(),
                )
                assert second.status_code == 409
                assert second.json()["error"]["code"] == "example_busy"
                release.set()
                first = await first_task
                assert first.status_code == 200

    asyncio.run(scenario())


def test_total_timeout_releases_busy_lock(
    make_app: Any, wav_bytes: bytes, monkeypatch: Any
) -> None:
    monkeypatch.setattr(SERVER, "TOTAL_TIMEOUT_SECONDS", 0.01)

    async def scenario() -> None:
        calls = 0

        async def upstream(_: httpx.Request) -> httpx.Response:
            nonlocal calls
            calls += 1
            if calls == 1:
                await asyncio.sleep(0.05)
            return httpx.Response(200, content=wav_bytes, headers={"Content-Type": "audio/wav"})

        app = make_app(transport=httpx.MockTransport(upstream))
        async with app.router.lifespan_context(app):
            transport = httpx.ASGITransport(app=app)
            async with httpx.AsyncClient(
                transport=transport, base_url="http://127.0.0.1:8202"
            ) as client:
                first = await client.post(
                    "/api/speech",
                    json={"input": "你好", "voice": "demo"},
                    headers=api_headers(),
                )
                second = await client.post(
                    "/api/speech",
                    json={"input": "你好", "voice": "demo"},
                    headers=api_headers(),
                )
                assert first.status_code == 504
                assert first.json()["error"]["code"] == "upstream_timeout"
                assert second.status_code == 200

    asyncio.run(scenario())


def test_audio_limit_is_checked_incrementally(make_app: Any, monkeypatch: Any) -> None:
    monkeypatch.setattr(SERVER, "MAX_AUDIO_RESPONSE_BYTES", 12)
    app = make_app(
        transport=httpx.MockTransport(
            lambda _: httpx.Response(
                200,
                content=b"RIFFxxxxWAVE-more",
                headers={"Content-Type": "audio/wav"},
            )
        )
    )
    response = call_app(app, "POST", "/api/speech", json={"input": "你好", "voice": "demo"})
    assert response.status_code == 502
    assert response.json()["error"]["code"] == "upstream_invalid_audio"


@pytest.mark.parametrize(
    "response",
    [
        httpx.Response(200, content=b"not wav", headers={"Content-Type": "audio/wav"}),
        httpx.Response(
            200,
            content=b"RIFFxxxxWAVE",
            headers={"Content-Type": "application/octet-stream"},
        ),
        httpx.Response(200, content=b"", headers={"Content-Type": "audio/wav"}),
    ],
)
def test_invalid_upstream_audio_is_rejected(make_app: Any, response: httpx.Response) -> None:
    app = make_app(transport=httpx.MockTransport(lambda _: response))
    result = call_app(app, "POST", "/api/speech", json={"input": "你好", "voice": "demo"})
    assert result.status_code == 502
    assert result.json()["error"]["code"] == "upstream_invalid_audio"


def test_base_url_must_be_loopback_v1_and_not_share_port(make_app: Any) -> None:
    with pytest.raises(ValueError):
        make_app(base_url="https://127.0.0.1:8201/v1")
    with pytest.raises(ValueError):
        make_app(base_url="http://example.test:8201/v1")
    with pytest.raises(ValueError):
        make_app(base_url="http://127.0.0.1:8201/v2")
    with pytest.raises(ValueError):
        make_app(base_url="http://127.0.0.1:8202/v1")


def test_speech_can_be_called_again_after_upstream_failure(make_app: Any, wav_bytes: bytes) -> None:
    calls = 0

    def upstream(_: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        if calls == 1:
            return httpx.Response(503, json={"error": {"code": "backend_not_ready"}})
        return httpx.Response(200, content=wav_bytes, headers={"Content-Type": "audio/wav"})

    app = make_app(transport=httpx.MockTransport(upstream))
    first = call_app(app, "POST", "/api/speech", json={"input": "你好", "voice": "demo"})
    second = call_app(app, "POST", "/api/speech", json={"input": "你好", "voice": "demo"})
    assert first.status_code == 503
    assert second.status_code == 200


def test_lifespan_closes_upstream_client(make_app: Any) -> None:
    app = make_app(transport=httpx.MockTransport(lambda _: httpx.Response(200, json={"data": []})))
    with TestClient(app, base_url="http://127.0.0.1:8202") as client:
        client.get("/api/voices", headers=api_headers())
        upstream_client = app.state.upstream_client
        assert not upstream_client.is_closed
    assert upstream_client.is_closed


def test_cli_rejects_invalid_port() -> None:
    with pytest.raises(SystemExit):
        SERVER.main(["--port", "0"])
