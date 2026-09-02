"""Vendor-neutral TTS policy and the public preset voice registry."""

from __future__ import annotations

import re
from collections.abc import Mapping
from dataclasses import dataclass
from types import MappingProxyType


@dataclass(frozen=True, slots=True)
class VoiceProfile:
    """One public preset mapped to a model-independent voice instruction."""

    id: str
    instruction: str
    is_default: bool = False

    @property
    def description(self) -> str:
        """Expose the same stable text for API clients and model adapters."""
        return self.instruction


VOICE_PROFILES: Mapping[str, VoiceProfile] = MappingProxyType(
    {
        "default": VoiceProfile(
            id="default",
            instruction="自然清晰的中文女声，语气平和亲切，语速适中，适合日常对话。",  # noqa: RUF001
            is_default=True,
        ),
        "warm": VoiceProfile(
            id="warm",
            instruction="温暖柔和的中文女声，语速略慢，语气舒缓，适合阅读与陪伴场景。",  # noqa: RUF001
        ),
        "bright": VoiceProfile(
            id="bright",
            instruction="明亮活泼的中文女声，音调偏高，语气轻快，适合播报与讲解。",  # noqa: RUF001
        ),
        "calm": VoiceProfile(
            id="calm",
            instruction="沉稳平静的中文男声，语速平稳，语气专业，适合资讯播报。",  # noqa: RUF001
        ),
    }
)

DEFAULT_VOICE_ID = "default"

VOICE_ALIASES: Mapping[str, str] = MappingProxyType(
    {
        "alloy": "default",
        "ash": "default",
        "echo": "default",
        "onyx": "default",
        "coral": "warm",
        "sage": "warm",
        "marin": "warm",
        "nova": "bright",
        "ballad": "bright",
        "verse": "bright",
        "cedar": "bright",
        "fable": "calm",
        "shimmer": "calm",
    }
)

_MARKDOWN_CLEANUP_RE = re.compile(r"[*#`~_>]+")
_EMOJI_RE = re.compile(
    r"[\U00010000-\U0010FFFF\u2600-\u27BF\u2300-\u23FF\u2B50-\u2B55\u200d\ufe0f]+"
)
_TRAILING_WEAK_PUNCT_RE = re.compile(r"[\uFF0C,\u3001\uFF1A:\s]+$")
_SENTENCE_TERMINATORS = frozenset(
    {"\u3002", "\uff01", "\uff1f", "!", "?", "\uff1b", ";", "\u2026", "\u2014", "."}
)

_MIN_GENERATION_TOKENS = 32
_MAX_GENERATION_TOKENS = 1_200
_BASE_BUFFER_TOKENS = 24
_TOKENS_PER_TEXT_CHAR = 5


def normalize_tts_text(text: str) -> str:
    """Normalize text before acoustic generation without changing its meaning."""

    clean = _MARKDOWN_CLEANUP_RE.sub("", text)
    clean = _EMOJI_RE.sub("", clean).strip()
    if not clean:
        return ""
    clean = _TRAILING_WEAK_PUNCT_RE.sub("", clean).strip()
    if not clean:
        return ""
    if clean[-1] not in _SENTENCE_TERMINATORS:
        has_cjk = any("\u4e00" <= char <= "\u9fff" for char in clean)
        clean += "。" if has_cjk else "."
    return clean


def generation_token_budget(text: str) -> int:
    """Calculate a bounded acoustic-token budget from normalized text length."""

    clean = text.strip()
    if not clean:
        return _MIN_GENERATION_TOKENS
    estimated = _BASE_BUFFER_TOKENS + len(clean) * _TOKENS_PER_TEXT_CHAR
    return max(_MIN_GENERATION_TOKENS, min(_MAX_GENERATION_TOKENS, estimated))


def get_voice_profile(voice: str) -> VoiceProfile:
    """Return a registered preset or raise a stable lookup error."""

    try:
        return VOICE_PROFILES[voice]
    except KeyError as exc:
        raise ValueError(f"unknown preset voice: {voice}") from exc


def resolve_voice(voice: str) -> str:
    """Map an OpenAI standard voice name onto the nearest server preset."""
    return VOICE_ALIASES.get(voice, voice)


__all__ = [
    "DEFAULT_VOICE_ID",
    "VOICE_ALIASES",
    "VOICE_PROFILES",
    "VoiceProfile",
    "generation_token_budget",
    "get_voice_profile",
    "normalize_tts_text",
    "resolve_voice",
]
