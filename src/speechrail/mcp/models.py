"""Pydantic result models for the SpeechRail MCP proxy tools.

The MCP SDK derives each tool's published ``outputSchema`` from its return
annotation and validates the result against it, emitting ``structuredContent``.
A strict model would turn a valid SpeechRail payload into a failed tool call,
so every model uses ``extra="allow"`` and defaults all non-key fields: unknown
keys survive and missing optionals fall back to defaults, while the known
fields keep the advertised schema informative.
"""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel, ConfigDict, Field


class AudioArtifact(BaseModel):
    """A synthesized audio file written to the proxy host."""

    model_config = ConfigDict(extra="allow")

    audio_path: str
    content_type: str
    output_format: str
    bytes: int


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
    """One ``GET /v1/voices`` entry with its discriminators."""

    model_config = ConfigDict(extra="allow")

    id: str | None = None
    name: str | None = None
    mode: str | None = None
    available: bool | None = None
    variant: str | None = None
    is_default: bool | None = None
    aliases: list[str] | None = None
    capabilities: dict[str, Any] | None = None


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


class DescribeResult(BaseModel):
    """The merged capability snapshot returned by ``describe``."""

    model_config = ConfigDict(extra="allow")

    tier: str
    profile: str | None = None
    diarization_ready: bool = False
    readiness: Readiness
    tts_lifecycle: dict[str, Any] | None = None
    realtime: RealtimeStatus
    clone_supported: bool = False
    preview_supported: bool = False
    jobs: JobsStatus
    models: list[ModelEntry] = Field(default_factory=list)
    voices: list[VoiceEntry] = Field(default_factory=list)


class VoiceRecord(BaseModel):
    """A created or deleted persistent voice record."""

    model_config = ConfigDict(extra="allow")

    id: str | None = None
    name: str | None = None
    mode: str | None = None
    available: bool | None = None
    capabilities: dict[str, Any] | None = None


class JobRecord(BaseModel):
    """A durable transcription/speech job record."""

    model_config = ConfigDict(extra="allow")

    id: str | None = None
    kind: str | None = None
    state: str | None = None
    result_ref: str | None = None
    params: dict[str, Any] | None = None
