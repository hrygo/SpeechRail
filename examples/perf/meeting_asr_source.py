"""Frozen development and diagnostic ASR sources; no holdout or model loading.

The shared meeting source validator also checks the activity/text references
and fixed ASR sidecar. None of those become ASR input or a primary transcript.
A separately frozen, explicit primary reference supplies ASR scoring order.
"""

from __future__ import annotations

import asyncio
import json
import wave
from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from meeting_candidate_execution import read_control_json
from meeting_candidate_runner import inspect_wav_pcm
from meeting_development_fixture import (
    _check_input_stamps,
    _check_inputs,
    _prepare,
    _reference,
    _stamp,
)
from meeting_evaluation_identity import canonical_digest
from prepare_meeting_evaluation_manifest import _artifact, _digest, _external, build_manifests
from probe_meeting_asr_quality import AsrCase

from speechrail.runtime.cleanup import join_cleanup


@dataclass(frozen=True, slots=True)
class LockedAsrCase:
    """Case bytes stay immutable; input files remain checked through replay."""

    case: AsrCase
    candidate_sha256: str
    _prepared: Mapping[str, Any]
    _primary_descriptor: Mapping[str, str]
    _primary_stamp: tuple[int, ...]
    _diagnostic: bool = False

    def verify_stamps(self) -> None:
        try:
            _check_input_stamps(self._prepared)
            path = self._prepared["root"] / self._primary_descriptor["path"]
            if _stamp(path) != self._primary_stamp:
                raise ValueError("ASR primary reference changed")
        except KeyError, TypeError, ValueError, OSError:
            raise ValueError("locked ASR source changed") from None

    def verify(self) -> None:
        try:
            self.verify_stamps()
            _check_inputs(self._prepared)
            _artifact(self._primary_descriptor, self._prepared["root"], sidecar=False)
            self.verify_stamps()
        except KeyError, TypeError, ValueError, OSError:
            raise ValueError("locked ASR source validation failed") from None

    def proof(self) -> dict[str, object]:
        self.verify_stamps()
        return {
            "schema_version": 1,
            "bytes_verified": True,
            "primary_reference_sha256": self._primary_descriptor["sha256"],
            "human_reference_provenance_verified": False,
            "source_catalog_provenance_verified": False,
            "source_scope": "diagnostic" if self._diagnostic else "development",
            "natural_development_eligible": not self._diagnostic,
        }


def load_locked_asr_diagnostic_case(
    catalog: Mapping[str, Any],
    split_lock: Mapping[str, Any],
    *,
    artifact_root: Path,
    scorer_policy: Mapping[str, Any],
    fixture_id: str,
    candidate_sha256: str,
    primary_reference: Mapping[str, str],
) -> LockedAsrCase:
    """Load an explicitly diagnostic catalog without a pre-existing ASR sidecar.

    Rebuild ancestry/split locks instead of relabeling a diagnostic manifest as
    development. The separate primary file still freezes missing/ambiguous text.
    This entry point never reads a holdout or creates quality certification.
    """
    try:
        _digest(candidate_sha256)
        root = _external(artifact_root)
        # Do not open any declared holdout artifacts while rebuilding this pool.
        frozen = json.loads(json.dumps(catalog, allow_nan=False))
        if any(row["split"] != "diagnostic" for row in frozen["fixtures"]):
            raise ValueError("diagnostic catalog must contain diagnostic fixtures only")
        result = build_manifests(frozen, artifact_root=root, scorer_policy=scorer_policy)
        if canonical_digest(result["split_lock"]) != canonical_digest(split_lock):
            raise ValueError("diagnostic catalog differs from frozen lock")
        manifest = result["diagnostic"]
        matches = [row for row in manifest["fixtures"] if row["id"] == fixture_id]
        if len(matches) != 1:
            raise ValueError("diagnostic fixture must be unique")
        fixture = matches[0]
        if set(fixture["artifacts"]) != {"pcm", "activity_reference", "text_reference"}:
            raise ValueError("diagnostic ASR requires PCM and independent references only")
        before = {
            kind: _stamp(root / descriptor["path"])
            for kind, descriptor in fixture["artifacts"].items()
        }
        total = inspect_wav_pcm(root / fixture["artifacts"]["pcm"]["path"])
        for kind in ("activity_reference", "text_reference"):
            _reference(
                root / fixture["artifacts"][kind]["path"], total, text=kind == "text_reference"
            )
        prepared = {
            "root": root,
            "fixture": fixture,
            "total": total,
            "stamps": before,
            "manifest_sha256": canonical_digest(manifest),
        }
        _check_inputs(prepared)
        return _load_prepared_case(
            prepared,
            fixture_id=fixture_id,
            candidate_sha256=candidate_sha256,
            primary_reference=primary_reference,
            diagnostic=True,
        )
    except KeyError, TypeError, ValueError, OSError, wave.Error:
        raise ValueError("locked ASR diagnostic source validation failed") from None


def load_locked_asr_case(
    manifest: Mapping[str, Any],
    split_lock: Mapping[str, Any],
    *,
    artifact_root: Path,
    scorer_policy: Mapping[str, Any],
    fixture_id: str,
    candidate_sha256: str,
    primary_reference: Mapping[str, str],
) -> LockedAsrCase:
    """Read one common development fixture, plus its independent primary lock.

    The primary JSON header binds the development manifest and WAV file digest.
    Uncertain overlap order stays uncertain. This records declared consistency,
    not human-source attestation. No transcript is reconstructed from intervals.
    """
    try:
        prepared = _prepare(
            manifest,
            split_lock,
            root=artifact_root,
            policy=scorer_policy,
            fixture_id=fixture_id,
            candidate_sha256=candidate_sha256,
        )
        return _load_prepared_case(
            prepared,
            fixture_id=fixture_id,
            candidate_sha256=candidate_sha256,
            primary_reference=primary_reference,
            diagnostic=False,
        )
    except KeyError, TypeError, ValueError, OSError, wave.Error:
        raise ValueError("locked ASR development source validation failed") from None


def _load_prepared_case(
    prepared: Mapping[str, Any],
    *,
    fixture_id: str,
    candidate_sha256: str,
    primary_reference: Mapping[str, str],
    diagnostic: bool,
) -> LockedAsrCase:
    descriptor = json.loads(json.dumps(primary_reference, allow_nan=False))
    if prepared["total"] > 600 * 16000:
        raise ValueError("ASR diagnostic exceeds ten-minute PCM bound")
    root, fixture = prepared["root"], prepared["fixture"]
    if not isinstance(descriptor, dict) or not isinstance(descriptor.get("path"), str):
        raise ValueError("invalid primary reference descriptor")
    path = root / descriptor["path"]
    _artifact(descriptor, root, sidecar=False)
    stamp = _stamp(path)
    primary = read_control_json(path)
    if (
        set(primary)
        != {
            "schema_version",
            "fixture_id",
            "manifest_sha256",
            "pcm_sha256",
            "overlap_order",
            "main_reference",
        }
        or type(primary["schema_version"]) is not int
        or primary["schema_version"] != 1
        or primary["fixture_id"] != fixture_id
        or primary["manifest_sha256"] != prepared["manifest_sha256"]
        or primary["pcm_sha256"] != fixture["artifacts"]["pcm"]["sha256"]
        or (
            primary["main_reference"] is not None
            and (
                not isinstance(primary["main_reference"], str)
                or len(primary["main_reference"]) > 10000
            )
        )
    ):
        raise ValueError("primary reference differs from frozen source")
    with wave.open(str(root / fixture["artifacts"]["pcm"]["path"]), "rb") as handle:
        pcm = handle.readframes(prepared["total"] + 1)
    if len(pcm) != prepared["total"] * 2:
        raise ValueError("ASR PCM differs from validated WAV")
    case = AsrCase(
        fixture["source_group_id"],
        prepared["manifest_sha256"],
        pcm,
        primary["main_reference"],
        primary["overlap_order"],
    )
    # Drop unrelated reference text from the retained guard.
    guard = {key: prepared[key] for key in ("fixture", "root", "stamps")}
    result = LockedAsrCase(case, candidate_sha256, guard, descriptor, stamp, diagnostic)
    result.verify()
    return result


async def evaluate_locked_asr_case(
    source: LockedAsrCase,
    replay: Callable[[AsrCase], Awaitable[dict[str, Any]]],
) -> dict[str, Any]:
    """Run a replay that owns its session cleanup; join source checks on exit."""
    await join_cleanup(asyncio.create_task(asyncio.to_thread(source.verify)))
    try:
        try:
            result = await replay(source.case)
        except Exception:
            raise RuntimeError("locked ASR replay failed") from None
    finally:
        await join_cleanup(asyncio.create_task(asyncio.to_thread(source.verify)))
    if (
        not isinstance(result, dict)
        or any(result.get(key) != value for key, value in source.case.identity().items())
        or result.get("candidate_sha256") != source.candidate_sha256
    ):
        raise ValueError("ASR replay result differs from frozen source or candidate")
    # No await between the final inexpensive input check and returning evidence.
    source.verify_stamps()
    if source._diagnostic:
        result = {
            **result,
            "split_role": "diagnostic",
            "natural_development_eligible": False,
            "quality_evidence_valid": False,
            "certification_eligible": False,
            "certified_max_speakers": None,
            "asr_quality_improvement_gate": "not_observed",
        }
    return {**result, "source_validation": source.proof()}
