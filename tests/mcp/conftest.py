"""Shared fixtures for the speechrail-mcp proxy tests.

The proxy tools are plain async functions taking an explicit
:class:`SpeechRailClient`, so the tests drive them with ``asyncio.run``
against an ``httpx.MockTransport`` that records every outbound request.
"""

from __future__ import annotations

import asyncio
from collections.abc import Callable, Coroutine
from typing import Any, TypeVar

import httpx
import pytest

from speechrail.mcp.client import SpeechRailClient

T = TypeVar("T")
Handler = Callable[[httpx.Request], httpx.Response]

_TEST_BASE_URL = "http://rail.test/v1"


@pytest.fixture
def run_async() -> Callable[[Coroutine[Any, Any, T]], T]:
    def run(coro: Coroutine[Any, Any, T]) -> T:
        return asyncio.run(coro)

    return run


@pytest.fixture
def json_response() -> Callable[..., httpx.Response]:
    def build(payload: dict[str, Any], *, status: int = 200) -> httpx.Response:
        return httpx.Response(status_code=status, json=payload)

    return build


@pytest.fixture
def envelope_response() -> Callable[..., httpx.Response]:
    """Build a SpeechRail unified error-envelope response."""

    def build(
        *,
        status: int,
        code: str,
        message: str,
        retryable: bool,
        error_type: str | None = None,
        request_id: str = "req_test",
        param: str | None = None,
    ) -> httpx.Response:
        error: dict[str, Any] = {
            "message": message,
            "type": error_type or ("server_error" if retryable else "invalid_request_error"),
            "code": code,
            "request_id": request_id,
            "retryable": retryable,
        }
        if param is not None:
            error["param"] = param
        return httpx.Response(status_code=status, json={"error": error})

    return build


@pytest.fixture
def make_client() -> Callable[..., tuple[SpeechRailClient, list[httpx.Request]]]:
    """Build a client over a recording MockTransport for a handler."""

    def build(
        handler: Handler, *, api_key: str | None = None
    ) -> tuple[SpeechRailClient, list[httpx.Request]]:
        requests: list[httpx.Request] = []

        def record(request: httpx.Request) -> httpx.Response:
            requests.append(request)
            return handler(request)

        client = SpeechRailClient(
            base_url=_TEST_BASE_URL,
            api_key=api_key,
            transport=httpx.MockTransport(record),
        )
        return client, requests

    return build
