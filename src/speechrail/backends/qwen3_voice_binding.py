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
# Public callers name the plan role; worker adapters pass the vendor variant.
# Both names resolve to the same route so routing can never drift between them.
_ROUTE_BY_NAME: Final[Mapping[str, str]] = MappingProxyType(
    {
        "tts_custom_voice": "custom_voice",
        "custom_voice": "custom_voice",
        "tts_base": "base",
        "base": "base",
        "voice_design": "voice_design",
    }
)
_VOICE_DESIGN_TASK_REQUIRED: Final[str] = (
    "instruction voices are served by the voice_design task, not by speech synthesis"
)


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

    @property
    def supports_incremental_stream(self) -> bool:
        """Whether this binding may declare incremental streaming capability.

        CustomVoice needs a verified vendor speaker binding and Base needs a
        clone reference; VoiceDesign never declares a stable incremental role
        even when its instruction path can synthesize complete text.
        """

        if self.variant == "base":
            return self.is_clone
        if self.variant == "custom_voice":
            return self.speaker is not None
        return False


def resolve_binding(
    role: str, voice: str, *, profile: VoiceProfile | None = None
) -> VoiceBinding:
    """Resolve a public voice for one plan role while preserving alias casing.

    A built-in fixed speaker resolves only for the CustomVoice role, a clone
    revision resolves only for the Base role, and the VoiceDesign role is
    restricted to design candidates.  No role falls back to another: a missing
    Base clone capability is an explicit rejection, never a silent re-route to
    a built-in speaker or to the VoiceDesign model.
    """

    try:
        variant = _ROUTE_BY_NAME[role]
    except KeyError:
        raise ValueError(f"unsupported voice role: {role}") from None
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
                f"voice {voice} requires an active Base clone capability; "
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
            f"voice {voice} requires an active Base clone capability; "
            "custom_voice variant does not synthesize cloned references"
        )
    if profile.mode != "system":
        # Instruction profiles are design candidates.  Routing them here would
        # hide an unsupported engine capability behind a built-in speaker.
        raise ValueError(_VOICE_DESIGN_TASK_REQUIRED)

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
