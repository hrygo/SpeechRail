"""Voice-clone quality gates: report model and reference-audio grading.

Deterministic, vendor-neutral domain model for the public ``VoiceQualityReport``
shape (``contracts/openapi.yaml``) and the ``voice_quality_v1`` reference-audio
policy (``docs/architecture/voice-clone-quality-gates-and-contract.md`` S4.2).

Reference-side failure codes (the fixed enum has no dedicated code for every
metric, so "insufficient usable speech" collapses onto ``audio_too_short``):

=================================  ==================
metric                              failure code
=================================  ==================
duration (too short *or* too long)  ``audio_too_short``
``noise_floor_dbfs``                ``high_noise_floor``
``estimated_snr_db``                ``low_snr``
``clipping_ratio``                  ``clipping``
leading/trailing silence            ``audio_too_short``
``speech_active_ratio``             ``audio_too_short``
``transcript_match``                ``transcript_mismatch``
=================================  ==================

``probe_failed`` and ``output_peak_exceeded`` are synthesis-side codes and are
never produced by reference grading.  ``transcript_match`` is injected by the
caller (``None`` means "unavailable" and is skipped, never auto-passed).
"""

from __future__ import annotations

import math
import re
import struct
import unicodedata
from collections.abc import Mapping
from dataclasses import dataclass, field
from datetime import UTC, datetime
from enum import StrEnum
from typing import Any, Final
from uuid import uuid4

from speechrail.domain.itn import apply_light_itn, resolve_chinese_magnitudes

POLICY_VERSION: Final[str] = "voice_quality_v1"

_ACTIVE_THRESHOLD_DBFS: Final[float] = -45.0
_ACTIVE_THRESHOLD_RMS: Final[float] = 10.0 ** (_ACTIVE_THRESHOLD_DBFS / 20.0)
_WINDOW_SECONDS: Final[float] = 0.02
_NOISE_PERCENTILE: Final[float] = 0.10
_EPSILON: Final[float] = 1e-12
_PCM16_FULL_SCALE: Final[float] = 32768.0
_TRANSCRIPT_DIGIT_TRANSLATION: Final[dict[int, str]] = str.maketrans(
    {
        "零": "0",
        "一": "1",
        "二": "2",
        "两": "2",
        "三": "3",
        "四": "4",
        "五": "5",
        "六": "6",
        "七": "7",
        "八": "8",
        "九": "9",
    }
)
_TRANSCRIPT_SEMANTIC_SYMBOLS: Final[frozenset[str]] = frozenset({".", "%", "℃", "°"})

# `.` is kept as a semantic symbol so decimals survive, which makes NFKC's
# rewrite of `……` into `......` a trap: those six dots are an ellipsis, a pause
# marker the TTS never voices and the ASR never returns. Scored as six missing
# characters they capped the `pause_markers` probe at 0.76 on a word-for-word
# synthesis, and under the `min()` aggregate that rejected every voice. A run of
# two or more dots is never a decimal separator, so drop the run and keep the
# single dot that `22.5` needs.
_TRANSCRIPT_ELLIPSIS_RUN: Final[re.Pattern[str]] = re.compile(r"\.{2,}")

# A TTS engine reads `℃` aloud and the ASR hands the spoken unit back, so the
# two sides of a probe comparison differ in notation alone. NFKC rewrites `℃`
# to `°c`, leaving `22.5℃` and `22.5摄氏度` a whole unit word apart: a
# word-for-word synthesis scored 0.9091 on the `numbers_punct` probe, below the
# 0.92 the output gate needs for `pass`, so no voice could reach
# `production_ready`. Folding the spoken unit onto the symbol before
# normalisation makes both sides meet as `°c`.
#
# Multi-character, so this cannot be a `str.maketrans` table: that form only
# accepts single-character keys. `str.replace` rewrites the whole run at once.
_TRANSCRIPT_SPOKEN_UNITS: Final[tuple[tuple[str, str], ...]] = (("摄氏度", "°C"),)


class VoiceQualityStatus(StrEnum):
    """Quality report status ordering from weakest to strongest outcome."""

    UNEVALUATED = "unevaluated"
    PASS = "pass"
    WARN = "warn"
    REJECT = "reject"


class VoiceQualityFailureCode(StrEnum):
    """Stable failure-reason codes shared by reference and synthesis gates."""

    AUDIO_TOO_SHORT = "audio_too_short"
    LOW_SNR = "low_snr"
    HIGH_NOISE_FLOOR = "high_noise_floor"
    CLIPPING = "clipping"
    TRANSCRIPT_MISMATCH = "transcript_mismatch"
    PROBE_FAILED = "probe_failed"
    OUTPUT_PEAK_EXCEEDED = "output_peak_exceeded"
    CLONE_SPEED_UNSUPPORTED = "clone_speed_unsupported"
    OUTPUT_INVALID = "output_invalid"
    OUTPUT_NONDETERMINISTIC = "output_nondeterministic"
    TRANSCRIPTION_UNAVAILABLE = "transcription_unavailable"


VOICE_QUALITY_FAILURE_CODES: Final[tuple[str, ...]] = tuple(
    code.value for code in VoiceQualityFailureCode
)

_KNOWN_FAILURE_CODES: Final[frozenset[str]] = frozenset(VOICE_QUALITY_FAILURE_CODES)

_STATUS_RANK: Final[dict[str, int]] = {
    VoiceQualityStatus.UNEVALUATED.value: 0,
    VoiceQualityStatus.PASS.value: 1,
    VoiceQualityStatus.WARN.value: 2,
    VoiceQualityStatus.REJECT.value: 3,
}


# ---------------------------------------------------------------------------
# Serialization model
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class VoiceQualityReference:
    """Reference-audio metrics (see ``VoiceQualityReference`` in openapi.yaml)."""

    duration_seconds: float
    sample_rate: int
    channels: int
    speech_active_ratio: float
    noise_floor_dbfs: float
    estimated_snr_db: float
    clipping_ratio: float
    leading_silence_seconds: float
    trailing_silence_seconds: float
    transcript_match: float | None

    def to_dict(self) -> dict[str, Any]:
        return {
            "duration_seconds": self.duration_seconds,
            "sample_rate": self.sample_rate,
            "channels": self.channels,
            "speech_active_ratio": self.speech_active_ratio,
            "noise_floor_dbfs": self.noise_floor_dbfs,
            "estimated_snr_db": self.estimated_snr_db,
            "clipping_ratio": self.clipping_ratio,
            "leading_silence_seconds": self.leading_silence_seconds,
            "trailing_silence_seconds": self.trailing_silence_seconds,
            "transcript_match": self.transcript_match,
        }

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> VoiceQualityReference:
        if not isinstance(data, Mapping):
            raise ValueError("reference must be an object")
        transcript = data.get("transcript_match")
        return cls(
            duration_seconds=float(data.get("duration_seconds", 0.0)),
            sample_rate=int(data.get("sample_rate", 0)),
            channels=int(data.get("channels", 0)),
            speech_active_ratio=float(data.get("speech_active_ratio", 0.0)),
            noise_floor_dbfs=float(data.get("noise_floor_dbfs", 0.0)),
            estimated_snr_db=float(data.get("estimated_snr_db", 0.0)),
            clipping_ratio=float(data.get("clipping_ratio", 0.0)),
            leading_silence_seconds=float(data.get("leading_silence_seconds", 0.0)),
            trailing_silence_seconds=float(data.get("trailing_silence_seconds", 0.0)),
            transcript_match=float(transcript) if transcript is not None else None,
        )


@dataclass(frozen=True, slots=True)
class VoiceQualityProbeScore:
    """Per-probe intelligibility score for one fixed probe.

    ``synthesis.transcript_match`` aggregates the probe set, so on its own it
    cannot separate "the voice is unintelligible" from "one probe's text does
    not survive the TTS-to-ASR round trip". Carrying each probe's own score
    makes an aggregate regression attributable.
    """

    probe_id: str
    transcript_match: float
    # Whether this probe's numbers came back digit-for-digit identical.
    # `None` means the probe carries no digits and the question does not apply.
    # Kept separate from ``transcript_match`` so that field keeps meaning plain
    # character similarity: a wrong digit is a one-character edit inside a long
    # probe and scores like one, which is exactly why it needed its own verdict.
    numbers_exact: bool | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "probe_id": self.probe_id,
            "transcript_match": self.transcript_match,
            "numbers_exact": self.numbers_exact,
        }

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> VoiceQualityProbeScore:
        if not isinstance(data, Mapping):
            raise ValueError("probe score must be an object")
        raw_exact = data.get("numbers_exact")
        return cls(
            probe_id=_require_str(data.get("probe_id"), "probe_id"),
            transcript_match=float(data.get("transcript_match", 0.0)),
            numbers_exact=raw_exact if isinstance(raw_exact, bool) else None,
        )


@dataclass(frozen=True, slots=True)
class VoiceQualitySynthesis:
    """Synthesis probe metrics (see ``VoiceQualitySynthesis`` in openapi.yaml)."""

    probe_count: int
    successful_probe_count: int
    active_rms_dbfs: float
    peak_dbfs: float
    chunk_jump_p95_db: float
    clipping_ratio: float
    deterministic: bool
    transcript_match: float | None = None
    intelligibility_evaluated: bool = False
    probe_scores: list[VoiceQualityProbeScore] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "probe_count": self.probe_count,
            "successful_probe_count": self.successful_probe_count,
            "active_rms_dbfs": self.active_rms_dbfs,
            "peak_dbfs": self.peak_dbfs,
            "chunk_jump_p95_db": self.chunk_jump_p95_db,
            "clipping_ratio": self.clipping_ratio,
            "deterministic": self.deterministic,
            "transcript_match": self.transcript_match,
            "intelligibility_evaluated": self.intelligibility_evaluated,
            "probe_scores": [score.to_dict() for score in self.probe_scores],
        }

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> VoiceQualitySynthesis:
        if not isinstance(data, Mapping):
            raise ValueError("synthesis must be an object")
        raw_scores = data.get("probe_scores", [])
        if not isinstance(raw_scores, list):
            raw_scores = []
        return cls(
            probe_count=int(data.get("probe_count", 0)),
            successful_probe_count=int(data.get("successful_probe_count", 0)),
            active_rms_dbfs=float(data.get("active_rms_dbfs", 0.0)),
            peak_dbfs=float(data.get("peak_dbfs", 0.0)),
            chunk_jump_p95_db=float(data.get("chunk_jump_p95_db", 0.0)),
            clipping_ratio=float(data.get("clipping_ratio", 0.0)),
            deterministic=bool(data.get("deterministic", False)),
            transcript_match=(
                float(data["transcript_match"])
                if data.get("transcript_match") is not None
                else None
            ),
            intelligibility_evaluated=bool(data.get("intelligibility_evaluated", False)),
            probe_scores=[
                VoiceQualityProbeScore.from_dict(item)
                for item in raw_scores
                if isinstance(item, Mapping)
            ],
        )


@dataclass(frozen=True, slots=True)
class VoiceQualityReport:
    """Top-level quality report (see ``VoiceQualityReport`` in openapi.yaml)."""

    policy_version: str
    status: str
    run_id: str
    tested_at: str
    # ``None`` means "this run did not evaluate the reference audio". The output
    # gate never does; it grades synthesis only, and the reference side is
    # measured once at clone time into the voice profile. A zero-filled block
    # would read as a measurement, and every one of those zeros is the worst
    # possible value for its metric.
    reference: VoiceQualityReference | None
    synthesis: VoiceQualitySynthesis
    failure_codes: list[str]

    def to_dict(self) -> dict[str, Any]:
        return {
            "policy_version": self.policy_version,
            "status": self.status,
            "run_id": self.run_id,
            "tested_at": self.tested_at,
            "reference": None if self.reference is None else self.reference.to_dict(),
            "synthesis": self.synthesis.to_dict(),
            "failure_codes": list(self.failure_codes),
        }

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> VoiceQualityReport:
        if not isinstance(data, Mapping):
            raise ValueError("voice quality report must be an object")
        reference_raw = data.get("reference")
        synthesis_raw = data.get("synthesis")
        if not isinstance(synthesis_raw, Mapping):
            raise ValueError("voice quality report must contain a synthesis object")
        if reference_raw is not None and not isinstance(reference_raw, Mapping):
            raise ValueError("voice quality report reference must be an object or null")
        raw_codes = data.get("failure_codes", [])
        if not isinstance(raw_codes, list):
            raw_codes = []
        codes = [
            code for code in raw_codes if isinstance(code, str) and code in _KNOWN_FAILURE_CODES
        ]
        return cls(
            policy_version=_require_str(data.get("policy_version"), "policy_version"),
            status=_require_str(data.get("status"), "status"),
            run_id=_require_str(data.get("run_id"), "run_id"),
            tested_at=_require_str(data.get("tested_at"), "tested_at"),
            reference=(
                None
                if reference_raw is None
                else VoiceQualityReference.from_dict(reference_raw)
            ),
            synthesis=VoiceQualitySynthesis.from_dict(synthesis_raw),
            failure_codes=codes,
        )


def _require_str(value: object, field: str) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{field} must be a string")
    return value


# ---------------------------------------------------------------------------
# Signal metrics over mono PCM16 bytes
# ---------------------------------------------------------------------------


def _decode_pcm16_mono(pcm: bytes) -> list[int]:
    if len(pcm) % 2 != 0:
        raise ValueError("PCM16 payload length must be even")
    if not pcm:
        return []
    return list(struct.unpack(f"<{len(pcm) // 2}h", pcm))


def _normalized(pcm: bytes) -> list[float]:
    return [sample / _PCM16_FULL_SCALE for sample in _decode_pcm16_mono(pcm)]


def _rms(samples: list[float]) -> float:
    if not samples:
        return 0.0
    return math.sqrt(sum(sample * sample for sample in samples) / len(samples))


def _dbfs(amplitude: float) -> float:
    return 20.0 * math.log10(max(amplitude, _EPSILON))


def _percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    lower_value = ordered[lower]
    upper_value = ordered[upper]
    return lower_value + (upper_value - lower_value) * (position - lower)


def duration_seconds(pcm: bytes, sample_rate: int) -> float:
    """Return audio duration in seconds for mono PCM16 bytes."""
    if sample_rate <= 0:
        raise ValueError("sample_rate must be positive")
    return (len(pcm) // 2) / float(sample_rate)


def clipping_ratio(pcm: bytes) -> float:
    """Return the fraction of samples that reach the int16 full-scale rail."""
    samples = _decode_pcm16_mono(pcm)
    if not samples:
        return 0.0
    clipped = sum(1 for sample in samples if abs(sample) >= 32_767)
    return clipped / len(samples)


def speech_active_ratio(pcm: bytes, sample_rate: int) -> float:
    """Return the fraction of 20ms windows whose RMS exceeds the active threshold."""
    if sample_rate <= 0:
        raise ValueError("sample_rate must be positive")
    samples = _normalized(pcm)
    if not samples:
        return 0.0
    window_samples = max(1, round(sample_rate * _WINDOW_SECONDS))
    active = 0
    total = 0
    for start in range(0, len(samples), window_samples):
        window = samples[start : start + window_samples]
        total += 1
        if _rms(window) > _ACTIVE_THRESHOLD_RMS:
            active += 1
    return active / total


def leading_trailing_silence_seconds(
    pcm: bytes,
    sample_rate: int,
    *,
    threshold_dbfs: float = _ACTIVE_THRESHOLD_DBFS,
) -> tuple[float, float]:
    """Return (leading, trailing) silence durations for mono PCM16 bytes."""
    if sample_rate <= 0:
        raise ValueError("sample_rate must be positive")
    samples = _normalized(pcm)
    if not samples:
        return 0.0, 0.0
    threshold = 10.0 ** (threshold_dbfs / 20.0)
    window_samples = max(1, round(sample_rate * _WINDOW_SECONDS))
    window_flags: list[bool] = []
    for start in range(0, len(samples), window_samples):
        window = samples[start : start + window_samples]
        window_flags.append(_rms(window) > threshold)

    total = len(window_flags)
    leading = total
    for index, active in enumerate(window_flags):
        if active:
            leading = index
            break
    trailing = total
    for index in range(total - 1, -1, -1):
        if window_flags[index]:
            trailing = total - 1 - index
            break
    return leading * _WINDOW_SECONDS, trailing * _WINDOW_SECONDS


def noise_floor_dbfs(pcm: bytes) -> float:
    """Return a conservative low-level noise estimate in dBFS."""
    samples = _normalized(pcm)
    if not samples:
        return -120.0
    magnitudes = [abs(sample) for sample in samples if sample != 0.0]
    if not magnitudes:
        return -120.0
    return _dbfs(_percentile(magnitudes, _NOISE_PERCENTILE))


def estimated_snr_db(pcm: bytes, sample_rate: int) -> float:
    """Estimate signal-to-noise ratio from overall RMS and the noise floor."""
    if sample_rate <= 0:
        raise ValueError("sample_rate must be positive")
    samples = _normalized(pcm)
    if not samples:
        return 0.0
    overall_rms = _rms(samples)
    if overall_rms <= 0.0:
        return 0.0
    return _dbfs(overall_rms) - noise_floor_dbfs(pcm)


# ---------------------------------------------------------------------------
# Grading policy (voice_quality_v1)
# ---------------------------------------------------------------------------


def _grade_upper(
    value: float,
    pass_bound: float,
    warn_bound: float,
    code: str,
    *,
    strict_pass: bool = False,
) -> tuple[str, str | None]:
    """Lower-is-better metric.

    Passes at ``value <= pass_bound`` (or ``value < pass_bound`` when
    ``strict_pass``), warns up to ``warn_bound``, and rejects above it.
    """
    within_pass = value < pass_bound if strict_pass else value <= pass_bound
    if within_pass:
        return VoiceQualityStatus.PASS.value, None
    if value <= warn_bound:
        return VoiceQualityStatus.WARN.value, code
    return VoiceQualityStatus.REJECT.value, code


def _grade_lower(
    value: float, pass_bound: float, warn_bound: float, code: str
) -> tuple[str, str | None]:
    """Higher-is-better metric: ``>= pass_bound`` pass, ``>= warn_bound`` warn, else reject."""
    if value >= pass_bound:
        return VoiceQualityStatus.PASS.value, None
    if value >= warn_bound:
        return VoiceQualityStatus.WARN.value, code
    return VoiceQualityStatus.REJECT.value, code


def grade_reference_quality(
    metrics: VoiceQualityReference,
    *,
    transcript_match: float | None = None,
) -> tuple[str, list[str]]:
    """Apply the ``voice_quality_v1`` policy and return ``(status, failure_codes)``.

    The overall status is the most severe metric outcome; every non-passing
    metric contributes its failure code (de-duplicated, order preserved).
    """
    results: list[tuple[str, str | None]] = []

    duration = metrics.duration_seconds
    too_short = VoiceQualityFailureCode.AUDIO_TOO_SHORT.value
    if 4.0 <= duration <= 30.0:
        results.append((VoiceQualityStatus.PASS.value, None))
    elif 2.0 <= duration < 4.0 or 30.0 < duration <= 45.0:
        results.append((VoiceQualityStatus.WARN.value, too_short))
    else:
        results.append((VoiceQualityStatus.REJECT.value, too_short))

    results.append(
        _grade_upper(
            metrics.noise_floor_dbfs,
            -45.0,
            -35.0,
            VoiceQualityFailureCode.HIGH_NOISE_FLOOR.value,
        )
    )
    results.append(
        _grade_lower(
            metrics.estimated_snr_db,
            20.0,
            15.0,
            VoiceQualityFailureCode.LOW_SNR.value,
        )
    )
    results.append(
        _grade_upper(
            metrics.clipping_ratio,
            0.0001,
            0.001,
            VoiceQualityFailureCode.CLIPPING.value,
            strict_pass=True,
        )
    )

    silence = max(metrics.leading_silence_seconds, metrics.trailing_silence_seconds)
    results.append(
        _grade_upper(silence, 0.8, 1.5, VoiceQualityFailureCode.AUDIO_TOO_SHORT.value)
    )
    results.append(
        _grade_lower(
            metrics.speech_active_ratio,
            0.55,
            0.35,
            VoiceQualityFailureCode.AUDIO_TOO_SHORT.value,
        )
    )

    match_value = transcript_match if transcript_match is not None else metrics.transcript_match
    if match_value is not None:
        results.append(
            _grade_lower(
                float(match_value),
                0.98,
                0.90,
                VoiceQualityFailureCode.TRANSCRIPT_MISMATCH.value,
            )
        )

    overall = VoiceQualityStatus.PASS.value
    codes: list[str] = []
    for status, code in results:
        if _STATUS_RANK[status] > _STATUS_RANK[overall]:
            overall = status
        if status != VoiceQualityStatus.PASS.value and code is not None:
            codes.append(code)

    return overall, list(dict.fromkeys(codes))


def normalize_transcript_for_match(text: str) -> str:
    """Normalize ASR/reference text for bounded character-level comparison."""
    # Magnitudes first: `二十二点五` is arithmetic that `apply_light_itn` only
    # resolves when a decimal marker is present, and `五千三百` has no marker at
    # all, so both would otherwise reach the digit table as characters. Runs with
    # no magnitude word (`三六九`, `二零二六`) are left alone and stay positional.
    folded = resolve_chinese_magnitudes(text)
    for spoken, symbol in _TRANSCRIPT_SPOKEN_UNITS:
        folded = folded.replace(spoken, symbol)
    normalized = unicodedata.normalize("NFKC", apply_light_itn(folded)).casefold()
    normalized = _TRANSCRIPT_ELLIPSIS_RUN.sub("", normalized)
    normalized = normalized.translate(_TRANSCRIPT_DIGIT_TRANSLATION)
    return "".join(
        char
        for char in normalized
        if char.isalnum() or char in _TRANSCRIPT_SEMANTIC_SYMBOLS
    )


_TRANSCRIPT_NUMBER_RUN: Final[re.Pattern[str]] = re.compile(r"[0-9]+(?:\.[0-9]+)?")


def probe_carries_digits(text: str) -> bool:
    """Whether a probe's text contains a number worth comparing digit by digit."""
    return _TRANSCRIPT_NUMBER_RUN.search(normalize_transcript_for_match(text)) is not None


def transcript_numbers_match(expected: str, actual: str) -> bool:
    """Return whether both sides spell exactly the same numbers.

    Character edit distance is the wrong instrument for a misread digit. The
    `numbers_punct` probe is 44 characters long, so reading `22.5℃` as `25℃`
    costs one substitution -- 0.9375, clear of the 0.92 the gate needs for
    `pass` -- while the number the listener hears is simply wrong. Digit runs
    are therefore compared exactly and independently of edit distance.

    Both sides are normalized first, so `二十二点五` and `22.5` are the same
    number by the time they are compared. A side with no digits yields an empty
    list, and two empty lists are equal: the comparison is vacuously satisfied
    and callers gate applicability on :func:`probe_carries_digits`.
    """
    reference = _TRANSCRIPT_NUMBER_RUN.findall(normalize_transcript_for_match(expected))
    hypothesis = _TRANSCRIPT_NUMBER_RUN.findall(normalize_transcript_for_match(actual))
    return reference == hypothesis


def transcript_match_score(expected: str, actual: str) -> float:
    """Return normalized character similarity in ``[0, 1]`` using edit distance."""
    reference = normalize_transcript_for_match(expected)
    hypothesis = normalize_transcript_for_match(actual)
    if not reference:
        return 1.0 if not hypothesis else 0.0
    if not hypothesis:
        return 0.0

    previous = list(range(len(hypothesis) + 1))
    for row, ref_char in enumerate(reference, start=1):
        current = [row]
        for column, hyp_char in enumerate(hypothesis, start=1):
            substitution = previous[column - 1] + (ref_char != hyp_char)
            insertion = current[column - 1] + 1
            deletion = previous[column] + 1
            current.append(min(substitution, insertion, deletion))
        previous = current

    distance = previous[-1]
    return max(0.0, 1.0 - distance / max(len(reference), len(hypothesis)))


# ---------------------------------------------------------------------------
# Report construction helpers
# ---------------------------------------------------------------------------


def now_iso8601_z() -> str:
    """Return the current UTC time as an ISO8601 ``Z``-suffixed string."""
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def new_run_id() -> str:
    """Return a fresh ``vqr_``-prefixed hex run identifier."""
    return f"vqr_{uuid4().hex}"


def make_quality_report(
    reference: VoiceQualityReference,
    synthesis: VoiceQualitySynthesis,
    *,
    transcript_match: float | None = None,
) -> VoiceQualityReport:
    """Grade a reference and wrap it (with synthesis metrics) in a full report."""
    status, codes = grade_reference_quality(reference, transcript_match=transcript_match)
    return VoiceQualityReport(
        policy_version=POLICY_VERSION,
        status=status,
        run_id=new_run_id(),
        tested_at=now_iso8601_z(),
        reference=reference,
        synthesis=synthesis,
        failure_codes=codes,
    )


# ---------------------------------------------------------------------------
# Fixed Chinese probe set
# ---------------------------------------------------------------------------

VOICE_QUALITY_V1_ZH_PROBES: Final[list[dict[str, str]]] = [
    {
        "id": "self_intro",
        "category": "cross_reset_identity",
        "text": "请进行自我介绍",
    },
    {
        "id": "short_sentence",
        "category": "short",
        "text": "今天天气真好，我们开个会吧。",
    },
    {
        "id": "long_paragraph",
        "category": "long",
        "text": (
            "请先简要介绍你的工作经历和目前关注的项目，并告诉我你今天希望达成的目标，"
            "以及在执行过程中你会采用哪些优先级策略。"
        ),
    },
    {
        "id": "question_prompt",
        "category": "question",
        "text": "你认为人工智能能否真正提升我们的工作效率？为什么？",
    },
    {
        "id": "numbers_punct",
        "category": "numbers_punct",
        "text": "今天是2026年9月9日，温度是22.5℃，请你告诉我 3、6、9 的顺序。",
    },
    {
        "id": "pause_markers",
        "category": "pauses",
        "text": "我们先来——先说第一点……然后我们再讨论第二点。",
    },
]


__all__ = [
    "POLICY_VERSION",
    "VOICE_QUALITY_FAILURE_CODES",
    "VOICE_QUALITY_V1_ZH_PROBES",
    "VoiceQualityFailureCode",
    "VoiceQualityProbeScore",
    "VoiceQualityReference",
    "VoiceQualityReport",
    "VoiceQualityStatus",
    "VoiceQualitySynthesis",
    "clipping_ratio",
    "duration_seconds",
    "estimated_snr_db",
    "grade_reference_quality",
    "leading_trailing_silence_seconds",
    "make_quality_report",
    "new_run_id",
    "noise_floor_dbfs",
    "normalize_transcript_for_match",
    "now_iso8601_z",
    "probe_carries_digits",
    "speech_active_ratio",
    "transcript_match_score",
    "transcript_numbers_match",
]
