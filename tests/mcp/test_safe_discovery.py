"""Discovery must not turn private source metadata into agent context."""
from __future__ import annotations

import asyncio

import httpx
import pytest

from speechrail.mcp.client import SpeechRailClient, SpeechRailError
from speechrail.mcp.tools import describe


def test_mcp_voice_projection_does_not_leak_source_or_nested_details() -> None:
    async def run():
        client = SpeechRailClient(transport=httpx.MockTransport(lambda request: httpx.Response(
            200, json={"data": [{
                "id": "v", "name": "Voice", "mode": "clone", "available": True,
                "ref_text": "PRIVATE", "audio_path": "/PRIVATE", "instruction": "PRIVATE",
                "description": "PRIVATE", "creation": {"reference_text": "PRIVATE"},
                "quality": {"debug": "PRIVATE"},
                "capabilities": {"supports_clone": True, "private": "PRIVATE"},
            }]},
        )))
        try:
            result = await client.fetch_voices()
            assert result[0]["id"] == "v"
            assert result[0]["capabilities"] == {"supports_clone": True}
            assert "PRIVATE" not in str(result)
        finally:
            await client.aclose()
    asyncio.run(run())


@pytest.mark.parametrize("status", [401, 503])
def test_capability_auth_and_storage_failures_propagate(status: int) -> None:
    async def run():
        client = SpeechRailClient(transport=httpx.MockTransport(lambda req: httpx.Response(
            status, json={"error": {"code": "test_error", "message": "safe"}},
        )))
        try:
            with pytest.raises(SpeechRailError):
                await client.fetch_capabilities()
        finally:
            await client.aclose()
    asyncio.run(run())


@pytest.mark.parametrize("status", [404, 405])
def test_capability_route_is_required(status: int) -> None:
    async def run():
        client = SpeechRailClient(
            transport=httpx.MockTransport(
                lambda req: httpx.Response(status, json={"detail": "Not Found"})
            )
        )
        try:
            with pytest.raises(SpeechRailError) as excinfo:
                await client.fetch_capabilities()
            assert excinfo.value.status == status
        finally:
            await client.aclose()

    asyncio.run(run())


def test_unknown_capability_schema_is_rejected() -> None:
    async def run():
        client = SpeechRailClient(
            transport=httpx.MockTransport(
                lambda req: httpx.Response(
                    200,
                    json={"schema_version": "effective_capabilities_v2"},
                )
            )
        )
        try:
            with pytest.raises(SpeechRailError) as excinfo:
                await client.fetch_capabilities()
            assert excinfo.value.code == "invalid_capability_schema"
            assert excinfo.value.retryable is False
        finally:
            await client.aclose()

    asyncio.run(run())


def test_describe_uses_atomic_effective_snapshot_without_legacy_fields() -> None:
    snapshot = {
        "schema_version": "effective_capabilities_v1",
        "snapshot_id": "e",
        "voices": [
            {
                "id": "effective_voice",
                "name": "Effective voice",
                "mode": "clone",
                "available": True,
                "voice_revision": "vr_" + "a" * 32,
            }
        ],
    }
    def handler(request):
        if request.url.path == "/v1/speechrail/capabilities":
            return httpx.Response(200, json=snapshot)
        if request.url.path == "/health":
            return httpx.Response(200, json={})
        return httpx.Response(200, json={"data": []})
    async def run():
        client = SpeechRailClient(transport=httpx.MockTransport(handler))
        try:
            result = await describe(client)
            assert result["effective_capabilities"] == snapshot
            assert result["voices"][0]["id"] == "effective_voice"
            assert "legacy_voices" not in result
            assert "voice_discovery_source" not in result
            assert "legacy_discovery_consistency" not in result
        finally:
            await client.aclose()
    asyncio.run(run())
