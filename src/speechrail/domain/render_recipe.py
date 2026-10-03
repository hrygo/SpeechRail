"""Immutable description of one render that actually executed.

The recipe answers "what reached the acoustic model", not "what the caller
asked for". A fact that was never observed stays missing: a partial recipe
never receives a digest, so no client can mistake an unknown runtime or seed
policy for a reusable, reproducible identity.

This module holds types and canonical encoding only. Resource planning, model
selection and worker execution stay where they already live.
"""

from __future__ import annotations

import hashlib
import json
import math
from dataclasses import dataclass
from typing import Any, Literal

RENDER_RECIPE_SCHEMA_VERSION = "render_recipe_v1"
RENDER_PLAN_SCHEMA_VERSION = "render_plan_v1"

RecipeState = Literal["complete", "partial"]

#: Explicit value, not missing knowledge: this render used no pronunciation set.
PRONUNCIATION_UNUSED = "unused"

#: Facts that must be known before a recipe may claim completeness. Each entry
#: is the path used in ``missing_fields`` and in the public recipe payload.
REQUIRED_RECIPE_FIELDS: tuple[str, ...] = (
    "content.raw_text_sha256",
    "content.acoustic_text_sha256",
    "content.normalization_revision",
    "content.planner_revision",
    "content.pronunciation_revision",
    "voice.id",
    "voice.revision",
    "model.role",
    "model.artifact",
    "model.artifact_revision",
    "model.engine_revision",
    "parameters.effective_speed",
    "parameters.effective_language",
    "parameters.seed_policy",
    "parameters.output_format",
    "parameters.sample_rate",
    "parameters.channels",
)

_SHA256_LENGTH = 64


def _require_sha256(name: str, value: str | None) -> None:
    if value is None:
        return
    if len(value) != _SHA256_LENGTH or any(
        char not in "0123456789abcdef" for char in value
    ):
        raise ValueError(f"invalid_{name}")


def _require_optional_str(name: str, value: str | None) -> None:
    if value is not None and (not isinstance(value, str) or not value):
        raise ValueError(f"invalid_{name}")


@dataclass(frozen=True, slots=True)
class RenderRecipe:
    """One executed render, described only by verifiable facts.

    ``output_format``, ``sample_rate`` and ``channels`` are required because
    the receipt fixes them before any audio exists. Every other field is
    optional precisely so an unobserved fact can be reported as unknown.
    """

    output_format: str
    sample_rate: int
    channels: int
    raw_text_sha256: str | None = None
    acoustic_text_sha256: str | None = None
    normalization_revision: str | None = None
    planner_revision: str | None = None
    planner_max_chars: int | None = None
    pronunciation_set_id: str | None = None
    pronunciation_revision: str | None = None
    voice_id: str | None = None
    voice_revision: str | None = None
    voice_mode: str | None = None
    model_role: str | None = None
    model_artifact: str | None = None
    model_artifact_revision: str | None = None
    engine_revision: str | None = None
    effective_speed: float | None = None
    effective_language: str | None = None
    seed_policy: str | None = None
    observed_sampling_parameters: dict[str, Any] | None = None

    def __post_init__(self) -> None:
        if not self.output_format:
            raise ValueError("invalid_output_format")
        if type(self.sample_rate) is not int or self.sample_rate <= 0:
            raise ValueError("invalid_sample_rate")
        if type(self.channels) is not int or self.channels <= 0:
            raise ValueError("invalid_channels")
        _require_sha256("raw_text_sha256", self.raw_text_sha256)
        _require_sha256("acoustic_text_sha256", self.acoustic_text_sha256)
        for name in (
            "normalization_revision",
            "planner_revision",
            "pronunciation_set_id",
            "pronunciation_revision",
            "voice_id",
            "voice_revision",
            "voice_mode",
            "model_role",
            "model_artifact",
            "model_artifact_revision",
            "engine_revision",
            "effective_language",
            "seed_policy",
        ):
            _require_optional_str(name, getattr(self, name))
        if self.planner_max_chars is not None and (
            type(self.planner_max_chars) is not int or self.planner_max_chars <= 0
        ):
            raise ValueError("invalid_planner_max_chars")
        if self.effective_speed is not None and (
            isinstance(self.effective_speed, bool)
            or not isinstance(self.effective_speed, (int, float))
            or not math.isfinite(float(self.effective_speed))
        ):
            raise ValueError("invalid_effective_speed")

    @property
    def missing_fields(self) -> tuple[str, ...]:
        """Required facts this render never observed, in a stable order."""

        observed: dict[str, bool] = {
            "content.raw_text_sha256": self.raw_text_sha256 is not None,
            "content.acoustic_text_sha256": self.acoustic_text_sha256 is not None,
            "content.normalization_revision": self.normalization_revision is not None,
            "content.planner_revision": self.planner_revision is not None,
            "content.pronunciation_revision": self.pronunciation_revision is not None,
            "voice.id": self.voice_id is not None,
            "voice.revision": self.voice_revision is not None,
            "model.role": self.model_role is not None,
            "model.artifact": self.model_artifact is not None,
            "model.artifact_revision": self.model_artifact_revision is not None,
            "model.engine_revision": self.engine_revision is not None,
            "parameters.effective_speed": self.effective_speed is not None,
            "parameters.effective_language": self.effective_language is not None,
            "parameters.seed_policy": self.seed_policy is not None,
            "parameters.output_format": bool(self.output_format),
            "parameters.sample_rate": self.sample_rate > 0,
            "parameters.channels": self.channels > 0,
        }
        return tuple(name for name in REQUIRED_RECIPE_FIELDS if not observed[name])

    @property
    def state(self) -> RecipeState:
        return "partial" if self.missing_fields else "complete"

    def canonical_payload(self) -> dict[str, Any]:
        """The facts a digest is taken over. Never includes user text."""

        return {
            "schema_version": RENDER_RECIPE_SCHEMA_VERSION,
            "content": {
                "raw_text_sha256": self.raw_text_sha256,
                "acoustic_text_sha256": self.acoustic_text_sha256,
                "normalization_revision": self.normalization_revision,
                "planner_revision": self.planner_revision,
                "planner_max_chars": self.planner_max_chars,
                "pronunciation_set_id": self.pronunciation_set_id,
                "pronunciation_revision": self.pronunciation_revision,
            },
            "voice": {
                "id": self.voice_id,
                "revision": self.voice_revision,
                "mode": self.voice_mode,
            },
            "model": {
                "role": self.model_role,
                "artifact": self.model_artifact,
                "artifact_revision": self.model_artifact_revision,
                "engine_revision": self.engine_revision,
            },
            "parameters": {
                "effective_speed": (
                    float(self.effective_speed)
                    if self.effective_speed is not None
                    else None
                ),
                "effective_language": self.effective_language,
                "seed_policy": self.seed_policy,
                "observed_sampling_parameters": self.observed_sampling_parameters,
                "output_format": self.output_format,
                "sample_rate": self.sample_rate,
                "channels": self.channels,
            },
        }

    def canonical_bytes(self) -> bytes:
        return json.dumps(
            self.canonical_payload(),
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")

    @property
    def digest(self) -> str | None:
        """SHA-256 of the canonical recipe, or None while facts are missing."""

        if self.missing_fields:
            return None
        return hashlib.sha256(self.canonical_bytes()).hexdigest()

    def to_dict(self) -> dict[str, Any]:
        payload = self.canonical_payload()
        payload["state"] = self.state
        payload["missing_fields"] = list(self.missing_fields)
        payload["digest"] = self.digest
        return payload


@dataclass(frozen=True, slots=True)
class RenderPlanIdentity:
    """One request-time execution descriptor.

    The plan identifies how a render would be executed, never what it said.
    Two different scripts can share a plan; content reuse keys must use the
    recipe or the text hashes instead.
    """

    plan_id: str
    digest: str


def render_plan_identity(recipe: RenderRecipe) -> RenderPlanIdentity:
    """Derive the plan identity from the execution-descriptor subset."""

    payload = {
        "schema_version": RENDER_PLAN_SCHEMA_VERSION,
        "voice": {
            "id": recipe.voice_id,
            "revision": recipe.voice_revision,
            "mode": recipe.voice_mode,
        },
        "model": {
            "role": recipe.model_role,
            "artifact": recipe.model_artifact,
            "artifact_revision": recipe.model_artifact_revision,
        },
        "parameters": {
            "effective_speed": (
                float(recipe.effective_speed)
                if recipe.effective_speed is not None
                else None
            ),
            "effective_language": recipe.effective_language,
            "pronunciation_revision": recipe.pronunciation_revision,
            "output_format": recipe.output_format,
            "sample_rate": recipe.sample_rate,
            "channels": recipe.channels,
        },
        "content_policy": {
            "normalization_revision": recipe.normalization_revision,
            "planner_revision": recipe.planner_revision,
            "planner_max_chars": recipe.planner_max_chars,
        },
    }
    canonical = json.dumps(
        payload,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    digest = hashlib.sha256(canonical).hexdigest()
    return RenderPlanIdentity(plan_id=f"plan_{digest[:32]}", digest=digest)


def text_sha256(text: str) -> str:
    """Hash text for correlation only. Not an anonymization guarantee."""

    return hashlib.sha256(text.encode("utf-8")).hexdigest()
