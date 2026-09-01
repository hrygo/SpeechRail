"""Typed, vendor-neutral inference ports for ASR and TTS backends."""

from __future__ import annotations

from collections.abc import AsyncIterator
from typing import Literal, Protocol

from pydantic import BaseModel, ConfigDict, Field

from speechrail.domain.contracts import TranscriptResult, TranscriptSegment
from speechrail.domain.diarization import DiarizationConfig, DiarizationUpdate


class TranscriptionRequest(BaseModel):
    """Validated PCM16 batch ASR input passed to a backend adapter."""

    model_config = ConfigDict(frozen=True)

    request_id: str = Field(min_length=1, max_length=200)
    audio: bytes = Field(min_length=2, max_length=40 * 1024 * 1024)
    language: str | None = Field(default=None, max_length=64)
    prompt: str = Field(default="", max_length=10_000)


class SpeechRequest(BaseModel):
    """Validated TTS request independent of a vendor voice implementation."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    text: str = Field(min_length=1, max_length=100_000)
    voice: str = Field(min_length=1, max_length=200)
    output_format: Literal["pcm16", "wav"] = "pcm16"
    sample_rate: int = Field(default=24_000, ge=8_000, le=48_000)
    speed: float = Field(default=1.0, ge=0.25, le=4.0)
    language: str = Field(default="auto", min_length=1, max_length=64)


class AudioChunk(BaseModel):
    """One ordered PCM or container chunk from a speech backend."""

    model_config = ConfigDict(frozen=True)

    response_id: str = Field(min_length=1, max_length=200)
    chunk_index: int = Field(ge=0)
    audio: bytes = Field(min_length=1, max_length=4 * 1024 * 1024)


class BatchTranscriber(Protocol):
    async def transcribe(self, request: TranscriptionRequest) -> TranscriptResult: ...


class StreamingTranscriber(Protocol):
    def stream(self, audio: AsyncIterator[bytes]) -> AsyncIterator[TranscriptResult]: ...


class SpeechSynthesizer(Protocol):
    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]: ...


class StreamingAsrEvent(BaseModel):
    """Vendor-neutral incremental event from one realtime ASR backend session."""

    model_config = ConfigDict(frozen=True)

    kind: Literal["partial", "completed", "error"]
    text: str = Field(default="", max_length=100_000)
    language: str | None = Field(default=None, max_length=64)
    segments: tuple[TranscriptSegment, ...] = ()
    error_code: str | None = Field(default=None, max_length=200)


class RealtimeAsrSession(Protocol):
    """One non-resumable backend session that consumes PCM while events stream out."""

    async def connect(self) -> None: ...

    async def append_audio(self, audio: bytes) -> None: ...

    async def flush(self) -> None: ...

    async def commit(self) -> None: ...

    def events(self) -> AsyncIterator[StreamingAsrEvent]: ...

    async def close(self) -> None: ...


class RealtimeAsrFactory(Protocol):
    """Creates a new backend session after the public v2 session is configured."""

    def create(self, *, language: str | None, prompt: str) -> RealtimeAsrSession: ...


class DiarizationSession(Protocol):
    """One bounded acoustic attribution session owned by a public runtime."""

    async def append_audio(self, audio: bytes) -> None: ...

    async def annotate(self, segments: tuple[TranscriptSegment, ...]) -> DiarizationUpdate: ...

    async def finalize(self) -> DiarizationUpdate: ...

    async def close(self) -> None: ...


class DiarizationEngine(Protocol):
    """Creates a session-local diarization stream after input validation."""

    def create(self, *, config: DiarizationConfig) -> DiarizationSession: ...
