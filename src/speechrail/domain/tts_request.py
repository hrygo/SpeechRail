"""Shared TTS request normalization and model/voice parameter policy."""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Literal

from speechrail.domain.tts_errors import TtsBackendError

TtsModelVariant = Literal["voice_design", "custom_voice", "base"]
ValidationPolicy = Literal["allow_unverified", "require_output_pass"]

_LANGUAGE_ALIASES = {
    "zh": "chinese",
    "zh-cn": "chinese",
    "zh-hans": "chinese",
    "zh-tw": "chinese",
    "zh-hant": "chinese",
    "chinese": "chinese",
    "en": "english",
    "english": "english",
    "ja": "japanese",
    "japanese": "japanese",
    "ko": "korean",
    "korean": "korean",
    "de": "german",
    "german": "german",
    "fr": "french",
    "french": "french",
    "ru": "russian",
    "russian": "russian",
    "pt": "portuguese",
    "pt-br": "portuguese",
    "portuguese": "portuguese",
    "es": "spanish",
    "spanish": "spanish",
    "it": "italian",
    "italian": "italian",
    "auto": "auto",
}


class TtsParameterError(TtsBackendError, ValueError):
    """A deterministic request rejection with an agent/API-safe code."""

    def __init__(self, code: str, message: str, *, param: str) -> None:
        self.param = param
        self.message = message
        super().__init__(
            code,
            stage="validate",
            public_code=code,
            retryable=False,
            detail=message,
        )


@dataclass(frozen=True, slots=True)
class TtsParameterValidation:
    """Canonical values to pass from a public adapter to a vendor backend."""

    language: str
    speed: float


def normalize_tts_language(language: str) -> str:
    """Normalize public ISO-ish language inputs to Qwen3-TTS language names."""

    if not isinstance(language, str):
        raise TtsParameterError(
            "unsupported_language", "language must be a string", param="language"
        )
    normalized = language.strip().lower().replace("_", "-")
    if not normalized:
        raise TtsParameterError(
            "unsupported_language", "language must not be blank", param="language"
        )
    try:
        return _LANGUAGE_ALIASES[normalized]
    except KeyError as exc:
        raise TtsParameterError(
            "unsupported_language",
            f"unsupported TTS language: {language.strip()}",
            param="language",
        ) from exc


def validate_tts_parameters(
    *,
    model_variant: TtsModelVariant,
    is_clone: bool,
    speed: float,
    language: str,
    instruction: str | None,
    seed: int | None,
) -> TtsParameterValidation:
    """Apply one policy for all TTS adapters before a backend call."""

    if not isinstance(speed, (int, float)) or isinstance(speed, bool) or not math.isfinite(speed):
        raise TtsParameterError("invalid_speed", "speed must be finite", param="speed")
    if not 0.25 <= float(speed) <= 4.0:
        raise TtsParameterError(
            "invalid_speed", "speed must be between 0.25 and 4.0", param="speed"
        )
    if model_variant == "base" and not is_clone:
        raise TtsParameterError(
            "base_clone_required",
            "Base TTS requires a registered clone voice",
            param="voice",
        )
    if is_clone:
        if float(speed) != 1.0:
            raise TtsParameterError(
                "clone_speed_unsupported",
                "the Base clone backend supports only speed=1.0",
                param="speed",
            )
        if instruction is not None:
            raise TtsParameterError(
                "clone_instruction_unsupported",
                "clone synthesis does not accept VoiceDesign instructions",
                param="instruction",
            )
        if seed is not None:
            raise TtsParameterError(
                "clone_seed_unsupported",
                "clone synthesis does not accept a caller seed",
                param="seed",
            )
    elif instruction is not None and model_variant != "voice_design":
        raise TtsParameterError(
            "instructions_unsupported",
            "instructions require a VoiceDesign TTS model",
            param="instruction",
        )
    elif model_variant == "custom_voice" and seed is not None:
        raise TtsParameterError(
            "custom_voice_seed_unsupported",
            "CustomVoice synthesis does not accept a caller seed",
            param="seed",
        )
    elif model_variant == "voice_design" and instruction is None and seed is not None:
        raise TtsParameterError(
            "voice_design_seed_requires_instruction",
            "a VoiceDesign seed requires an explicit instruction",
            param="seed",
        )
    return TtsParameterValidation(
        language=normalize_tts_language(language),
        speed=float(speed),
    )
