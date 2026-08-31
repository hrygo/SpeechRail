"""Typed, vendor-neutral inference ports for ASR and TTS backends."""

from __future__ import annotations

from collections.abc import AsyncIterator
from typing import Literal, Protocol

from pydantic import BaseModel, ConfigDict, Field

from speechrail.domain.contracts import TranscriptResult


class TranscriptionRequest(BaseModel):
    """Validated PCM16 batch ASR input passed to a backend adapter."""

    model_config = ConfigDict(frozen=True)

    request_id: str = Field(min_length=1, max_length=200)
    audio: bytes = Field(min_length=2, max_length=40 * 1024 * 1024)
    language: str | None = Field(default=None, max_length=64)
    prompt: str = Field(default="", max_length=10_000)


class SpeechRequest(BaseModel):
    """Validated TTS request independent of a vendor voice implementation."""

    model_config = ConfigDict(frozen=True)

    text: str = Field(min_length=1, max_length=100_000)
    voice: str = Field(min_length=1, max_length=200)
    output_format: Literal["pcm16", "wav"] = "pcm16"
    sample_rate: int = Field(default=24_000, ge=8_000, le=48_000)
    instructions: str | None = Field(default=None, max_length=10_000)


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
