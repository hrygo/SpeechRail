"""Canonical model resolution, TTS plan roles, and explicit capability checks."""

from __future__ import annotations

from collections.abc import Iterable
from types import MappingProxyType
from typing import Final

from speechrail.config.model_catalog import ModelRole
from speechrail.config.profiles import Capability, RuntimeProfile

# TTS is routed by the plan role that owns the weights, never by a directory
# name or a profile label.  ``voice_design`` is deliberately excluded from the
# runtime roles: it is only reachable from a voice_design task, never from
# ordinary synthesis or the incremental stream.
TTS_RUNTIME_ROLES: Final[tuple[ModelRole, ModelRole]] = ("tts_custom_voice", "tts_base")
VOICE_DESIGN_ROLE: Final[ModelRole] = "voice_design"

# The vendor engine names the same routes differently.  The mapping is explicit
# so a worker identity that does not match its plan role fails closed.
ENGINE_VARIANT_BY_ROLE: Final = MappingProxyType(
    {
        "tts_custom_voice": "custom_voice",
        "tts_base": "base",
        "voice_design": "voice_design",
    }
)
ROLE_BY_ENGINE_VARIANT: Final = MappingProxyType(
    {variant: role for role, variant in ENGINE_VARIANT_BY_ROLE.items()}
)


def engine_variant_for_role(role: ModelRole) -> str:
    """Return the vendor model variant that serves one plan role."""

    try:
        return ENGINE_VARIANT_BY_ROLE[role]
    except KeyError as exc:
        raise ValueError(f"unsupported TTS plan role: {role}") from exc


def role_for_engine_variant(variant: str) -> ModelRole:
    """Return the plan role that owns one vendor model variant."""

    try:
        return ROLE_BY_ENGINE_VARIANT[variant]
    except KeyError as exc:
        raise ValueError(f"unsupported TTS engine variant: {variant}") from exc


class ModelRegistry:
    def __init__(
        self,
        *,
        canonical_model_id: str,
        aliases: Iterable[str],
        profiles: Iterable[RuntimeProfile],
    ) -> None:
        canonical = canonical_model_id.strip()
        if not canonical:
            raise ValueError("canonical_model_id must not be empty")
        self._canonical = canonical
        self._aliases = {canonical, *(alias.strip() for alias in aliases if alias.strip())}
        self._profiles = tuple(profiles)
        if not self._profiles:
            raise ValueError("at least one runtime profile is required")

    @property
    def canonical_model_id(self) -> str:
        return self._canonical

    def resolve(self, model_id: str) -> str:
        if model_id.strip() not in self._aliases:
            raise ValueError("model_not_found")
        return self._canonical

    def require_capability(self, model_id: str, capability: Capability) -> RuntimeProfile:
        self.resolve(model_id)
        for profile in self._profiles:
            if capability in profile.capabilities:
                return profile
        raise ValueError("capability_not_supported")
