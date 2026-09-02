"""Validated ASR results shared by HTTP, realtime and compatibility edges."""

from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field, model_validator

from speechrail.domain.diarization import DiarizationSpeaker


class TranscriptWord(BaseModel):
    model_config = ConfigDict(frozen=True)

    word: str = Field(min_length=1, max_length=10_000)
    start_ms: int = Field(ge=0)
    end_ms: int = Field(ge=0)

    @model_validator(mode="after")
    def validate_range(self) -> TranscriptWord:
        if self.end_ms < self.start_ms:
            raise ValueError("end_ms must not precede start_ms")
        return self


class TranscriptSegment(BaseModel):
    model_config = ConfigDict(frozen=True)

    id: int = Field(ge=0)
    start_ms: int = Field(ge=0)
    end_ms: int = Field(ge=0)
    text: str = Field(min_length=1, max_length=100_000)
    language: str | None = Field(default=None, max_length=64)
    speaker: str | None = Field(default=None, max_length=200)
    speakers: tuple[DiarizationSpeaker, ...] = ()
    speaker_revision: int | None = Field(default=None, ge=1)
    partial: bool = False
    source_epoch: int = Field(default=0, ge=0)

    @model_validator(mode="after")
    def validate_segment(self) -> TranscriptSegment:
        if self.end_ms < self.start_ms:
            raise ValueError("end_ms must not precede start_ms")
        if not self.text.strip():
            raise ValueError("text must not be blank")
        return self


class TranscriptWindow(BaseModel):
    """One source epoch state; partial text is mutually exclusive with finality."""

    model_config = ConfigDict(frozen=True)

    source_epoch: int = Field(ge=0)
    sequence: int = Field(default=0, ge=0)
    partial: str | None = Field(default=None, max_length=100_000)
    segments: tuple[TranscriptSegment, ...] = ()
    final: bool | None = None

    @model_validator(mode="after")
    def validate_window(self) -> TranscriptWindow:
        if self.partial is not None and not self.partial.strip():
            raise ValueError("partial must not be blank")
        if self.partial is not None and self.final is True:
            raise ValueError("partial window cannot be final")
        if any(segment.source_epoch != self.source_epoch for segment in self.segments):
            raise ValueError("all segments must share source_epoch")
        if self.final is None:
            object.__setattr__(self, "final", self.partial is None)
        return self

    @property
    def is_final(self) -> bool:
        return self.final is True


class TranscriptResult(BaseModel):
    model_config = ConfigDict(frozen=True)

    request_id: str = Field(min_length=1, max_length=200)
    model_id: str = Field(min_length=1, max_length=200)
    text: str = Field(default="", max_length=100_000)
    language: str | None = Field(default=None, max_length=64)
    duration_ms: int = Field(ge=0)
    segments: tuple[TranscriptSegment, ...] = ()
    words: tuple[TranscriptWord, ...] = ()
