"""FastMCP composition root for the ``speechrail-mcp`` proxy process.

Wires the stateless tool logic (``speechrail.mcp.tools``) onto a REST client
(``speechrail.mcp.client``) and registers them as FastMCP tools.  The proxy is
a dedicated process: it never imports the SpeechRail FastAPI application and
never instantiates any model worker.
"""

from __future__ import annotations

import os
import sys
from collections.abc import Awaitable
from typing import Any, Literal, cast

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.exceptions import ToolError

from speechrail.config.auth import resolve_api_key
from speechrail.mcp import tools
from speechrail.mcp.client import (
    DEFAULT_BASE_URL,
    DEFAULT_TIMEOUT_SECONDS,
    SpeechRailClient,
    SpeechRailError,
)
from speechrail.mcp.tools import ToolCallError

_SERVER_NAME = "speechrail-mcp"
_TRANSPORTS = frozenset({"stdio", "streamable-http"})

_INSTRUCTIONS = (
    "SpeechRail MCP exposes the local SpeechRail ASR/TTS service as a small "
    "toolset. Always start with describe() to learn the active profile tier, "
    "its readiness and the voices that are available on it. Pass audio as an "
    "audio_ref (a local file path or file:// URI) and never inline base64: "
    "inline audio would leak into your context. Prefer the synchronous "
    "transcribe/synthesize tools; when a call reports audio_too_long or "
    "times out, use create_job with the same input_ref and poll get_job. If "
    "SpeechRail is busy (backend_busy or queue_full) retry with backoff and "
    "do not loop. Real-time full-duplex audio is outside this toolset: it "
    "uses the /v1/realtime WebSocket directly."
)


def _failure_text(failure: ToolCallError) -> str:
    retry = "retryable" if failure.retryable else "not retryable"
    text = f"[code={failure.code}, retryable={retry}] {failure.message}"
    if failure.hint:
        text = f"{text}\nHint: {failure.hint}"
    return text


async def _map_errors(coro: Awaitable[dict[str, Any]]) -> dict[str, Any]:
    """Run a tool coroutine and convert failures to MCP tool errors."""
    try:
        return await coro
    except ToolCallError as exc:
        raise ToolError(_failure_text(exc)) from exc
    except SpeechRailError as exc:
        raise ToolError(exc.to_message()) from exc


def _timeout_from_env() -> float:
    raw = os.getenv("SPEECHRAIL_MCP_TIMEOUT_SECONDS")
    if not raw:
        return DEFAULT_TIMEOUT_SECONDS
    try:
        value = float(raw)
    except ValueError:
        return DEFAULT_TIMEOUT_SECONDS
    return value if value > 0 else DEFAULT_TIMEOUT_SECONDS


_resolve_api_key = resolve_api_key


def create_server() -> FastMCP:
    """Build a FastMCP server bound to the configured SpeechRail daemon.

    Environment:
      SPEECHRAIL_BASE_URL             server base (default http://127.0.0.1:8201/v1)
      SPEECHRAIL_API_KEY              bearer key (optional: auto-discovered from the
                                      daemon's config/.env when unset)
      SPEECHRAIL_APP_HOME             app home for key discovery (default ~/Library/...)
      SPEECHRAIL_MCP_TIMEOUT_SECONDS  per-request timeout in seconds
    """
    base_url = os.getenv("SPEECHRAIL_BASE_URL", DEFAULT_BASE_URL)
    api_key = _resolve_api_key()
    client = SpeechRailClient(
        base_url=base_url,
        api_key=api_key,
        timeout_seconds=_timeout_from_env(),
    )
    mcp = FastMCP(name=_SERVER_NAME, instructions=_INSTRUCTIONS)

    @mcp.tool()
    async def describe() -> dict[str, Any]:
        """Return the current capability snapshot.

        Merges GET /v1/models, GET /v1/voices and GET /health into one
        payload: active tier/profile, diarization readiness, clone/preview
        support and the full model + voice lists.  Every voice entry carries
        mode, available and capability discriminators; only choose voices
        with available=true.
        """
        return await _map_errors(tools.describe(client))

    @mcp.tool()
    async def transcribe(
        audio_ref: str,
        language: str | None = None,
        diarize: bool = False,
        timestamps: bool = False,
    ) -> dict[str, Any]:
        """Transcribe audio referenced by a local path or file:// URI.

        audio_ref: local file path or file:// URI (base64 is rejected).
        language: optional ISO 639-1 code; omitted means auto-detect.
        diarize: true returns diarized segments with anonymous speaker labels
            and requires diarization_ready=true on describe().
        timestamps: true returns verbose_json with segments (and words when
            available). Output shapes: default {text}; timestamps
            {text, segments}; diarize {segments:[{speaker,start,end,text}]}.
        """
        return await _map_errors(
            tools.transcribe(
                client,
                audio_ref=audio_ref,
                language=language,
                diarize=diarize,
                timestamps=timestamps,
            )
        )

    @mcp.tool()
    async def synthesize(
        text: str,
        voice: str = "serena",
        output_format: str = "mp3",
        speed: float = 1.0,
    ) -> dict[str, Any]:
        """Synthesize text to a local audio file and return its path.

        text: text to speak (up to 4096 chars).
        voice: a voice id from describe().voices (defaults to serena);
            clone/instruction voices are rejected outside the quality tier.
        output_format: mp3 (default), wav or pcm.
        speed: speaking rate from 0.25 to 4.0.
        Returns {audio_path, content_type, output_format, bytes}; delete the
        temp file after the host plays/sends it.
        """
        return await _map_errors(
            tools.synthesize(
                client,
                text=text,
                voice=voice,
                output_format=output_format,
                speed=speed,
            )
        )

    @mcp.tool()
    async def preview_voice(instruction: str, text: str) -> dict[str, Any]:
        """Audition a VoiceDesign instruction (quality tier only).

        instruction: natural-language voice description to audition.
        text: sample text to speak with the provisional voice.
        Returns {audio_path, content_type, output_format, bytes}. Non-quality
        profiles are rejected up front; call describe() to confirm support.
        """
        return await _map_errors(
            tools.preview_voice(client, instruction=instruction, text=text)
        )

    @mcp.tool()
    async def create_job(
        kind: str,
        input_ref: str,
        params: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Create a durable transcription/speech job and return its handle.

        kind: transcription or speech.
        input_ref: path/URI reused by the worker (same convention as
            audio_ref; up to 1000 chars).
        params: reserved for future request options (not yet stored).
        Returns the job record {id, kind, state, result_ref}; poll with
        get_job and cancel with cancel_job.
        """
        return await _map_errors(
            tools.create_job(client, kind=kind, input_ref=input_ref, params=params)
        )

    @mcp.tool()
    async def get_job(job_id: str) -> dict[str, Any]:
        """Fetch a durable job by job_id and return its current record."""
        return await _map_errors(tools.get_job(client, job_id=job_id))

    @mcp.tool()
    async def cancel_job(job_id: str) -> dict[str, Any]:
        """Cancel a durable job by job_id and return its updated record."""
        return await _map_errors(tools.cancel_job(client, job_id=job_id))

    return mcp


def main(argv: list[str] | None = None) -> int:
    """Run the proxy over the configured MCP transport.

    Transport comes from SPEECHRAIL_MCP_TRANSPORT (stdio | streamable-http)
    or from ``--transport`` on the command line.  Defaults to stdio for
    host-local MCP clients (Claude Code / Cursor / Open-WebUI agent).
    """
    args = argv if argv is not None else list(sys.argv[1:])
    transport = os.getenv("SPEECHRAIL_MCP_TRANSPORT", "stdio")
    if args:
        if args in (["--help"], ["-h"]):
            print(
                "usage: speechrail-mcp [--transport stdio|streamable-http]\n\n"
                "Environment: SPEECHRAIL_BASE_URL, SPEECHRAIL_API_KEY, "
                "SPEECHRAIL_MCP_TIMEOUT_SECONDS, SPEECHRAIL_MCP_TRANSPORT"
            )
            return 0
        if len(args) == 2 and args[0] == "--transport":
            transport = args[1]
        else:
            print(
                "usage: speechrail-mcp [--transport stdio|streamable-http]",
                file=sys.stderr,
            )
            return 2
    if transport not in _TRANSPORTS:
        print(
            f"unsupported transport {transport!r}; choose from {sorted(_TRANSPORTS)}",
            file=sys.stderr,
        )
        return 2
    validated: Literal["stdio", "streamable-http"] = cast(
        Literal["stdio", "streamable-http"], transport
    )
    server = create_server()
    server.run(transport=validated)
    return 0
