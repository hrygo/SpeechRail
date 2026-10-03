"""Vendor-neutral sampling facts for one executed TTS render.

The worker reports the sampler it *actually* used. A request that asked for
a seed and got one is `caller_fixed`; a clone derives its own; a voice-design
render inherits the profile's seed. When nothing seeded the stream, the
policy says so explicitly — the recipe must never present an unfixed sampler
as a reproducible one.
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

TTS_SAMPLING_SCHEMA: Literal["tts_sampling_v1"] = "tts_sampling_v1"

SeedPolicy = Literal[
    "caller_fixed",
    "clone_reference_derived",
    "voice_profile_fixed",
    "unseeded_sampler",
]


class TtsSamplingObservation(BaseModel):
    """The sampling policy and parameters that produced one render's audio."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    schema_version: Literal["tts_sampling_v1"] = TTS_SAMPLING_SCHEMA
    seed_policy: SeedPolicy
    #: The seed actually applied to the sampling stream, if any.
    seed: int | None = Field(default=None, ge=0)
    temperature: float = Field(ge=0)
    top_p: float = Field(gt=0, le=1)
    repetition_penalty: float = Field(gt=0)

    @property
    def is_reproducible(self) -> bool:
        """Whether the same inputs would drive the same sampling stream.

        This is a statement about the sampler only. It says nothing about
        whether two renders sound alike, and never authorises reuse on its own.
        """

        return self.seed_policy != "unseeded_sampler"

    def recipe_payload(self) -> dict[str, object]:
        """The shape stored on a render recipe's parameters section."""

        return {
            "seed_policy": self.seed_policy,
            "seed": self.seed,
            "temperature": self.temperature,
            "top_p": self.top_p,
            "repetition_penalty": self.repetition_penalty,
        }
