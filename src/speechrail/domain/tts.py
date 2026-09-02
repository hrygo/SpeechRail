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



_ABBREVIATIONS = frozenset(
    {"mr.", "mrs.", "ms.", "dr.", "prof.", "e.g.", "i.e.", "etc.", "u.s.", "u.s.a.", "vs.", "fig."}
)
_MAIN_PUNCTS = frozenset({"。", "！", "？", "；", "\n", "\r", "!", "?", ";"})
_SECONDARY_PUNCTS = frozenset({"，", "、", ","})


class StreamingSentenceSplitter:
    """Incremental, boundary-aware sentence splitter for streaming LLM text ingestion."""

    def __init__(
        self,
        *,
        min_sentence_chars: int = 2,
        min_secondary_chars: int = 15,
    ) -> None:
        self._min_sentence_chars = min_sentence_chars
        self._min_secondary_chars = min_secondary_chars
        self._buffer: list[str] = []

    @property
    def buffer_text(self) -> str:
        return "".join(self._buffer)

    def feed(self, text_chunk: str) -> list[str]:
        """Append text chunk and yield completed sentences if boundary conditions met."""
        if not text_chunk:
            return []
        self._buffer.append(text_chunk)
        current = "".join(self._buffer)
        sentences: list[str] = []

        while True:
            split_idx = self._find_split_point(current)
            if split_idx is None:
                break
            sentence = current[:split_idx].strip()
            current = current[split_idx:].lstrip()
            if sentence:
                sentences.append(sentence)

        self._buffer = [current] if current else []
        return sentences

    def flush(self) -> list[str]:
        """Flush any remaining buffered text as the final sentence."""
        current = "".join(self._buffer).strip()
        self._buffer.clear()
        if not current:
            return []
        return [current]

    def clear(self) -> None:
        """Clear all buffered text without emitting."""
        self._buffer.clear()

    def _find_split_point(self, text: str) -> int | None:
        text_len = len(text)
        if text_len < self._min_sentence_chars:
            return None

        open_book = 0
        open_double_quote = 0
        open_ascii_quote = 0

        for i, char in enumerate(text):
            if char == "《":
                open_book += 1
            elif char == "》":
                open_book = max(0, open_book - 1)
            elif char == "“":
                open_double_quote += 1
            elif char == "”":
                open_double_quote = max(0, open_double_quote - 1)
            elif char == '"':
                open_ascii_quote = 1 - open_ascii_quote

            if i < self._min_sentence_chars - 1:
                continue

            is_enclosed = open_book > 0 or open_double_quote > 0 or open_ascii_quote > 0

            # Period check with abbreviation & decimal protection
            if char == ".":
                if i + 1 < text_len and text[i + 1].isdigit() and i > 0 and text[i - 1].isdigit():
                    continue  # Decimal number like 3.14
                # Check for common abbreviation prefix
                word_before = text[: i + 1].rsplit(None, 1)[-1].lower()
                if word_before in _ABBREVIATIONS:
                    continue
                if not is_enclosed or i >= 30:
                    return i + 1

            if char in _MAIN_PUNCTS:
                if not is_enclosed or i >= 30:
                    return i + 1

            if char in _SECONDARY_PUNCTS and i >= self._min_secondary_chars:
                if not is_enclosed or i >= 40:
                    return i + 1

        return None



def apply_crossfade(
    pcm: bytes,
    *,
    sample_rate: int = 24_000,
    fade_ms: int = 5,
    fade_in: bool = True,
    fade_out: bool = True,
) -> bytes:
    """Apply linear fade-in and/or fade-out to mono PCM16 audio to prevent clicking."""
    if not pcm or len(pcm) % 2 != 0 or fade_ms <= 0:
        return pcm
    num_samples = len(pcm) // 2
    fade_samples = min(num_samples, (sample_rate * fade_ms) // 1000)
    if fade_samples <= 0:
        return pcm

    import numpy as np

    samples = np.frombuffer(pcm, dtype="<i2").astype(np.float32)
    if fade_in:
        ramp_in = np.linspace(0.0, 1.0, fade_samples, dtype=np.float32)
        samples[:fade_samples] *= ramp_in
    if fade_out:
        ramp_out = np.linspace(1.0, 0.0, fade_samples, dtype=np.float32)
        samples[-fade_samples:] *= ramp_out

    return np.clip(samples, -32768.0, 32767.0).astype("<i2").tobytes()


def create_breath_pause(sample_rate: int = 24_000, pause_ms: int = 100) -> bytes:
    """Generate silent mono PCM16 bytes for natural inter-sentence breathing pause."""
    if pause_ms <= 0:
        return b""
    num_samples = (sample_rate * pause_ms) // 1000
    return b"\x00\x00" * num_samples


__all__ = [
    "DEFAULT_VOICE_ID",
    "StreamingSentenceSplitter",
    "VOICE_ALIASES",
    "VOICE_PROFILES",
    "VoiceProfile",
    "apply_crossfade",
    "create_breath_pause",
    "generation_token_budget",
    "get_voice_profile",
    "normalize_tts_text",
    "resolve_voice",
]

