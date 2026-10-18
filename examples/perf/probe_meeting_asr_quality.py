"""Development-only ASR replay library over the current WindowAsrSession port.

The caller supplies external, frozen manifest data, an already-created session,
actual runtime identity observations, and the current audio-only VAD/boundary
adapters. This module never locates models, downloads, opens holdout, or changes
service configuration. A digest binds evidence; it does not attest its origin.
Only hashes, counts and metrics are returned. Text and PCM stay in memory.
Each case holds at most ten minutes of PCM in memory; this diagnostic feeder
is not a production bounded-stream transport. Trusted composition-root runtime
attestation is not connected: injected observers/adapters cannot certify A0.
"""

from __future__ import annotations

import asyncio
import hashlib
import math
import re
import time
import unicodedata
from collections import defaultdict
from collections.abc import Awaitable, Callable, Mapping, Sequence
from dataclasses import asdict, dataclass
from pathlib import Path
from types import MappingProxyType
from typing import Any, Literal, cast
from uuid import uuid4

from meeting_evaluation_identity import (
    MeetingCandidateSpec,
    candidate_digest,
    canonical_digest,
    validate_execution_identity,
)
from meeting_quality_metrics import paired_meeting_interval

from speechrail.application.asr_window_coordinator import AsrWindowCoordinator, Review
from speechrail.domain.asr_window import (
    FinalWindowUnit,
    WindowDecodeObservation,
    WindowDecodeRequest,
    WindowDecodeResult,
    WindowIdentity,
    WindowPolicy,
)
from speechrail.domain.audio_timeline import SampleSpan
from speechrail.domain.ports import WindowAsrSession
from speechrail.realtime.speech_admission import AdmissionDecision
from speechrail.runtime.cleanup import join_cleanup

ASR_SCORER: Mapping[str, object] = MappingProxyType(
    {
        "version": "asr-body-v2",
        "decode_evidence": "all_attempts_eos_false_within_frozen_cap_v1",
        "implementation_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "character": "NFKC_casefold_unicode_L_N_M_v1",
        "word": "NFKC_casefold_cjk_char_and_alnum_word_v1",
        "raw_character": "unicode_codepoints_v1",
        "raw_word": "whitespace_v1",
        "main_reference": "frozen_unambiguous_order_only",
        "overlap": "ambiguous_order_not_observed",
        "edit_alignment_tie": "diagonal_delete_insert_v1",
        "primary_estimator": "equal_source_group_pooled_cer_repeat_mean_errors_v1",
        "ci_estimator": "paired_equal_source_group_cer_difference_v1",
    }
)
_WORD = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]|[a-z0-9]+")
Origin = Literal["caller_reported", "fake", "runtime_observed"]


@dataclass(frozen=True, slots=True)
class AsrAdmission:
    """Current SpeechAdmission events and the earliest still-retained sample.

    The caller accounts for its VAD raw buffer when computing this frontier,
    just as RealtimeAsr does. Undecided pre-roll is not confirmed silence.
    """

    decisions: tuple[AdmissionDecision, ...]
    retained_from_sample: int


Admission = Callable[[SampleSpan, bytes], AsrAdmission]


def _validate_timeout(value: float) -> None:
    if type(value) not in {float, int} or not math.isfinite(value) or not 0 < value <= 300:
        raise ValueError("decode timeout must be finite and bounded to 300 seconds")


def _callback[T](callback: Callable[..., T], *args: object) -> T:
    try:
        return callback(*args)
    except Exception:
        raise RuntimeError("ASR external callback failed") from None


@dataclass(frozen=True, slots=True)
class AsrCase:
    """One pre-frozen development manifest entry; references never reach ASR.

    The manifest owner must freeze its unambiguous main transcript before
    inspecting candidate output. Ambiguous overlap is not arbitrarily ordered.
    manifest_sha256 binds the external manifest, not a new holdout attempt.
    """

    source_group_id: str
    manifest_sha256: str
    pcm16: bytes
    main_reference: str | None
    overlap_order: Literal["unambiguous", "ambiguous"]

    def __post_init__(self) -> None:
        if not isinstance(self.source_group_id, str) or not 1 <= len(self.source_group_id) <= 256:
            raise ValueError("invalid source meeting group")
        if re.fullmatch(r"[0-9a-f]{64}", self.manifest_sha256) is None:
            raise ValueError("manifest must be frozen by SHA-256")
        if not isinstance(self.pcm16, bytes) or not self.pcm16 or len(self.pcm16) % 2:
            raise ValueError("PCM must be nonempty mono 16 kHz PCM16")
        if len(self.pcm16) > 600 * 16000 * 2:
            raise ValueError("diagnostic case exceeds the ten-minute PCM memory bound")
        if self.main_reference is not None and not isinstance(self.main_reference, str):
            raise ValueError("main reference must be text or null")
        if self.overlap_order not in {"unambiguous", "ambiguous"}:
            raise ValueError("overlap order must be explicit")

    @property
    def reference_sha256(self) -> str:
        return canonical_digest(
            {
                "main_reference": self.main_reference,
                "overlap_order": self.overlap_order,
            }
        )

    def identity(self) -> dict[str, str]:
        values = {
            "source_group_sha256": canonical_digest({"source": self.source_group_id}),
            "manifest_sha256": self.manifest_sha256,
            "pcm_sha256": hashlib.sha256(self.pcm16).hexdigest(),
            "reference_sha256": self.reference_sha256,
            "scorer_sha256": canonical_digest(ASR_SCORER),
        }
        return {**values, "case_sha256": canonical_digest(values)}


@dataclass(frozen=True, slots=True)
class RuntimeObservation:
    """Caller-measured identity, never inferred from candidate-spec or sidecar.

    runtime_observed records the caller's claim that it measured the executable,
    model bundle and effective settings. Its values are checked for equality;
    this injection point does not independently verify runtime provenance.
    Decode-limit evidence comes only from each WindowDecodeResult.observation.
    """

    identity: Mapping[str, object]
    origin: Origin = "caller_reported"

    def __post_init__(self) -> None:
        if self.origin not in {"caller_reported", "fake", "runtime_observed"}:
            raise ValueError("invalid execution evidence origin")


def _settings(spec: MeetingCandidateSpec) -> tuple[WindowPolicy, str | None]:
    if dict(spec.scorer) != ASR_SCORER:
        raise ValueError("ASR scorer differs from the frozen normalization/overlap policy")
    preset = spec.as_dict()["preset"]
    if not {"window_policy", "vad", "language", "context"} <= preset.keys():
        raise ValueError("freeze window, VAD, language and context settings before replay")
    if preset["context"] != "empty":
        raise ValueError("diagnostic context must be empty; reference answers are forbidden")
    if not isinstance(preset["vad"], str) or not preset["vad"]:
        raise ValueError("VAD identity is required")
    if preset["language"] is not None and not isinstance(preset["language"], str):
        raise ValueError("invalid frozen language")
    if not {"max_tokens", "timestamps"} <= spec.decoder.keys():
        raise ValueError("freeze decoder limit and timestamp policy before replay")
    if type(spec.decoder["max_tokens"]) is not int or spec.decoder["max_tokens"] <= 0:
        raise ValueError("invalid frozen decoder limit")
    if type(spec.decoder["timestamps"]) is not bool:
        raise ValueError("invalid frozen timestamp policy")
    return WindowPolicy(**preset["window_policy"]), preset["language"]


class _RecordedSession:
    """Observe the actual decode boundary, not an imported transcript sidecar."""

    def __init__(
        self,
        session: WindowAsrSession,
        data: AsrCase,
        timeout_seconds: float,
        frozen_token_cap: int,
    ) -> None:
        self.session, self.data = session, data
        self.frozen_token_cap = frozen_token_cap
        self.decode_attempts: list[dict[str, Any]] = []
        self.timeout_seconds = timeout_seconds
        self.calls = 0
        self.attempts: set[str] = set()
        self.failures: set[str] = set()

    async def decode(self, request: WindowDecodeRequest) -> WindowDecodeResult:
        span = request.input_span
        if (
            span.end * 2 > len(self.data.pcm16)
            or request.pcm16 != self.data.pcm16[span.start * 2 : span.end * 2]
            or request.context != ""
            or request.attempt_id in self.attempts
        ):
            self.failures.add("input_or_attempt_mismatch")
            raise ValueError("ASR input differs from frozen PCM or reuses an attempt")
        if self.calls >= 4096:
            self.failures.add("decode_attempt_budget_exceeded")
            raise ValueError("ASR diagnostic exceeds its attempt budget")
        self.attempts.add(request.attempt_id)
        self.calls += 1
        attempt: dict[str, Any] = {
            "attempt_sha256": canonical_digest(
                {
                    "identity": asdict(request.identity),
                    "attempt_id": request.attempt_id,
                    "kind": request.kind,
                    "start_sample": span.start,
                    "end_sample": span.end,
                }
            ),
            "kind": request.kind,
            "start_sample": span.start,
            "end_sample": span.end,
            "observation_present": False,
            "observation_matches_kind": None,
            "decode_max_new_tokens": None,
            "generation_max_new_tokens": None,
            "generated_token_count": None,
            "finish_reason": "unknown",
            "truncated": None,
            "result_complete": None,
            "token_limit_hit": None,
        }
        self.decode_attempts.append(attempt)
        try:
            async with asyncio.timeout(self.timeout_seconds):
                result = await self.session.decode(request)
        except TimeoutError:
            self.failures.add("decode_timeout")
            raise
        except Exception:
            self.failures.add("decode_failed")
            # Do not put vendor messages, model paths or text into diagnostics.
            raise RuntimeError("ASR decode failed") from None
        if (result.identity, result.attempt_id, result.input_span) != (
            request.identity,
            request.attempt_id,
            request.input_span,
        ):
            self.failures.add("result_identity_mismatch")
            raise ValueError("ASR result identity mismatch")
        attempt["result_complete"] = result.complete
        observation = result.observation
        if observation is not None:
            reason = observation.finish_reason
            hit = (
                True
                if reason == "length" or observation.truncated is True
                else False
                if reason == "eos" and observation.truncated is False
                else None
            )
            attempt.update(
                observation_present=True,
                observation_matches_kind=observation.kind == request.kind,
                decode_max_new_tokens=observation.decode_max_new_tokens,
                generation_max_new_tokens=observation.generation_max_new_tokens,
                generated_token_count=observation.generated_token_count,
                finish_reason=reason
                if reason in {"eos", "length"}
                else "unknown"
                if reason is None
                else "other",
                truncated=observation.truncated,
                token_limit_hit=hit,
            )
            if observation.kind != request.kind:
                self.failures.add("decode_observation_kind_mismatch")
                raise ValueError("ASR decode observation kind mismatch")
            if observation.decode_max_new_tokens > self.frozen_token_cap:
                self.failures.add("decode_budget_exceeds_frozen_limit")
        if request.kind == "review" and not result.complete:
            self.failures.add("incomplete_decode")
            raise ValueError("ASR review is incomplete")
        return result

    def decode_evidence(self) -> dict[str, Any]:
        hits = [row["token_limit_hit"] for row in self.decode_attempts]
        hit = True if True in hits else False if hits and all(v is False for v in hits) else None
        return {
            "schema_version": 1,
            "frozen_token_cap": self.frozen_token_cap,
            "attempt_budget": 4096,
            "attempts": self.decode_attempts,
            "attempts_sha256": canonical_digest({"attempts": self.decode_attempts}),
            "attempts_with_observation": sum(
                row["observation_present"] for row in self.decode_attempts
            ),
            "attempts_without_observation": sum(
                not row["observation_present"] for row in self.decode_attempts
            ),
            "attempts_with_unknown_limit": sum(value is None for value in hits),
            "token_limit_hit": hit,
        }

    async def close(self) -> None:
        async def cleanup() -> None:
            try:
                await self.session.close()
            except Exception:
                raise RuntimeError("ASR session cleanup failed") from None

        await join_cleanup(asyncio.create_task(cleanup(), name="asr-probe-cleanup"))


def _valid_decode_evidence(report: Mapping[str, Any]) -> bool:
    """Recheck bounded diagnostic evidence; this does not attest its producer."""
    evidence = report.get("decode_evidence")
    if (
        not isinstance(evidence, Mapping)
        or type(report.get("schema_version")) is not int
        or report["schema_version"] != 2
        or type(evidence.get("schema_version")) is not int
        or evidence["schema_version"] != 1
    ):
        return False
    attempts = evidence.get("attempts")
    cap = evidence.get("frozen_token_cap")
    calls = report.get("actual_decode_calls")
    if (
        not isinstance(attempts, list)
        or type(calls) is not int
        or not 0 < calls == len(attempts) <= 4096
        or type(cap) is not int
        or cap <= 0
        or evidence.get("token_limit_hit") is not False
        or any(
            type(evidence.get(key)) is not int or evidence[key] != value
            for key, value in (
                ("attempt_budget", 4096),
                ("attempts_with_observation", calls),
                ("attempts_without_observation", 0),
                ("attempts_with_unknown_limit", 0),
            )
        )
    ):
        return False
    hashes: set[str] = set()
    for row in attempts:
        if not isinstance(row, Mapping):
            return False
        digest = row.get("attempt_sha256")
        if (
            not isinstance(digest, str)
            or re.fullmatch(r"[0-9a-f]{64}", digest) is None
            or digest in hashes
            or row.get("observation_present") is not True
            or row.get("observation_matches_kind") is not True
            or row.get("token_limit_hit") is not False
            or row.get("finish_reason") != "eos"
            or row.get("truncated") is not False
            or type(row.get("result_complete")) is not bool
            or (row.get("kind") == "review" and row["result_complete"] is not True)
        ):
            return False
        hashes.add(digest)
        start, end = row.get("start_sample"), row.get("end_sample")
        if (
            type(start) is not int
            or type(end) is not int
            or not 0 <= start < end <= report["expected_samples"]
        ):
            return False
        try:
            observed = WindowDecodeObservation.from_wire_dict(
                {
                    key: row.get(key)
                    for key in (
                        "kind",
                        "decode_max_new_tokens",
                        "generation_max_new_tokens",
                        "finish_reason",
                        "truncated",
                        "generated_token_count",
                    )
                }
            )
            if observed.decode_max_new_tokens > cap:
                return False
        except TypeError, ValueError:
            return False
    return evidence.get("attempts_sha256") == canonical_digest({"attempts": attempts})


def _edit_metrics(reference: Sequence[str], hypothesis: Sequence[str]) -> dict[str, Any]:
    if max(len(reference), len(hypothesis)) > 10000:
        raise ValueError("ASR text exceeds bounded scoring length")
    # Linear-memory shortest path counts; stable ties: diagonal, delete, insert.
    # These edit operations do not identify acoustic error causes.
    previous = [(j, 0, 0, j) for j in range(len(hypothesis) + 1)]
    for i, left in enumerate(reference, 1):
        current = [(i, 0, i, 0)]
        for j, right in enumerate(hypothesis, 1):
            diagonal, deletion, insertion = previous[j - 1], previous[j], current[-1]
            changed = int(left != right)
            current.append(
                min(
                    (
                        (diagonal[0] + changed, diagonal[1] + changed, diagonal[2], diagonal[3]),
                        (deletion[0] + 1, deletion[1], deletion[2] + 1, deletion[3]),
                        (insertion[0] + 1, insertion[1], insertion[2], insertion[3] + 1),
                    ),
                    key=lambda counts: counts[0],
                )
            )
        previous = current
    errors, substitutions, deletions, insertions = previous[-1]
    return {
        "reference_tokens": len(reference),
        "errors": errors,
        "substitutions": substitutions,
        "deletions": deletions,
        "insertions": insertions,
        "alignment_tie_policy": "diagonal_delete_insert_v1",
        "acoustic_attribution": "not_proven",
        "error_rate": errors / len(reference) if reference else None,
    }


def _metrics(data: AsrCase, hypothesis: str) -> dict[str, Any]:
    reference = data.main_reference
    available = reference is not None and data.overlap_order == "unambiguous"
    reference = reference if available and reference is not None else ""
    expected = unicodedata.normalize("NFKC", reference).casefold()
    actual = unicodedata.normalize("NFKC", hypothesis).casefold()
    raw_c = _edit_metrics(list(reference), list(hypothesis))
    raw_w = _edit_metrics(reference.split(), hypothesis.split())
    norm_c = _edit_metrics(
        [c for c in expected if unicodedata.category(c)[0] in {"L", "N", "M"}],
        [c for c in actual if unicodedata.category(c)[0] in {"L", "N", "M"}],
    )
    norm_w = _edit_metrics(_WORD.findall(expected), _WORD.findall(actual))
    return {
        "availability": "observed" if norm_c["reference_tokens"] else "not_observed",
        "raw": {
            "cer": raw_c["error_rate"],
            "wer": raw_w["error_rate"],
            "characters": raw_c,
            "words": raw_w,
        },
        "normalized": {
            "cer": norm_c["error_rate"],
            "wer": norm_w["error_rate"],
            "characters": norm_c,
            "words": norm_w,
        },
    }


def _report(
    data: AsrCase,
    spec: MeetingCandidateSpec,
    recorded: _RecordedSession,
    observation: RuntimeObservation,
    *,
    text: str,
    coverage: int,
    mode: str,
    replay_policy: Mapping[str, object],
    diagnostics: Mapping[str, object] | None = None,
) -> dict[str, Any]:
    metrics = _metrics(data, text)
    failures = set(recorded.failures)
    if not recorded.calls:
        failures.add("no_actual_decode")
    if coverage != len(data.pcm16) // 2:
        failures.add("coverage_gap_or_duplicate")
    evidence = recorded.decode_evidence()
    if evidence["attempts_with_unknown_limit"] or not recorded.calls:
        failures.add("decode_limit_not_observed")
    if evidence["token_limit_hit"]:
        failures.add("decode_limit_hit")
    if metrics["availability"] != "observed":
        failures.add("main_reference_not_observed")
    valid = not failures
    return {
        "schema_version": 2,
        "split_role": "development",
        "mode": mode,
        **data.identity(),
        "candidate_sha256": candidate_digest(spec),
        "replay_policy_sha256": canonical_digest(replay_policy),
        "weights_sha256": canonical_digest(
            {
                "model_revision": spec.model_revision,
                "model_files": dict(spec.model_files_sha256),
                "dtype": spec.dtype,
            }
        ),
        "actual_decode_calls": recorded.calls,
        "decode_evidence": evidence,
        "coverage_samples": coverage,
        "expected_samples": len(data.pcm16) // 2,
        "execution_origin": observation.origin,
        "execution_identity_matches": True,
        "runtime_identity_verified": False,
        "quality_evidence_valid": valid,
        "failures": sorted(failures),
        "metrics": metrics,
        "certification_eligible": False,
        "runtime_verification": "trusted_composition_root_not_connected",
        "diagnostics": {
            "key_facts_review": "not_observed",
            "timestamp_attribution": "not_observed",
            "error_categories": {
                "capture_or_chunk_loss": (
                    "observed" if "coverage_gap_or_duplicate" in failures else "not_proven"
                ),
                "truncation_or_repetition": (
                    "observed"
                    if {"incomplete_decode", "decode_limit_hit"} & failures
                    else "not_proven"
                ),
                "acoustic_substitution": "not_proven",
                "normalization": "scored_separately",
                "timestamp_attribution": "not_observed",
            },
            **(diagnostics or {}),
        },
    }


async def replay_long_blocks(
    data: AsrCase,
    spec: MeetingCandidateSpec,
    session: WindowAsrSession,
    *,
    observe: Callable[[], RuntimeObservation],
    block_seconds: int = 30,
    decode_timeout_seconds: float = 30,
) -> dict[str, Any]:
    """Fixed audio-grid chunks, same PCM; this is never a production candidate.

    References and reference boundaries cannot influence chunk construction.
    Compare with A0 only when weights/dtype match. Context is deliberately empty.
    The caller owns model preparation; this function always closes its session.
    """
    recorded = _RecordedSession(session, data, decode_timeout_seconds, 0)
    try:
        _validate_timeout(decode_timeout_seconds)
        _, language = _settings(spec)
        recorded.frozen_token_cap = cast(int, spec.decoder["max_tokens"])
        before = _callback(observe)
        validate_execution_identity(spec, before.identity)
        if type(block_seconds) is not int or not 1 <= block_seconds <= 30:
            raise ValueError("long-block diagnostic must be bounded to 1–30 seconds")
        text: list[str] = []
        coverage = 0
        identity = WindowIdentity("asr-diagnostic", 0, "long-block")
        for start in range(0, len(data.pcm16) // 2, block_seconds * 16000):
            span = SampleSpan(start, min(start + block_seconds * 16000, len(data.pcm16) // 2))
            try:
                result = await recorded.decode(
                    WindowDecodeRequest(
                        identity,
                        uuid4().hex,
                        "review",
                        span,
                        data.pcm16[span.start * 2 : span.end * 2],
                        language,
                        "",
                    )
                )
            except TimeoutError, ValueError, RuntimeError:
                break
            text.append(result.text)
            coverage += span.length
        after = _callback(observe)
        validate_execution_identity(spec, after.identity)
        if before.origin != after.origin:
            raise ValueError("execution evidence origin changed during replay")
        return _report(
            data,
            spec,
            recorded,
            after,
            text="".join(text),
            coverage=coverage,
            mode="bounded_long_block_diagnostic",
            replay_policy={
                "mode": "bounded_long_block_diagnostic",
                "block_seconds": block_seconds,
                "decode_timeout_seconds": decode_timeout_seconds,
            },
        )
    finally:
        await recorded.close()


async def replay_production_windows(
    data: AsrCase,
    spec: MeetingCandidateSpec,
    session: WindowAsrSession,
    *,
    observe: Callable[[], RuntimeObservation],
    admission: Admission,
    finish_admission: Callable[[], AsrAdmission] | None = None,
    pace: Callable[[float], Awaitable[None]] = asyncio.sleep,
    clock: Callable[[], float] = time.monotonic,
    review_factory: Callable[[WindowAsrSession], Review] | None = None,
    feed_samples: int = 1600,
    decode_timeout_seconds: float = 30,
) -> dict[str, Any]:
    """Exercise the production coordinator with injected current VAD/review.

    admission receives only audio and spans: it returns SpeechAdmission events
    and its retained frontier. finish_admission drains delayed EOF decisions.
    The caller must supply the actual adapters/settings and
    runtime observations for A0. A fake VAD or fake clock remains fake evidence.
    Optional review_factory can bind the current WindowBoundaryReview to the
    recorded decoder, so contextual fallback calls are observed as well.
    The feeder paces and flushes each packet sequentially. It is a diagnostic
    callable replay, not independent live capture or a real-time latency test.
    """
    recorded = _RecordedSession(session, data, decode_timeout_seconds, 0)
    coordinator: AsrWindowCoordinator | None = None
    try:
        _validate_timeout(decode_timeout_seconds)
        policy, language = _settings(spec)
        recorded.frozen_token_cap = cast(int, spec.decoder["max_tokens"])
        if type(feed_samples) is not int or not 1 <= feed_samples <= 16000:
            raise ValueError("feed size must be bounded to one second")
        before = _callback(observe)
        validate_execution_identity(spec, before.identity)
        previous_clock: float | None = None

        def measured_clock() -> float:
            nonlocal previous_clock
            value = _callback(clock)
            if (
                type(value) not in (int, float)
                or not math.isfinite(value)
                or (previous_clock is not None and value < previous_clock)
            ):
                raise ValueError("ASR replay clock must be finite and monotonic")
            previous_clock = float(value)
            return float(value)

        origin = measured_clock()
        finals: list[tuple[SampleSpan, str]] = []
        first_final: float | None = None
        sealed = 0
        covered = 0

        async def send(event: dict[str, object]) -> None:
            nonlocal sealed, covered, first_final
            if str(event["type"]) in {
                "speechrail.transcription.window.sealed",
                "speechrail.transcription.window.failed",
            }:
                span = event["closed_span"]
                if not isinstance(span, dict) or span["start"] != sealed:
                    recorded.failures.add("coverage_gap_or_duplicate")
                    return
                sealed = span["end"]
                coverage_entries = event["coverage"]
                if not isinstance(coverage_entries, list):
                    raise ValueError("invalid production coverage")
                for entry in coverage_entries:
                    part = entry["span"]
                    covered += part["end"] - part["start"]
                    if entry["outcome"] == "failed":
                        recorded.failures.add("terminal_failed")
                units = event.get("final_units", [])
                if not isinstance(units, list):
                    raise ValueError("invalid final production units")
                for unit in units:
                    owned = unit["owned_span"]
                    finals.append((SampleSpan(owned["start"], owned["end"]), unit["text"]))
                    if first_final is None:
                        first_final = measured_clock() - origin

        async def on_final(unit: FinalWindowUnit, pcm: bytes) -> None:
            if pcm != data.pcm16[unit.owned_span.start * 2 : unit.owned_span.end * 2]:
                recorded.failures.add("final_pcm_mismatch")

        coordinator = AsrWindowCoordinator(
            identity=WindowIdentity("asr-diagnostic", 0, "production"),
            policy=policy,
            scene="meeting",
            decoder=recorded,
            send=send,
            on_final=on_final,
            language=language,
            context="",
            clock=measured_clock,
            to_wire_sample=lambda value: value,
            review=_callback(review_factory, recorded) if review_factory is not None else None,
        )
        previous_admission = frontier = 0

        def apply_admission(batch: AsrAdmission, accepted: int) -> None:
            nonlocal previous_admission, frontier
            assert coordinator is not None
            if (
                type(batch.retained_from_sample) is not int
                or not frontier <= batch.retained_from_sample <= accepted
            ):
                raise ValueError("admission frontier regressed or exceeds accepted PCM")
            for decision in batch.decisions:
                if decision.kind == "audio":
                    span = SampleSpan(decision.start_sample, decision.end_sample)
                    if (
                        not max(frontier, previous_admission) <= span.start < span.end <= accepted
                        or decision.pcm != data.pcm16[span.start * 2 : span.end * 2]
                    ):
                        raise ValueError("admission has duplicate, missing or future audio")
                    previous_admission = span.end
                    coordinator.admit(span)
                elif decision.kind == "end":
                    coordinator.close_block("vad")
            frontier = batch.retained_from_sample
            coordinator.silence_before(frontier)

        for start in range(0, len(data.pcm16) // 2, feed_samples):
            end = min(start + feed_samples, len(data.pcm16) // 2)
            pcm = data.pcm16[start * 2 : end * 2]
            await pace((end - start) / 16000)
            await coordinator.append(start, pcm)
            apply_admission(_callback(admission, SampleSpan(start, end), pcm), end)
            await coordinator.flush_intents()
        if finish_admission is not None:
            apply_admission(_callback(finish_admission), len(data.pcm16) // 2)
        if frontier != len(data.pcm16) // 2:
            recorded.failures.add("vad_tail_not_drained")
        receipt = await coordinator.freeze()
        if receipt.failed_items_count:
            recorded.failures.add("terminal_failed")
        after = _callback(observe)
        validate_execution_identity(spec, after.identity)
        if before.origin != after.origin:
            raise ValueError("execution evidence origin changed during replay")
        return _report(
            data,
            spec,
            recorded,
            after,
            text="".join(text for _, text in sorted(finals, key=lambda value: value[0].start)),
            coverage=covered,
            mode="production_window",
            replay_policy={
                "mode": "production_window",
                "feed_samples": feed_samples,
                "decode_timeout_seconds": decode_timeout_seconds,
                "window_policy": policy.to_wire_dict(),
                "contextual_boundary_adapter": review_factory is not None,
            },
            diagnostics={
                "first_final_seconds": first_final,
                "clock_source": "monotonic" if clock is time.monotonic else "injected",
                "final_timing_scope": "synthetic_or_runtime_replay_not_p95",
                "input_timing_scope": "paced_sequential_feeder_not_capture_benchmark",
                "contextual_boundary_adapter": review_factory is not None,
            },
        )
    finally:
        if coordinator is not None:
            await coordinator.close()
        else:
            await recorded.close()


def _character_counts(row: Mapping[str, Any]) -> tuple[int, int] | None:
    """Check primary CER arithmetic without trusting rates or reading text."""
    metrics = row["metrics"]
    if metrics.get("availability") != "observed":
        return None
    normalized = metrics["normalized"]
    counts = normalized["characters"]
    fields = ("reference_tokens", "errors", "substitutions", "deletions", "insertions")
    if any(type(counts.get(key)) is not int or not 0 <= counts[key] <= 10000 for key in fields):
        raise ValueError("ASR character counts must be bounded nonnegative integers")
    reference, errors = counts["reference_tokens"], counts["errors"]
    substitutions, deletions, insertions = (counts[key] for key in fields[2:])
    if (
        reference == 0
        or errors != substitutions + deletions + insertions
        or substitutions + deletions > reference
        or reference - deletions + insertions > 10000
        or counts.get("alignment_tie_policy") != ASR_SCORER["edit_alignment_tie"]
        or any(
            type(rate) not in (int, float)
            or not math.isfinite(rate)
            or not math.isclose(rate, errors / reference, rel_tol=1e-12, abs_tol=1e-12)
            for rate in (counts.get("error_rate"), normalized.get("cer"))
        )
    ):
        raise ValueError("ASR character counts and CER disagree")
    return reference, errors


def compare_asr_runs(
    baseline: Sequence[Mapping[str, Any]],
    candidate: Sequence[Mapping[str, Any]],
    *,
    policy: Mapping[str, Any],
    key_facts_review: Literal["not_observed", "pass", "fail"] = "not_observed",
) -> dict[str, Any]:
    """Compare source-group macro CER and the matching paired macro interval.

    Repeat errors average per unique case, then fragment counts pool within
    source. Each source gets one vote for both point improvement and interval.
    Overall pooled CER is reported separately. Repeats never add independent N.
    The text gate is separate from real execution, human facts, coexistence,
    holdout and installation acceptance.
    This library does not certify that an injected replay is the actual A0.
    """
    if not baseline or len(baseline) != len(candidate):
        raise ValueError("paired ASR runs require the same nonempty cases")
    if key_facts_review not in {"not_observed", "pass", "fail"}:
        raise ValueError("invalid manual key facts review")
    if any(len({row["candidate_sha256"] for row in rows}) != 1 for rows in (baseline, candidate)):
        raise ValueError("each arm requires one frozen candidate identity")
    if any(
        len({row["replay_policy_sha256"] for row in rows}) != 1 for rows in (baseline, candidate)
    ):
        raise ValueError("each arm requires one frozen replay policy")
    cases: tuple[
        dict[str, dict[str, tuple[int, list[int]]]], dict[str, dict[str, tuple[int, list[int]]]]
    ] = (
        defaultdict(dict),
        defaultdict(dict),
    )
    valid = True
    eligible = True
    reference_counts: dict[str, int] = {}
    keys = (
        "source_group_sha256",
        "case_sha256",
        "pcm_sha256",
        "reference_sha256",
        "manifest_sha256",
        "scorer_sha256",
    )
    ordered = [sorted(rows, key=lambda row: row["case_sha256"]) for rows in (baseline, candidate)]
    for old, new in zip(*ordered, strict=True):
        if any(old[key] != new[key] for key in keys):
            raise ValueError("paired ASR runs differ in PCM, reference or scoring identity")
        if (
            new["mode"] == "bounded_long_block_diagnostic"
            and old["weights_sha256"] != new["weights_sha256"]
        ):
            raise ValueError("long-block diagnosis requires the same weights and dtype as A0")
        for index, row in enumerate((old, new)):
            value = row["metrics"]["normalized"]["cer"]
            counts = _character_counts(row)
            if counts is not None:
                frozen_count = reference_counts.setdefault(row["case_sha256"], counts[0])
                if frozen_count != counts[0]:
                    raise ValueError(
                        "ASR character reference count differs across paired or repeated cases"
                    )
            row_valid = (
                counts is not None
                and _valid_decode_evidence(row)
                and row["quality_evidence_valid"] is True
                and not row["failures"]
                and type(row["actual_decode_calls"]) is int
                and row["actual_decode_calls"] > 0
                and row["scorer_sha256"] == canonical_digest(ASR_SCORER)
                and row["coverage_samples"] == row["expected_samples"]
                and type(value) in {float, int}
                and math.isfinite(value)
            )
            valid = valid and row_valid
            eligible = (
                eligible
                and row["certification_eligible"] is True
                and row["runtime_identity_verified"] is True
                and row["execution_origin"] == "runtime_observed"
                and row["mode"] == "production_window"
            )
            if row_valid and counts is not None:
                entry = cases[index][row["source_group_sha256"]].setdefault(
                    row["case_sha256"],
                    (counts[0], []),
                )
                entry[1].append(counts[1])
    interval = None
    relative = None
    old_mean = new_mean = None
    old_pooled = new_pooled = None
    if valid:
        group_counts = [
            {
                source: (
                    math.fsum(math.fsum(errors) / len(errors) for _, errors in rows.values()),
                    sum(count for count, _ in rows.values()),
                )
                for source, rows in arm.items()
            }
            for arm in cases
        ]
        groups = [
            {source: [errors / count] for source, (errors, count) in arm.items()}
            for arm in group_counts
        ]
        interval = paired_meeting_interval(groups[0], groups[1], policy=policy)
        old_mean, new_mean = (
            math.fsum(math.fsum(values) / len(values) for values in group.values()) / len(group)
            for group in groups
        )
        old_pooled, new_pooled = (
            math.fsum(errors for errors, _ in arm.values())
            / sum(count for _, count in arm.values())
            for arm in group_counts
        )
        relative = (old_mean - new_mean) / old_mean if old_mean else None
    text_passed = (
        relative is not None
        and relative >= 0.1
        and interval is not None
        and interval["upper"] is not None
        and interval["upper"] < 0
    )
    passed = text_passed and eligible and key_facts_review == "pass"
    return {
        "schema_version": 1,
        "split_role": "development",
        "baseline": "unverified_replay",
        "a0_execution": "not_observed",
        "baseline_macro_cer": old_mean,
        "candidate_macro_cer": new_mean,
        "baseline_pooled_cer": old_pooled,
        "candidate_pooled_cer": new_pooled,
        "primary_point_estimator": ASR_SCORER["primary_estimator"],
        "ci_estimator": ASR_SCORER["ci_estimator"],
        "relative_cer_improvement": relative,
        "paired_cer": interval,
        "development_text_gate": "pass" if text_passed else "fail",
        "key_facts_review": key_facts_review,
        "quality_gate": "pass" if passed else "fail",
        "certification_eligible": passed,
        "holdout_coexistence_installation": "not_observed",
        "mechanism_attribution": "not_proven",
    }
