"""Canonical model resolution and explicit capability checks."""

from __future__ import annotations

from collections.abc import Iterable

from speechrail.config.profiles import Capability, RuntimeProfile


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
