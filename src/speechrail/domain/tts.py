"""Vendor-neutral TTS policy and the public preset voice registry."""

from __future__ import annotations

import json
import random
import re
import time
import uuid
from collections.abc import Mapping
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from types import MappingProxyType
from typing import Any


@dataclass(frozen=True, slots=True)
class VoiceProfile:
    """One public preset mapped to a model-independent voice instruction."""

    id: str
    instruction: str
    is_default: bool = False
    name: str = ""
    seed: int = 42
    temperature: float = 0.1
    is_system: bool = False
    created_at: float = 0.0

    @property
    def description(self) -> str:
        """Expose the same stable text for API clients and model adapters."""
        return self.instruction

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name or self.id,
            "instruction": self.instruction,
            "seed": self.seed,
            "temperature": self.temperature,
            "is_default": self.is_default,
            "is_system": self.is_system,
            "created_at": self.created_at,
        }


@dataclass(frozen=True, slots=True)
class VoiceCapabilities:
    """Public voice capabilities without vendor-specific details."""

    variant: str
    supports_speaker: bool
    supports_instruction: bool


SYSTEM_VOICE_PROFILES: Mapping[str, VoiceProfile] = MappingProxyType(
    {
        "serena": VoiceProfile(
            id="serena",
            name="温柔中文女声",
            instruction="温暖柔和的年轻中文女声，音色自然亲切，语气平和，语速适中。",
            seed=42,
            temperature=0.1,
            is_default=True,
            is_system=True,
        ),
        "vivian": VoiceProfile(
            id="vivian",
            name="明亮中文女声",
            instruction="明亮清脆的年轻中文女声，略带锋利质感，语气轻快自然。",
            seed=1024,
            temperature=0.1,
            is_system=True,
        ),
        "uncle_fu": VoiceProfile(
            id="uncle_fu",
            name="醇厚中文男声",
            instruction="成熟稳重的中文男声，音色低沉醇厚，语速平稳，表达从容。",
            seed=2048,
            temperature=0.1,
            is_system=True,
        ),
        "dylan": VoiceProfile(
            id="dylan",
            name="北京青年男声",
            instruction="清晰自然的年轻中文男声，带自然北京口音，语气轻松直接。",
            seed=5120,
            temperature=0.1,
            is_system=True,
        ),
        "eric": VoiceProfile(
            id="eric",
            name="成都活力男声",
            instruction="活泼明亮的年轻中文男声，略带沙哑质感和自然四川口音。",
            seed=6144,
            temperature=0.1,
            is_system=True,
        ),
        "ryan": VoiceProfile(
            id="ryan",
            name="动感英语男声",
            instruction="富有活力和节奏感的英语男声，发音清晰，表达有推动力。",
            seed=7168,
            temperature=0.1,
            is_system=True,
        ),
        "aiden": VoiceProfile(
            id="aiden",
            name="阳光美式男声",
            instruction="阳光自然的美式英语年轻男声，中频清晰，语气友好。",
            seed=8192,
            temperature=0.1,
            is_system=True,
        ),
        "ono_anna": VoiceProfile(
            id="ono_anna",
            name="轻快日语女声",
            instruction="轻盈灵动的日语年轻女声，语气俏皮自然，节奏明快。",
            seed=9216,
            temperature=0.1,
            is_system=True,
        ),
        "sohee": VoiceProfile(
            id="sohee",
            name="温暖韩语女声",
            instruction="温暖柔和的韩语女声，情感丰富，表达自然亲切。",
            seed=10240,
            temperature=0.1,
            is_system=True,
        ),
    }
)

VOICE_PROFILES: Mapping[str, VoiceProfile] = SYSTEM_VOICE_PROFILES

DEFAULT_VOICE_ID = "serena"

VOICE_ALIASES: Mapping[str, str] = MappingProxyType(
    {
        # Legacy SpeechRail preset IDs remain accepted but are not listed as
        # canonical voices. Every canonical ID maps one-to-one to one Qwen
        # CustomVoice speaker across balanced/light.
        "default": "serena",
        "warm": "serena",
        "bright": "vivian",
        "calm": "uncle_fu",
        "alloy": "serena",
        "ash": "serena",
        "echo": "serena",
        "onyx": "serena",
        "coral": "serena",
        "sage": "serena",
        "marin": "serena",
        "nova": "vivian",
        "ballad": "vivian",
        "verse": "vivian",
        "cedar": "vivian",
        "fable": "uncle_fu",
        "shimmer": "uncle_fu",
    }
)

_MARKDOWN_CLEANUP_RE = re.compile(r"[*#`~_>]+")
_EMOJI_RE = re.compile(
    r"[𐀀-􏿿☀-➿⌀-⏿⭐-⭕‍️]+"
)
_TRAILING_WEAK_PUNCT_RE = re.compile(r"[，,、：:\s]+$")
_SENTENCE_TERMINATORS = frozenset(
    {"。", "！", "？", "!", "?", "；", ";", "…", "—", "."}
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
        has_cjk = any("一" <= char <= "鿿" for char in clean)
        clean += "。" if has_cjk else "."
    return clean


def generation_token_budget(text: str) -> int:
    """Calculate a bounded acoustic-token budget from normalized text length."""

    clean = text.strip()
    if not clean:
        return _MIN_GENERATION_TOKENS
    estimated = _BASE_BUFFER_TOKENS + len(clean) * _TOKENS_PER_TEXT_CHAR
    return max(_MIN_GENERATION_TOKENS, min(_MAX_GENERATION_TOKENS, estimated))


def resolve_voice(voice: str) -> str:
    """Map an OpenAI standard voice name onto the nearest server preset."""
    return VOICE_ALIASES.get(voice, voice)


class VoiceRegistry:
    """Thread-safe registry managing system preset voices and persistent user-designed voices."""

    def __init__(self, storage_path: Path | None = None) -> None:
        self._storage_path = storage_path or (Path.home() / ".speechrail" / "custom_voices.json")
        self._custom_voices: dict[str, VoiceProfile] = {}
        self._load_custom_voices()

    def _load_custom_voices(self) -> None:
        if not self._storage_path.is_file():
            return
        try:
            data = json.loads(self._storage_path.read_text(encoding="utf-8"))
            if isinstance(data, list):
                for item in data:
                    if isinstance(item, dict) and "id" in item and "instruction" in item:
                        vid = str(item["id"]).strip().lower()
                        if vid not in SYSTEM_VOICE_PROFILES and vid not in VOICE_ALIASES:
                            self._custom_voices[vid] = VoiceProfile(
                                id=vid,
                                name=str(item.get("name", vid)),
                                instruction=str(item["instruction"]),
                                seed=int(item.get("seed", 42)),
                                temperature=float(item.get("temperature", 0.1)),
                                is_default=False,
                                is_system=False,
                                created_at=float(item.get("created_at", 0.0)),
                            )
        except Exception:
            pass

    def _save_custom_voices(self) -> None:
        try:
            self._storage_path.parent.mkdir(parents=True, exist_ok=True)
            data = [profile.to_dict() for profile in self._custom_voices.values()]
            self._storage_path.write_text(
                json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8"
            )
        except Exception:
            pass

    def list_profiles(self) -> list[VoiceProfile]:
        system = list(SYSTEM_VOICE_PROFILES.values())
        custom = sorted(self._custom_voices.values(), key=lambda v: v.created_at, reverse=True)
        return system + custom

    def get_profile(self, voice: str) -> VoiceProfile:
        resolved = resolve_voice(voice)
        if resolved in SYSTEM_VOICE_PROFILES:
            return SYSTEM_VOICE_PROFILES[resolved]
        if resolved in self._custom_voices:
            return self._custom_voices[resolved]
        raise ValueError(f"unknown preset voice: {voice}")

    def create_custom_profile(
        self,
        name: str,
        instruction: str,
        voice_id: str | None = None,
        seed: int | None = None,
    ) -> VoiceProfile:
        if not name.strip():
            raise ValueError("voice name must not be empty")
        if not instruction.strip():
            raise ValueError("voice instruction must not be empty")
        if voice_id:
            vid = voice_id.strip().lower()
        else:
            vid = f"custom_{int(time.time())}_{uuid.uuid4().hex[:4]}"

        if vid in SYSTEM_VOICE_PROFILES or vid in VOICE_ALIASES:
            raise ValueError(f"cannot override system voice ID: {vid}")

        used_seed = seed if seed is not None else random.randint(1000, 999999)
        profile = VoiceProfile(
            id=vid,
            name=name.strip(),
            instruction=instruction.strip(),
            seed=used_seed,
            temperature=0.1,
            is_default=False,
            is_system=False,
            created_at=time.time(),
        )
        self._custom_voices[vid] = profile
        self._save_custom_voices()
        return profile

    def delete_custom_profile(self, voice_id: str) -> None:
        vid = voice_id.strip().lower()
        if vid in SYSTEM_VOICE_PROFILES or vid in VOICE_ALIASES:
            raise ValueError(f"system voice cannot be deleted: {vid}")
        if vid not in self._custom_voices:
            raise KeyError(f"custom voice not found: {vid}")
        del self._custom_voices[vid]
        self._save_custom_voices()


_GLOBAL_VOICE_REGISTRY = VoiceRegistry()


def get_voice_registry() -> VoiceRegistry:
    """Return the singleton voice registry."""
    return _GLOBAL_VOICE_REGISTRY


def get_voice_profile(voice: str) -> VoiceProfile:
    """Return a registered preset or custom profile, or raise a stable lookup error."""
    return _GLOBAL_VOICE_REGISTRY.get_profile(voice)


_ABBREVIATIONS = frozenset(
    {"mr.", "mrs.", "ms.", "dr.", "prof.", "e.g.", "i.e.", "etc.", "u.s.", "u.s.a.", "vs.", "fig."}
)
_MAIN_PUNCTS = frozenset({"。", "！", "？", "；", "\n", "\r", "!", "?", ";"})
_SECONDARY_PUNCTS = frozenset({"，", "、", ","})
_BOUNDED_MAIN_PUNCTS = _MAIN_PUNCTS | {".", "…", "—"}
_BOUNDED_SECONDARY_MIN_CHARS = 15
_QUOTE_CLOSERS = {"》": "《", "”": "“", "」": "「", "』": "『"}
_QUOTE_OPENERS = frozenset(_QUOTE_CLOSERS.values())
_URL_TRAILING_CHARS = frozenset(
    " \t\r\n,，、。！？!?；;:：)]}》”」』'\""
)


def _advance_quote_state(
    text: str, stack: list[str], ascii_quote_open: bool
) -> bool:
    """Advance quote state through one bounded text slice."""
    for char in text:
        if char in _QUOTE_OPENERS:
            stack.append(char)
        elif char in _QUOTE_CLOSERS:
            opener = _QUOTE_CLOSERS[char]
            if stack and stack[-1] == opener:
                stack.pop()
        elif char == '"':
            ascii_quote_open = not ascii_quote_open
    return ascii_quote_open


def _non_space_token(text: str, index: int) -> tuple[str, int, int]:
    """Return the non-whitespace token containing ``index`` and its bounds."""
    start = index
    while start > 0 and not text[start - 1].isspace():
        start -= 1
    end = index + 1
    while end < len(text) and not text[end].isspace():
        end += 1
    return text[start:end], start, end


def _is_abbreviation_period(text: str, index: int) -> bool:
    token, token_start, _ = _non_space_token(text, index)
    prefix = token[: index - token_start + 1].lstrip("\"'“”‘’([{《「『").lower()
    if not prefix:
        return False
    return any(
        abbreviation == prefix or abbreviation.startswith(prefix)
        for abbreviation in _ABBREVIATIONS
    )


def _is_url_punctuation(text: str, index: int) -> bool:
    token, token_start, token_end = _non_space_token(text, index)
    if "://" not in token or not re.search(r"(?i)(?:https?|ftp)://", token):
        return False
    if index >= token_end - 1:
        return False
    next_char = text[index + 1] if index + 1 < len(text) else ""
    return next_char not in _URL_TRAILING_CHARS and index >= token_start


def _is_protected_period(text: str, index: int) -> bool:
    previous = text[index - 1] if index > 0 else ""
    following = text[index + 1] if index + 1 < len(text) else ""
    if previous.isdigit() and following.isdigit():
        return True
    return _is_abbreviation_period(text, index) or _is_url_punctuation(text, index)


def _find_bounded_boundary(
    text: str,
    start: int,
    limit: int,
    quote_stack: list[str],
    ascii_quote_open: bool,
) -> int | None:
    """Find the best boundary in ``text[start:limit]`` without dropping data."""
    quote_stack = list(quote_stack)
    sentence_boundary: int | None = None
    secondary_boundary: int | None = None

    for index in range(start, limit):
        char = text[index]
        if char in _QUOTE_OPENERS:
            quote_stack.append(char)
        elif char in _QUOTE_CLOSERS:
            opener = _QUOTE_CLOSERS[char]
            if quote_stack and quote_stack[-1] == opener:
                quote_stack.pop()
        elif char == '"':
            ascii_quote_open = not ascii_quote_open

        if index == start:
            continue
        if quote_stack or ascii_quote_open:
            continue
        if _is_url_punctuation(text, index):
            continue
        if char == "." and _is_protected_period(text, index):
            continue
        if char in _BOUNDED_MAIN_PUNCTS:
            sentence_boundary = index + 1
        elif (
            char in _SECONDARY_PUNCTS
            and index - start + 1 >= _BOUNDED_SECONDARY_MIN_CHARS
        ):
            secondary_boundary = index + 1

    return sentence_boundary or secondary_boundary


def bounded_sentences(text: str, max_chars: int = 240) -> tuple[str, ...]:
    """Split text into bounded, lossless chunks for acoustic generation.

    Sentence-ending punctuation is preferred, followed by secondary punctuation
    and whitespace. Protected periods in decimals, URLs, abbreviations and
    quoted text are ignored as boundaries. A final hard character boundary keeps
    even unpunctuated input lossless when one sentence exceeds ``max_chars``.
    """
    if max_chars <= 0:
        raise ValueError("max_chars must be positive")
    if not text:
        return ()

    chunks: list[str] = []
    start = 0
    quote_stack: list[str] = []
    ascii_quote_open = False
    while start < len(text):
        limit = min(len(text), start + max_chars)
        if limit == len(text):
            chunks.append(text[start:])
            break

        boundary = _find_bounded_boundary(
            text,
            start,
            limit,
            quote_stack,
            ascii_quote_open,
        )
        if boundary is None:
            whitespace = text.rfind(" ", start + 1, limit)
            boundary = whitespace + 1 if whitespace >= start + 1 else limit
        chunks.append(text[start:boundary])
        ascii_quote_open = _advance_quote_state(
            text[start:boundary], quote_stack, ascii_quote_open
        )
        start = boundary
    return tuple(chunks)


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

            if char in _MAIN_PUNCTS and (not is_enclosed or i >= 30):
                return i + 1

            if (
                char in _SECONDARY_PUNCTS
                and i >= self._min_secondary_chars
                and (not is_enclosed or i >= 40)
            ):
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


@lru_cache(maxsize=16)
def create_breath_pause(sample_rate: int = 24_000, pause_ms: int = 100) -> bytes:
    """Generate silent mono PCM16 bytes for natural inter-sentence breathing pause."""
    if pause_ms <= 0:
        return b""
    num_samples = (sample_rate * pause_ms) // 1000
    return b"\x00\x00" * num_samples


__all__ = [
    "DEFAULT_VOICE_ID",
    "SYSTEM_VOICE_PROFILES",
    "VOICE_ALIASES",
    "VOICE_PROFILES",
    "StreamingSentenceSplitter",
    "VoiceCapabilities",
    "VoiceProfile",
    "VoiceRegistry",
    "apply_crossfade",
    "bounded_sentences",
    "create_breath_pause",
    "generation_token_budget",
    "get_voice_profile",
    "get_voice_registry",
    "normalize_tts_text",
    "resolve_voice",
]
