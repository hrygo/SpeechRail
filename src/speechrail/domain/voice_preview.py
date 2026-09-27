"""Single source for the default voice-preview text shown by API clients.

The preview is a *display* projection: it tells a client which sample text to
send when a person auditions a voice.  It never constrains what a voice can
speak, and it is deliberately not part of the acoustic voice identity, so
editing a template does not mint a new ``voice_revision``.
"""

from __future__ import annotations

from collections.abc import Mapping
from types import MappingProxyType
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from speechrail.domain.tts import VoiceProfile

# Base language tags only.  No region or dialect is implied: the locale
# describes the sample text, never a constraint on what a voice can speak.
PREVIEW_TEMPLATES: Mapping[str, str] = MappingProxyType(
    {
        "zh": "这是一段音色试听。声音清晰自然，每一句表达都恰到好处。",
        "en": (
            "This is a voice preview. The speech should be clear, "
            "natural, and easy to follow."
        ),
        "ja": "これは音声の試聴です。聞き取りやすく、自然な声をお届けします。",
        "ko": "목소리 미리 듣기입니다. 또렷하고 자연스러운 목소리를 들어 보세요.",
    }
)

SUPPORTED_PREVIEW_LOCALES = frozenset(PREVIEW_TEMPLATES)


def normalize_preview_locale(locale: object) -> str | None:
    """Return a supported base language tag, or None when the source is unknown.

    Unknown, blank or malformed values resolve to ``None`` so an unknown
    display attribute degrades to "no preview" instead of guessing a language
    from a voice name, description or reference transcript.
    """

    if not isinstance(locale, str):
        return None
    normalized = locale.strip().lower()
    if normalized not in SUPPORTED_PREVIEW_LOCALES:
        return None
    return normalized


def preview_text_for_locale(locale: object) -> str | None:
    """Return the maintained sample text for a base language tag."""

    normalized = normalize_preview_locale(locale)
    if normalized is None:
        return None
    return PREVIEW_TEMPLATES[normalized]


def preview_for_profile(profile: VoiceProfile) -> dict[str, Any] | None:
    """Project a voice's default preview, or None when the source is unknown."""

    locale = normalize_preview_locale(profile.preview_locale)
    if locale is None:
        return None
    return {"locale": locale, "text": PREVIEW_TEMPLATES[locale]}


__all__ = [
    "PREVIEW_TEMPLATES",
    "SUPPORTED_PREVIEW_LOCALES",
    "normalize_preview_locale",
    "preview_for_profile",
    "preview_text_for_locale",
]
