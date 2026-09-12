"""Resolve public voices into model-specific TTS bindings."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from types import MappingProxyType
from typing import Final

from speechrail.domain.tts import (
    VoiceCapabilities,
    VoiceProfile,
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
_SUPPORTED_VARIANTS: Final[frozenset[str]] = frozenset({"voice_design", "custom_voice", "base"})


@dataclass(frozen=True, slots=True)
class VoiceBinding:
    """A normalized TTS backend voice binding."""

    variant: str
    voice: str
    speaker: str | None
    instruction: str | None
    is_clone: bool = False
    ref_audio_path: str | None = None
    ref_text: str | None = None

    @property
    def capabilities(self) -> VoiceCapabilities:
        """Return public capabilities without local paths."""

        return VoiceCapabilities(
            variant=self.variant,
            supports_speaker=self.speaker is not None,
            supports_instruction=self.instruction is not None,
            supports_clone=self.is_clone,
        )


def resolve_binding(
    variant: str, voice: str, *, profile: VoiceProfile | None = None
) -> VoiceBinding:
    """Resolve a public voice for a model variant while preserving alias casing."""

    if variant not in _SUPPORTED_VARIANTS:
        raise ValueError(f"unsupported voice variant: {variant}")
    if not isinstance(voice, str):
        raise ValueError(f"unknown preset voice: {voice}")

    preset_voice = resolve_voice(voice)
    if profile is None:
        profile = get_voice_profile(preset_voice)
    elif profile.id != preset_voice:
        raise ValueError("voice profile does not match requested voice")
    if variant == "base":
        if profile.mode != "clone":
            raise ValueError(f"voice {voice} is not a clone voice for base variant")
        return VoiceBinding(
            variant=variant,
            voice=preset_voice,
            speaker=None,
            instruction=None,
            is_clone=True,
            ref_audio_path=profile.audio_path,
            ref_text=profile.ref_text,
        )

    if variant == "voice_design":
        if profile.mode == "clone":
            raise ValueError(
                f"voice {voice} requires base clone capability (quality tier); "
                "voice_design is reserved for prompt-created voices"
            )
        return VoiceBinding(
            variant=variant,
            voice=preset_voice,
            speaker=None,
            instruction=profile.instruction,
            is_clone=False,
        )

    if profile.mode == "clone":
        raise ValueError(
            f"voice {voice} requires base clone capability (quality tier); "
            "custom_voice variant does not support voice cloning"
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
        is_clone=False,
    )


__all__ = ["VoiceBinding", "resolve_binding"]
