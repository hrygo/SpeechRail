"""HTTP/WebSocket authentication primitives shared by route factories."""

from __future__ import annotations

from uuid import uuid4

from fastapi import Request, WebSocket
from fastapi.responses import JSONResponse

from speechrail.config import Settings


def http_auth_error(request: Request, settings: Settings) -> JSONResponse | None:
    """Bearer-key gate for protected HTTP paths; None means authorized."""
    if (
        settings.api_key is not None
        and request.headers.get("Authorization", "") != f"Bearer {settings.api_key}"
    ):
        return JSONResponse(
            status_code=401,
            content={
                "error": {
                    "message": "Invalid or missing API key",
                    "type": "authentication_error",
                    "code": "invalid_api_key",
                    "request_id": getattr(
                        request.state, "request_id", f"req_{uuid4().hex}"
                    ),
                    "retryable": False,
                }
            },
            headers={"WWW-Authenticate": "Bearer"},
        )
    return None


def websocket_is_authorized(websocket: WebSocket, settings: Settings) -> bool:
    """Bearer-key gate for protected WebSocket paths."""
    if settings.api_key is None:
        return True
    return websocket.headers.get("Authorization", "") == f"Bearer {settings.api_key}"
