"""Resolve public voices into model-specific TTS bindings."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from types import MappingProxyType
from typing import Final

from speechrail.domain.tts import (
    VoiceCapabilities,
    get_voice_profile,
    resolve_voice,
)

_CUSTOM_VOICE_SPEAKERS: Final[Mapping[str, str]] = MappingProxyType(
    {
        "serena": "Serena",
        "vivian": "Vivian",
        "uncle_fu": "Uncle_Fu",
        "dylan": "Dylan",
        "eric": "Eric",
        "ryan": "Ryan",
        "aiden": "Aiden",
        "ono_anna": "Ono_Anna",
        "sohee": "Sohee",
    }
)
_SUPPORTED_VARIANTS: Final[frozenset[str]] = frozenset({"voice_design", "custom_voice"})


@dataclass(frozen=True, slots=True)
class VoiceBinding:
    """A normalized TTS backend voice binding."""

    variant: str
    voice: str
    speaker: str | None
    instruction: str | None

    @property
    def capabilities(self) -> VoiceCapabilities:
        """Return public capabilities without local paths."""

        return VoiceCapabilities(
            variant=self.variant,
            supports_speaker=self.speaker is not None,
            supports_instruction=self.instruction is not None,
        )


def resolve_binding(variant: str, voice: str) -> VoiceBinding:
    """Resolve a public voice for a model variant while preserving alias casing."""

    if variant not in _SUPPORTED_VARIANTS:
        raise ValueError(f"unsupported voice variant: {variant}")
    if not isinstance(voice, str):
        raise ValueError(f"unknown preset voice: {voice}")

    preset_voice = resolve_voice(voice)
    profile = get_voice_profile(preset_voice)
    if variant == "voice_design":
        return VoiceBinding(
            variant=variant,
            voice=preset_voice,
            speaker=None,
            instruction=profile.instruction,
        )

    try:
        speaker = _CUSTOM_VOICE_SPEAKERS[preset_voice]
    except KeyError as exc:
        raise ValueError(f"voice has no custom_voice speaker binding: {preset_voice}") from exc
    return VoiceBinding(
        variant=variant,
        voice=preset_voice,
        speaker=speaker,
        instruction=None,
    )


__all__ = ["VoiceBinding", "resolve_binding"]
