"""Phase 1 (1-4 speakers) Sortformer & speaker-attributed ASR evaluation probe.

Enforces external archive/manifest locks (rejecting .partial archives, R004
holdout fixtures, Eval_Ali development misuse, >4 speaker sessions, and multi-
candidate tuning sweeps on frozen holdouts), freezes the Phase 1 candidate
model/algorithm/threshold/scoring specification before any frozen holdout is
unlocked, bridges 16 kHz mono PCM16 audio through the 4-slot Sortformer
protocol-v1 session interface, and computes three-way metrics per session and
stratified across 1, 2, 3, and 4 speakers:
  1. ASR-only: normalized CER and token/word WER.
  2. Diarization-only: DER, JER, comparable DER (collar=0.25, skip_overlap),
     known_coverage (>=90%), known_accuracy (>=95%), top_four_min_known_coverage
     (>=95%), with other_min_known_coverage marked not applicable for <=4 speakers.
  3. Legacy product cp/tcp text metrics with an explicit unknown penalty,
     plus temporal-oracle diagnostics. Standard cp/tcp/DI-cp metrics are
     provided independently by meeting_quality_metrics.
"""

from __future__ import annotations

import argparse
import asyncio
import gzip
import hashlib
import itertools
import json
import math
import re
import shutil
import sys
import tarfile
import unicodedata
import wave
from collections.abc import Callable, Sequence
from dataclasses import asdict
from pathlib import Path
from typing import Any, cast

try:
    from .asr_quality import character_error_metrics  # type: ignore[import-not-found]
    from .diarization_quality import score_diarization  # type: ignore[import-not-found]
    from .meeting_evaluation_identity import (
        MeetingCandidateSpec,
        candidate_digest,
        file_digest,
        model_file_digests,
        validate_execution_identity,
    )
except ImportError:  # pragma: no cover - direct CLI or top-level import
    from asr_quality import (  # type: ignore[no-redef,import-not-found]
        character_error_metrics,
    )
    from diarization_quality import (  # type: ignore[no-redef,import-not-found]
        score_diarization,
    )
    from meeting_evaluation_identity import (
        MeetingCandidateSpec,
        candidate_digest,
        file_digest,
        model_file_digests,
        validate_execution_identity,
    )

from speechrail.backends.diarization.coreml import (  # type: ignore[import-untyped]
    FLUIDAUDIO_COMMIT,
    MODEL_BUNDLE_NAME,
    MODEL_REVISION,
    CoreMLSortformerEngine,
)
from speechrail.backends.diarization.slot_postpass import (  # type: ignore[import-untyped]
    SlotConsolidationConfig,
    consolidate_slot_spans,
)
from speechrail.domain.diarization.ports import (  # type: ignore[import-untyped]
    ActivitySession,
)
from speechrail.domain.diarization.types import (  # type: ignore[import-untyped]
    ActivityFrame,
)

JsonDict = dict[str, Any]
_FROZEN_SPLIT_ROLES = frozenset({"frozen_holdout", "frozen_evaluation"})
_ALLOWED_SPLIT_ROLES = frozenset({"development"}) | _FROZEN_SPLIT_ROLES
_FORBIDDEN_DEV_TOKENS = ("r004", "eval_ali", "alimeeting_eval", "alimeeting-eval")
_TOKEN_PATTERN = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]|[a-z0-9]+")
_REQUIRED_STRATA = (1, 2, 3, 4)


def _file_digest(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def _require_external_path(path: Path, *, repository_root: Path) -> Path:
    resolved = path.expanduser().resolve()
    root = repository_root.resolve()
    if resolved == root or resolved.is_relative_to(root):
        raise ValueError("evaluation inputs and outputs must remain outside the repository")
    return resolved


def _is_real_number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def frozen_phase1_candidate_spec(*, repository_root: Path) -> JsonDict:
    """Explain historical schema-1 results; never use this identity for new certification."""
    root = repository_root.resolve()
    catalog_path = root / "src/speechrail/assets/model-catalog.json"
    runtime_lock_path = root / "src/speechrail/assets/runtime-lock.json"
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    runtime_lock = json.loads(runtime_lock_path.read_text(encoding="utf-8"))

    raw_artifacts = catalog.get("artifacts", [])
    artifacts: dict[str, JsonDict] = (
        {
            str(item["key"]): cast(JsonDict, item)
            for item in raw_artifacts
            if isinstance(item, dict) and "key" in item
        }
        if isinstance(raw_artifacts, list)
        else {}
    )
    diar_artifact = artifacts.get("diarization-sortformer-fp16", {})
    asr_quality = artifacts.get("asr-1.7b-q8", {})
    asr_reference = artifacts.get("asr-1.7b-bf16", {})
    aligner = artifacts.get("aligner-bf16", {})

    spec_payload: JsonDict = {
        "schema_version": 1,
        "phase": "phase1_sortformer_1to4",
        "runtime_lock": {
            "id": runtime_lock.get("id"),
            "python": runtime_lock.get("python"),
            "asr_requirements_count": len(runtime_lock.get("asr_requirements", [])),
        },
        "diarization": {
            "backend": "sortformer",
            "artifact_key": "diarization-sortformer-fp16",
            "model_id": (
                diar_artifact.get("model_id") or "FluidInference/diar-streaming-sortformer-coreml"
            ),
            "model_bundle": "SortformerNvidiaLow_v2.1.mlmodelc",
            "model_revision": (
                diar_artifact.get("revision") or "ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1"
            ),
            "dtype": "fp16",
            "fluidaudio_sdk_commit": "5c19d5e12320e22bbfb7a1877b089d2665a69add",
            "sortformer_config": "SortformerConfig.balancedV2_1",
            "activity_threshold": 0.25,
            "timeline_max_stored_seconds": 60.0,
            "eof_padding": "one_right_context_silence_clipped_to_accepted_samples",
            "system_cap": 4,
            "max_speakers": 4,
            "sample_rate_hz": 16000,
        },
        "asr": {
            "quality_tier_artifact": {
                "artifact_key": "asr-1.7b-q8",
                "model_id": asr_quality.get("model_id"),
                "revision": asr_quality.get("revision"),
                "quantization": asr_quality.get("quantization"),
            },
            "reference_tier_artifact": {
                "artifact_key": "asr-1.7b-bf16",
                "model_id": asr_reference.get("model_id"),
                "revision": asr_reference.get("revision"),
                "quantization": asr_reference.get("quantization"),
            },
            "aligner_artifact": {
                "artifact_key": "aligner-bf16",
                "model_id": aligner.get("model_id"),
                "revision": aligner.get("revision"),
                "quantization": aligner.get("quantization"),
            },
        },
        "attribution_algorithm": {
            "frame_to_span_merge_tolerance_seconds": 1e-6,
            "utterance_to_span_rule": "max_temporal_overlap_with_unknown_fallback",
            "unknown_label_policy": "never_mapped_to_reference_retained_in_error_denominator",
        },
        "scoring_and_quality_gates": {
            "required_speaker_strata": [1, 2, 3, 4],
            "text_normalization": "NFKC_casefold_unicode_L_N_M",
            "word_tokenization": "NFKC_casefold_cjk_char_and_alnum_word_v1",
            "der_collar_seconds": 0.0,
            "der_skip_overlap": False,
            "comparable_der_collar_seconds": 0.25,
            "comparable_der_skip_overlap": True,
            "tcp_collar_seconds": 5.0,
            "known_coverage_min": 0.90,
            "known_accuracy_min": 0.95,
            "top_four_min_known_coverage_min": 0.95,
            "other_min_known_coverage_le_4_speakers": "not_applicable",
        },
    }
    canonical_bytes = json.dumps(spec_payload, sort_keys=True, separators=(",", ":")).encode(
        "utf-8"
    )
    spec_sha256 = hashlib.sha256(canonical_bytes).hexdigest()
    return {
        "candidate_spec_sha256": spec_sha256,
        "spec": spec_payload,
    }


def sortformer_execution_spec(
    *,
    repository_root: Path,
    executable: Path,
    model_path: Path,
    consolidate: bool,
) -> MeetingCandidateSpec:
    """Measure local artifact bytes and bind every effective legacy decoder knob."""
    root = repository_root.resolve()
    return MeetingCandidateSpec(
        implementation_id="speechrail-sortformer-v2.1-diagnostic-v2",
        adapter_sha256=file_digest(root / "src/speechrail/backends/diarization/coreml.py"),
        sdk_revision=FLUIDAUDIO_COMMIT,
        worker_sha256=file_digest(executable),
        model_revision=MODEL_REVISION,
        model_files_sha256=model_file_digests(model_path),
        dtype="fp16",
        compute_units="all",
        preset={
            "name": "balancedV2_1",
            "numSpeakers": 4,
            "preEncoderDims": 512,
            "subsamplingFactor": 8,
            "chunkLen": 6,
            "chunkLeftContext": 1,
            "chunkRightContext": 7,
            "fifoLen": 188,
            "spkcacheLen": 188,
            "spkcacheUpdatePeriod": 144,
            "spkcacheSilFramesPerSpk": 3,
            "debugMode": False,
            "sampleRate": 16000,
            "melWindow": 400,
            "melStride": 160,
            "melFeatures": 128,
            "silenceThreshold": 0.2,
            "predScoreThreshold": 0.25,
            "scoresBoostLatest": 0.05,
            "strongBoostRate": 0.75,
            "weakBoostRate": 1.5,
            "minPosScoresRate": 0.5,
            "maxIndex": 99999,
            "timeline_max_stored_seconds": 60,
            "timeline_store_segments": False,
            "worker_source_sha256": file_digest(
                root / "native/diarization/Sources/SpeechRailDiarizationWorker/main.swift"
            ),
        },
        decoder={
            "activity_threshold": 0.25,
            "activity_comparison": ">=",
            "eof_padding": "one_right_context_clipped_to_accepted_samples",
            "consolidation": {"enabled": consolidate, **asdict(SlotConsolidationConfig())},
            "consolidation_source_sha256": file_digest(
                root / "src/speechrail/backends/diarization/slot_postpass.py"
            ),
        },
        attribution={
            "algorithm": "max_temporal_overlap_with_unknown_fallback",
            "unknown": "retain",
            "probe_sha256": file_digest(Path(__file__)),
        },
        scorer={
            "version": "legacy-diagnostic-v2",
            "certification_eligible": False,
            "source_sha256": file_digest(root / "examples/perf/diarization_quality.py"),
            "collar": 0.0,
            "skip_overlap": False,
            "tcp_collar_seconds": 5.0,
            "normalization": "NFKC_casefold_unicode_L_N_M",
            "word_tokenization": "NFKC_casefold_cjk_char_and_alnum_word_v1",
        },
    )


def verify_archive_ready(
    archive_path: Path,
    *,
    repository_root: Path,
    expected_sha256: str,
    publisher_sha256: str | None = None,
) -> JsonDict:
    """Verify an external tar.gz corpus archive before unpacking or manifest generation.

    Rejects `.partial` downloads, missing files, corrupted gzip streams, or
    digest mismatches. Explicitly distinguishes local SHA-256 consistency from
    official publisher checksum verification.
    """
    if re.fullmatch(r"[0-9a-f]{64}", expected_sha256) is None:
        raise ValueError("expected_sha256 must be a 64-character lowercase hex digest")
    if publisher_sha256 is not None and re.fullmatch(r"[0-9a-f]{64}", publisher_sha256) is None:
        raise ValueError("publisher_sha256 must be a 64-character lowercase hex digest")
    if archive_path.name.endswith(".partial") or ".partial." in archive_path.name:
        raise ValueError("partial archive download cannot be used as a verified corpus")

    resolved = _require_external_path(archive_path, repository_root=repository_root)
    if not resolved.is_file():
        raise ValueError("corpus archive is unavailable")

    actual_sha256 = _file_digest(resolved)
    if actual_sha256 != expected_sha256:
        raise ValueError("corpus archive digest differs from expected_sha256")
    if publisher_sha256 is not None and actual_sha256 != publisher_sha256:
        raise ValueError("corpus archive digest differs from official publisher_sha256")

    member_count = 0
    try:
        with gzip.open(resolved, "rb") as gz_stream:
            while gz_stream.read(1024 * 1024):
                pass
        with tarfile.open(resolved, mode="r:gz") as tar_stream:
            for member in tar_stream:
                if member.isfile():
                    member_count += 1
    except (OSError, EOFError, tarfile.TarError) as exc:
        raise ValueError("corpus archive failed gzip/tar integrity verification") from exc

    if member_count <= 0:
        raise ValueError("corpus archive contains no files")

    return {
        "archive_name": resolved.name,
        "size_bytes": resolved.stat().st_size,
        "sha256": actual_sha256,
        "gzip_tar_valid": True,
        "file_member_count": member_count,
        "publisher_checksum_verified": publisher_sha256 is not None,
    }


def _contains_forbidden_dev_token(text: str) -> bool:
    lowered = text.casefold()
    return any(tok in lowered for tok in _FORBIDDEN_DEV_TOKENS)


def validate_locked_1to4_manifest(
    manifest_path: Path,
    manifest_bytes: bytes,
    *,
    repository_root: Path,
    candidate_count: int = 1,
) -> tuple[list[JsonDict], JsonDict]:
    """Validate a locked 1-4 speaker manifest and enforce split-role boundaries."""
    resolved_manifest = _require_external_path(manifest_path, repository_root=repository_root)
    if candidate_count < 1:
        raise ValueError("candidate_count must be positive")
    try:
        manifest = json.loads(manifest_bytes)
        split_lock = json.loads(resolved_manifest.with_name("split-lock.json").read_bytes())
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError(
            "1-4 speaker evaluation requires a locked manifest and split-lock.json"
        ) from exc

    if not isinstance(manifest, dict) or not isinstance(split_lock, dict):
        raise ValueError("invalid manifest or split-lock structure")

    split_role = manifest.get("split_role")
    if split_role not in _ALLOWED_SPLIT_ROLES:
        raise ValueError(
            "manifest must declare split_role as development, frozen_holdout, or frozen_evaluation"
        )
    if split_role in _FROZEN_SPLIT_ROLES and candidate_count > 1:
        raise ValueError(
            "frozen holdout/evaluation splits (such as AliMeeting Eval) cannot run "
            "multi-candidate tuning sweeps"
        )

    splits = split_lock.get("splits")
    split_entry = splits.get(split_role) if isinstance(splits, dict) else None
    digest = hashlib.sha256(manifest_bytes).hexdigest()
    if (
        not isinstance(split_entry, dict)
        or split_entry.get("manifest_sha256") != digest
        or split_lock.get("speaker_count_cap") != 4
    ):
        raise ValueError("manifest digest or speaker_count_cap does not match split-lock.json")

    if isinstance(splits, dict):
        for other_role in ("holdout", "frozen_holdout", "frozen_evaluation"):
            if other_role == split_role:
                continue
            other_entry = splits.get(other_role)
            if isinstance(other_entry, dict) and other_entry.get("manifest_sha256") == digest:
                raise ValueError("holdout manifest cannot be evaluated as a development split")

    dataset_name = str(manifest.get("dataset") or split_lock.get("dataset") or "")
    source_split = str(manifest.get("source_split") or split_entry.get("source_split") or "")
    if split_role == "development" and (
        _contains_forbidden_dev_token(dataset_name)
        or _contains_forbidden_dev_token(source_split)
        or source_split.casefold() in {"eval", "test", "holdout"}
    ):
        raise ValueError(
            "AliMeeting Eval or holdout splits cannot be partitioned or used as development"
        )

    fixtures = manifest.get("fixtures")
    if not isinstance(fixtures, list) or not fixtures:
        raise ValueError("manifest must contain at least one 1-4 speaker session fixture")

    seen_ids: set[str] = set()
    validated_fixtures: list[JsonDict] = []
    for item in fixtures:
        if not isinstance(item, dict):
            raise ValueError("fixture entry must be an object")
        identifier = item.get("id")
        speakers_count = item.get("speakers_count")
        duration = item.get("duration_seconds")
        audio_sha = item.get("audio_sha256")
        ref_sha = item.get("reference_sha256")
        if (
            not isinstance(identifier, str)
            or not identifier.strip()
            or "R004" in identifier
            or identifier in seen_ids
            or type(speakers_count) is not int
            or not 1 <= speakers_count <= 4
            or not _is_real_number(duration)
            or not math.isfinite(float(cast(float, duration)))
            or float(cast(float, duration)) <= 0
            or not isinstance(audio_sha, str)
            or re.fullmatch(r"[0-9a-f]{64}", audio_sha) is None
            or not isinstance(ref_sha, str)
            or re.fullmatch(r"[0-9a-f]{64}", ref_sha) is None
        ):
            raise ValueError("fixture violates 1-4 speaker, R004-holdout, or digest lock rules")
        if split_role == "development" and _contains_forbidden_dev_token(identifier):
            raise ValueError(
                "AliMeeting Eval or R004 fixture cannot be used in a development split"
            )
        seen_ids.add(identifier)
        validated_fixtures.append(cast(JsonDict, item))

    if split_entry.get("sessions") != len(validated_fixtures):
        raise ValueError("split-lock session count differs from manifest fixtures")

    return validated_fixtures, {
        "dataset": split_lock.get("dataset"),
        "license": split_lock.get("license"),
        "split_role": split_role,
        "manifest_sha256": digest,
        "session_count": len(validated_fixtures),
        "speaker_counts": [int(f["speakers_count"]) for f in validated_fixtures],
    }


def validate_frozen_holdout_unlock(
    development_receipt_path: Path,
    *,
    repository_root: Path,
    expected_candidate_spec_sha256: str,
    holdout_manifest_sha256: str,
) -> JsonDict:
    """Verify development certification passed with the frozen spec before unlocking holdout."""
    resolved = _require_external_path(development_receipt_path, repository_root=repository_root)
    if re.fullmatch(r"[0-9a-f]{64}", expected_candidate_spec_sha256) is None:
        raise ValueError("expected_candidate_spec_sha256 must be a 64-character hex digest")
    if re.fullmatch(r"[0-9a-f]{64}", holdout_manifest_sha256) is None:
        raise ValueError("holdout_manifest_sha256 must be a 64-character hex digest")
    try:
        receipt = json.loads(resolved.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError(
            "frozen holdout requires a readable development certification receipt"
        ) from exc

    if not isinstance(receipt, dict):
        raise ValueError("invalid development certification receipt")

    dev_manifest_sha = receipt.get("manifest_sha256")
    if (
        receipt.get("split_role") != "development"
        or not isinstance(dev_manifest_sha, str)
        or re.fullmatch(r"[0-9a-f]{64}", dev_manifest_sha) is None
        or dev_manifest_sha == holdout_manifest_sha256
    ):
        raise ValueError(
            "development receipt must come from a distinct locked development manifest"
        )
    if receipt.get("candidate_spec_sha256") != expected_candidate_spec_sha256:
        raise ValueError(
            "development receipt candidate_spec_sha256 does not match frozen candidate spec"
        )
    if (
        receipt.get("all_1to4_strata_observed") is not True
        or receipt.get("phase1_diarization_certified") is not True
        or receipt.get("verdict") != "go"
    ):
        raise ValueError(
            "frozen holdout is locked: development 1-4 speaker strata or quality gates did not pass"
        )

    raise ValueError(
        "legacy Phase 1 receipts are diagnostic only; use the v2 identity/policy holdout gate"
    )


def _tokenize_words(text: str) -> list[str]:
    normalized = unicodedata.normalize("NFKC", text).casefold()
    return _TOKEN_PATTERN.findall(normalized)


def _normalized_chars(text: str) -> list[str]:
    normalized = unicodedata.normalize("NFKC", text).casefold()
    return [c for c in normalized if unicodedata.category(c)[0] in {"L", "N", "M"}]


def _join_utterance_text(utterances: Sequence[JsonDict]) -> str:
    return " ".join(str(utterance["text"]) for utterance in utterances)


def _sequence_edit_distance(expected: Sequence[str], actual: Sequence[str]) -> int:
    if not expected:
        return len(actual)
    if not actual:
        return len(expected)
    previous = list(range(len(actual) + 1))
    for row, left in enumerate(expected, 1):
        current = [row]
        for column, right in enumerate(actual, 1):
            current.append(
                min(
                    current[-1] + 1,
                    previous[column] + 1,
                    previous[column - 1] + (left != right),
                )
            )
        previous = current
    return previous[-1]


def word_error_metrics(reference: str, hypothesis: str) -> JsonDict:
    """Compute normalized token/word error rate (CJK character + Latin/number word tokens)."""
    expected = _tokenize_words(reference)
    actual = _tokenize_words(hypothesis)
    if max(len(expected), len(actual)) > 20_000:
        raise ValueError("ASR word-error text exceeds scoring bounds")
    errors = _sequence_edit_distance(expected, actual)
    return {
        "reference_words": len(expected),
        "hypothesis_words": len(actual),
        "word_errors": errors,
        "wer": errors / len(expected) if expected else None,
        "tokenization": "NFKC_casefold_cjk_char_and_alnum_word_v1",
    }


def _validate_timed_utterances(
    utterances: Sequence[JsonDict],
    *,
    duration: float,
    allow_unknown: bool,
) -> list[JsonDict]:
    validated: list[JsonDict] = []
    for row in utterances:
        if not isinstance(row, dict):
            raise ValueError("utterance must be an object")
        start = row.get("start")
        end = row.get("end")
        speaker = row.get("speaker")
        text = row.get("text")
        if (
            not _is_real_number(start)
            or not _is_real_number(end)
            or not isinstance(speaker, str)
            or not speaker
            or (not allow_unknown and speaker == "unknown")
            or not isinstance(text, str)
        ):
            raise ValueError("invalid speaker-attributed utterance row")
        start_f = float(cast(float, start))
        end_f = float(cast(float, end))
        if not math.isfinite(start_f + end_f) or not 0 <= start_f < end_f <= duration + 1.0 + 1e-9:
            raise ValueError("invalid speaker-attributed utterance row")
        bounded_start = min(start_f, duration)
        bounded_end = min(end_f, duration)
        if bounded_end <= bounded_start:
            continue
        validated.append(
            {
                "start": bounded_start,
                "end": bounded_end,
                "speaker": speaker,
                "text": text,
            }
        )
    return sorted(validated, key=lambda item: (item["start"], item["end"], item["speaker"]))


def _time_constrained_stream_distance(
    ref_utts: Sequence[JsonDict],
    hyp_utts: Sequence[JsonDict],
    *,
    collar_seconds: float,
    tokenizer: Callable[[str], list[str]],
) -> int:
    """Compute time-constrained edit distance between two speaker utterance streams.

    A reference token from utterance R[i] and a hypothesis token from utterance H[j]
    may align via substitution/match only if R[i] and H[j] overlap within `collar_seconds`.
    """
    ref_tokens: list[tuple[str, float, float]] = []
    for utt in ref_utts:
        for tok in tokenizer(utt["text"]):
            ref_tokens.append((tok, float(utt["start"]), float(utt["end"])))
    hyp_tokens: list[tuple[str, float, float]] = []
    for utt in hyp_utts:
        for tok in tokenizer(utt["text"]):
            hyp_tokens.append((tok, float(utt["start"]), float(utt["end"])))

    if not ref_tokens:
        return len(hyp_tokens)
    if not hyp_tokens:
        return len(ref_tokens)

    inf = len(ref_tokens) + len(hyp_tokens) + 1
    previous = list(range(len(hyp_tokens) + 1))
    for row, (r_tok, r_start, r_end) in enumerate(ref_tokens, 1):
        current = [row]
        for col, (h_tok, h_start, h_end) in enumerate(hyp_tokens, 1):
            deletion = previous[col] + 1
            insertion = current[-1] + 1
            overlaps = (h_start <= r_end + collar_seconds) and (r_start <= h_end + collar_seconds)
            substitution = previous[col - 1] + (r_tok != h_tok) if overlaps else inf
            current.append(min(deletion, insertion, substitution))
        previous = current
    return previous[-1]


def score_speaker_attributed_asr(
    reference_utterances: Sequence[JsonDict],
    hypothesis_utterances: Sequence[JsonDict],
    *,
    duration: float,
    tcp_collar_seconds: float = 5.0,
) -> JsonDict:
    """Compute legacy product text metrics and temporal-oracle diagnostics for <=4 speakers.

    Unattributed hypothesis utterances (`speaker == "unknown"`) are never mapped to
    any reference speaker and remain in the insertion error denominator so unknown
    labels cannot mask attribution failures.
    """
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError("duration must be positive and finite")
    if not math.isfinite(tcp_collar_seconds) or tcp_collar_seconds < 0:
        raise ValueError("tcp_collar_seconds must be non-negative")

    ref_rows = _validate_timed_utterances(
        reference_utterances, duration=duration, allow_unknown=False
    )
    hyp_rows = _validate_timed_utterances(
        hypothesis_utterances, duration=duration, allow_unknown=True
    )

    ref_speakers = sorted({row["speaker"] for row in ref_rows})
    hyp_known_speakers = sorted({row["speaker"] for row in hyp_rows if row["speaker"] != "unknown"})
    if len(ref_speakers) > 4 or len(hyp_known_speakers) > 4:
        raise ValueError("Phase 1 speaker-attributed scorer supports at most 4 speakers")

    ref_by_spk: dict[str, list[JsonDict]] = {spk: [] for spk in ref_speakers}
    for row in ref_rows:
        ref_by_spk[row["speaker"]].append(row)

    hyp_by_spk: dict[str, list[JsonDict]] = {spk: [] for spk in hyp_known_speakers}
    unknown_utts: list[JsonDict] = []
    for row in hyp_rows:
        if row["speaker"] == "unknown":
            unknown_utts.append(row)
        else:
            hyp_by_spk[row["speaker"]].append(row)

    total_ref_chars = sum(len(_normalized_chars(r["text"])) for r in ref_rows)
    total_ref_words = sum(len(_tokenize_words(r["text"])) for r in ref_rows)
    unknown_char_penalty = sum(len(_normalized_chars(u["text"])) for u in unknown_utts)
    unknown_word_penalty = sum(len(_tokenize_words(u["text"])) for u in unknown_utts)

    slot_count = max(len(ref_speakers), len(hyp_known_speakers), 1)
    padded_ref = ref_speakers + [f"__empty_ref_{i}" for i in range(slot_count - len(ref_speakers))]
    padded_hyp = hyp_known_speakers + [
        f"__empty_hyp_{i}" for i in range(slot_count - len(hyp_known_speakers))
    ]

    best_cp_char_errors: int | None = None
    best_cp_word_errors: int | None = None
    best_tcp_char_errors: int | None = None
    best_tcp_word_errors: int | None = None
    best_mapping: dict[str, str] = {}

    for perm in itertools.permutations(padded_hyp):
        cp_char_err = unknown_char_penalty
        cp_word_err = unknown_word_penalty
        tcp_char_err = unknown_char_penalty
        tcp_word_err = unknown_word_penalty
        current_map: dict[str, str] = {}
        for r_spk, h_spk in zip(padded_ref, perm, strict=True):
            r_list = ref_by_spk.get(r_spk, [])
            h_list = hyp_by_spk.get(h_spk, [])
            if not r_spk.startswith("__empty_ref_") and not h_spk.startswith("__empty_hyp_"):
                current_map[h_spk] = r_spk
            r_text = _join_utterance_text(r_list)
            h_text = _join_utterance_text(h_list)
            cp_char_err += _sequence_edit_distance(
                _normalized_chars(r_text), _normalized_chars(h_text)
            )
            cp_word_err += _sequence_edit_distance(_tokenize_words(r_text), _tokenize_words(h_text))
            tcp_char_err += _time_constrained_stream_distance(
                r_list, h_list, collar_seconds=tcp_collar_seconds, tokenizer=_normalized_chars
            )
            tcp_word_err += _time_constrained_stream_distance(
                r_list, h_list, collar_seconds=tcp_collar_seconds, tokenizer=_tokenize_words
            )
        if best_cp_char_errors is None or cp_char_err < best_cp_char_errors:
            best_cp_char_errors = cp_char_err
            best_mapping = current_map
        if best_cp_word_errors is None or cp_word_err < best_cp_word_errors:
            best_cp_word_errors = cp_word_err
        if best_tcp_char_errors is None or tcp_char_err < best_tcp_char_errors:
            best_tcp_char_errors = tcp_char_err
        if best_tcp_word_errors is None or tcp_word_err < best_tcp_word_errors:
            best_tcp_word_errors = tcp_word_err

    assert best_cp_char_errors is not None
    assert best_cp_word_errors is not None
    assert best_tcp_char_errors is not None
    assert best_tcp_word_errors is not None

    oracle_hyp_by_spk: dict[str, list[JsonDict]] = {spk: [] for spk in ref_speakers}
    unmatched_oracle_chars = 0
    unmatched_oracle_words = 0
    for h_row in hyp_rows:
        best_ref_spk: str | None = None
        best_overlap = 0.0
        for r_row in ref_rows:
            overlap = max(
                0.0,
                min(float(h_row["end"]), float(r_row["end"]))
                - max(float(h_row["start"]), float(r_row["start"])),
            )
            if overlap > best_overlap:
                best_overlap = overlap
                best_ref_spk = r_row["speaker"]
        if best_ref_spk is not None:
            oracle_hyp_by_spk[best_ref_spk].append(h_row)
        elif ref_speakers:
            oracle_hyp_by_spk[ref_speakers[0]].append(h_row)
        else:
            unmatched_oracle_chars += len(_normalized_chars(h_row["text"]))
            unmatched_oracle_words += len(_tokenize_words(h_row["text"]))

    di_char_errors = unmatched_oracle_chars
    di_word_errors = unmatched_oracle_words
    for r_spk in ref_speakers:
        r_text = _join_utterance_text(ref_by_spk[r_spk])
        h_text = _join_utterance_text(
            sorted(oracle_hyp_by_spk[r_spk], key=lambda x: (x["start"], x["end"]))
        )
        di_char_errors += _sequence_edit_distance(
            _normalized_chars(r_text), _normalized_chars(h_text)
        )
        di_word_errors += _sequence_edit_distance(_tokenize_words(r_text), _tokenize_words(h_text))

    cp_cer = best_cp_char_errors / total_ref_chars if total_ref_chars else None
    tcp_cer = best_tcp_char_errors / total_ref_chars if total_ref_chars else None
    temporal_oracle_cer = di_char_errors / total_ref_chars if total_ref_chars else None
    cp_wer = best_cp_word_errors / total_ref_words if total_ref_words else None
    tcp_wer = best_tcp_word_errors / total_ref_words if total_ref_words else None
    temporal_oracle_wer = di_word_errors / total_ref_words if total_ref_words else None

    return {
        "standard_metric": False,
        "metric_family": "legacy_product_text_and_temporal_oracle",
        "reference_speakers_count": len(ref_speakers),
        "hypothesis_known_speakers_count": len(hyp_known_speakers),
        "unknown_utterance_count": len(unknown_utts),
        "unknown_character_Count": unknown_char_penalty,
        "unknown_word_count": unknown_word_penalty,
        "tcp_collar_seconds": tcp_collar_seconds,
        "optimal_speaker_mapping": best_mapping,
        "reference_characters": total_ref_chars,
        "cp_char_errors": best_cp_char_errors,
        "tcp_char_errors": best_tcp_char_errors,
        "temporal_oracle_char_errors": di_char_errors,
        "cp_cer": cp_cer,
        "tcp_cer": tcp_cer,
        "temporal_oracle_cer": temporal_oracle_cer,
        "product_cp_minus_temporal_oracle_cer": (
            cp_cer - temporal_oracle_cer
            if cp_cer is not None and temporal_oracle_cer is not None
            else None
        ),
        "reference_words": total_ref_words,
        "cp_word_errors": best_cp_word_errors,
        "tcp_word_errors": best_tcp_word_errors,
        "temporal_oracle_word_errors": di_word_errors,
        "cp_wer": cp_wer,
        "tcp_wer": tcp_wer,
        "temporal_oracle_wer": temporal_oracle_wer,
        "product_cp_minus_temporal_oracle_wer": (
            cp_wer - temporal_oracle_wer
            if cp_wer is not None and temporal_oracle_wer is not None
            else None
        ),
    }


def frames_to_speaker_spans(
    frames: Sequence[ActivityFrame],
    *,
    sample_rate: int = 16_000,
    duration: float,
) -> list[JsonDict]:
    """Convert Sortformer 4-slot ActivityFrames into merged speaker spans S1..S4."""
    if sample_rate <= 0 or not math.isfinite(duration) or duration <= 0:
        raise ValueError("invalid sample_rate or duration")
    raw_spans: dict[int, list[tuple[float, float]]] = {slot: [] for slot in range(4)}
    for frame in frames:
        start_sec = max(0.0, frame.span.start / sample_rate)
        end_sec = min(duration, frame.span.end / sample_rate)
        if end_sec <= start_sec:
            continue
        for slot in frame.active_slots:
            if not 0 <= slot < 4:
                raise ValueError("Sortformer slot index must be in 0..3")
            slot_list = raw_spans[slot]
            if slot_list and abs(slot_list[-1][1] - start_sec) <= 1e-6:
                slot_list[-1] = (slot_list[-1][0], end_sec)
            else:
                slot_list.append((start_sec, end_sec))

    merged: list[JsonDict] = []
    for slot in range(4):
        speaker = f"S{slot + 1}"
        for start_sec, end_sec in raw_spans[slot]:
            merged.append({"start": start_sec, "end": end_sec, "speaker": speaker})
    return sorted(merged, key=lambda item: (item["start"], item["end"], item["speaker"]))


def attribute_utterances_to_spans(
    asr_segments: Sequence[JsonDict],
    speaker_spans: Sequence[JsonDict],
    *,
    duration: float,
) -> list[JsonDict]:
    """Assign each timed ASR segment to the speaker span with maximum overlap, or 'unknown'."""
    attributed: list[JsonDict] = []
    for seg in asr_segments:
        start = float(seg["start"])
        end = min(float(seg["end"]), duration)
        text = str(seg["text"])
        if end <= start or not text.strip():
            continue
        overlap_by_speaker: dict[str, float] = {}
        for span in speaker_spans:
            ov = max(0.0, min(end, float(span["end"])) - max(start, float(span["start"])))
            if ov > 0:
                spk = str(span["speaker"])
                overlap_by_speaker[spk] = overlap_by_speaker.get(spk, 0.0) + ov
        if overlap_by_speaker:
            best_speaker = max(sorted(overlap_by_speaker), key=lambda k: overlap_by_speaker[k])
        else:
            best_speaker = "unknown"
        attributed.append({"start": start, "end": end, "speaker": best_speaker, "text": text})
    return attributed


def score_meeting_1to4_session(
    *,
    reference_speaker_spans: Sequence[JsonDict],
    hypothesis_speaker_spans: Sequence[JsonDict],
    reference_utterances: Sequence[JsonDict],
    hypothesis_utterances: Sequence[JsonDict],
    duration: float,
    tcp_collar_seconds: float = 5.0,
) -> JsonDict:
    """Compute decoupled ASR, diarization, and joint SA-ASR metrics for a 1-4 speaker session."""
    diar = score_diarization(reference_speaker_spans, hypothesis_speaker_spans, duration=duration)
    diar.pop("participants", None)
    participant_count = int(diar["participant_count"])
    if not 1 <= participant_count <= 4:
        raise ValueError("Phase 1 session scorer requires 1..4 reference speakers")

    diar["other_min_known_coverage_applicable"] = False
    diar["other_min_known_coverage_status"] = "not_applicable_le_4_speakers"
    diar_gate_pass = (
        float(diar["known_coverage"]) >= 0.90
        and float(diar["known_accuracy"]) >= 0.95
        and float(diar["top_four_min_known_coverage"]) >= 0.95
    )
    diar["quality_gate"] = "pass" if diar_gate_pass else "fail"

    validated_ref_utterances = _validate_timed_utterances(
        reference_utterances, duration=duration, allow_unknown=False
    )
    validated_hyp_utterances = _validate_timed_utterances(
        hypothesis_utterances, duration=duration, allow_unknown=True
    )
    ref_full_text = _join_utterance_text(validated_ref_utterances)
    hyp_full_text = _join_utterance_text(validated_hyp_utterances)
    asr_cer = character_error_metrics(ref_full_text, hyp_full_text)
    asr_wer = word_error_metrics(ref_full_text, hyp_full_text)
    sa_asr = score_speaker_attributed_asr(
        validated_ref_utterances,
        validated_hyp_utterances,
        duration=duration,
        tcp_collar_seconds=tcp_collar_seconds,
    )
    diar["speaker_attributed_word_error"] = sa_asr["cp_wer"]

    return {
        "speakers_count": participant_count,
        "duration_seconds": duration,
        "asr_only": {
            "cer": asr_cer["cer"],
            "character_errors": asr_cer["character_errors"],
            "reference_characters": asr_cer["reference_characters"],
            "wer": asr_wer["wer"],
            "word_errors": asr_wer["word_errors"],
            "reference_words": asr_wer["reference_words"],
        },
        "diarization_only": diar,
        "speaker_attributed": sa_asr,
        "diarization_gate": diar["quality_gate"],
    }


def summarize_1to4_strata(
    session_results: Sequence[JsonDict],
    *,
    allow_empty: bool = False,
) -> JsonDict:
    """Stratify session results across 1, 2, 3, and 4 speakers without hiding unobserved strata."""
    if not session_results and not allow_empty:
        raise ValueError("at least one session result is required")

    by_count: dict[int, list[JsonDict]] = {count: [] for count in _REQUIRED_STRATA}
    for row in session_results:
        count = int(row["speakers_count"])
        if count not in by_count:
            raise ValueError("session speakers_count is outside 1..4")
        by_count[count].append(row)

    strata_summary: dict[str, JsonDict] = {}
    unobserved_strata: list[int] = []
    for count in _REQUIRED_STRATA:
        key = f"{count}_speaker" if count == 1 else f"{count}_speakers"
        rows = by_count[count]
        if not rows:
            unobserved_strata.append(count)
            strata_summary[key] = {
                "speakers_count": count,
                "status": "unobserved_stratum",
                "quality_gate": "no-go",
                "session_count": 0,
                "diarization_gate_pass_sessions": 0,
                "mean_cer": None,
                "mean_wer": None,
                "mean_der": None,
                "mean_jer": None,
                "mean_known_coverage": None,
                "mean_known_accuracy": None,
                "minimum_top_four_known_coverage": None,
                "other_min_known_coverage": "N/A",
                "mean_cp_cer": None,
                "mean_tcp_cer": None,
                "mean_temporal_oracle_cer": None,
                "mean_cp_wer": None,
                "mean_tcp_wer": None,
                "mean_temporal_oracle_wer": None,
            }
            continue
        n = len(rows)
        pass_sessions = sum(r["diarization_gate"] == "pass" for r in rows)
        stratum_pass = pass_sessions == n
        strata_summary[key] = {
            "speakers_count": count,
            "status": "observed",
            "quality_gate": "go" if stratum_pass else "no-go",
            "session_count": n,
            "diarization_gate_pass_sessions": pass_sessions,
            "mean_cer": sum(float(r["asr_only"]["cer"] or 0.0) for r in rows) / n,
            "mean_wer": sum(float(r["asr_only"]["wer"] or 0.0) for r in rows) / n,
            "mean_der": sum(float(r["diarization_only"]["der"]) for r in rows) / n,
            "mean_jer": sum(float(r["diarization_only"]["jer"]) for r in rows) / n,
            "mean_known_coverage": sum(float(r["diarization_only"]["known_coverage"]) for r in rows)
            / n,
            "mean_known_accuracy": sum(float(r["diarization_only"]["known_accuracy"]) for r in rows)
            / n,
            "minimum_top_four_known_coverage": min(
                float(r["diarization_only"]["top_four_min_known_coverage"]) for r in rows
            ),
            "other_min_known_coverage": "N/A",
            "mean_cp_cer": sum(float(r["speaker_attributed"]["cp_cer"] or 0.0) for r in rows) / n,
            "mean_tcp_cer": sum(float(r["speaker_attributed"]["tcp_cer"] or 0.0) for r in rows) / n,
            "mean_temporal_oracle_cer": sum(
                float(r["speaker_attributed"]["temporal_oracle_cer"] or 0.0) for r in rows
            )
            / n,
            "mean_cp_wer": sum(float(r["speaker_attributed"]["cp_wer"] or 0.0) for r in rows) / n,
            "mean_tcp_wer": sum(float(r["speaker_attributed"]["tcp_wer"] or 0.0) for r in rows) / n,
            "mean_temporal_oracle_wer": sum(
                float(r["speaker_attributed"]["temporal_oracle_wer"] or 0.0) for r in rows
            )
            / n,
        }

    all_observed_pass = bool(session_results) and all(
        r["diarization_gate"] == "pass" for r in session_results
    )
    all_strata_covered = len(unobserved_strata) == 0
    certified = all_observed_pass and all_strata_covered
    return {
        "total_sessions": len(session_results),
        "observed_speaker_counts": sorted(count for count in _REQUIRED_STRATA if by_count[count]),
        "unobserved_speaker_counts": unobserved_strata,
        "all_1to4_strata_observed": all_strata_covered,
        "all_observed_sessions_pass_diarization_gate": all_observed_pass,
        "phase1_diarization_certified": certified,
        "verdict": "go" if certified else "no-go",
        "strata": strata_summary,
    }


async def run_sortformer_session_on_wav(
    wav_path: Path,
    *,
    session_factory: Callable[[str], ActivitySession],
    epoch: str,
    chunk_samples: int = 16_000,
    consolidate: bool = False,
) -> tuple[list[JsonDict], float]:
    """Stream a 16 kHz mono PCM16 WAV through a Sortformer ActivitySession."""
    if chunk_samples <= 0:
        raise ValueError("chunk_samples must be positive")
    with wave.open(str(wav_path), "rb") as wav_file:
        if (
            wav_file.getnchannels(),
            wav_file.getframerate(),
            wav_file.getsampwidth(),
        ) != (1, 16_000, 2):
            raise ValueError("Sortformer evaluation requires 16 kHz mono PCM16 WAV")
        total_samples = wav_file.getnframes()
        if total_samples <= 0:
            raise ValueError("evaluation WAV is empty")
        pcm_bytes = wav_file.readframes(total_samples)

    duration = total_samples / 16_000
    session = session_factory(epoch)
    collected_frames: dict[tuple[int, int], ActivityFrame] = {}
    cursor = 0
    try:
        while cursor < total_samples:
            take = min(chunk_samples, total_samples - cursor)
            chunk = pcm_bytes[cursor * 2 : (cursor + take) * 2]
            await session.append(start_sample=cursor, pcm16=chunk)
            cursor += take
        await session.finish(through_sample=total_samples)
        async for update in session.updates():
            for frame in update.frames:
                collected_frames[(frame.span.start, frame.span.end)] = frame
    except BaseException:
        await session.cancel()
        raise

    ordered_frames = [collected_frames[key] for key in sorted(collected_frames)]
    if consolidate:
        return (
            consolidate_slot_spans(ordered_frames, duration=duration),
            duration,
        )
    return (
        frames_to_speaker_spans(ordered_frames, sample_rate=16_000, duration=duration),
        duration,
    )


def _anonymize_session_metrics(session_id: str, scored: JsonDict) -> JsonDict:
    """Strip any reference speaker IDs from optimal_speaker_mapping before persisting."""
    sa = dict(scored["speaker_attributed"])
    sa.pop("optimal_speaker_mapping", None)
    return {
        "session_id": session_id,
        "speakers_count": scored["speakers_count"],
        "duration_seconds": scored["duration_seconds"],
        "diarization_gate": scored["diarization_gate"],
        "asr_only": scored["asr_only"],
        "diarization_only": scored["diarization_only"],
        "speaker_attributed": sa,
    }


async def evaluate_locked_1to4_split(
    *,
    manifest_path: Path,
    output_dir: Path,
    repository_root: Path,
    expected_split_role: str,
    session_factory: Callable[[str], ActivitySession],
    development_receipt_path: Path | None = None,
    consolidate: bool = False,
    execution_spec: MeetingCandidateSpec | None = None,
    observed_identity: JsonDict | None = None,
) -> JsonDict:
    """Execute Phase 1 evaluation on a locked external 1-4 speaker development or holdout split."""
    resolved_manifest = _require_external_path(manifest_path, repository_root=repository_root)
    resolved_output = _require_external_path(output_dir, repository_root=repository_root)
    if resolved_output.exists():
        raise ValueError("output_dir must not already exist")
    if execution_spec is not None:
        if observed_identity is None:
            raise ValueError("execution identity must be observed before inference")
        validate_execution_identity(execution_spec, observed_identity)
        if execution_spec.decoder["consolidation"]["enabled"] is not consolidate:
            raise ValueError("execution identity consolidation differs from runner")

    manifest_bytes = resolved_manifest.read_bytes()
    fixtures, meta = validate_locked_1to4_manifest(
        resolved_manifest,
        manifest_bytes,
        repository_root=repository_root,
        candidate_count=1,
    )
    actual_role = str(meta["split_role"])
    if expected_split_role == "development" and actual_role != "development":
        raise ValueError("evaluate-development requires a manifest with split_role=development")
    if expected_split_role == "frozen_holdout" and actual_role not in _FROZEN_SPLIT_ROLES:
        raise ValueError(
            "evaluate-frozen-holdout requires split_role in {frozen_holdout, frozen_evaluation}"
        )

    frozen_spec = frozen_phase1_candidate_spec(repository_root=repository_root)
    spec_sha256 = str(frozen_spec["candidate_spec_sha256"])
    manifest_sha256 = str(meta["manifest_sha256"])

    unlock_info: JsonDict | None = None
    if actual_role in _FROZEN_SPLIT_ROLES:
        if development_receipt_path is None:
            raise ValueError(
                "frozen holdout evaluation requires --development-receipt from a passing dev run"
            )
        unlock_info = validate_frozen_holdout_unlock(
            development_receipt_path,
            repository_root=repository_root,
            expected_candidate_spec_sha256=spec_sha256,
            holdout_manifest_sha256=manifest_sha256,
        )

    raw_session_results: list[JsonDict] = []
    anonymous_session_rows: list[JsonDict] = []
    for fixture in fixtures:
        session_id = str(fixture["id"])
        audio_path = _require_external_path(
            Path(str(fixture["path"])), repository_root=repository_root
        )
        ref_path = _require_external_path(
            Path(str(fixture["reference_path"])), repository_root=repository_root
        )
        asr_hyp_path = _require_external_path(
            Path(str(fixture["asr_hypothesis_path"])), repository_root=repository_root
        )
        asr_hyp_sha = str(fixture.get("asr_hypothesis_sha256") or "")
        if re.fullmatch(r"[0-9a-f]{64}", asr_hyp_sha) is None:
            raise ValueError("fixture must include a 64-character asr_hypothesis_sha256")
        if _file_digest(audio_path) != fixture["audio_sha256"]:
            raise ValueError("audio digest differs from locked manifest")
        if _file_digest(ref_path) != fixture["reference_sha256"]:
            raise ValueError("reference digest differs from locked manifest")
        if _file_digest(asr_hyp_path) != asr_hyp_sha:
            raise ValueError("ASR hypothesis digest differs from locked manifest")

        hyp_spans, duration = await run_sortformer_session_on_wav(
            audio_path,
            session_factory=session_factory,
            epoch=session_id,
            consolidate=consolidate,
        )
        ref_payload = json.loads(ref_path.read_text(encoding="utf-8"))
        asr_payload = json.loads(asr_hyp_path.read_text(encoding="utf-8"))
        ref_spans = ref_payload["speaker_spans"]
        ref_utts = ref_payload["utterances"]
        if len({str(s["speaker"]) for s in ref_spans}) != int(fixture["speakers_count"]):
            raise ValueError("reference speaker count differs from manifest speakers_count")

        attributed_hyp_utts = attribute_utterances_to_spans(
            asr_payload["segments"], hyp_spans, duration=duration
        )
        scored = score_meeting_1to4_session(
            reference_speaker_spans=ref_spans,
            hypothesis_speaker_spans=hyp_spans,
            reference_utterances=ref_utts,
            hypothesis_utterances=attributed_hyp_utts,
            duration=duration,
        )
        raw_session_results.append(scored)
        anonymous_session_rows.append(_anonymize_session_metrics(session_id, scored))

    if resolved_manifest.read_bytes() != manifest_bytes:
        raise ValueError("manifest changed during evaluation")

    strata_summary = summarize_1to4_strata(raw_session_results, allow_empty=False)
    report: JsonDict = {
        "schema_version": 1,
        "split_role": actual_role,
        "dataset": meta["dataset"],
        "license": meta["license"],
        "manifest_sha256": manifest_sha256,
        "candidate_spec_sha256": spec_sha256,
        "candidate_spec": frozen_spec["spec"],
        "holdout_unlock": unlock_info,
        "all_1to4_strata_observed": strata_summary["all_1to4_strata_observed"],
        "all_observed_sessions_pass_diarization_gate": strata_summary[
            "all_observed_sessions_pass_diarization_gate"
        ],
        "phase1_diarization_certified": False,
        "verdict": "no-go",
        "diagnostic_only": True,
        "certification_blocker": "legacy scoring is not the approved v2 product policy",
        "execution_candidate_sha256": (
            candidate_digest(execution_spec) if execution_spec is not None else None
        ),
        "execution_candidate": execution_spec.as_dict() if execution_spec is not None else None,
        "evaluation": strata_summary,
        "sessions": anonymous_session_rows,
    }

    resolved_output.mkdir(parents=True, exist_ok=False)
    receipt_filename = (
        "development-certification.json"
        if actual_role == "development"
        else "frozen-holdout-report.json"
    )
    receipt_path = resolved_output / receipt_filename
    encoded = json.dumps(report, indent=2, sort_keys=True, ensure_ascii=False).encode("utf-8")
    receipt_path.write_bytes(encoded)
    (resolved_output / f"{receipt_filename}.sha256").write_text(
        hashlib.sha256(encoded).hexdigest() + "\n", encoding="utf-8"
    )
    return report


def _probe_path_status(path: Path) -> JsonDict:
    try:
        st = path.stat()
        return {
            "path": str(path),
            "accessible": True,
            "exists": True,
            "size_bytes": st.st_size,
            "error": None,
        }
    except PermissionError as exc:
        return {
            "path": str(path),
            "accessible": False,
            "exists": True,
            "size_bytes": None,
            "error": f"PermissionError(errno={exc.errno}): {exc.strerror}",
        }
    except FileNotFoundError as exc:
        return {
            "path": str(path),
            "accessible": False,
            "exists": False,
            "size_bytes": None,
            "error": f"FileNotFoundError(errno={exc.errno}): {exc.strerror}",
        }
    except OSError as exc:
        return {
            "path": str(path),
            "accessible": False,
            "exists": None,
            "size_bytes": None,
            "error": f"{type(exc).__name__}(errno={exc.errno}): {exc.strerror}",
        }


def run_preflight_probe(
    *,
    repository_root: Path,
    benchmark_root: Path,
    model_root: Path,
) -> JsonDict:
    """Inspect candidate spec lock, disk space, external paths, and 1-4 strata readiness."""
    frozen_spec = frozen_phase1_candidate_spec(repository_root=repository_root)
    usage = shutil.disk_usage(repository_root)
    worker_bin = (
        repository_root
        / "native/diarization/.build/out/Products/Release/SpeechRailDiarizationWorker"
    )
    worker_sha = _file_digest(worker_bin) if worker_bin.is_file() else None

    probed_paths = {
        "benchmark_root": _probe_path_status(benchmark_root),
        "model_root": _probe_path_status(model_root),
        "sortformer_mlmodelc": _probe_path_status(model_root / "SortformerNvidiaLow_v2.1.mlmodelc"),
        "aishell4_test_archive": _probe_path_status(
            benchmark_root / "issue370-aishell4-test-20261017/test.tar.gz"
        ),
        "aishell4_reconstructed_split": _probe_path_status(
            benchmark_root / "issue370-aishell4-test-20261017/reconstructed-split"
        ),
        "alimeeting_eval_partial": _probe_path_status(
            benchmark_root / "issue370-alimeeting-eval-20261017/Eval_Ali.tar.gz.partial"
        ),
        "alimeeting_eval_complete": _probe_path_status(
            benchmark_root / "issue370-alimeeting-eval-20261017/Eval_Ali.tar.gz"
        ),
        "development_1to4_manifest": _probe_path_status(
            benchmark_root / "issue370-sortformer-1to4-20261017/development.json"
        ),
    }

    blockers: list[str] = []
    for name, info in probed_paths.items():
        if not info["accessible"]:
            blockers.append(f"{name}: {info['error']}")

    strata_report = summarize_1to4_strata([], allow_empty=True)
    return {
        "mode": "preflight",
        "candidate_spec_sha256": frozen_spec["candidate_spec_sha256"],
        "candidate_spec": frozen_spec["spec"],
        "worker_executable_sha256": worker_sha,
        "disk_usage": {
            "total_gib": round(usage.total / (1024**3), 2),
            "used_gib": round(usage.used / (1024**3), 2),
            "free_gib": round(usage.free / (1024**3), 2),
        },
        "external_paths": probed_paths,
        "blockers": blockers,
        "evaluation": strata_report,
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Phase 1 (1-4 speakers) Sortformer & SA-ASR evaluation probe."
    )
    parser.add_argument(
        "--mode",
        choices=("preflight", "evaluate-development", "evaluate-frozen-holdout"),
        default="preflight",
        help="Execution mode.",
    )
    parser.add_argument(
        "--benchmark-root",
        type=Path,
        default=Path("/Users/hrygo/Library/Application Support/SpeechRail/benchmarks"),
    )
    parser.add_argument(
        "--model-root",
        type=Path,
        default=Path("/Users/hrygo/Library/Application Support/SpeechRail/models"),
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=None,
        help="External locked 1-4 speaker manifest path for evaluate-* modes.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="External output directory for evaluate-* modes.",
    )
    parser.add_argument(
        "--development-receipt",
        type=Path,
        default=None,
        help="Path to development-certification.json required for evaluate-frozen-holdout.",
    )
    parser.add_argument(
        "--executable",
        type=Path,
        default=None,
        help="Optional path to SpeechRailDiarizationWorker executable.",
    )
    parser.add_argument(
        "--require-pass",
        action="store_true",
        help="Exit with code 2 when any 1..4 speaker stratum is unobserved or quality gate fails.",
    )
    parser.add_argument(
        "--slot-consolidate",
        action="store_true",
        default=False,
        help="Consolidate whole-session Sortformer slot spans before scoring.",
    )
    parser.add_argument(
        "--candidate-spec",
        type=Path,
        default=None,
        help="External frozen v2 candidate JSON; measured execution must match before inference.",
    )
    args = parser.parse_args(list(argv) if argv is not None else None)
    repo_root = Path(__file__).resolve().parents[2]

    if args.mode == "preflight":
        report = run_preflight_probe(
            repository_root=repo_root,
            benchmark_root=args.benchmark_root,
            model_root=args.model_root,
        )
        sys.stdout.write(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
        if args.require_pass and report["evaluation"]["verdict"] != "go":
            return 2
        return 0

    if args.manifest is None or args.output is None:
        sys.stderr.write(f"{args.mode} requires --manifest and --output outside the repository\n")
        return 2

    worker_exe = (
        args.executable
        if args.executable is not None
        else repo_root
        / "native/diarization/.build/out/Products/Release/SpeechRailDiarizationWorker"
    )
    model_bundle = args.model_root / MODEL_BUNDLE_NAME
    try:
        engine = CoreMLSortformerEngine(
            model_path=model_bundle,
            executable=worker_exe,
        )
        if not engine.readiness.ready:
            raise ValueError(engine.readiness.message)
        observed = sortformer_execution_spec(
            repository_root=repo_root,
            executable=worker_exe,
            model_path=model_bundle,
            consolidate=args.slot_consolidate,
        )
        spec = observed
        if args.candidate_spec is not None:
            spec_path = _require_external_path(args.candidate_spec, repository_root=repo_root)
            spec = MeetingCandidateSpec(**json.loads(spec_path.read_text(encoding="utf-8")))
        validate_execution_identity(spec, observed.as_dict())
        expected_role = "development" if args.mode == "evaluate-development" else "frozen_holdout"
        eval_report = asyncio.run(
            evaluate_locked_1to4_split(
                manifest_path=args.manifest,
                output_dir=args.output,
                repository_root=repo_root,
                expected_split_role=expected_role,
                session_factory=lambda epoch: engine.open(epoch=epoch),
                development_receipt_path=args.development_receipt,
                consolidate=args.slot_consolidate,
                execution_spec=spec,
                observed_identity=observed.as_dict(),
            )
        )
    except (OSError, ValueError, RuntimeError) as exc:
        error_payload = {
            "mode": args.mode,
            "verdict": "no-go",
            "error_type": type(exc).__name__,
            "error": str(exc),
        }
        sys.stdout.write(json.dumps(error_payload, indent=2, ensure_ascii=False) + "\n")
        return 2

    sys.stdout.write(json.dumps(eval_report, indent=2, ensure_ascii=False) + "\n")
    if eval_report["verdict"] != "go":
        return 2
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
