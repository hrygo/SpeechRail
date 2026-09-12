"""Path-free provenance for a newly registered, generated voice reference."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, StrictInt


class VoiceCreation(BaseModel):
    """Immutable provenance, not a claim of speaker-identity validation."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    origin: Literal["generated"] = "generated"
    method: Literal["voice_design_reference_v1"] = "voice_design_reference_v1"
    model_artifact: str = Field(pattern=r"^[a-z0-9._-]{1,128}$")
    model_revision: str = Field(pattern=r"^[0-9a-f]{40}$")
    seed: StrictInt = Field(ge=0, le=2**32 - 1)
    instruction_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    reference_text_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    reference_audio_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    preprocessing_version: Literal["energy_v1"] = "energy_v1"
