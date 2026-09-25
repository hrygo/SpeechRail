"""MCPServer composition root for the ``speechrail-mcp`` proxy process.

Wires the stateless tool logic (``speechrail.mcp.tools``) onto a REST client
(``speechrail.mcp.client``) and registers them as MCPServer tools and
resources.  The proxy is a dedicated process: it never imports the SpeechRail
FastAPI application and never instantiates any model worker.
"""

from __future__ import annotations

import json
import os
import sys
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager
from typing import Annotated, Any, Literal, cast

from mcp.server import MCPServer
from mcp.server.caching import CacheableMethod, CacheHint
from mcp.server.mcpserver.context import Context
from mcp.server.mcpserver.exceptions import ResourceError, ToolError
from mcp.types import Annotations, ToolAnnotations
from pydantic import Field

from speechrail import __version__
from speechrail.config.auth import resolve_api_key
from speechrail.mcp import tools
from speechrail.mcp.client import (
    DEFAULT_BASE_URL,
    DEFAULT_TIMEOUT_SECONDS,
    SpeechRailClient,
    SpeechRailError,
)
from speechrail.mcp.models import (
    AudioArtifact,
    DescribeResult,
    JobListResult,
    JobRecord,
    JobResultArtifact,
    TranscribeResult,
    VoiceDesignCandidateRecord,
    VoiceDesignPublishResult,
    VoiceRecord,
    VoiceValidationResult,
)
from speechrail.mcp.tools import ToolCallError

_SERVER_NAME = "speechrail-mcp"
_SERVER_TITLE = "SpeechRail"
_SERVER_DESCRIPTION = (
    "Local SpeechRail ASR/TTS service exposed as MCP tools for agents."
)
_TRANSPORTS = frozenset({"stdio", "streamable-http"})

# Deviate from the MCP SDK default 8000, which is commonly occupied by local
# model servers. stdio binds no port at all.
_DEFAULT_HTTP_HOST = "127.0.0.1"
_DEFAULT_HTTP_PORT = 8202
_USAGE = (
    "usage: speechrail-mcp [--transport stdio|streamable-http] [--host HOST] [--port PORT]\n\n"
    "Environment: SPEECHRAIL_BASE_URL, SPEECHRAIL_API_KEY, "
    "SPEECHRAIL_MCP_TIMEOUT_SECONDS, SPEECHRAIL_MCP_TRANSPORT, "
    "SPEECHRAIL_MCP_HOST, SPEECHRAIL_MCP_PORT"
)

# List methods are safe to cache publicly: the tool set and the three resource
# URIs are static metadata. resources/read is deliberately absent because the
# capability snapshot it returns changes with the active profile.
_CACHE_HINTS: dict[CacheableMethod, CacheHint] = {
    "tools/list": CacheHint(ttl_ms=300_000, scope="public"),
    "prompts/list": CacheHint(ttl_ms=300_000, scope="public"),
    "resources/list": CacheHint(ttl_ms=300_000, scope="public"),
}

_INSTRUCTIONS = (
    "SpeechRail MCP exposes the complete local SpeechRail ASR/TTS, voice and "
    "durable-job surface. Always start with describe(): it requires the current "
    "effective_capabilities_v1 contract and reports the active profile, profile "
    "consistency, readiness, available voices and validation state. The proxy "
    "never changes profiles; missing capabilities are reported from the current "
    "snapshot. `available=true` means the voice can be routed; for clone voices "
    "it does not mean `production_ready=true`. VoiceDesign preview/create_voice "
    "produces an instruction voice. design_voice creates a private candidate; "
    "then call confirm_voice_design, validate_voice_design with a different "
    "test text, attach explicit identity/naturalness review only after human "
    "audition, and finally publish_voice_design. Candidate generation and "
    "machine validation never substitute for human review. After clone_voice, "
    "call validate_voice and require a persisted synthesis output pass before a "
    "production render. Reference-gate success is not output-gate success. Do "
    "not retry `clone_speed_unsupported` by forcing a speed: Base clone is "
    "fixed at speed=1.0 and the error is a capability mismatch. Pass audio as "
    "a local file path or file:// URI and never inline base64. Prefer the "
    "synchronous transcribe/synthesize tools; when a call reports "
    "audio_too_long or times out, use create_job with an Idempotency-Key and "
    "poll get_job, list_jobs, then fetch the result with get_job_result. If "
    "SpeechRail is busy (backend_busy or queue_full), retry with bounded "
    "backoff and do not loop. Real-time full-duplex audio is outside this "
    "toolset and uses the /v1/realtime WebSocket directly. SpeechRail is a "
    "stateless Speech Plane: it performs ASR, VAD, diarization facts and "
    "explicit TTS rendering only. The caller owns the LLM, conversation "
    "history, memory, persona, tools, playback and barge-in policy; MCP never "
    "creates a Realtime WebSocket handle or a server-side conversation."
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


async def _resource_json(
    coro: Awaitable[Any],
    transform: Callable[[Any], Any] | None = None,
) -> str:
    """Await a resource payload, map REST failures, and serialize to JSON."""
    try:
        payload = await coro
    except SpeechRailError as exc:
        raise ResourceError(exc.to_message()) from exc
    if transform is not None:
        payload = transform(payload)
    return json.dumps(payload)


def _tool_annotations(
    title: str,
    *,
    read_only: bool,
    destructive: bool,
    idempotent: bool,
) -> ToolAnnotations:
    return ToolAnnotations(
        title=title,
        read_only_hint=read_only,
        destructive_hint=destructive,
        idempotent_hint=idempotent,
        open_world_hint=False,
    )


def _timeout_from_env() -> float:
    raw = os.getenv("SPEECHRAIL_MCP_TIMEOUT_SECONDS")
    if not raw:
        return DEFAULT_TIMEOUT_SECONDS
    try:
        value = float(raw)
    except ValueError:
        return DEFAULT_TIMEOUT_SECONDS
    return value if value > 0 else DEFAULT_TIMEOUT_SECONDS


def _host_from_env() -> str:
    return os.getenv("SPEECHRAIL_MCP_HOST") or _DEFAULT_HTTP_HOST


def _port_from_env() -> int:
    raw = os.getenv("SPEECHRAIL_MCP_PORT")
    if not raw:
        return _DEFAULT_HTTP_PORT
    try:
        value = int(raw)
    except ValueError:
        return _DEFAULT_HTTP_PORT
    return value if 1 <= value <= 65535 else _DEFAULT_HTTP_PORT


_resolve_api_key = resolve_api_key


def create_server(*, client: SpeechRailClient | None = None) -> MCPServer:
    """Build an MCPServer bound to the configured SpeechRail daemon.

    Args:
        client: Optional pre-built REST client. When omitted, one is created
            from the environment below; tests inject a ``MockTransport`` client.

    Environment:
      SPEECHRAIL_BASE_URL             server base (default http://127.0.0.1:8201/v1)
      SPEECHRAIL_API_KEY              bearer key (optional: auto-discovered from the
                                      daemon's config/.env when unset)
      SPEECHRAIL_APP_HOME             app home for key discovery (default ~/Library/...)
      SPEECHRAIL_MCP_TIMEOUT_SECONDS  per-request timeout in seconds
    """
    if client is None:
        base_url = os.getenv("SPEECHRAIL_BASE_URL", DEFAULT_BASE_URL)
        api_key = _resolve_api_key()
        client = SpeechRailClient(
            base_url=base_url,
            api_key=api_key,
            timeout_seconds=_timeout_from_env(),
        )
    rest_client = client

    # The server owns its REST client for its whole lifetime; ``aclose`` is
    # idempotent, so an injected test client is closed here too.
    @asynccontextmanager
    async def lifespan(_: MCPServer[None]) -> AsyncIterator[None]:
        yield
        await rest_client.aclose()

    mcp = MCPServer(
        name=_SERVER_NAME,
        title=_SERVER_TITLE,
        description=_SERVER_DESCRIPTION,
        version=__version__,
        instructions=_INSTRUCTIONS,
        cache_hints=_CACHE_HINTS,
        lifespan=lifespan,
    )

    @mcp.tool(
        title="Current capability snapshot",
        annotations=_tool_annotations(
            "Current capability snapshot",
            read_only=True,
            destructive=False,
            idempotent=True,
        ),
    )
    async def describe() -> DescribeResult:
        """Return current capability observations and the atomic snapshot.

        Realtime metadata explicitly reports caller-owned orchestration and
        the absence of server-side LLM or conversation state. Every voice
        entry carries current mode, availability and revision discriminators;
        only choose voices with available=true.
        """
        return DescribeResult.model_validate(await _map_errors(tools.describe(client)))

    @mcp.tool(
        title="Transcribe audio",
        annotations=_tool_annotations(
            "Transcribe audio",
            read_only=True,
            destructive=False,
            idempotent=True,
        ),
    )
    async def transcribe(
        audio_ref: Annotated[
            str,
            Field(description="Local audio file path or file:// URI; base64 is rejected."),
        ],
        ctx: Context,
        language: Annotated[
            str | None,
            Field(description="Optional ISO 639-1 language code; omitted means auto-detect."),
        ] = None,
        diarize: Annotated[
            bool,
            Field(
                description=(
                    "Return diarized segments with anonymous speaker labels; "
                    "requires diarization_ready=true on describe()."
                )
            ),
        ] = False,
        timestamps: Annotated[
            bool,
            Field(
                description=(
                    "Return verbose_json segments (and words when available); "
                    "ignored when diarize is true."
                )
            ),
        ] = False,
    ) -> TranscribeResult:
        """Transcribe audio referenced by a local path or file:// URI.

        audio_ref: local file path or file:// URI (base64 is rejected).
        language: optional ISO 639-1 code; omitted means auto-detect.
        diarize: true returns diarized segments with anonymous speaker labels
            and requires diarization_ready=true on describe().
        timestamps: true returns verbose_json with segments (and words when
            available). Output shapes: default {text}; timestamps
            {text, segments}; diarize {segments:[{speaker,start,end,text}]}.
        """
        await ctx.report_progress(0.0, 1.0, "started")
        raw = await _map_errors(
            tools.transcribe(
                client,
                audio_ref=audio_ref,
                language=language,
                diarize=diarize,
                timestamps=timestamps,
            )
        )
        await ctx.report_progress(1.0, 1.0, "done")
        return TranscribeResult.model_validate(raw)

    @mcp.tool(
        title="Synthesize speech to a file",
        annotations=_tool_annotations(
            "Synthesize speech to a file",
            read_only=False,
            destructive=False,
            idempotent=False,
        ),
    )
    async def synthesize(
        text: Annotated[str, Field(description="Text to synthesize (up to 4096 characters).")],
        ctx: Context,
        voice: Annotated[
            str,
            Field(description="A voice id from describe().voices; defaults to serena."),
        ] = "serena",
        output_format: Annotated[
            str,
            Field(description="Audio container: mp3 (default), wav or pcm."),
        ] = "mp3",
        speed: Annotated[
            float,
            Field(description="Speaking rate from 0.25 to 4.0."),
        ] = 1.0,
        language: Annotated[
            str,
            Field(description="TTS language code/name; describe() is authoritative."),
        ] = "auto",
        instruction: Annotated[
            str | None,
            Field(description="Ephemeral VoiceDesign instruction; unsupported for clone voices."),
        ] = None,
        seed: Annotated[
            int | None,
            Field(description="Caller seed; supported only on explicit VoiceDesign instructions."),
        ] = None,
        validation_policy: Annotated[
            Literal["allow_unverified", "require_output_pass"],
            Field(
                description=(
                    "allow_unverified for audition/diagnostics (default), or "
                    "require_output_pass for formal production."
                )
            ),
        ] = "allow_unverified",
        expected_voice_revision: Annotated[
            str | None,
            Field(
                description=(
                    "Optional vr_... voice revision from describe(); when omitted, "
                    "the effective snapshot is pinned automatically."
                )
            ),
        ] = None,
        expected_model_revision: Annotated[
            str | None,
            Field(
                description=(
                    "Optional model catalog revision from describe(); when omitted, "
                    "the effective snapshot is pinned automatically."
                )
            ),
        ] = None,
    ) -> AudioArtifact:
        """Synthesize text to a local audio file and return its path.

        text: text to speak (up to 4096 chars).
        voice: a voice id from describe().voices (defaults to serena);
            clone/instruction voices are rejected when the current effective
            snapshot does not publish their required capability.
        output_format: mp3 (default), wav or pcm.
        speed: speaking rate from 0.25 to 4.0.
        expected_voice_revision / expected_model_revision: optional revision
            pins; effective capability snapshots supply them automatically.
        Returns {audio_path, content_type, output_format, bytes}; delete the
        temp file after the host plays/sends it.
        """
        await ctx.report_progress(0.0, 1.0, "started")
        raw = await _map_errors(
            tools.synthesize(
                client,
                text=text,
                voice=voice,
                output_format=output_format,
                speed=speed,
                language=language,
                instruction=instruction,
                seed=seed,
                validation_policy=validation_policy,
                expected_voice_revision=expected_voice_revision,
                expected_model_revision=expected_model_revision,
            )
        )
        await ctx.report_progress(1.0, 1.0, "done")
        return AudioArtifact.model_validate(raw)

    @mcp.tool(
        title="Audition a voice instruction",
        annotations=_tool_annotations(
            "Audition a voice instruction",
            read_only=False,
            destructive=False,
            idempotent=False,
        ),
    )
    async def preview_voice(
        instruction: Annotated[
            str,
            Field(
                description=(
                    "Natural-language VoiceDesign instruction "
                    "(Chinese or English, 30-200 words)."
                )
            ),
        ],
        text: Annotated[
            str,
            Field(description="Sample text to speak with the provisional voice."),
        ],
    ) -> AudioArtifact:
        """Audition an instruction when VoiceDesign is active.

        instruction: natural-language voice description to audition.
            Chinese or English only (30-200 words); describe acoustic traits
            across gender/age/pitch/speed/emotion, never a real person.
        text: sample text to speak with the provisional voice.
        Returns {audio_path, content_type, output_format, bytes}. Ephemeral:
            nothing is persisted; call create_voice to register the chosen
            instruction. The active effective snapshot must publish VoiceDesign;
            call describe() to inspect current capabilities.
        """
        return AudioArtifact.model_validate(
            await _map_errors(tools.preview_voice(client, instruction=instruction, text=text))
        )

    @mcp.tool(
        title="Create a persistent voice",
        annotations=_tool_annotations(
            "Create a persistent voice",
            read_only=False,
            destructive=False,
            idempotent=False,
        ),
    )
    async def create_voice(
        name: Annotated[str, Field(description="Display name for the voice (required).")],
        instruction: Annotated[
            str,
            Field(
                description=(
                    "The auditioned VoiceDesign instruction (up to 10000 "
                    "characters, Chinese or English)."
                )
            ),
        ],
        voice_id: Annotated[
            str | None,
            Field(
                description=(
                    "Optional stable id matching ^[a-zA-Z0-9_-]{1,64}$; "
                    "omitted means server-assigned."
                )
            ),
        ] = None,
        seed: Annotated[
            int | None,
            Field(description="Optional integer 0..4294967295 for reproducible synthesis."),
        ] = None,
    ) -> VoiceRecord:
        """Register a persistent instruction-driven voice.

        name: display name for the voice (required).
        instruction: the auditioned VoiceDesign instruction (required,
            up to 10000 chars, Chinese or English).
        voice_id: optional stable id matching ^[a-zA-Z0-9_-]{1,64}$;
            omitted means server-assigned.
        seed: optional integer 0..4294967295 for reproducible synthesis.
        Returns the created voice entry (id, mode, available, capabilities).
            Registration requires VoiceDesign in the current effective
            capability snapshot.
        """
        return VoiceRecord.model_validate(
            await _map_errors(
                tools.create_voice(
                    client,
                    name=name,
                    instruction=instruction,
                    voice_id=voice_id,
                    seed=seed,
                )
            )
        )

    @mcp.tool(
        title="Get voice details",
        annotations=_tool_annotations(
            "Get voice details", read_only=True, destructive=False, idempotent=True
        ),
    )
    async def get_voice(
        voice_id: Annotated[str, Field(description="Canonical voice id or alias.")],
    ) -> VoiceRecord:
        """Return one safe voice record and its validation/production state."""
        return VoiceRecord.model_validate(
            await _map_errors(tools.get_voice(client, voice_id=voice_id))
        )

    @mcp.tool(
        title="Create a VoiceDesign candidate",
        annotations=_tool_annotations(
            "Create a VoiceDesign candidate",
            read_only=False,
            destructive=False,
            idempotent=False,
        ),
    )
    async def design_voice(
        voice_id: Annotated[str, Field(description="New stable voice id.")],
        name: Annotated[str, Field(description="Display name.")],
        instruction: Annotated[str, Field(description="VoiceDesign acoustic instruction.")],
        reference_text: Annotated[
            str,
            Field(description="Text aligned to the generated reference audio; 20-240 chars."),
        ],
        seed: Annotated[int, Field(description="VoiceDesign seed; defaults to 42.")] = 42,
        language: Annotated[
            str,
            Field(description="Current generated-reference gate language; defaults to zh."),
        ] = "zh",
        idempotency_key: Annotated[
            str | None,
            Field(description="Optional key for safe retry of the same registration payload."),
        ] = None,
    ) -> VoiceDesignCandidateRecord:
        """Generate a private candidate; nothing is published until validation."""
        return VoiceDesignCandidateRecord.model_validate(
            await _map_errors(
                tools.design_voice(
                    client,
                    voice_id=voice_id,
                    name=name,
                    instruction=instruction,
                    reference_text=reference_text,
                    seed=seed,
                    language=language,
                    idempotency_key=idempotency_key,
                )
            )
        )

    @mcp.tool(
        title="Confirm a VoiceDesign candidate",
        annotations=_tool_annotations(
            "Confirm a VoiceDesign candidate",
            read_only=False,
            destructive=False,
            idempotent=True,
        ),
    )
    async def confirm_voice_design(
        candidate_id: Annotated[
            str,
            Field(description="VoiceDesign candidate id matching ^vd_[0-9a-f]{24}$."),
        ],
        reference_text: Annotated[
            str | None,
            Field(
                description=(
                    "Optional corrected transcript aligned to the generated "
                    "reference; editing it revokes earlier validation."
                )
            ),
        ] = None,
    ) -> VoiceDesignCandidateRecord:
        """Confirm the reference transcript before Base validation."""
        return VoiceDesignCandidateRecord.model_validate(
            await _map_errors(
                tools.confirm_voice_design(
                    client,
                    candidate_id=candidate_id,
                    reference_text=reference_text,
                )
            )
        )

    @mcp.tool(
        title="Validate a VoiceDesign candidate",
        annotations=_tool_annotations(
            "Validate a VoiceDesign candidate",
            read_only=False,
            destructive=False,
            idempotent=False,
        ),
    )
    async def validate_voice_design(
        candidate_id: Annotated[
            str,
            Field(description="VoiceDesign candidate id matching ^vd_[0-9a-f]{24}$."),
        ],
        test_text: Annotated[
            str | None,
            Field(
                description=(
                    "Base validation text different from the reference; "
                    "omit to use a server-controlled text."
                )
            ),
        ] = None,
        capability_key: Annotated[
            str | None,
            Field(description="Optional render capability key: fast/quality/reference."),
        ] = None,
        validation_id: Annotated[
            str | None,
            Field(description="Machine validation id to attach a human review."),
        ] = None,
        identity_review: Annotated[
            str | None,
            Field(description="Human audition identity review: pass/warn/reject."),
        ] = None,
        naturalness_review: Annotated[
            str | None,
            Field(description="Human audition naturalness review: pass/warn/reject."),
        ] = None,
    ) -> VoiceDesignCandidateRecord:
        """Run Base new-text validation or attach an explicit human audition."""
        return VoiceDesignCandidateRecord.model_validate(
            await _map_errors(
                tools.validate_voice_design(
                    client,
                    candidate_id=candidate_id,
                    test_text=test_text,
                    capability_key=capability_key,
                    validation_id=validation_id,
                    identity_review=identity_review,
                    naturalness_review=naturalness_review,
                )
            )
        )

    @mcp.tool(
        title="Publish a VoiceDesign candidate",
        annotations=_tool_annotations(
            "Publish a VoiceDesign candidate",
            read_only=False,
            destructive=False,
            idempotent=True,
        ),
    )
    async def publish_voice_design(
        candidate_id: Annotated[
            str,
            Field(description="VoiceDesign candidate id matching ^vd_[0-9a-f]{24}$."),
        ],
        expected_candidate_revision: Annotated[
            str | None,
            Field(description="Optional exact candidate revision CAS guard."),
        ] = None,
    ) -> VoiceDesignPublishResult:
        """Publish one validated candidate as an immutable Base voice."""
        return VoiceDesignPublishResult.model_validate(
            await _map_errors(
                tools.publish_voice_design(
                    client,
                    candidate_id=candidate_id,
                    expected_candidate_revision=expected_candidate_revision,
                )
            )
        )

    @mcp.tool(
        title="Clone a voice from local audio",
        annotations=_tool_annotations(
            "Clone a voice from local audio",
            read_only=False,
            destructive=False,
            idempotent=False,
        ),
    )
    async def clone_voice(
        audio_ref: Annotated[
            str,
            Field(
                description=(
                    "Local reference audio path or file:// URI; "
                    "remote/base64 is rejected."
                )
            ),
        ],
        name: Annotated[str, Field(description="Display name.")],
        ref_text: Annotated[str, Field(description="Transcript of the reference audio.")],
        voice_id: Annotated[
            str | None,
            Field(description="Optional stable id matching ^[a-zA-Z0-9_-]{1,64}$."),
        ] = None,
        idempotency_key: Annotated[
            str | None,
            Field(description="Optional key for safe retry of the same audio/payload."),
        ] = None,
    ) -> VoiceRecord:
        """Register a local reference recording when Base is active."""
        return VoiceRecord.model_validate(
            await _map_errors(
                tools.clone_voice(
                    client,
                    audio_ref=audio_ref,
                    name=name,
                    ref_text=ref_text,
                    voice_id=voice_id,
                    idempotency_key=idempotency_key,
                )
            )
        )

    @mcp.tool(
        title="Validate a registered voice",
        annotations=_tool_annotations(
            "Validate a registered voice", read_only=False, destructive=False, idempotent=False
        ),
    )
    async def validate_voice(
        voice_id: Annotated[str, Field(description="Registered voice id.")],
        runs: Annotated[int, Field(description="Probe repetitions, 1-3.")] = 1,
    ) -> VoiceValidationResult:
        """Run the current synthesis output gate; this may load the local TTS worker."""
        return VoiceValidationResult.model_validate(
            await _map_errors(tools.validate_voice(client, voice_id=voice_id, runs=runs))
        )

    @mcp.tool(
        title="Delete a voice",
        annotations=_tool_annotations(
            "Delete a voice",
            read_only=False,
            destructive=True,
            idempotent=True,
        ),
    )
    async def delete_voice(
        voice_id: Annotated[str, Field(description="Id of the persistent voice to delete.")],
    ) -> VoiceRecord:
        """Delete a persistent custom voice by voice_id."""
        return VoiceRecord.model_validate(
            await _map_errors(tools.delete_voice(client, voice_id=voice_id))
        )

    @mcp.tool(
        title="Create a durable job",
        annotations=_tool_annotations(
            "Create a durable job",
            read_only=False,
            destructive=False,
            idempotent=False,
        ),
    )
    async def create_job(
        kind: Annotated[str, Field(description="Job kind: transcription or speech.")],
        input_ref: Annotated[
            str,
            Field(
                description=(
                    "Absolute local path or file:// URI reused by the worker "
                    "(up to 1000 characters); speech expects a UTF-8 text file."
                )
            ),
        ],
        params: Annotated[
            dict[str, Any] | None,
            Field(
                description=(
                    "Kind-specific JSON object stored and echoed back by the server; "
                    "transcription accepts language, diarize, timestamps; speech "
                    "accepts voice, speed, language, instruction, seed, and "
                    "validation_policy (allow_unverified or require_output_pass). "
                    "Unknown keys and invalid values are rejected."
                )
            ),
        ] = None,
        idempotency_key: Annotated[
            str | None,
            Field(description="Optional key; same owner/key/payload returns the same job."),
        ] = None,
    ) -> JobRecord:
        """Create a durable transcription/speech job and return its handle.

        kind: transcription or speech.
        input_ref: absolute local path or file:// URI reused by the worker
            (up to 1000 chars; speech expects a UTF-8 text file).
        params: kind-specific options stored and echoed by the server; unknown
            keys are rejected. Speech accepts validation_policy=allow_unverified
            or require_output_pass.
        Returns the job record {id, kind, state, result_ref}; poll with
        get_job and cancel with cancel_job.
        """
        return JobRecord.model_validate(
            await _map_errors(
                tools.create_job(
                    client,
                    kind=kind,
                    input_ref=input_ref,
                    params=params,
                    idempotency_key=idempotency_key,
                )
            )
        )

    @mcp.tool(
        title="Get a job record",
        annotations=_tool_annotations(
            "Get a job record",
            read_only=True,
            destructive=False,
            idempotent=True,
        ),
    )
    async def get_job(
        job_id: Annotated[str, Field(description="Id of the durable job.")],
        ctx: Context,
    ) -> JobRecord:
        """Fetch a durable job by job_id and return its current record."""
        await ctx.report_progress(0.0, 1.0, "started")
        raw = await _map_errors(tools.get_job(client, job_id=job_id))
        await ctx.report_progress(1.0, 1.0, "done")
        return JobRecord.model_validate(raw)

    @mcp.tool(
        title="List durable jobs",
        annotations=_tool_annotations(
            "List durable jobs", read_only=True, destructive=False, idempotent=True
        ),
    )
    async def list_jobs(
        limit: Annotated[int, Field(description="Page size, 1-100.")] = 20,
        cursor: Annotated[
            str | None, Field(description="Opaque cursor from the previous page.")
        ] = None,
    ) -> JobListResult:
        """List owner-scoped jobs without exposing input contents."""
        return JobListResult.model_validate(
            await _map_errors(tools.list_jobs(client, limit=limit, cursor=cursor))
        )

    @mcp.tool(
        title="Get job result",
        annotations=_tool_annotations(
            "Get job result", read_only=True, destructive=False, idempotent=True
        ),
    )
    async def get_job_result(
        job_id: Annotated[str, Field(description="Completed durable job id.")],
    ) -> JobResultArtifact:
        """Materialize a completed speech/transcription result on the MCP host."""
        return JobResultArtifact.model_validate(
            await _map_errors(tools.get_job_result(client, job_id=job_id))
        )

    @mcp.tool(
        title="Cancel a job",
        annotations=_tool_annotations(
            "Cancel a job",
            read_only=False,
            destructive=True,
            idempotent=True,
        ),
    )
    async def cancel_job(
        job_id: Annotated[str, Field(description="Id of the durable job.")],
    ) -> JobRecord:
        """Cancel a durable job by job_id and return its updated record."""
        return JobRecord.model_validate(
            await _map_errors(tools.cancel_job(client, job_id=job_id))
        )

    @mcp.resource(
        "speechrail://capabilities",
        name="capabilities",
        title="SpeechRail capabilities",
        description=(
            "Current capability observations plus the required atomic "
            "effective-capabilities snapshot: active tier/profile, readiness, "
            "models and voices."
        ),
        mime_type="application/json",
        annotations=Annotations(audience=["user", "assistant"]),
    )
    async def capabilities_resource() -> str:
        return await _resource_json(tools.describe(client))

    @mcp.resource(
        "speechrail://voices",
        name="voices",
        title="SpeechRail voices",
        description="Read-only voice list from GET /v1/voices for the active profile.",
        mime_type="application/json",
        annotations=Annotations(audience=["user", "assistant"]),
    )
    async def voices_resource() -> str:
        return await _resource_json(
            client.fetch_voices(), lambda voices: {"data": voices}
        )

    @mcp.resource(
        "speechrail://models",
        name="models",
        title="SpeechRail models",
        description="Read-only model list from GET /v1/models for the active profile.",
        mime_type="application/json",
        annotations=Annotations(audience=["user", "assistant"]),
    )
    async def models_resource() -> str:
        return await _resource_json(
            client.fetch_models(), lambda models: {"data": models}
        )

    return mcp


def main(argv: list[str] | None = None) -> int:
    """Run the proxy over the configured MCP transport.

    Transport comes from SPEECHRAIL_MCP_TRANSPORT (stdio | streamable-http)
    or from ``--transport`` on the command line.  Defaults to stdio for
    host-local MCP clients (Claude Code / Cursor / Open-WebUI agent).

    streamable-http binds SPEECHRAIL_MCP_HOST:SPEECHRAIL_MCP_PORT (or
    ``--host``/``--port``), default 127.0.0.1:8202. stdio ignores both.
    """
    args = argv if argv is not None else list(sys.argv[1:])
    transport = os.getenv("SPEECHRAIL_MCP_TRANSPORT", "stdio")
    host = _host_from_env()
    port = _port_from_env()
    index = 0
    while index < len(args):
        arg = args[index]
        if arg in ("--help", "-h"):
            print(_USAGE)
            return 0
        if arg not in ("--transport", "--host", "--port") or index + 1 >= len(args):
            print(_USAGE, file=sys.stderr)
            return 2
        value = args[index + 1]
        if arg == "--transport":
            transport = value
        elif arg == "--host":
            host = value
        else:
            try:
                port = int(value)
            except ValueError:
                print(f"invalid port {value!r}", file=sys.stderr)
                return 2
            if not 1 <= port <= 65535:
                print(f"invalid port {value!r}", file=sys.stderr)
                return 2
        index += 2
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
    if validated == "streamable-http":
        server.run(transport=validated, host=host, port=port)
    else:
        server.run(transport=validated)
    return 0
