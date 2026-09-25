"""The single voice-to-plan-role decision for TTS.

Every surface (REST speech, realtime, render jobs, discovery) must resolve the
same voice to the same plan role, because the role decides which weights serve
the request:

* a built-in fixed speaker is served by the CustomVoice artifact;
* a registered clone revision, including one published by the design studio,
  is served by the Base artifact;
* VoiceDesign is reserved for the voice_design task (candidate generation and
  audition) and must never be reachable from ordinary synthesis or the
  incremental stream.

The module stays vendor-neutral and path-free: it only names roles and the
spec/validation keys that bind evidence to one tier and one execution mode.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
from typing import Protocol

from speechrail.config.model_catalog import ModelRole, SpecTier
from speechrail.domain.model_spec import required_spec_artifact
from speechrail.runtime.registry import VOICE_DESIGN_ROLE


class TtsExecutionMode(StrEnum):
    """How one voice is executed, independent of the model that executes it."""

    STREAM = "stream"
    RENDER = "render"


class VoiceRouteContext(Protocol):
    """The only profile fields routing may depend on."""

    @property
    def mode(self) -> str: ...

    @property
    def revision(self) -> str | None: ...


class TtsRouteError(ValueError):
    """A voice cannot be routed to a plan role on this service."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def route_role_for_mode(mode: str) -> ModelRole:
    """Map one public voice mode to the plan role that owns its weights."""

    if mode == "clone":
        return "tts_base"
    if mode == "system":
        return "tts_custom_voice"
    if mode == "instruction":
        # Instruction voices are design candidates and auditions.  They are
        # served by the voice_design task, never by ordinary synthesis: the
        # target architecture forbids the VoiceDesign model from producing
        # run-time output directly.
        raise TtsRouteError(
            "voice_design_task_required",
            "instruction voices are served by the voice_design task, "
            "not by speech synthesis",
        )
    raise TtsRouteError("voice_mode_unsupported", f"unsupported voice mode: {mode}")


def route_role_for_voice(profile: VoiceRouteContext) -> ModelRole:
    """Map one leased voice profile to its plan role."""

    return route_role_for_mode(profile.mode)


def tts_capability_key(tier: SpecTier, mode: TtsExecutionMode) -> str:
    """Return the evidence key for one tier and execution mode.

    Validation of one combination never proves another, so ``quality.stream``
    and ``quality.render`` (and every other tier) are separate keys.
    """

    return f"{tier}.{mode.value}"


@dataclass(frozen=True, slots=True)
class TtsRouteSelection:
    """One resolved runtime role selection for a voice and execution mode."""

    tier: SpecTier
    mode: TtsExecutionMode
    role: ModelRole
    artifact_key: str
    capability_key: str
    voice_revision: str | None


def select_tts_route(
    *,
    tier: SpecTier,
    mode: TtsExecutionMode,
    profile: VoiceRouteContext,
) -> TtsRouteSelection:
    """Resolve the plan role, artifact, and evidence key for one request."""

    role = route_role_for_voice(profile)
    if role == VOICE_DESIGN_ROLE:
        raise TtsRouteError(
            "voice_design_task_required",
            "voice_design is not a runtime synthesis route",
        )
    artifact_key = required_spec_artifact(tier, role)
    if artifact_key is None:
        raise TtsRouteError(
            "tts_spec_unavailable",
            f"the {tier} tier has no artifact for plan role {role}",
        )
    return TtsRouteSelection(
        tier=tier,
        mode=mode,
        role=role,
        artifact_key=artifact_key,
        capability_key=tts_capability_key(tier, mode),
        voice_revision=profile.revision,
    )


__all__ = [
    "TtsExecutionMode",
    "TtsRouteError",
    "TtsRouteSelection",
    "VoiceRouteContext",
    "route_role_for_mode",
    "route_role_for_voice",
    "select_tts_route",
    "tts_capability_key",
]
