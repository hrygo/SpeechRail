"""Vendor-neutral TTS policy and the public preset voice registry."""

from __future__ import annotations

import io
import json
import logging
import math
import os
import random
import re
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import wave
from array import array
from collections.abc import Iterator, Mapping
from contextlib import contextmanager, suppress
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from types import MappingProxyType
from typing import Any

logger = logging.getLogger(__name__)

VOICE_ID_RE = re.compile(r"^[a-zA-Z0-9_-]{1,64}$")


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

    @property
    def description(self) -> str:
        """Expose the same stable text for API clients and model adapters."""
        return self.instruction or self.ref_text or ""

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


def _atomic_write_bytes(target: Path, payload: bytes, *, mode: int) -> Path:
    """Write ``payload`` to ``target`` atomically with an explicit mode.

    The payload is written to a temp file in the same directory, fsync'd, then
    ``os.replace``'d onto the target so a hard kill or write failure can never
    leave a half-written file. The final file is chmod'd to ``mode`` (e.g. 0600
    for private voice metadata/audio).
    """
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(
        prefix=f".{target.name}.", suffix=".tmp", dir=target.parent
    )
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        tmp_path.chmod(mode)
        tmp_path.replace(target)
        dir_fd = os.open(target.parent, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except BaseException:
        with suppress(OSError):
            tmp_path.unlink(missing_ok=True)
        raise
    return target


def tts_voice_class(voice: str) -> str:
    """Return a low-cardinality voice category label for metrics.

    Maps a resolved voice onto one of ``system``, ``custom`` or ``clone`` so a
    user-controlled custom/clone voice ID can never grow into an unbounded
    metric label time series. Unknown or failsafe voices resolve to ``custom``.
    """
    try:
        profile = get_voice_profile(voice)
    except (ValueError, VoiceStoreUnavailableError):
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

def transcode_and_validate_clone_audio(
    audio_bytes: bytes,
    *,
    ffmpeg_path: str = "ffmpeg",
    min_duration: float = 2.0,
    max_duration: float = 45.0,
    target_sample_rate: int = 24_000,
    skip_signal_validation: bool = False,
) -> tuple[bytes, float]:
    """Transcode user audio into 24kHz mono PCM16 WAV and validate duration limits.

    When ``skip_signal_validation`` is True the clipping/silence/speech signal
    check is skipped so the authoritative quality gate (``grade_reference_quality``)
    remains the single classifier for reference audio quality. Size, duration and
    container-format checks are always enforced.
    """
    if not audio_bytes:
        raise ValueError("audio content must not be empty")
    if len(audio_bytes) > 15 * 1024 * 1024:
        raise ValueError("audio file exceeds 15MB limit")

    try:
        proc = subprocess.run(
            [
                str(ffmpeg_path),
                "-y",
                "-i",
                "pipe:0",
                "-ac",
                "1",
                "-ar",
                str(target_sample_rate),
                "-f",
                "wav",
                "pipe:1",
            ],
            input=audio_bytes,
            capture_output=True,
            timeout=10,
            check=False,
        )
    except FileNotFoundError as exc:
        raise RuntimeError("ffmpeg_not_found") from exc
    except subprocess.TimeoutExpired as exc:
        raise ValueError("audio transcoding timed out") from exc

    if proc.returncode != 0:
        err_msg = proc.stderr.decode("utf-8", errors="replace")[:200]
        raise ValueError(f"audio transcoding failed: {err_msg}")

    wav_bytes = proc.stdout
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
    return wav_bytes, duration


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


class VoiceInUseError(RuntimeError):
    """A custom voice still has an active immutable audio reader lease."""

    code = "voice_in_use"


class VoiceRegistry:
    """Thread-safe registry with atomic metadata commits and reader leases."""

    def __init__(
        self,
        storage_path: Path | None = None,
        voices_dir: Path | None = None,
    ) -> None:
        self._storage_path = Path(
            storage_path or (Path.home() / ".speechrail" / "custom_voices.json")
        )
        self._voices_dir = Path(voices_dir or (Path.home() / ".speechrail" / "voices"))
        self._lock = threading.RLock()
        self._last_loaded_mtime_ns = 0
        self._custom_voices: dict[str, VoiceProfile] = {}
        self._store_error: str | None = None
        self._pending_profiles: dict[str, VoiceProfile] | None = None
        self._audio_readers: dict[Path, int] = {}
        self._retired_audio: set[Path] = set()
        self._load_custom_voices()

    def _mark_unavailable(self, exc: BaseException) -> None:
        self._store_error = "custom voice registry is unavailable"
        logger.warning("failed to load custom voices: %s", type(exc).__name__)

    def _load_custom_voices(self) -> None:
        with self._lock:
            self._load_custom_voices_locked()

    def _load_custom_voices_locked(self) -> None:
        if self._storage_path.parent.is_symlink():
            self._mark_unavailable(
                ValueError("custom voice registry parent must not be a symlink")
            )
            return
        if not self._storage_path.exists():
            if self._storage_path.is_symlink():
                self._mark_unavailable(ValueError("custom voice registry symlink is broken"))
                return
            self._custom_voices = {}
            self._last_loaded_mtime_ns = 0
            self._store_error = None
            return
        if not self._storage_path.is_file():
            self._mark_unavailable(ValueError("custom voice registry is not a file"))
            return
        try:
            stat = self._storage_path.stat()
            if self._storage_path.is_symlink():
                raise ValueError("custom voice registry must not be a symlink")
            if stat.st_mode & 0o077:
                self._storage_path.chmod(0o600)
            data = json.loads(self._storage_path.read_text(encoding="utf-8"))
            if not isinstance(data, list):
                raise ValueError("custom voice registry must be a JSON list")
            loaded: dict[str, VoiceProfile] = {}
            for item in data:
                profile = self._profile_from_record(item)
                if profile.id in loaded:
                    raise ValueError(f"duplicate custom voice id: {profile.id}")
                loaded[profile.id] = profile
        except Exception as exc:
            self._last_loaded_mtime_ns = self._safe_mtime_ns()
            self._mark_unavailable(exc)
            return
        self._custom_voices = loaded
        self._last_loaded_mtime_ns = stat.st_mtime_ns
        self._store_error = None

    def _safe_mtime_ns(self) -> int:
        try:
            return self._storage_path.stat().st_mtime_ns
        except OSError:
            return 0

    def _check_reload(self) -> None:
        with self._lock:
            if self._storage_path.parent.is_symlink():
                self._mark_unavailable(
                    ValueError("custom voice registry parent must not be a symlink")
                )
                return
            if not self._storage_path.exists():
                if self._storage_path.is_symlink():
                    self._mark_unavailable(ValueError("custom voice registry symlink is broken"))
                    return
                if self._last_loaded_mtime_ns or self._custom_voices:
                    self._custom_voices = {}
                    self._last_loaded_mtime_ns = 0
                    self._store_error = None
                return
            if not self._storage_path.is_file():
                self._mark_unavailable(ValueError("custom voice registry is not a file"))
                return
            try:
                mtime_ns = self._storage_path.stat().st_mtime_ns
            except OSError as exc:
                self._mark_unavailable(exc)
                return
            if mtime_ns != self._last_loaded_mtime_ns:
                self._load_custom_voices_locked()

    def _ensure_available_locked(self, *, reload: bool = False) -> None:
        if reload:
            self._load_custom_voices_locked()
        else:
            self._check_reload()
        if self._store_error is not None:
            raise VoiceStoreUnavailableError(self._store_error)

    def _profile_from_record(self, item: object) -> VoiceProfile:
        if not isinstance(item, dict):
            raise ValueError("custom voice record must be an object")
        raw_id = item.get("id")
        if not isinstance(raw_id, str):
            raise ValueError("custom voice id must be a string")
        vid = raw_id.strip().lower()
        if not VOICE_ID_RE.fullmatch(vid):
            raise ValueError("custom voice id has invalid format")
        if vid in SYSTEM_VOICE_PROFILES or vid in VOICE_ALIASES:
            raise ValueError(f"custom voice id is reserved: {vid}")

        name = item.get("name", vid)
        instruction = item.get("instruction", "")
        if not isinstance(name, str) or not isinstance(instruction, str):
            raise ValueError("custom voice name and instruction must be strings")
        raw_mode = item.get("mode")
        if raw_mode is None:
            raw_mode = "instruction" if instruction.strip() else "clone"
        if not isinstance(raw_mode, str) or raw_mode not in {"instruction", "clone"}:
            raise ValueError("custom voice mode is invalid")

        ref_text = item.get("ref_text")
        if ref_text is not None and not isinstance(ref_text, str):
            raise ValueError("custom voice ref_text must be a string")
        audio_raw = item.get("audio_path")
        if audio_raw is not None and not isinstance(audio_raw, str):
            raise ValueError("custom voice audio_path must be a string")
        audio_path: str | None = None
        if audio_raw is not None:
            audio_path = str(self._controlled_audio_path(audio_raw, vid, require_exists=True))
        if raw_mode == "clone" and (
            ref_text is None or not ref_text.strip() or audio_path is None
        ):
            raise ValueError("clone voice record is incomplete")

        seed = item.get("seed", 42)
        if type(seed) is not int or not 0 <= seed <= 2**32 - 1:
            raise ValueError("custom voice seed is invalid")
        temperature = item.get("temperature", 0.1)
        created_at = item.get("created_at", 0.0)
        duration_seconds = item.get("duration_seconds", 0.0)
        for value, field in (
            (temperature, "temperature"),
            (created_at, "created_at"),
            (duration_seconds, "duration_seconds"),
        ):
            if (
                isinstance(value, bool)
                or not isinstance(value, (int, float))
                or not math.isfinite(float(value))
                or float(value) < 0
            ):
                raise ValueError(f"custom voice {field} is invalid")
        quality_raw = item.get("quality")
        quality: dict[str, Any] | None = None
        if quality_raw is not None:
            if not isinstance(quality_raw, dict):
                raise ValueError("custom voice quality must be an object")
            quality = quality_raw
        return VoiceProfile(
            id=vid,
            name=name,
            instruction=instruction,
            seed=seed,
            temperature=float(temperature),
            is_default=False,
            is_system=False,
            created_at=float(created_at),
            mode=raw_mode,
            ref_text=ref_text,
            audio_path=audio_path,
            duration_seconds=float(duration_seconds),
            quality=quality,
        )

    def _controlled_audio_path(
        self, raw_path: str, voice_id: str, *, require_exists: bool
    ) -> Path:
        candidate = Path(raw_path)
        if not candidate.is_absolute():
            raise ValueError("voice audio path must be absolute")
        if self._voices_dir.is_symlink():
            raise ValueError("voices directory must not be a symlink")
        try:
            resolved = candidate.resolve(strict=False)
            voices_root = self._voices_dir.resolve()
        except OSError as exc:
            raise ValueError("voice audio path cannot be resolved") from exc
        if resolved.parent != voices_root:
            raise ValueError("voice audio path escapes voices directory")
        if candidate.is_symlink():
            raise ValueError("voice audio path must not be a symlink")
        if not (
            resolved.name == f"{voice_id}.wav"
            or re.fullmatch(
                rf"{re.escape(voice_id)}\.(?:[0-9a-f]{{32}}|[0-9a-f-]{{36}})\.wav",
                resolved.name,
                flags=re.IGNORECASE,
            )
        ):
            raise ValueError("voice audio path has an invalid filename")
        if require_exists and (not resolved.is_file() or not candidate.is_file()):
            raise ValueError("voice audio file is missing")
        if require_exists:
            try:
                mode = resolved.stat().st_mode
                if mode & 0o077:
                    resolved.chmod(0o600)
            except OSError as exc:
                raise ValueError("voice audio file permissions are unsafe") from exc
        return resolved

    def _prepare_store_dirs_locked(self) -> None:
        try:
            if self._storage_path.parent.is_symlink():
                raise OSError("custom voice registry parent must not be a symlink")
            if self._voices_dir.is_symlink():
                raise OSError("voices directory must not be a symlink")
            self._storage_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            self._voices_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
            if self._voices_dir.stat().st_mode & 0o077:
                self._voices_dir.chmod(0o700)
        except OSError as exc:
            raise VoiceStoreUnavailableError("custom voice store cannot be prepared") from exc

    def _save_custom_voices(self) -> None:
        # Atomic (temp + fsync + rename) and 0600 so a hard kill during a write
        # cannot leave a half-written registry.  ``_pending_profiles`` lets a
        # caller persist a private candidate before publishing it in memory.
        profiles = (
            self._pending_profiles
            if self._pending_profiles is not None
            else self._custom_voices
        )
        self._prepare_store_dirs_locked()
        data = [profile.to_dict() for profile in profiles.values()]
        payload = json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8")
        written = _atomic_write_bytes(self._storage_path, payload, mode=0o600)
        self._last_loaded_mtime_ns = written.stat().st_mtime_ns

    def _storage_state(self) -> tuple[bool, bytes | None]:
        try:
            if not self._storage_path.is_file():
                return False, None
            return True, self._storage_path.read_bytes()
        except OSError:
            return True, None

    def _commit_candidate(
        self,
        candidate: dict[str, VoiceProfile],
        *,
        new_audio: Path | None = None,
    ) -> None:
        previous = self._custom_voices
        before = self._storage_state()
        self._pending_profiles = candidate
        try:
            self._save_custom_voices()
        except BaseException as exc:
            self._pending_profiles = None
            self._custom_voices = previous
            after = self._storage_state()
            safe_to_remove = after == before and (not before[0] or before[1] is not None)
            if new_audio is not None and safe_to_remove:
                with suppress(OSError):
                    new_audio.unlink(missing_ok=True)
            elif new_audio is not None or after != before:
                self._mark_unavailable(RuntimeError("registry commit outcome is uncertain"))
                raise VoiceStoreUnavailableError(
                    "custom voice registry commit is uncertain"
                ) from exc
            raise
        finally:
            self._pending_profiles = None
        self._custom_voices = candidate
        self._store_error = None

    def _retire_audio_locked(self, raw_path: str | None, voice_id: str) -> None:
        if raw_path is None:
            return
        path = self._controlled_audio_path(raw_path, voice_id, require_exists=False)
        if not path.exists():
            return
        if self._audio_readers.get(path, 0) > 0:
            self._retired_audio.add(path)
            return
        try:
            path.unlink(missing_ok=True)
        except OSError as exc:
            self._retired_audio.add(path)
            logger.warning("failed to clean retired voice audio: %s", type(exc).__name__)

    def _cleanup_retired_locked(self) -> None:
        for path in tuple(self._retired_audio):
            if self._audio_readers.get(path, 0) > 0:
                continue
            try:
                path.unlink(missing_ok=True)
            except OSError as exc:
                logger.warning("failed to clean retired voice audio: %s", type(exc).__name__)
                continue
            self._retired_audio.discard(path)

    def _voice_has_readers_locked(self, voice_id: str) -> bool:
        prefix = f"{voice_id}."
        legacy = f"{voice_id}.wav"
        for path, readers in self._audio_readers.items():
            if readers > 0 and (path.name == legacy or path.name.startswith(prefix)):
                return True
        return False

    def list_profiles(self) -> list[VoiceProfile]:
        with self._lock:
            self._ensure_available_locked(reload=True)
            system = list(SYSTEM_VOICE_PROFILES.values())
            custom = sorted(
                self._custom_voices.values(), key=lambda v: v.created_at, reverse=True
            )
            return system + custom

    def get_profile(self, voice: str) -> VoiceProfile:
        resolved = resolve_voice(voice)
        if resolved in SYSTEM_VOICE_PROFILES:
            return SYSTEM_VOICE_PROFILES[resolved]
        with self._lock:
            self._ensure_available_locked(reload=True)
            if resolved in self._custom_voices:
                return self._custom_voices[resolved]
        raise ValueError(f"unknown preset voice: {voice}")

    @contextmanager
    def lease_profile(self, voice: str) -> Iterator[VoiceProfile]:
        """Lease an immutable profile snapshot while a backend reads its audio."""

        resolved = resolve_voice(voice)
        audio_path: Path | None = None
        with self._lock:
            if resolved in SYSTEM_VOICE_PROFILES:
                profile = SYSTEM_VOICE_PROFILES[resolved]
            else:
                self._ensure_available_locked(reload=True)
                custom_profile = self._custom_voices.get(resolved)
                if custom_profile is None:
                    raise ValueError(f"unknown preset voice: {voice}")
                profile = custom_profile
                if profile.audio_path is not None:
                    try:
                        audio_path = self._controlled_audio_path(
                            profile.audio_path, profile.id, require_exists=True
                        )
                    except ValueError as exc:
                        raise VoiceStoreUnavailableError(
                            "custom voice audio is unavailable"
                        ) from exc
                    self._audio_readers[audio_path] = self._audio_readers.get(audio_path, 0) + 1
        try:
            yield profile
        finally:
            if audio_path is not None:
                with self._lock:
                    readers = self._audio_readers.get(audio_path, 0)
                    if readers <= 1:
                        self._audio_readers.pop(audio_path, None)
                    else:
                        self._audio_readers[audio_path] = readers - 1
                    self._cleanup_retired_locked()

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
        if len(instruction.strip()) > 10_000:
            raise ValueError("voice instruction exceeds the 10000 character limit")
        if voice_id:
            vid = voice_id.strip().lower()
            if not VOICE_ID_RE.fullmatch(vid):
                raise ValueError("voice_id must match regex ^[a-zA-Z0-9_-]{1,64}$")
        else:
            vid = f"custom_{int(time.time())}_{uuid.uuid4().hex[:4]}"
        if vid in SYSTEM_VOICE_PROFILES or vid in VOICE_ALIASES:
            raise ValueError(f"cannot override system voice ID: {vid}")
        if seed is not None and (type(seed) is not int or not 0 <= seed <= 2**32 - 1):
            raise ValueError("voice seed must be between 0 and 4294967295")

        profile = VoiceProfile(
            id=vid,
            name=name.strip(),
            instruction=instruction.strip(),
            seed=seed if seed is not None else random.randint(1000, 999999),
            temperature=0.1,
            is_default=False,
            is_system=False,
            created_at=time.time(),
            mode="instruction",
        )
        with self._lock:
            self._ensure_available_locked(reload=True)
            previous = self._custom_voices.get(vid)
            candidate = dict(self._custom_voices)
            candidate[vid] = profile
            self._commit_candidate(candidate)
            if previous is not None:
                self._retire_audio_locked(previous.audio_path, vid)
            return profile

    def create_cloned_profile(
        self,
        *,
        name: str,
        ref_text: str,
        audio_bytes: bytes,
        voice_id: str | None = None,
        duration_seconds: float,
        quality: dict[str, Any] | None = None,
    ) -> VoiceProfile:
        if not name.strip():
            raise ValueError("voice name must not be empty")
        if not ref_text.strip():
            raise ValueError("ref_text must not be empty")
        if voice_id:
            vid = voice_id.strip().lower()
            if not VOICE_ID_RE.fullmatch(vid):
                raise ValueError("voice_id must match regex ^[a-zA-Z0-9_-]{1,64}$")
        else:
            vid = f"clone_{int(time.time())}_{uuid.uuid4().hex[:6]}"
        if vid in SYSTEM_VOICE_PROFILES or vid in VOICE_ALIASES:
            raise ValueError(f"cannot override system voice ID: {vid}")
        if (
            isinstance(duration_seconds, bool)
            or not isinstance(duration_seconds, (int, float))
            or not math.isfinite(float(duration_seconds))
            or duration_seconds < 0
        ):
            raise ValueError("duration_seconds must be a non-negative number")
        if quality is not None and not isinstance(quality, dict):
            raise ValueError("quality must be an object")

        with self._lock:
            self._ensure_available_locked(reload=True)
            self._prepare_store_dirs_locked()
            target_file = (self._voices_dir / f"{vid}.{uuid.uuid4().hex}.wav").resolve()
            self._controlled_audio_path(str(target_file), vid, require_exists=False)
            _atomic_write_bytes(target_file, audio_bytes, mode=0o600)
            previous = self._custom_voices.get(vid)
            profile = VoiceProfile(
                id=vid,
                name=name.strip(),
                instruction="",
                seed=42,
                temperature=0.1,
                is_default=False,
                is_system=False,
                created_at=time.time(),
                mode="clone",
                ref_text=ref_text.strip(),
                audio_path=str(target_file),
                duration_seconds=round(float(duration_seconds), 2),
                quality=quality,
            )
            candidate = dict(self._custom_voices)
            candidate[vid] = profile
            self._commit_candidate(candidate, new_audio=target_file)
            if previous is not None:
                self._retire_audio_locked(previous.audio_path, vid)
            return profile

    def delete_custom_profile(self, voice_id: str) -> None:
        vid = voice_id.strip().lower()
        if not VOICE_ID_RE.fullmatch(vid):
            raise ValueError("invalid voice ID format")
        if vid in SYSTEM_VOICE_PROFILES or vid in VOICE_ALIASES:
            raise ValueError(f"system voice cannot be deleted: {vid}")
        with self._lock:
            self._ensure_available_locked(reload=True)
            profile = self._custom_voices.get(vid)
            if profile is None:
                raise KeyError(f"custom voice not found: {vid}")
            if self._voice_has_readers_locked(vid):
                raise VoiceInUseError(f"custom voice is in use: {vid}")
            candidate = dict(self._custom_voices)
            del candidate[vid]
            self._commit_candidate(candidate)
            if profile.audio_path is not None:
                try:
                    path = self._controlled_audio_path(
                        profile.audio_path, vid, require_exists=False
                    )
                    path.unlink(missing_ok=True)
                except OSError as exc:
                    self._retired_audio.add(path)
                    self._mark_unavailable(exc)
                    raise VoiceStoreUnavailableError(
                        "custom voice metadata deleted but audio cleanup failed"
                    ) from exc


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
    "VOICE_ID_RE",
    "VOICE_PROFILES",
    "StreamingSentenceSplitter",
    "VoiceCapabilities",
    "VoiceProfile",
    "VoiceRegistry",
    "apply_crossfade",
    "bounded_sentences",
    "canonicalize_clone_reference_audio",
    "create_breath_pause",
    "generation_token_budget",
    "get_voice_profile",
    "get_voice_registry",
    "normalize_tts_text",
    "resolve_voice",
    "transcode_and_validate_clone_audio",
    "tts_voice_class",
]
