"""Immutable task requests and resolved execution plans."""

from __future__ import annotations

import re
from collections.abc import Mapping
from enum import StrEnum
from types import MappingProxyType
from typing import Literal, Self

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from speechrail.domain.model_spec import ModelRole, SpecTier

TaskKind = Literal["conversation", "caption", "transcription", "render", "voice_design"]
OutputKind = Literal["text", "audio", "alignment", "diarization"]
_TASK_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}")


class RequiredOutput(StrEnum):
    TEXT = "text"
    AUDIO = "audio"
    ALIGNMENT = "alignment"
    DIARIZATION = "diarization"


class AudioFormat(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    kind: Literal["audio/pcm"] = "audio/pcm"
    sample_rate: int = Field(gt=0, le=192_000)
    channels: int = Field(default=1, ge=1, le=8)


class AlignmentOptions(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    granularity: Literal["segment", "word"] = "word"


class DiarizationOptions(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    max_speakers: int | None = Field(default=None, ge=1, le=32)


class TaskRequest(BaseModel):
    """One immutable request before model, voice, and capability resolution."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    task_id: str = Field(min_length=1, max_length=128)
    kind: TaskKind
    asr_spec: SpecTier | None = None
    tts_spec: SpecTier | None = None
    selection_generation: int = Field(gt=0)
    voice_revision: str | None = Field(default=None, min_length=1, max_length=128)
    input_format: AudioFormat
    required_outputs: frozenset[RequiredOutput] = Field(min_length=1)
    alignment_options: AlignmentOptions | None = None
    diarization_options: DiarizationOptions | None = None
    allow_auto: bool = False
    language: str = Field(min_length=2, max_length=16)

    @field_validator("task_id")
    @classmethod
    def validate_task_id(cls, value: str) -> str:
        if _TASK_ID_RE.fullmatch(value) is None:
            raise ValueError("task_id contains unsupported characters")
        return value

    @field_validator("language")
    @classmethod
    def normalize_language(cls, value: str) -> str:
        return value.strip().lower()

    @model_validator(mode="after")
    def validate_required_specs(self) -> Self:
        audio_only = self.required_outputs == frozenset({RequiredOutput.AUDIO})
        if not audio_only and self.asr_spec is None and not self.allow_auto:
            raise ValueError("ASR tasks require asr_spec unless allow_auto is enabled")
        if (
            RequiredOutput.AUDIO in self.required_outputs
            and self.tts_spec is None
            and not self.allow_auto
        ):
            raise ValueError("TTS tasks require tts_spec unless allow_auto is enabled")
        if (
            RequiredOutput.ALIGNMENT in self.required_outputs
            and self.alignment_options is None
        ):
            raise ValueError("alignment output requires alignment_options")
        if (
            RequiredOutput.DIARIZATION in self.required_outputs
            and self.diarization_options is None
        ):
            raise ValueError("diarization output requires diarization_options")
        if (
            RequiredOutput.ALIGNMENT not in self.required_outputs
            and self.alignment_options is not None
        ):
            raise ValueError("alignment_options require the alignment output")
        if (
            RequiredOutput.DIARIZATION not in self.required_outputs
            and self.diarization_options is not None
        ):
            raise ValueError("diarization_options require the diarization output")
        if self.kind == "voice_design" and self.voice_revision is not None:
            raise ValueError(
                "voice_design creates a new revision and cannot bind an existing voice"
            )
        return self


class PlanModel(BaseModel):
    """The path-free model identity bound into one immutable plan."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    spec_id: str = Field(min_length=1, max_length=128)
    role: ModelRole
    tier: SpecTier
    artifact_key: str = Field(min_length=1, max_length=128)
    artifact_revision: str = Field(min_length=40, max_length=40)
    engine_revision: str = Field(min_length=1, max_length=128)


class ResolvedPlan(BaseModel):
    """Immutable, path-free task plan shared by every execution surface."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    plan_id: str = Field(min_length=1, max_length=80)
    task_id: str = Field(min_length=1, max_length=128)
    selection_generation: int = Field(gt=0)
    asr_spec: SpecTier | None
    tts_spec: SpecTier | None
    models: tuple[PlanModel, ...] = Field(min_length=1)
    voice_revision: str | None
    input_format: AudioFormat
    kernel_format: AudioFormat
    output_format: AudioFormat
    limits: Mapping[str, int]
    required_outputs: frozenset[RequiredOutput]
    resource_profile_revision: str = Field(min_length=1, max_length=128)
    capability_evidence_revision: str = Field(min_length=1, max_length=128)
    digest: str = Field(min_length=64, max_length=64)

    @field_validator("limits")
    @classmethod
    def freeze_limits(cls, value: Mapping[str, int]) -> Mapping[str, int]:
        return MappingProxyType(dict(value))


__all__ = [
    "AlignmentOptions",
    "AudioFormat",
    "DiarizationOptions",
    "PlanModel",
    "RequiredOutput",
    "ResolvedPlan",
    "TaskKind",
    "TaskRequest",
]
