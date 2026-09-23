"""Pydantic result models for the SpeechRail MCP proxy tools.

The MCP SDK derives each tool's published ``outputSchema`` from its return
annotation and validates the result against it, emitting ``structuredContent``.
A strict model would turn a valid SpeechRail payload into a failed tool call,
so every model uses ``extra="allow"`` and defaults all non-key fields: unknown
keys survive and missing optionals fall back to defaults, while the known
fields keep the advertised schema informative.
"""

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field


class AudioArtifact(BaseModel):
    """A synthesized audio file written to the proxy host."""

    model_config = ConfigDict(extra="allow")

    audio_path: str
    host: str = "mcp_host"
    content_type: str
    output_format: str
    bytes: int
    language: str | None = None
    sample_rate: int | None = None
    duration_seconds: float | None = None
    request_id: str | None = None
    voice_revision: str | None = None
    model_revision: str | None = None
    validation_policy: str | None = None
    validation_state: dict[str, Any] | None = None


class TranscriptSegment(BaseModel):
    """One transcript segment, optionally speaker-attributed."""

    model_config = ConfigDict(extra="allow")

    speaker: str | None = None
    start: float | None = None
    end: float | None = None
    text: str | None = None


class TranscriptWord(BaseModel):
    """One timestamped word from a verbose transcript."""

    model_config = ConfigDict(extra="allow")

    word: str | None = None
    start: float | None = None
    end: float | None = None


class TranscribeResult(BaseModel):
    """A transcription response in any SpeechRail output shape."""

    model_config = ConfigDict(extra="allow")

    text: str | None = None
    segments: list[TranscriptSegment] | None = None
    words: list[TranscriptWord] | None = None
    language: str | None = None
    duration: float | None = None


class ModelEntry(BaseModel):
    """One ``GET /v1/models`` entry (artifact, alias or resolved target)."""

    model_config = ConfigDict(extra="allow")

    id: str | None = None
    object: str | None = None
    owned_by: str | None = None
    profile: str | None = None
    family: str | None = None
    variant: str | None = None
    resolves_to: str | None = None
    capabilities: dict[str, Any] | None = None


class VoiceEntry(BaseModel):
    """One safe voice entry projected from the effective capability snapshot."""

    model_config = ConfigDict(extra="allow")

    id: str | None = None
    name: str | None = None
    mode: str | None = None
    available: bool | None = None
    variant: str | None = None
    is_default: bool | None = None
    aliases: list[str] | None = None
    capabilities: dict[str, Any] | None = None
    validation_state: dict[str, Any] | None = None
    validated_for: list[str] | None = None
    production_ready: bool | None = None
    production_ready_reason: str | None = None


class Readiness(BaseModel):
    """Worker readiness flags from ``GET /health``."""

    model_config = ConfigDict(extra="allow")

    asr: bool = False
    tts: bool = False
    diarization: bool = False


class JobsStatus(BaseModel):
    """Durable-job spool and runner status."""

    model_config = ConfigDict(extra="allow")

    spool_ready: bool = False
    runner_active: bool = False


class RealtimeStatus(BaseModel):
    """Realtime VAD and streaming state summary."""

    model_config = ConfigDict(extra="allow")

    vad: dict[str, Any] | None = None
    streaming_state: str | None = None
    asr_state: str | None = None
    tts_state: str | None = None
    orchestration: str = "caller"
    server_llm: bool = False
    conversation_state: bool = False
    websocket_path: str = "/v1/realtime"
    mcp_realtime: bool = False


class DescribeResult(BaseModel):
    """Current observations plus the required effective capability snapshot."""

    model_config = ConfigDict(extra="allow")

    tier: str
    profile: str | None = None
    profile_consistency: Literal["consistent", "inconsistent", "unknown"] = "unknown"
    diarization_ready: bool = False
    readiness: Readiness
    tts_lifecycle: dict[str, Any] | None = None
    realtime: RealtimeStatus
    clone_supported: bool = False
    preview_supported: bool = False
    jobs: JobsStatus
    models: list[ModelEntry] = Field(default_factory=list)
    voices: list[VoiceEntry] = Field(default_factory=list)
    effective_capabilities: dict[str, Any]


class VoiceRecord(BaseModel):
    """A created or deleted persistent voice record."""

    model_config = ConfigDict(extra="allow")

    id: str | None = None
    name: str | None = None
    mode: str | None = None
    available: bool | None = None
    availability_reason: str | None = None
    capabilities: dict[str, Any] | None = None
    variant: str | None = None
    revision: str | None = None
    validation_state: dict[str, Any] | None = None
    validated_for: list[str] | None = None
    production_ready: bool | None = None
    production_ready_reason: str | None = None
    synthesis_validation: str | None = None


class VoiceValidationResult(BaseModel):
    """Reference/output validation result for one current voice revision."""

    model_config = ConfigDict(extra="allow")

    status: str | None = None
    run_id: str | None = None
    failure_codes: list[str] = Field(default_factory=list)
    validation_persisted: bool | None = None


class JobRecord(BaseModel):
    """A durable transcription/speech job record."""

    model_config = ConfigDict(extra="allow")

    id: str | None = None
    kind: str | None = None
    state: str | None = None
    error_code: str | None = None
    error_message: str | None = None
    result_ref: str | None = None
    params: dict[str, Any] | None = None
    attempts: int | None = None
    queue_position: int | None = None
    eta_seconds: float | None = None
    deadline: str | None = None


class JobListResult(BaseModel):
    """Owner-scoped paginated durable-job listing."""

    model_config = ConfigDict(extra="allow")

    data: list[JobRecord] = Field(default_factory=list)
    next_cursor: str | None = None
    has_more: bool = False


class JobResultArtifact(BaseModel):
    """A job result materialized as a local file on the MCP host."""

    model_config = ConfigDict(extra="allow")

    result_path: str
    host: str = "mcp_host"
    content_type: str
    bytes: int
    job_id: str | None = None
