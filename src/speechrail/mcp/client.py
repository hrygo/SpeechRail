"""Stateless HTTP client for the SpeechRail REST API (proxy side).

This module intentionally knows nothing about MCP or the FastAPI
application: it mirrors the OpenAI-compatible REST contract any local
client speaks.  Non-2xx responses are parsed from the unified SpeechRail
error envelope ``{"error": {message, type, code, request_id, retryable}}``
(see ``speechrail.http.errors``) and raised as a typed ``SpeechRailError`` so
the tool layer can map them to MCP tool failures with stable retry hints.
"""

from __future__ import annotations

from typing import Any, cast

import httpx

DEFAULT_BASE_URL = "http://127.0.0.1:8201/v1"
DEFAULT_TIMEOUT_SECONDS = 120.0

# Container mime hints accepted by the /v1/audio/transcriptions upload gate
# (``_has_supported_audio_hint`` in ``speechrail.http.routes.audio``).
_AUDIO_CONTENT_TYPES: dict[str, str] = {
    ".aac": "audio/aac",
    ".flac": "audio/flac",
    ".m4a": "audio/mp4",
    ".mp3": "audio/mpeg",
    ".mp4": "video/mp4",
    ".mpeg": "audio/mpeg",
    ".mpga": "audio/mpeg",
    ".ogg": "audio/ogg",
    ".opus": "audio/ogg",
    ".wav": "audio/wav",
    ".webm": "audio/webm",
}
_DEFAULT_AUDIO_CONTENT_TYPE = "application/octet-stream"

_RETRYABLE_HINTS: dict[str, str] = {
    "backend_busy": "SpeechRail is busy; retry with backoff starting at 1s and do not loop",
    "queue_full": "SpeechRail queue is full; retry with backoff starting at 1s and do not loop",
    "voice_not_available": "call describe() and choose a voice with available=true",
    "voice_not_found": "call describe() and choose a voice from the current profile",
    "model_not_found": "call describe() to inspect the models of the active profile",
    "audio_too_long": "audio is too long for a synchronous request; use create_job",
    "audio_too_large": "audio exceeds the upload limit; provide a smaller audio_ref",
    "diarization_not_available": (
        "diarization is not installed/ready; install it and check describe()"
    ),
    "job_not_found": "check the job_id; jobs are owner-scoped and may have expired",
    "backend_not_ready": "SpeechRail backend is not ready; call describe() to inspect readiness",
}


def hint_for_code(code: str) -> str | None:
    """Return a stable agent-facing hint for a SpeechRail error code."""
    return _RETRYABLE_HINTS.get(code)


def audio_content_type(filename: str) -> str:
    """Map a filename suffix to a container mime hint accepted by SpeechRail."""
    if "." in filename:
        suffix = filename.rsplit(".", 1)[-1].lower()
        if suffix:
            return _AUDIO_CONTENT_TYPES.get(f".{suffix}", _DEFAULT_AUDIO_CONTENT_TYPE)
    return _DEFAULT_AUDIO_CONTENT_TYPE


class SpeechRailError(RuntimeError):
    """A SpeechRail REST failure parsed from the unified error envelope."""

    def __init__(
        self,
        *,
        status: int,
        code: str,
        message: str,
        retryable: bool,
        error_type: str | None = None,
        request_id: str | None = None,
        param: str | None = None,
        hint: str | None = None,
    ) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.retryable = retryable
        self.error_type = error_type
        self.request_id = request_id
        self.param = param
        self.hint = hint

    def to_message(self) -> str:
        """Render a compact, hint-carrying message for an MCP tool error."""
        retry = "retryable" if self.retryable else "not retryable"
        parts = f"SpeechRail error {self.code} ({retry}): {self.message}"
        if self.request_id:
            parts = f"{parts} [request_id={self.request_id}]"
        if self.hint:
            parts = f"{parts}\nHint: {self.hint}"
        return parts


def parse_error_response(response: httpx.Response) -> SpeechRailError:
    """Parse a non-2xx response into a :class:`SpeechRailError`."""
    status = response.status_code
    code = f"http_{status}"
    message = (
        response.text.strip()[:300]
        or f"SpeechRail request failed with status {status}"
    )
    error_type: str | None = None
    request_id: str | None = None
    retryable = False
    param: str | None = None
    try:
        body = response.json()
    except ValueError:
        body = None
    if isinstance(body, dict):
        error = body.get("error")
        if isinstance(error, dict):
            raw_code = error.get("code")
            if isinstance(raw_code, str) and raw_code:
                code = raw_code
            raw_message = error.get("message")
            if isinstance(raw_message, str) and raw_message:
                message = raw_message
            raw_type = error.get("type")
            if isinstance(raw_type, str):
                error_type = raw_type
            raw_id = error.get("request_id")
            if isinstance(raw_id, str):
                request_id = raw_id
            raw_retryable = error.get("retryable")
            if isinstance(raw_retryable, bool):
                retryable = raw_retryable
            raw_param = error.get("param")
            if isinstance(raw_param, str):
                param = raw_param
    hint = hint_for_code(code)
    if code == "backend_not_ready" and "SPEECHRAIL_JOB_SPOOL_DIR" in message:
        hint = (
            "SpeechRail job spool is not ready; configure SPEECHRAIL_JOB_SPOOL_DIR "
            "and restart the daemon"
        )
    return SpeechRailError(
        status=status,
        code=code,
        message=message,
        retryable=retryable,
        error_type=error_type,
        request_id=request_id,
        param=param,
        hint=hint,
    )


class SpeechRailClient:
    """Minimal async REST client bound to one SpeechRail daemon."""

    def __init__(
        self,
        *,
        base_url: str = DEFAULT_BASE_URL,
        api_key: str | None = None,
        timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        base = base_url.rstrip("/")
        if base.endswith("/v1"):
            self._api_url = base
            self._root_url = base[: -len("/v1")] or base
        else:
            self._api_url = f"{base}/v1"
            self._root_url = base
        self._api_key = api_key
        self._client = httpx.AsyncClient(timeout=timeout_seconds, transport=transport)

    async def aclose(self) -> None:
        """Release the underlying connection pool."""
        await self._client.aclose()

    def _headers(self) -> dict[str, str]:
        if self._api_key:
            return {"Authorization": f"Bearer {self._api_key}"}
        return {}

    async def _request(
        self,
        method: str,
        path: str,
        *,
        api: bool = True,
        headers: dict[str, str] | None = None,
        **kwargs: Any,
    ) -> httpx.Response:
        base = self._api_url if api else self._root_url
        url = f"{base}/{path.lstrip('/')}"
        request_headers = self._headers()
        if headers:
            request_headers.update(headers)
        try:
            response = await self._client.request(
                method, url, headers=request_headers, **kwargs
            )
        except httpx.HTTPError as exc:
            raise SpeechRailError(
                status=0,
                code="connection_error",
                message=f"cannot reach SpeechRail at {url}: {exc}",
                retryable=True,
                hint="make sure the SpeechRail daemon is running and reachable",
            ) from exc
        if response.is_success:
            return response
        raise parse_error_response(response)

    @staticmethod
    def _object(response: httpx.Response) -> dict[str, Any]:
        payload = response.json()
        if not isinstance(payload, dict):
            raise SpeechRailError(
                status=response.status_code,
                code="invalid_response",
                message="SpeechRail returned a non-object JSON body",
                retryable=False,
            )
        return payload

    async def fetch_models(self) -> list[dict[str, Any]]:
        """Return the ``data`` list of ``GET /v1/models``."""
        response = await self._request("GET", "models")
        data = self._object(response).get("data")
        if not isinstance(data, list):
            return []
        return cast(list[dict[str, Any]], [entry for entry in data if isinstance(entry, dict)])

    async def fetch_voices(self) -> list[dict[str, Any]]:
        """Return the ``data`` list of ``GET /v1/voices``."""
        response = await self._request("GET", "voices")
        data = self._object(response).get("data")
        if not isinstance(data, list):
            return []
        return cast(list[dict[str, Any]], [entry for entry in data if isinstance(entry, dict)])

    async def fetch_health(self) -> dict[str, Any]:
        """Return the body of ``GET /health`` (readiness/ profile facts)."""
        response = await self._request("GET", "health", api=False)
        return self._object(response)

    async def transcribe(
        self,
        *,
        content: bytes,
        filename: str,
        response_format: str,
        language: str | None = None,
    ) -> dict[str, Any]:
        """POST /v1/audio/transcriptions as multipart and return the JSON body.

        ``response_format`` is one of ``json``, ``verbose_json`` or
        ``diarized_json`` (the proxy never requests plain-text formats).
        """
        files = {"file": (filename, content, audio_content_type(filename))}
        data: dict[str, str] = {"response_format": response_format}
        if language:
            data["language"] = language
        response = await self._request(
            "POST", "audio/transcriptions", files=files, data=data
        )
        return self._object(response)

    async def synthesize(
        self,
        *,
        model: str,
        text: str,
        voice: str,
        response_format: str,
        speed: float,
    ) -> bytes:
        """POST /v1/audio/speech and return the raw audio body."""
        body = {
            "model": model,
            "input": text,
            "voice": voice,
            "response_format": response_format,
            "speed": speed,
        }
        response = await self._request("POST", "audio/speech", json=body)
        return response.content

    async def voice_preview(
        self,
        *,
        model: str,
        text: str,
        instruction: str,
        response_format: str = "wav",
    ) -> bytes:
        """POST /v1/voices/previews and return the raw audio body."""
        body = {
            "model": model,
            "input": text,
            "instruction": instruction,
            "response_format": response_format,
        }
        response = await self._request("POST", "voices/previews", json=body)
        return response.content

    async def create_voice(
        self,
        *,
        name: str,
        instruction: str,
        voice_id: str | None = None,
        seed: int | None = None,
    ) -> dict[str, Any]:
        """POST /v1/voices and return the created voice entry."""
        body: dict[str, Any] = {"name": name, "instruction": instruction}
        if voice_id is not None:
            body["id"] = voice_id
        if seed is not None:
            body["seed"] = seed
        response = await self._request("POST", "voices", json=body)
        return self._object(response)

    async def delete_voice(self, *, voice_id: str) -> dict[str, Any]:
        """DELETE /v1/voices/{voice_id} and return the deletion record."""
        response = await self._request("DELETE", f"voices/{voice_id}")
        return self._object(response)

    async def create_job(
        self,
        *,
        kind: str,
        input_ref: str,
        params: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        """POST /v1/jobs and return the created job record."""
        body: dict[str, Any] = {"kind": kind, "input_ref": input_ref}
        if params is not None:
            body["params"] = params
        response = await self._request("POST", "jobs", json=body)
        return self._object(response)

    async def get_job(self, *, job_id: str) -> dict[str, Any]:
        """GET /v1/jobs/{job_id} and return the job record."""
        response = await self._request("GET", f"jobs/{job_id}")
        return self._object(response)

    async def cancel_job(self, *, job_id: str) -> dict[str, Any]:
        """DELETE /v1/jobs/{job_id} and return the cancelled job record."""
        response = await self._request("DELETE", f"jobs/{job_id}")
        return self._object(response)
