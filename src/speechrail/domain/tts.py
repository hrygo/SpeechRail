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
        "default": VoiceProfile(
            id="default",
            name="默认原声",
            instruction="自然清晰的中文女声，语气平和亲切，语速适中，适合日常对话。",
            seed=42,
            temperature=0.1,
            is_default=True,
            is_system=True,
        ),
        "warm": VoiceProfile(
            id="warm",
            name="温暖磁性",
            instruction="温暖柔和的中文女声，语速略慢，语气舒缓，适合阅读与陪伴场景。",
            seed=1024,
            temperature=0.1,
            is_system=True,
        ),
        "bright": VoiceProfile(
            id="bright",
            name="清脆干练",
            instruction="明亮活泼的中文女声，音调偏高，语气轻快，适合播报与讲解。",
            seed=2048,
            temperature=0.1,
            is_system=True,
        ),
        "calm": VoiceProfile(
            id="calm",
            name="沉稳专业",
            instruction="沉稳平静的中文男声，语速平稳，语气专业，适合资讯播报。",
            seed=4096,
            temperature=0.1,
            is_system=True,
        ),
    }
)

VOICE_PROFILES: Mapping[str, VoiceProfile] = SYSTEM_VOICE_PROFILES

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
                        if vid not in SYSTEM_VOICE_PROFILES:
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

        if vid in SYSTEM_VOICE_PROFILES:
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
        if vid in SYSTEM_VOICE_PROFILES:
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
    "create_breath_pause",
    "generation_token_budget",
    "get_voice_profile",
    "get_voice_registry",
    "normalize_tts_text",
    "resolve_voice",
]
