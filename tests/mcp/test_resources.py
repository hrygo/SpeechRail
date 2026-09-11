"""Resource tests for the speechrail-mcp MCPServer surface.

The three ``speechrail://`` resources are read-only JSON projections of the
same SpeechRail REST snapshot the tools read.  They are driven through an
injected ``httpx.MockTransport`` client, so no daemon is required.
"""

from __future__ import annotations

import asyncio
import json
from collections.abc import Callable
from typing import Any

import httpx
import pytest
from mcp.server.mcpserver.exceptions import ResourceError, ResourceNotFoundError

from speechrail.mcp import server

_CAPABILITIES_URI = "speechrail://capabilities"
_VOICES_URI = "speechrail://voices"
_MODELS_URI = "speechrail://models"
_EXPECTED_URIS = {_CAPABILITIES_URI, _VOICES_URI, _MODELS_URI}


def _run(coro: Any) -> Any:
    return asyncio.run(coro)


def _models() -> list[dict[str, Any]]:
    return [
        {
            "id": "speechrail/qwen3-asr",
            "object": "model",
            "profile": "quality",
            "family": "qwen3_asr",
            "variant": "asr",
        },
        {
            "id": "speechrail/qwen3-tts",
            "object": "model",
            "profile": "quality",
            "family": "qwen3_tts",
            "variant": "voice_design",
        },
    ]


def _voices() -> list[dict[str, Any]]:
    return [
        {
            "id": "serena",
            "name": "serena",
            "mode": "system",
            "available": True,
            "variant": "voice_design",
        }
    ]


def _health() -> dict[str, Any]:
    return {
        "status": "ok",
        "profile": "quality",
        "asr_ready": True,
        "tts_ready": True,
        "diarization_ready": True,
    }


def _handler(
    json_response: Callable[..., httpx.Response],
) -> Callable[[httpx.Request], httpx.Response]:
    def handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if request.method == "GET" and path == "/v1/models":
            return json_response({"object": "list", "data": _models()})
        if request.method == "GET" and path == "/v1/voices":
            return json_response({"object": "list", "data": _voices()})
        if request.method == "GET" and path == "/health":
            return json_response(_health())
        raise AssertionError(f"unexpected request {request.method} {path}")

    return handler


def test_server_registers_three_read_only_resources(
    make_client: Any, json_response: Any
) -> None:
    client, _requests = make_client(_handler(json_response))
    app = server.create_server(client=client)

    resources = _run(app.list_resources())
    by_uri = {str(resource.uri): resource for resource in resources}

    assert set(by_uri) == _EXPECTED_URIS
    for uri, resource in by_uri.items():
        assert resource.name, uri
        assert resource.title, uri
        assert resource.description, uri
        assert resource.mime_type == "application/json"


def test_capabilities_resource_returns_describe_json(
    make_client: Any, json_response: Any
) -> None:
    client, requests = make_client(_handler(json_response))
    app = server.create_server(client=client)

    contents = list(_run(app.read_resource(_CAPABILITIES_URI)))
    assert len(contents) == 1
    assert contents[0].mime_type == "application/json"

    payload = json.loads(contents[0].content)
    assert payload["tier"] == "quality"
    assert payload["readiness"] == {"asr": True, "tts": True, "diarization": True}
    assert [request.url.path for request in requests] == [
        "/v1/models",
        "/v1/voices",
        "/health",
    ]


def test_voices_resource_returns_voice_list(make_client: Any, json_response: Any) -> None:
    client, requests = make_client(_handler(json_response))
    app = server.create_server(client=client)

    contents = list(_run(app.read_resource(_VOICES_URI)))
    payload = json.loads(contents[0].content)

    assert payload == {"data": _voices()}
    assert [request.url.path for request in requests] == ["/v1/voices"]


def test_models_resource_returns_model_list(make_client: Any, json_response: Any) -> None:
    client, requests = make_client(_handler(json_response))
    app = server.create_server(client=client)

    contents = list(_run(app.read_resource(_MODELS_URI)))
    payload = json.loads(contents[0].content)

    assert payload == {"data": _models()}
    assert [request.url.path for request in requests] == ["/v1/models"]


def test_read_resource_unknown_uri_is_rejected(make_client: Any, json_response: Any) -> None:
    client, _requests = make_client(_handler(json_response))
    app = server.create_server(client=client)

    with pytest.raises(ResourceNotFoundError):
        _run(app.read_resource("speechrail://does-not-exist"))


def test_voices_resource_maps_rest_errors_to_resource_error(
    make_client: Any, envelope_response: Any
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return envelope_response(
            status=503,
            code="backend_not_ready",
            message="voices backend is not ready",
            retryable=True,
        )

    client, _requests = make_client(handler)
    app = server.create_server(client=client)

    with pytest.raises(ResourceError) as excinfo:
        _run(app.read_resource(_VOICES_URI))

    message = str(excinfo.value)
    assert "backend_not_ready" in message
    assert "voices backend is not ready" in message


def test_capabilities_advertise_tools_and_resources(
    make_client: Any, json_response: Any
) -> None:
    client, _requests = make_client(_handler(json_response))
    app = server.create_server(client=client)

    capabilities = app._lowlevel_server.get_capabilities()

    assert capabilities.tools is not None
    assert capabilities.resources is not None
    # The SDK always registers prompt handlers in MCPServer, so an empty
    # ``prompts`` capability is advertised and has no supported suppression.
    assert capabilities.prompts is not None
