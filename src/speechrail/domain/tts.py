"""Vendor-neutral TTS policy and the public preset voice registry."""

from __future__ import annotations

import hashlib
import io
import json
import logging
import math
import re
import sys
import wave
from array import array
from collections.abc import Iterator, Mapping
from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import dataclass
from functools import lru_cache
from types import MappingProxyType
from typing import TYPE_CHECKING, Any

from speechrail.domain.voice_creation import VoiceCreation

if TYPE_CHECKING:
    # Plan roles are catalog vocabulary.  Importing them for real would make
    # ``speechrail.domain.tts`` pull in the ``speechrail.config`` package, which
    # in turn imports this module, so the annotation stays type-only.
    from speechrail.config.model_catalog import ModelRole

logger = logging.getLogger(__name__)

VOICE_ID_RE = re.compile(r"^[a-zA-Z0-9_-]{1,64}$")
VOICE_REVISION_RE = re.compile(r"^vr_[0-9a-f]{32}$")


@dataclass(frozen=True, slots=True)
class VoiceProfile:
    """One public preset mapped to a model-independent voice instruction or clone context."""

    id: str
    instruction: str = ""
    is_default: bool = False
    name: str = ""
    seed: int = 42
    temperature: float = 0.1
    is_system: bool = False
    created_at: float = 0.0
    mode: str = "system"  # "system" | "instruction" | "clone"
    ref_text: str | None = None
    audio_path: str | None = None
    duration_seconds: float = 0.0
    quality: dict[str, Any] | None = None
    creation: VoiceCreation | None = None
    revision: str | None = None
    revoked: bool = False
    # Display-only: the language of the maintained audition sample text.
    # It is not part of the acoustic identity, so changing it never mints a
    # new ``revision``.  ``None`` means "no known default sample".
    preview_locale: str | None = None

    @property
    def description(self) -> str:
        """Expose the same stable text for API clients and model adapters."""
        return self.instruction or self.ref_text or ""

    @property
    def runtime_role(self) -> ModelRole | None:
        """Return the plan role that owns this voice, or None when design-only.

        ``system`` voices are built-in fixed speakers and therefore CustomVoice
        weights; ``clone`` voices (including published design revisions) are
        Base weights.  ``instruction`` voices are design candidates: they are
        served by the voice_design task and have no runtime synthesis role.
        Discovery must read this instead of inferring a role from a model
        directory or an active tier.
        """

        if self.mode == "clone":
            return "tts_base"
        if self.mode == "system":
            return "tts_custom_voice"
        return None

    def to_dict(self) -> dict[str, Any]:
        data: dict[str, Any] = {
            "id": self.id,
            "name": self.name or self.id,
            "instruction": self.instruction,
            "seed": self.seed,
            "temperature": self.temperature,
            "is_default": self.is_default,
            "is_system": self.is_system,
            "created_at": self.created_at,
            "mode": self.mode,
        }
        if self.ref_text is not None:
            data["ref_text"] = self.ref_text
        if self.audio_path is not None:
            data["audio_path"] = self.audio_path
        if self.duration_seconds > 0:
            data["duration_seconds"] = self.duration_seconds
        if self.quality is not None:
            data["quality"] = self.quality
        if self.creation is not None:
            data["creation"] = self.creation.model_dump(mode="json")
        if self.revision is not None:
            data["revision"] = self.revision
        if self.revoked:
            data["revoked"] = True
        if self.preview_locale is not None:
            data["preview_locale"] = self.preview_locale
        return data


@dataclass(frozen=True, slots=True)
class VoiceCapabilities:
    """Public voice capabilities without vendor-specific details."""

    variant: str
    supports_speaker: bool
    supports_instruction: bool
    supports_clone: bool = False


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
            preview_locale="zh",
        ),
        "vivian": VoiceProfile(
            id="vivian",
            name="明亮中文女声",
            instruction="明亮清脆的年轻中文女声，略带锋利质感，语气轻快自然。",
            seed=1024,
            temperature=0.1,
            is_system=True,
            preview_locale="zh",
        ),
        "uncle_fu": VoiceProfile(
            id="uncle_fu",
            name="醇厚中文男声",
            instruction="成熟稳重的中文男声，音色低沉醇厚，语速平稳，表达从容。",
            seed=2048,
            temperature=0.1,
            is_system=True,
            preview_locale="zh",
        ),
        "dylan": VoiceProfile(
            id="dylan",
            name="北京青年男声",
            instruction="清晰自然的年轻中文男声，带自然北京口音，语气轻松直接。",
            seed=5120,
            temperature=0.1,
            is_system=True,
            preview_locale="zh",
        ),
        "eric": VoiceProfile(
            id="eric",
            name="成都活力男声",
            instruction="活泼明亮的年轻中文男声，略带沙哑质感和自然四川口音。",
            seed=6144,
            temperature=0.1,
            is_system=True,
            preview_locale="zh",
        ),
        "ryan": VoiceProfile(
            id="ryan",
            name="动感英语男声",
            instruction="富有活力和节奏感的英语男声，发音清晰，表达有推动力。",
            seed=7168,
            temperature=0.1,
            is_system=True,
            preview_locale="en",
        ),
        "aiden": VoiceProfile(
            id="aiden",
            name="阳光美式男声",
            instruction="阳光自然的美式英语年轻男声，中频清晰，语气友好。",
            seed=8192,
            temperature=0.1,
            is_system=True,
            preview_locale="en",
        ),
        "ono_anna": VoiceProfile(
            id="ono_anna",
            name="轻快日语女声",
            instruction="轻盈灵动的日语年轻女声，语气俏皮自然，节奏明快。",
            seed=9216,
            temperature=0.1,
            is_system=True,
            preview_locale="ja",
        ),
        "sohee": VoiceProfile(
            id="sohee",
            name="温暖韩语女声",
            instruction="温暖柔和的韩语女声，情感丰富，表达自然亲切。",
            seed=10240,
            temperature=0.1,
            is_system=True,
            preview_locale="ko",
        ),
    }
)

VOICE_PROFILES: Mapping[str, VoiceProfile] = SYSTEM_VOICE_PROFILES

DEFAULT_VOICE_ID = "serena"

VOICE_ALIASES: Mapping[str, str] = MappingProxyType(
    {
        # Legacy SpeechRail voice IDs remain accepted but are not listed as
        # canonical voices. Every canonical ID maps one-to-one to one Qwen
        # CustomVoice speaker across the fast and quality selections.
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
_EMOJI_RE = re.compile(r"[𐀀-􏿿☀-➿⌀-⏿⭐-⭕‍️]+")
_TRAILING_WEAK_PUNCT_RE = re.compile(r"[，,、：:\s]+$")
_SENTENCE_TERMINATORS = frozenset({"。", "！", "？", "!", "?", "；", ";", "…", "—", "."})

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


#: Identifies the normalization contract above. Bump it whenever the rules in
#: `normalize_tts_text` change: stored recipes compare this value to decide
#: whether two renders normalized their text the same way.
TTS_NORMALIZATION_REVISION = "tts_norm_v1"


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


def tts_voice_class(voice: str, *, profile: VoiceProfile | None = None) -> str:
    """Return a low-cardinality voice category label for metrics.

    Maps a resolved voice onto one of ``system``, ``custom`` or ``clone`` so a
    user-controlled custom/clone voice ID can never grow into an unbounded
    metric label time series. Unknown or failsafe voices resolve to ``custom``.
    """
    try:
        profile = profile or get_system_voice_profile(voice)
    except ValueError, VoiceStoreUnavailableError:
        return "custom"
    if profile.mode == "clone":
        return "clone"
    if profile.mode == "system":
        return "system"
    return "custom"


_CANONICAL_REFERENCE_TARGET_DBFS = -20.0
_CANONICAL_REFERENCE_MAX_GAIN_DB = 9.0
_CANONICAL_REFERENCE_MAX_ATTENUATION_DB = 12.0
_CANONICAL_REFERENCE_PEAK_CEILING = 0.95
_CANONICAL_REFERENCE_PAD_SECONDS = 0.20
_CANONICAL_REFERENCE_MIN_SECONDS = 2.0


def canonicalize_clone_reference_audio(
    wav_bytes: bytes,
    *,
    target_sample_rate: int = 24_000,
) -> tuple[bytes, float]:
    """Create one canonical clone reference without whole-recording RMS bias.

    The input must already be decoded to mono PCM16 WAV and must have passed the
    reference quality gate. Gain is derived only from speech-active 20 ms
    windows, bounded conservatively, and capped by a fixed peak ceiling. Long
    leading/trailing inactive regions are trimmed while retaining a short pad.
    The returned WAV is the only reference persisted for Base cloning; the
    vendor loader must therefore not normalize it again.
    """
    try:
        with wave.open(io.BytesIO(wav_bytes), "rb") as wf:
            if (
                wf.getnchannels() != 1
                or wf.getsampwidth() != 2
                or wf.getframerate() != target_sample_rate
            ):
                raise ValueError(
                    "reference audio must be mono PCM16 at the target sample rate"
                )
            pcm = wf.readframes(wf.getnframes())
    except ValueError:
        raise
    except Exception as exc:
        raise ValueError("reference audio cannot be canonicalized") from exc

    samples = array("h")
    samples.frombytes(pcm[: len(pcm) - (len(pcm) % 2)])
    if sys.byteorder != "little":
        samples.byteswap()
    if not samples:
        raise ValueError("reference audio contains no usable speech")

    window_samples = max(1, round(target_sample_rate * 0.02))
    active_threshold = 10 ** (-45.0 / 20.0)
    active_windows: list[tuple[int, int]] = []
    active_energy = 0.0
    active_count = 0
    for start in range(0, len(samples), window_samples):
        end = min(len(samples), start + window_samples)
        window = samples[start:end]
        if not window:
            continue
        energy = sum((sample / 32_768.0) ** 2 for sample in window)
        rms = math.sqrt(energy / len(window))
        if rms > active_threshold:
            active_windows.append((start, end))
            active_energy += energy
            active_count += len(window)
    if not active_windows or active_count <= 0:
        raise ValueError("reference audio contains no usable speech")

    active_rms = math.sqrt(active_energy / active_count)
    target_rms = 10 ** (_CANONICAL_REFERENCE_TARGET_DBFS / 20.0)
    desired_gain = target_rms / max(active_rms, 1e-9)
    min_gain = 10 ** (-_CANONICAL_REFERENCE_MAX_ATTENUATION_DB / 20.0)
    max_gain = 10 ** (_CANONICAL_REFERENCE_MAX_GAIN_DB / 20.0)
    gain = min(max(desired_gain, min_gain), max_gain)
    peak = max(abs(sample) for sample in samples) / 32_768.0
    if peak > 0.0:
        gain = min(gain, _CANONICAL_REFERENCE_PEAK_CEILING / peak)

    pad = round(target_sample_rate * _CANONICAL_REFERENCE_PAD_SECONDS)
    start = max(0, active_windows[0][0] - pad)
    end = min(len(samples), active_windows[-1][1] + pad)
    minimum_samples = round(target_sample_rate * _CANONICAL_REFERENCE_MIN_SECONDS)
    if end - start < minimum_samples and len(samples) >= minimum_samples:
        missing = minimum_samples - (end - start)
        extend_left = min(start, missing // 2)
        start -= extend_left
        missing -= extend_left
        extend_right = min(len(samples) - end, missing)
        end += extend_right
        missing -= extend_right
        if missing:
            start = max(0, start - missing)

    conditioned = array("h")
    for sample in samples[start:end]:
        value = round(sample * gain)
        conditioned.append(max(-32_768, min(32_767, value)))
    if sys.byteorder != "little":
        conditioned.byteswap()

    output = io.BytesIO()
    with wave.open(output, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(target_sample_rate)
        wf.writeframes(conditioned.tobytes())
    duration = len(conditioned) / float(target_sample_rate)
    return output.getvalue(), duration


def validate_transcoded_clone_wav(
    wav_bytes: bytes,
    *,
    min_duration: float = 2.0,
    max_duration: float = 45.0,
    target_sample_rate: int = 24_000,
    skip_signal_validation: bool = False,
) -> float:
    """Validate a bounded in-memory 24kHz mono PCM16 WAV and return its duration.

    This is the shared single source of truth for clone reference container,
    duration and (optional) signal checks. Both the synchronous transcode helper
    and the async HTTP transcode path delegate here so the WAV boundary rules
    cannot drift between them. ``skip_signal_validation`` is True on the HTTP
    path so the authoritative quality gate (``grade_reference_quality``) remains
    the single classifier for reference audio quality.
    """
    max_pcm_bytes = int(max_duration * target_sample_rate * 2) + 2048
    if len(wav_bytes) > max_pcm_bytes:
        raise ValueError(
            f"audio exceeds maximum allowed size for {max_duration}s duration (too long)"
        )

    try:
        with wave.open(io.BytesIO(wav_bytes), "rb") as wf:
            frames = wf.getnframes()
            rate = wf.getframerate()
            frame_width = wf.getnchannels() * wf.getsampwidth()
            declared_pcm_bytes = frames * frame_width
            if declared_pcm_bytes > len(wav_bytes):
                # ffmpeg cannot seek on pipe output and may leave RIFF/data sizes
                # at 0xffffffff. Recover the actual PCM payload length from the
                # bounded in-memory WAV instead of treating that sentinel as data.
                offset = 12
                data_bytes: int | None = None
                while offset + 8 <= len(wav_bytes):
                    chunk_id = wav_bytes[offset : offset + 4]
                    chunk_size = int.from_bytes(
                        wav_bytes[offset + 4 : offset + 8], "little"
                    )
                    payload_start = offset + 8
                    if chunk_id == b"data":
                        payload_end = payload_start + chunk_size
                        if chunk_size == 0xFFFFFFFF or payload_end > len(wav_bytes):
                            payload_end = len(wav_bytes)
                        data_bytes = payload_end - payload_start
                        break
                    next_offset = payload_start + chunk_size + (chunk_size & 1)
                    if next_offset <= offset:
                        break
                    offset = next_offset
                if data_bytes is None or frame_width <= 0:
                    raise ValueError("transcoded audio has no valid PCM data chunk")
                frames = data_bytes // frame_width
            duration = frames / float(rate) if rate > 0 else 0.0
    except Exception as exc:
        raise ValueError("transcoded audio is not a valid WAV") from exc

    if duration < min_duration:
        raise ValueError(f"audio duration {duration:.1f}s is too short (minimum {min_duration}s)")
    if duration > max_duration:
        raise ValueError(f"audio duration {duration:.1f}s is too long (maximum {max_duration}s)")

    if not skip_signal_validation:
        _validate_clone_audio_signal(wav_bytes, target_sample_rate=target_sample_rate)
    return duration


def _validate_clone_audio_signal(wav_bytes: bytes, *, target_sample_rate: int) -> None:
    """Reject reference files that would make ICL cloning learn silence/noise."""

    try:
        with wave.open(io.BytesIO(wav_bytes), "rb") as wf:
            if (
                wf.getnchannels() != 1
                or wf.getsampwidth() != 2
                or wf.getframerate() != target_sample_rate
            ):
                raise ValueError("reference audio must be mono PCM16 at the target sample rate")
            pcm = wf.readframes(wf.getnframes())
    except ValueError:
        raise
    except Exception as exc:
        raise ValueError("reference audio quality cannot be inspected") from exc

    samples = array("h")
    samples.frombytes(pcm[: len(pcm) - (len(pcm) % 2)])
    if sys.byteorder != "little":
        samples.byteswap()
    if not samples:
        raise ValueError("reference audio contains no usable speech")

    clipped_samples = sum(abs(sample) >= 32_767 for sample in samples)
    if clipped_samples > max(8, int(len(samples) * 0.005)):
        raise ValueError("reference audio is clipped")

    active_threshold = 10 ** (-45 / 20)
    window_samples = max(1, round(target_sample_rate * 0.02))
    active_windows: list[int] = []
    total_windows = 0
    for start in range(0, len(samples), window_samples):
        window = samples[start : start + window_samples]
        rms = math.sqrt(sum(sample * sample for sample in window) / len(window)) / 32_768.0
        if rms > active_threshold:
            active_windows.append(total_windows)
        total_windows += 1

    if not active_windows or len(active_windows) / total_windows < 0.15:
        raise ValueError("reference audio contains insufficient usable speech")
    if active_windows[0] * 0.02 > 1.5 or (total_windows - 1 - active_windows[-1]) * 0.02 > 1.5:
        raise ValueError("reference audio has too much leading or trailing silence")


class VoiceStoreUnavailableError(RuntimeError):
    """The persistent custom voice registry cannot be trusted or updated."""

    code = "voice_store_unavailable"


class VoiceAlreadyExistsError(ValueError):
    """A create-only registration must not replace an existing voice."""

    code = "voice_already_exists"


class VoiceUpdateUnsupportedError(ValueError):
    """The requested metadata is immutable for this voice kind."""

    code = "voice_update_unsupported"


class VoiceInUseError(RuntimeError):
    """A custom voice still has an active immutable audio reader lease."""

    code = "voice_in_use"


class VoiceRevisionConflictError(RuntimeError):
    """A conditional voice operation observed a different acoustic revision."""

    code = "voice_revision_conflict"


class VoiceRevokedError(RuntimeError):
    """A voice revision was explicitly revoked for future synthesis."""

    code = "voice_revoked"


def _voice_revision(
    *,
    mode: str,
    instruction: str,
    seed: int,
    temperature: float,
    ref_text: str | None = None,
    reference_audio_sha256: str | None = None,
    creation: VoiceCreation | None = None,
) -> str:
    """Return a content-addressed revision for acoustic identity only."""

    payload = {
        "mode": mode,
        "instruction_sha256": hashlib.sha256(instruction.encode()).hexdigest(),
        "seed": seed,
        "temperature": temperature,
        "reference_text_sha256": (
            hashlib.sha256(ref_text.encode()).hexdigest() if ref_text is not None else None
        ),
        "reference_audio_sha256": reference_audio_sha256,
        "creation": creation.model_dump(mode="json") if creation is not None else None,
    }
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return "vr_" + hashlib.sha256(canonical).hexdigest()[:32]


def voice_revision_for_clone(
    *,
    ref_text: str,
    audio_bytes: bytes,
    creation: VoiceCreation | None,
) -> str:
    """Return the immutable revision a published clone profile will receive."""

    return _voice_revision(
        mode="clone",
        instruction="",
        seed=42,
        temperature=0.1,
        ref_text=ref_text.strip(),
        reference_audio_sha256=hashlib.sha256(audio_bytes).hexdigest(),
        creation=creation,
    )


_EPHEMERAL_VOICE_PROFILES: ContextVar[Mapping[str, VoiceProfile]] = ContextVar(
    "speechrail_ephemeral_voice_profiles",
    default=MappingProxyType({}),
)


def get_system_voice_profile(voice: str) -> VoiceProfile:
    """Resolve only immutable built-in voices; no storage or service locator."""
    resolved = resolve_voice(voice)
    try:
        return SYSTEM_VOICE_PROFILES[resolved]
    except KeyError:
        raise ValueError(f"unknown preset voice: {voice}") from None


def ephemeral_voice_profile(voice: str) -> VoiceProfile | None:
    """Read the request-scoped unpublished candidate, without durable lookup."""
    return _EPHEMERAL_VOICE_PROFILES.get().get(resolve_voice(voice))


@contextmanager
def use_voice_profile(profile: VoiceProfile) -> Iterator[None]:
    """Expose one candidate profile to internal synthesis without publishing it."""

    current = dict(_EPHEMERAL_VOICE_PROFILES.get())
    current[profile.id] = profile
    token = _EPHEMERAL_VOICE_PROFILES.set(MappingProxyType(current))
    try:
        yield
    finally:
        _EPHEMERAL_VOICE_PROFILES.reset(token)


_ABBREVIATIONS = frozenset(
    {"mr.", "mrs.", "ms.", "dr.", "prof.", "e.g.", "i.e.", "etc.", "u.s.", "u.s.a.", "vs.", "fig."}
)
_MAIN_PUNCTS = frozenset({"。", "！", "？", "；", "\n", "\r", "!", "?", ";"})
_SECONDARY_PUNCTS = frozenset({"，", "、", ","})
_BOUNDED_MAIN_PUNCTS = _MAIN_PUNCTS | {".", "…", "—"}
_BOUNDED_SECONDARY_MIN_CHARS = 15
_QUOTE_CLOSERS = {"》": "《", "”": "“", "」": "「", "』": "『"}
_QUOTE_OPENERS = frozenset(_QUOTE_CLOSERS.values())
_URL_TRAILING_CHARS = frozenset(" \t\r\n,，、。！？!?；;:：)]}》”」』'\"")


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
    "VOICE_ID_RE",
    "VOICE_PROFILES",
    "VOICE_REVISION_RE",
    "StreamingSentenceSplitter",
    "VoiceCapabilities",
    "VoiceProfile",
    "VoiceRevisionConflictError",
    "VoiceRevokedError",
    "apply_crossfade",
    "bounded_sentences",
    "canonicalize_clone_reference_audio",
    "create_breath_pause",
    "generation_token_budget",
    "get_system_voice_profile",
    "normalize_tts_text",
    "resolve_voice",
    "tts_voice_class",
    "use_voice_profile",
    "validate_transcoded_clone_wav",
    "voice_revision_for_clone",
]
