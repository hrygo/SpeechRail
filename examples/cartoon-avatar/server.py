"""Local proxy and static server for the cartoon avatar example.

The example deliberately keeps the browser-facing API small.  It never imports
SpeechRail's inference modules: all synthesis work is delegated to an already
running SpeechRail instance on loopback.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, Final, cast
from urllib.parse import urlsplit

import httpx
import uvicorn
from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse, Response
from pydantic import BaseModel, ConfigDict, Field, ValidationError
from starlette.staticfiles import StaticFiles

DEFAULT_BASE_URL: Final = "http://127.0.0.1:8201/v1"
DEFAULT_PORT: Final = 8202
MAX_REQUEST_BODY_BYTES: Final = 8 * 1024
MAX_VOICE_RESPONSE_BYTES: Final = 1 * 1024 * 1024
MAX_AUDIO_RESPONSE_BYTES: Final = 32 * 1024 * 1024
MAX_UPSTREAM_ERROR_BYTES: Final = 64 * 1024
TOTAL_TIMEOUT_SECONDS: float = 120.0
UPSTREAM_CONNECT_TIMEOUT_SECONDS: Final = 5.0
UPSTREAM_READ_TIMEOUT_SECONDS: Final = 120.0
_ALLOWED_LOOPBACK_HOSTS: Final = {"127.0.0.1", "localhost", "::1"}
_FORWARDED_STATUS_CODES: Final = {400, 401, 403, 409, 429, 503}
_SAFE_CODE = re.compile(r"^[a-z][a-z0-9_.-]{0,63}$")
_SAFE_REQUEST_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
_STATIC_DIR = Path(__file__).resolve().parent / "static"


_ERROR_MESSAGES: Final[dict[str, str]] = {
    "invalid_request": "请求格式无效，请检查输入后重试。",
    "request_too_large": "请求内容过大，请缩短文本后重试。",
    "unsupported_media_type": "请求必须使用 application/json。",
    "origin_forbidden": "请求来源不被允许，请从本地示例页面操作。",
    "invalid_host": "请通过本示例的本地地址访问。",
    "example_busy": "本示例正在生成上一段语音，请稍后重试。",
    "upstream_invalid_response": "SpeechRail 返回了无效的音色目录。",
    "upstream_invalid_audio": "SpeechRail 返回了无效的 WAV 音频。",
    "upstream_unreachable": "无法连接 SpeechRail，请确认服务正在运行。",
    "upstream_timeout": "SpeechRail 响应超时，请稍后重试。",
    "upstream_error": "SpeechRail 暂时无法完成请求，请稍后重试。",
    "unauthorized": "SpeechRail 鉴权失败，请检查 SPEECHRAIL_API_KEY。",
    "forbidden": "SpeechRail 拒绝了这次请求，请检查访问权限。",
    "voice_not_available": "所选音色当前不可用，请刷新音色后重试。",
    "rate_limited": "SpeechRail 当前繁忙，请稍后重试。",
    "backend_not_ready": "SpeechRail 尚未就绪，请稍后重试。",
    "backend_busy": "SpeechRail 当前繁忙，请稍后重试。",
    "conflict": "SpeechRail 当前无法接受这次请求，请稍后重试。",
    "upstream_bad_request": "SpeechRail 无法处理这次请求，请检查输入后重试。",
}


class SpeechInput(BaseModel):
    """The deliberately smaller browser-facing speech request."""

    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True, strict=True)

    input: str = Field(min_length=1, max_length=600)
    voice: str = Field(min_length=1, max_length=200)


class ExampleAPIError(Exception):
    """An error that is safe to expose through the example API envelope."""

    def __init__(self, status_code: int, code: str, request_id: str | None = None) -> None:
        super().__init__(code)
        self.status_code = status_code
        self.code = code
        self.request_id = request_id


class _UpstreamResponseTooLargeError(Exception):
    pass


def _new_request_id() -> str:
    return uuid.uuid4().hex


def _safe_request_id(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = value.strip()
    if _SAFE_REQUEST_ID.fullmatch(normalized) is None:
        return None
    return normalized


def _safe_error_code(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = value.strip().lower()
    if _SAFE_CODE.fullmatch(normalized) is None:
        return None
    return normalized


def _message_for(code: str, status_code: int | None = None) -> str:
    if code in _ERROR_MESSAGES:
        return _ERROR_MESSAGES[code]
    if status_code == 401:
        return _ERROR_MESSAGES["unauthorized"]
    if status_code == 403:
        return _ERROR_MESSAGES["forbidden"]
    if status_code == 429:
        return _ERROR_MESSAGES["rate_limited"]
    if status_code == 503:
        return _ERROR_MESSAGES["backend_not_ready"]
    return _ERROR_MESSAGES["upstream_error"]


def _error_response(
    status_code: int,
    code: str,
    request_id: str | None = None,
) -> JSONResponse:
    resolved_request_id = _safe_request_id(request_id) or _new_request_id()
    response = JSONResponse(
        status_code=status_code,
        content={
            "error": {
                "code": code,
                "message": _message_for(code, status_code),
                "request_id": resolved_request_id,
            }
        },
    )
    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Request-ID"] = resolved_request_id
    return response


def _parse_port(value: str) -> int:
    try:
        port = int(value)
    except (TypeError, ValueError) as exc:
        raise argparse.ArgumentTypeError("port must be an integer from 1 to 65535") from exc
    if not 1 <= port <= 65535:
        raise argparse.ArgumentTypeError("port must be an integer from 1 to 65535")
    return port


def _validate_port(port: int) -> int:
    if isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535:
        raise ValueError("port must be an integer from 1 to 65535")
    return port


def _validate_base_url(base_url: str, example_port: int) -> str:
    if not isinstance(base_url, str) or not base_url or base_url != base_url.strip():
        raise ValueError("SPEECHRAIL_BASE_URL must be an http loopback /v1 URL")
    if any(ord(character) < 0x20 for character in base_url):
        raise ValueError("SPEECHRAIL_BASE_URL must be an http loopback /v1 URL")
    try:
        parsed = urlsplit(base_url)
        hostname = parsed.hostname
        upstream_port = parsed.port or 80
    except ValueError as exc:
        raise ValueError("SPEECHRAIL_BASE_URL must be an http loopback /v1 URL") from exc
    if (
        parsed.scheme.lower() != "http"
        or hostname is None
        or hostname.lower() not in _ALLOWED_LOOPBACK_HOSTS
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or "?" in base_url
        or "#" in base_url
        or parsed.path not in {"/v1", "/v1/"}
    ):
        raise ValueError("SPEECHRAIL_BASE_URL must be an http loopback /v1 URL")
    if upstream_port == example_port:
        raise ValueError("SPEECHRAIL_BASE_URL port must differ from the example port")
    return base_url.rstrip("/")


def _parse_host(value: str | None) -> tuple[str, int] | None:
    if not value or any(character.isspace() for character in value):
        return None
    try:
        parsed = urlsplit(f"//{value}")
        port = parsed.port or 80
    except ValueError:
        return None
    if (
        parsed.hostname is None
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path
        or parsed.query
        or parsed.fragment
        or "?" in value
        or "#" in value
    ):
        return None
    return parsed.hostname.lower(), port


def _host_matches(value: str | None, port: int) -> bool:
    parsed = _parse_host(value)
    return parsed is not None and parsed[0] in _ALLOWED_LOOPBACK_HOSTS and parsed[1] == port


def _origin_matches(value: str | None, request_host: str | None, port: int) -> bool:
    if not value or any(character.isspace() for character in value):
        return False
    try:
        parsed = urlsplit(value)
        origin_port = parsed.port or 80
    except ValueError:
        return False
    parsed_request_host = _parse_host(request_host)
    return (
        parsed.scheme.lower() == "http"
        and parsed.hostname is not None
        and parsed.hostname.lower() in _ALLOWED_LOOPBACK_HOSTS
        and origin_port == port
        and parsed.username is None
        and parsed.password is None
        and not parsed.path
        and not parsed.query
        and not parsed.fragment
        and "?" not in value
        and "#" not in value
        and parsed_request_host == (parsed.hostname.lower(), origin_port)
    )


def _media_type(value: str | None) -> str:
    return value.split(";", 1)[0].strip().lower() if value else ""


def _is_json_content_type(value: str | None) -> bool:
    return _media_type(value) == "application/json"


def _is_wav_header(data: bytes) -> bool:
    return len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WAVE"


async def _read_limited(response: httpx.Response, limit: int) -> bytes:
    chunks: list[bytes] = []
    total = 0
    async for chunk in response.aiter_bytes():
        total += len(chunk)
        if total > limit:
            raise _UpstreamResponseTooLargeError
        chunks.append(chunk)
    return b"".join(chunks)


def _upstream_error(response: httpx.Response, body: bytes) -> ExampleAPIError:
    request_id = _safe_request_id(response.headers.get("X-Request-ID"))
    upstream_code: str | None = None
    try:
        payload = json.loads(body)
    except (TypeError, ValueError, json.JSONDecodeError):
        payload = None
    if isinstance(payload, dict):
        error = payload.get("error")
        if isinstance(error, dict):
            upstream_code = _safe_error_code(error.get("code"))
            request_id = request_id or _safe_request_id(error.get("request_id"))
    if response.status_code in _FORWARDED_STATUS_CODES:
        fallback_codes = {
            400: "upstream_bad_request",
            401: "unauthorized",
            403: "forbidden",
            409: "conflict",
            429: "rate_limited",
            503: "backend_not_ready",
        }
        return ExampleAPIError(
            response.status_code,
            upstream_code or fallback_codes[response.status_code],
            request_id,
        )
    return ExampleAPIError(502, "upstream_error", request_id)


def _exception_to_upstream_error(exc: Exception) -> ExampleAPIError:
    if isinstance(exc, httpx.TimeoutException):
        return ExampleAPIError(504, "upstream_timeout")
    if isinstance(exc, httpx.ConnectError):
        return ExampleAPIError(502, "upstream_unreachable")
    if isinstance(exc, httpx.RequestError):
        return ExampleAPIError(502, "upstream_error")
    return ExampleAPIError(502, "upstream_error")


def _client_from_request(request: Request) -> httpx.AsyncClient:
    return cast(httpx.AsyncClient, request.app.state.upstream_client)


async def _get_voices(request: Request) -> list[dict[str, Any]]:
    app = request.app
    client = _client_from_request(request)
    base_url = cast(str, app.state.upstream_base_url)
    headers = cast(dict[str, str], app.state.upstream_headers)
    try:
        async with asyncio.timeout(TOTAL_TIMEOUT_SECONDS):
            async with client.stream("GET", f"{base_url}/voices", headers=headers) as upstream:
                if not 200 <= upstream.status_code < 300:
                    body = await _read_limited(upstream, MAX_UPSTREAM_ERROR_BYTES)
                    raise _upstream_error(upstream, body)
                body = await _read_limited(upstream, MAX_VOICE_RESPONSE_BYTES)
    except ExampleAPIError:
        raise
    except _UpstreamResponseTooLargeError as exc:
        raise ExampleAPIError(502, "upstream_invalid_response") from exc
    except TimeoutError as exc:
        raise ExampleAPIError(504, "upstream_timeout") from exc
    except Exception as exc:
        raise _exception_to_upstream_error(exc) from exc

    try:
        payload = json.loads(body)
    except (TypeError, ValueError, json.JSONDecodeError) as exc:
        raise ExampleAPIError(502, "upstream_invalid_response") from exc
    if not isinstance(payload, dict) or not isinstance(payload.get("data"), list):
        raise ExampleAPIError(502, "upstream_invalid_response")

    voices: list[dict[str, Any]] = []
    for item in payload["data"]:
        if not isinstance(item, dict):
            raise ExampleAPIError(502, "upstream_invalid_response")
        voice_id = item.get("id")
        name = item.get("name")
        available = item.get("available")
        is_default = item.get("is_default")
        if (
            not isinstance(voice_id, str)
            or not 1 <= len(voice_id) <= 200
            or not isinstance(name, str)
            or not 1 <= len(name) <= 200
            or type(available) is not bool
            or type(is_default) is not bool
        ):
            raise ExampleAPIError(502, "upstream_invalid_response")
        voices.append(
            {
                "id": voice_id,
                "name": name,
                "available": available,
                "is_default": is_default,
            }
        )
    return voices


async def _get_speech(request: Request, speech_input: SpeechInput) -> tuple[bytes, str | None]:
    app = request.app
    client = _client_from_request(request)
    base_url = cast(str, app.state.upstream_base_url)
    headers = cast(dict[str, str], app.state.upstream_headers)
    payload = {
        "model": "speechrail/qwen3-tts",
        "input": speech_input.input,
        "voice": speech_input.voice,
        "response_format": "wav",
    }
    try:
        async with asyncio.timeout(TOTAL_TIMEOUT_SECONDS):
            async with client.stream(
                "POST",
                f"{base_url}/audio/speech",
                headers=headers,
                json=payload,
            ) as upstream:
                request_id = _safe_request_id(upstream.headers.get("X-Request-ID"))
                if not 200 <= upstream.status_code < 300:
                    try:
                        body = await _read_limited(upstream, MAX_UPSTREAM_ERROR_BYTES)
                    except _UpstreamResponseTooLargeError as exc:
                        raise ExampleAPIError(502, "upstream_error", request_id) from exc
                    raise _upstream_error(upstream, body)
                if _media_type(upstream.headers.get("Content-Type")) not in {
                    "audio/wav",
                    "audio/x-wav",
                    "audio/wave",
                }:
                    raise ExampleAPIError(502, "upstream_invalid_audio", request_id)
                body = await _read_limited(upstream, MAX_AUDIO_RESPONSE_BYTES)
                if not body or not _is_wav_header(body):
                    raise ExampleAPIError(502, "upstream_invalid_audio", request_id)
                return body, request_id
    except ExampleAPIError:
        raise
    except _UpstreamResponseTooLargeError as exc:
        raise ExampleAPIError(502, "upstream_invalid_audio") from exc
    except TimeoutError as exc:
        raise ExampleAPIError(504, "upstream_timeout") from exc
    except Exception as exc:
        raise _exception_to_upstream_error(exc) from exc


class _BodyLimitMiddleware:
    def __init__(self, app: Any, max_bytes: int = MAX_REQUEST_BODY_BYTES) -> None:
        self.app = app
        self.max_bytes = max_bytes

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        if (
            scope.get("type") != "http"
            or scope.get("method") != "POST"
            or scope.get("path") != "/api/speech"
        ):
            await self.app(scope, receive, send)
            return

        content_length = next(
            (value for key, value in scope.get("headers", []) if key.lower() == b"content-length"),
            None,
        )
        if content_length is not None:
            try:
                if int(content_length) > self.max_bytes:
                    await _error_response(413, "request_too_large")(scope, receive, send)
                    return
            except ValueError:
                pass

        chunks: list[bytes] = []
        total = 0
        while True:
            message = cast(dict[str, Any], await receive())
            if message.get("type") == "http.disconnect":
                break
            if message.get("type") != "http.request":
                continue
            chunk = cast(bytes, message.get("body", b""))
            total += len(chunk)
            if total > self.max_bytes:
                await _error_response(413, "request_too_large")(scope, receive, send)
                return
            chunks.append(chunk)
            if not message.get("more_body", False):
                break

        body = b"".join(chunks)
        delivered = False

        async def replay_receive() -> dict[str, Any]:
            nonlocal delivered
            if delivered:
                return {"type": "http.disconnect"}
            delivered = True
            return {"type": "http.request", "body": body, "more_body": False}

        await self.app(scope, replay_receive, send)


def create_app(
    *,
    base_url: str = DEFAULT_BASE_URL,
    api_key: str = "",
    port: int = DEFAULT_PORT,
    transport: httpx.AsyncBaseTransport | None = None,
) -> FastAPI:
    """Create the isolated example app without starting a server."""

    resolved_port = _validate_port(port)
    resolved_base_url = _validate_base_url(base_url, resolved_port)
    resolved_headers: dict[str, str] = {}
    if api_key:
        resolved_headers["Authorization"] = f"Bearer {api_key}"

    timeout = httpx.Timeout(
        connect=UPSTREAM_CONNECT_TIMEOUT_SECONDS,
        read=UPSTREAM_READ_TIMEOUT_SECONDS,
        write=UPSTREAM_READ_TIMEOUT_SECONDS,
        pool=UPSTREAM_CONNECT_TIMEOUT_SECONDS,
    )

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        client_kwargs: dict[str, Any] = {
            "timeout": timeout,
            "trust_env": False,
            "follow_redirects": False,
        }
        if transport is not None:
            client_kwargs["transport"] = transport
        client = httpx.AsyncClient(**client_kwargs)
        app.state.upstream_client = client
        try:
            yield
        finally:
            await client.aclose()

    app = FastAPI(title="SpeechRail Cartoon Avatar Example", lifespan=lifespan)
    app.state.upstream_base_url = resolved_base_url
    app.state.upstream_headers = resolved_headers
    app.state.speech_lock = asyncio.Lock()

    @app.exception_handler(ExampleAPIError)
    async def handle_example_error(_: Request, exc: ExampleAPIError) -> JSONResponse:
        return _error_response(exc.status_code, exc.code, exc.request_id)

    @app.exception_handler(RequestValidationError)
    async def handle_validation_error(_: Request, __: RequestValidationError) -> JSONResponse:
        return _error_response(400, "invalid_request")

    @app.middleware("http")
    async def guard_requests(request: Request, call_next: Any) -> Response:
        if not _host_matches(request.headers.get("host"), resolved_port):
            response = _error_response(400, "invalid_host")
        else:
            response = await call_next(request)
        if request.url.path.startswith("/api/"):
            response.headers["Cache-Control"] = "no-store"
        return response

    @app.get("/api/voices")
    async def voices(request: Request) -> JSONResponse:
        return JSONResponse(content={"data": await _get_voices(request)})

    @app.post("/api/speech")
    async def speech(request: Request) -> Response:
        if not _is_json_content_type(request.headers.get("content-type")):
            raise ExampleAPIError(415, "unsupported_media_type")
        if not _origin_matches(
            request.headers.get("origin"), request.headers.get("host"), resolved_port
        ):
            raise ExampleAPIError(403, "origin_forbidden")
        try:
            payload = json.loads(await request.body())
            speech_input = SpeechInput.model_validate(payload)
        except (json.JSONDecodeError, TypeError, ValueError, ValidationError) as exc:
            raise ExampleAPIError(400, "invalid_request") from exc

        lock = cast(asyncio.Lock, request.app.state.speech_lock)
        if lock.locked():
            raise ExampleAPIError(409, "example_busy")
        await lock.acquire()
        try:
            audio, request_id = await _get_speech(request, speech_input)
        finally:
            lock.release()
        response = Response(content=audio, media_type="audio/wav")
        if request_id is not None:
            response.headers["X-Request-ID"] = request_id
        response.headers["Cache-Control"] = "no-store"
        return response

    @app.get("/", include_in_schema=False)
    async def index() -> FileResponse:
        index_path = _STATIC_DIR / "index.html"
        if not index_path.is_file():
            raise HTTPException(status_code=404, detail="Not Found")
        return FileResponse(index_path, media_type="text/html")

    app.mount("/static", StaticFiles(directory=_STATIC_DIR, check_dir=False), name="static")
    app.add_middleware(_BodyLimitMiddleware)
    return app


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Run the local SpeechRail cartoon avatar example")
    parser.add_argument("--port", type=_parse_port, default=DEFAULT_PORT)
    args = parser.parse_args(argv)
    base_url = os.environ.get("SPEECHRAIL_BASE_URL", DEFAULT_BASE_URL)
    api_key = os.environ.get("SPEECHRAIL_API_KEY", "")
    app = create_app(base_url=base_url, api_key=api_key, port=args.port)
    uvicorn.run(app, host="127.0.0.1", port=args.port, workers=1, access_log=False)


if __name__ == "__main__":
    main()
