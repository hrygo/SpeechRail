"""Vendor-neutral chunk-level timing sidecar contracts for TTS."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from speechrail.domain.tts_text_planner import PLANNER_VERSION

TTS_TIMING_SCHEMA: Literal["tts_timing_v1"] = "tts_timing_v1"


class TtsTimingChunk(BaseModel):
    """One planner chunk mapped onto the final PCM sample domain."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    planner_chunk: int = Field(ge=0)
    text_start: int = Field(ge=0)
    text_end: int = Field(ge=0)
    audio_start_sample: int = Field(ge=0)
    audio_end_sample: int = Field(ge=0)
    timing_quality: Literal["chunk"] = "chunk"

    @model_validator(mode="after")
    def validate_ranges(self) -> TtsTimingChunk:
        if self.text_end < self.text_start:
            raise ValueError("text timing span is reversed")
        if self.audio_end_sample < self.audio_start_sample:
            raise ValueError("audio timing span is reversed")
        return self


class TtsTimingSidecar(BaseModel):
    """Completed chunk timing over normalized spoken text and final PCM samples."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    schema_version: Literal["tts_timing_v1"] = TTS_TIMING_SCHEMA
    timing_quality: Literal["chunk"] = "chunk"
    coordinate_space: Literal[
        "normalized_spoken_unicode_codepoints"
    ] = "normalized_spoken_unicode_codepoints"
    planner_version: Literal["tts_bounded_v1"] = "tts_bounded_v1"
    sample_rate: int = Field(gt=0)
    text_length: int = Field(ge=0)
    total_samples: int = Field(ge=0)
    chunks: tuple[TtsTimingChunk, ...]

    @model_validator(mode="after")
    def validate_contiguous_ranges(self) -> TtsTimingSidecar:
        previous_audio = 0
        previous_text = 0
        for index, chunk in enumerate(self.chunks):
            if chunk.planner_chunk != index:
                raise ValueError("planner chunk indexes must be contiguous")
            if chunk.audio_start_sample != previous_audio:
                raise ValueError("audio timing chunks must be contiguous")
            if chunk.text_start != previous_text:
                raise ValueError("text timing chunks must be contiguous")
            if chunk.text_end > self.text_length:
                raise ValueError("text timing span exceeds normalized text")
            previous_audio = chunk.audio_end_sample
            previous_text = chunk.text_end
        if previous_audio != self.total_samples:
            raise ValueError("timing chunks do not conserve output samples")
        if self.chunks and previous_text != self.text_length:
            raise ValueError("timing chunks do not cover normalized text")
        if not self.chunks and (self.text_length or self.total_samples):
            raise ValueError("non-empty timing domain requires chunks")
        return self


__all__ = [
    "TTS_TIMING_SCHEMA",
    "TtsTimingChunk",
    "TtsTimingSidecar",
]
