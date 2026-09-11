"""Lifespan tests for the ``speechrail-mcp`` proxy server.

``create_server`` builds a :class:`SpeechRailClient` that owns an
``httpx.AsyncClient``.  The proxy must release that connection pool when the
MCP server shuts down, so a spy client records ``aclose`` calls across the
server lifespan.
"""

from __future__ import annotations

import asyncio

import httpx

from speechrail.mcp import server
from speechrail.mcp.client import SpeechRailClient


class _SpyClient(SpeechRailClient):
    def __init__(self) -> None:
        super().__init__(
            base_url="http://rail.test/v1",
            transport=httpx.MockTransport(lambda r: httpx.Response(500)),
        )
        self.closed = 0

    async def aclose(self) -> None:
        self.closed += 1


def test_lifespan_closes_the_rest_client_on_shutdown() -> None:
    spy = _SpyClient()
    app = server.create_server(client=spy)

    async def run() -> None:
        async with app._lowlevel_server.lifespan(app._lowlevel_server):
            assert spy.closed == 0
        assert spy.closed == 1

    asyncio.run(run())
