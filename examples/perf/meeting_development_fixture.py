"""Execute one locked development fixture through replay, attribution and scoring.

This library requires the caller's shared-owner activity factory. It does not
launch a standalone service, establish cross-process exclusion, prove runtime
or producer provenance, issue receipts, or read a holdout. Raw text stays in an
exclusive external event artifact; returned evidence contains no transcripts.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import math
import os
import re
import sys
import wave
from collections.abc import AsyncIterator, Awaitable, Callable, Mapping
from pathlib import Path
from typing import Any, BinaryIO

from meeting_asr_sidecar import LockedASRSidecar, open_asr_sidecar
from meeting_candidate_runner import (
    FixedTextReplay,
    inspect_wav_pcm,
    iter_wav_pcm,
    run_candidate_stream,
)
from meeting_candidate_schedule import CommonPrefixSchedule
from meeting_evaluation_identity import canonical_digest
from meeting_quality_metrics import (
    nondegradation_gate,
    score_meeting_quality,
    standard_metric_totals,
    summarize_meeting_quality,
    validate_scorer_environment,
)
from prepare_meeting_evaluation_manifest import _artifact, _identifier

from speechrail.domain.diarization.ports import ActivitySession
from speechrail.runtime.cleanup import join_cleanup

_ROOT = Path(__file__).resolve().parents[2]
_SHA = re.compile(r"[0-9a-f]{64}")
_MAX_REFERENCE_BYTES = 16 * 1024 * 1024
_MAX_EVENTS_BYTES = 256 * 1024 * 1024
_MAX_ROWS = 100000
_CANDIDATE_EXECUTION_FIELDS = {
    "configured_port_exclusion": True,
    "exclusion_scope": "per_user_configured_port",
    "native_preflight_observed": True,
    "artifact_checks_through_cleanup": True,
    "exact_child_reaped": True,
    "model_revision_provenance_verified": False,
    "joint_asr_latency_observed": False,
    "production_certification": False,
}


def _stamp(path: Path) -> tuple[int, ...]:
    value = path.stat(follow_symlinks=False)
    return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def _pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("development reference contains duplicate fields")
        result[key] = value
    return result


def _reference(path: Path, total: int, *, text: bool) -> list[dict[str, Any]]:
    if path.stat().st_size > _MAX_REFERENCE_BYTES:
        raise ValueError("development reference exceeds budget")
    with path.open("rb") as handle:
        raw = handle.read(_MAX_REFERENCE_BYTES + 1)
    if len(raw) > _MAX_REFERENCE_BYTES:
        raise ValueError("development reference exceeds budget")
    try:
        value = json.loads(raw, object_pairs_hook=_pairs)
    except ValueError, UnicodeError:
        raise ValueError("development reference JSON invalid") from None
    if (
        not isinstance(value, dict)
        or set(value) != {"schema_version", "sample_rate", "total_samples", "segments"}
        or any(
            type(value[k]) is not int for k in ("schema_version", "sample_rate", "total_samples")
        )
        or (value["schema_version"], value["sample_rate"], value["total_samples"])
        != (1, 16000, total)
        or not isinstance(value["segments"], list)
        or len(value["segments"]) > _MAX_ROWS
    ):
        raise ValueError("development reference schema or timebase invalid")
    rows = []
    for row in value["segments"]:
        keys = {"start_sample", "end_sample", "speaker"} | ({"text"} if text else set())
        if (
            not isinstance(row, dict)
            or set(row) != keys
            or any(type(row[k]) is not int for k in ("start_sample", "end_sample"))
            or not 0 <= row["start_sample"] < row["end_sample"] <= total
            or not isinstance(row["speaker"], str)
            or not re.fullmatch(r"R[1-8]", row["speaker"])
            or (text and (not isinstance(row["text"], str) or not row["text"]))
        ):
            raise ValueError("development reference interval or anonymous label invalid")
        rows.append(
            {
                "start": row["start_sample"] / 16000,
                "end": row["end_sample"] / 16000,
                "speaker": row["speaker"],
                **({"text": row["text"]} if text else {}),
            }
        )
    return rows


def _prepare(
    manifest: Mapping[str, Any],
    lock: Mapping[str, Any],
    *,
    root: Path,
    policy: Mapping[str, Any],
    fixture_id: str,
    candidate_sha256: str,
) -> dict[str, Any]:
    try:
        # Snapshot caller-owned mappings before any await or model construction.
        frozen = json.loads(
            json.dumps({"manifest": manifest, "lock": lock, "policy": policy}, allow_nan=False)
        )
        manifest, lock, policy = (frozen[k] for k in ("manifest", "lock", "policy"))
        _identifier(fixture_id)
        validate_scorer_environment(policy)
        if (
            type(manifest["schema_version"]) is not int
            or manifest["schema_version"] != 2
            or manifest["split"] != "development"
            or type(lock["schema_version"]) is not int
            or lock["schema_version"] != 2
            or canonical_digest(manifest) != lock["development_manifest_sha256"]
            or canonical_digest(policy) != lock["scorer_policy_sha256"]
            or manifest["scorer_policy_sha256"] != lock["scorer_policy_sha256"]
            or manifest["source_catalog_sha256"] != lock["source_catalog_sha256"]
            or not _SHA.fullmatch(candidate_sha256)
        ):
            raise ValueError("development locks do not match")
        matches = [r for r in manifest["fixtures"] if r["id"] == fixture_id]
        if len(matches) != 1:
            raise ValueError("development fixture must be unique")
        fixture = matches[0]
        count = fixture["speakers_count"]
        if (
            fixture["split"] != "development"
            or type(count) is not int
            or not 1 <= count <= 8
            or type(fixture["channel"]) is not int
            or fixture["channel"] < 0
            or fixture["scene"] not in {"near", "far"}
            or not _SHA.fullmatch(fixture["source_group_id"])
            or fixture["sample_kind"]
            not in {"natural_single", "natural_meeting", "continuous_excerpt"}
            or (count == 1) != (fixture["sample_kind"] == "natural_single")
            or any(
                not isinstance(fixture[k], dict) or not fixture[k]
                for k in ("transform", "reference_label_policy")
            )
            or fixture["source_group_id"] not in manifest["group_order"][str(count)]
            or set(fixture["artifacts"])
            != {"pcm", "activity_reference", "text_reference", "asr_sidecar"}
        ):
            raise ValueError("development fixture scope or artifacts invalid")
        root = root.expanduser().resolve(strict=True)
        if root.is_relative_to(_ROOT) or not root.is_dir():
            raise ValueError("development artifacts must remain external")
        artifacts = fixture["artifacts"]
        for kind, d in artifacts.items():
            _artifact(d, root, sidecar=kind == "asr_sidecar")
        before = {kind: _stamp(root / d["path"]) for kind, d in artifacts.items()}
        total = inspect_wav_pcm(root / artifacts["pcm"]["path"])
        references = {
            kind: _reference(root / artifacts[kind]["path"], total, text=kind == "text_reference")
            for kind in ("activity_reference", "text_reference")
        }
        result = {
            "fixture": fixture,
            "manifest_sha256": canonical_digest(manifest),
            "split_lock_sha256": canonical_digest(lock),
            "policy": policy,
            "root": root,
            "total": total,
            "stamps": before,
            "references": references,
        }
        _check_inputs(result)
        return result
    except KeyError, TypeError, ValueError, OSError, wave.Error:
        raise ValueError("development input validation failed") from None


def _check_input_stamps(prepared: Mapping[str, Any]) -> None:
    """Cheap final observation; no await before exclusive evidence commit."""
    for kind, descriptor in prepared["fixture"]["artifacts"].items():
        if _stamp(prepared["root"] / descriptor["path"]) != prepared["stamps"][kind]:
            raise ValueError("development input changed before commit")


def _check_inputs(prepared: Mapping[str, Any]) -> None:
    for kind, descriptor in prepared["fixture"]["artifacts"].items():
        path = prepared["root"] / descriptor["path"]
        if _stamp(path) != prepared["stamps"][kind]:
            raise ValueError("development input changed")
        _artifact(descriptor, prepared["root"], sidecar=kind == "asr_sidecar")
        if _stamp(path) != prepared["stamps"][kind]:
            raise ValueError("development input changed")


@contextlib.asynccontextmanager
async def _sidecar(prepared: Mapping[str, Any]) -> AsyncIterator[LockedASRSidecar]:
    artifacts = prepared["fixture"]["artifacts"]
    cm = open_asr_sidecar(
        prepared["root"],
        artifacts["asr_sidecar"],
        pcm_sha256=artifacts["pcm"]["sha256"],
        total_samples=prepared["total"],
    )
    entering = asyncio.create_task(asyncio.to_thread(cm.__enter__))
    try:
        source = await join_cleanup(entering)
    except BaseException:
        # Cancellation after successful entry must not abandon the open file.
        if entering.done() and not entering.cancelled() and entering.exception() is None:
            await join_cleanup(asyncio.create_task(asyncio.to_thread(cm.__exit__, *sys.exc_info())))
        raise
    error: tuple[Any, Any, Any] = (None, None, None)
    try:
        yield source
    except BaseException:
        error = sys.exc_info()
        raise
    finally:
        await join_cleanup(asyncio.create_task(asyncio.to_thread(cm.__exit__, *error)))


def _write_json(path: Path, value: Mapping[str, Any]) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, sort_keys=True, allow_nan=False)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())


def _write_all(handle: BinaryIO, payload: bytes) -> None:
    remaining = memoryview(payload)
    while remaining:
        written = handle.write(remaining)
        if written is None or written <= 0:
            raise OSError("development event write is incomplete")
        remaining = remaining[written:]


def _create_output(path: Path) -> Path:
    output = path.expanduser().resolve()
    if output.is_relative_to(_ROOT):
        raise ValueError("development output must remain external")
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    return output


async def evaluate_development_fixture(
    manifest: Mapping[str, Any],
    split_lock: Mapping[str, Any],
    *,
    artifact_root: Path,
    scorer_policy: Mapping[str, Any],
    fixture_id: str,
    candidate_sha256: str,
    activity_factory: Callable[[], ActivitySession],
    output_directory: Path,
    input_mode: str = "throughput",
    epoch: str = "session",
    timeout_seconds: float = 1800,
    verify_candidate: Callable[[], Awaitable[Mapping[str, object]]] | None = None,
    verify_commit: Callable[[], None] | None = None,
) -> dict[str, Any]:
    """Replay and score a development fixture with a supervised caller factory.

    Never pass the references to the activity factory or text replay. The caller
    must establish cross-process exclusion, actual candidate identity and model
    execution authorization. This result cannot unlock a holdout or certify.
    """
    preparing = asyncio.create_task(
        asyncio.to_thread(
            _prepare,
            manifest,
            split_lock,
            root=artifact_root,
            policy=scorer_policy,
            fixture_id=fixture_id,
            candidate_sha256=candidate_sha256,
        )
    )
    prepared = await join_cleanup(preparing)
    output = await join_cleanup(
        asyncio.create_task(asyncio.to_thread(_create_output, output_directory))
    )
    identity = {
        "schema_version": 1,
        "fixture_id": fixture_id,
        "candidate_sha256": candidate_sha256,
        "manifest_sha256": prepared["manifest_sha256"],
        "split_lock_sha256": prepared["split_lock_sha256"],
        "scorer_policy_sha256": canonical_digest(prepared["policy"]),
    }
    await join_cleanup(
        asyncio.create_task(
            asyncio.to_thread(
                _write_json, output / "attempt.json", {**identity, "status": "started"}
            )
        )
    )
    activity_rows: list[dict[str, Any]] = []
    text_rows: list[dict[str, Any]] = []
    raw_size = 0
    try:
        async with _sidecar(prepared) as source:
            fd = os.open(output / "events.jsonl", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb", buffering=0) as raw:

                async def sink(event: Mapping[str, Any]) -> None:
                    nonlocal raw_size
                    payload = (
                        json.dumps(event, ensure_ascii=False, sort_keys=True, allow_nan=False)
                        + "\n"
                    ).encode("utf-8")
                    raw_size += len(payload)
                    if raw_size > _MAX_EVENTS_BYTES:
                        raise ValueError("development event artifact exceeds budget")
                    await join_cleanup(
                        asyncio.create_task(asyncio.to_thread(_write_all, raw, payload))
                    )
                    if event["kind"] in {"activity", "text"}:
                        rows = text_rows if event["kind"] == "text" else activity_rows
                        if len(rows) >= _MAX_ROWS:
                            raise ValueError("development score intervals exceed budget")
                        rows.append(
                            {
                                "start": event["start_sample"] / 16000,
                                "end": event["end_sample"] / 16000,
                                "speaker": event["speaker"],
                                **({"text": event["text"]} if rows is text_rows else {}),
                            }
                        )

                # Construction performs a bounded lookahead over file input.
                replay = await join_cleanup(
                    asyncio.create_task(asyncio.to_thread(FixedTextReplay, source))
                )
                execution = await run_candidate_stream(
                    iter_wav_pcm(
                        prepared["root"] / prepared["fixture"]["artifacts"]["pcm"]["path"]
                    ),
                    activity_factory=activity_factory,
                    text_replay=replay,
                    epoch=epoch,
                    sink=sink,
                    input_mode=input_mode,
                    timeout_seconds=timeout_seconds,
                )
                await join_cleanup(asyncio.create_task(asyncio.to_thread(raw.flush)))
                await join_cleanup(asyncio.create_task(asyncio.to_thread(os.fsync, raw.fileno())))
            proof = await join_cleanup(asyncio.create_task(asyncio.to_thread(source.proof)))
        await join_cleanup(asyncio.create_task(asyncio.to_thread(_check_inputs, prepared)))
        if execution["accepted_samples"] != prepared["total"]:
            raise ValueError("development PCM sample coverage differs from reference")
        quality = await join_cleanup(
            asyncio.create_task(
                asyncio.to_thread(
                    score_meeting_quality,
                    prepared["references"]["activity_reference"],
                    activity_rows,
                    reference_text=prepared["references"]["text_reference"],
                    hypothesis_text=text_rows,
                    duration=prepared["total"] / 16000,
                    policy=prepared["policy"],
                )
            )
        )
        await join_cleanup(asyncio.create_task(asyncio.to_thread(_check_inputs, prepared)))
        candidate_execution = (
            dict(await verify_candidate()) if verify_candidate is not None else None
        )
        if candidate_execution is not None and (
            set(candidate_execution) != set(_CANDIDATE_EXECUTION_FIELDS)
            or any(
                type(candidate_execution[key]) is not type(value)
                or candidate_execution[key] != value
                for key, value in _CANDIDATE_EXECUTION_FIELDS.items()
            )
        ):
            raise ValueError("candidate execution observation is invalid")
        result = {
            **identity,
            "status": "completed",
            "source_meeting_id": prepared["fixture"]["source_group_id"],
            "speakers_count": prepared["fixture"]["speakers_count"],
            "scene": prepared["fixture"]["scene"],
            "sample_kind": prepared["fixture"]["sample_kind"],
            "channel": prepared["fixture"]["channel"],
            "transform_sha256": canonical_digest(prepared["fixture"]["transform"]),
            "reference_label_policy_sha256": canonical_digest(
                prepared["fixture"]["reference_label_policy"]
            ),
            "quality": quality,
            "execution": execution,
            "sidecar": proof,
            "input_files_verified": True,
            "runtime_identity_verified": False,
            "certification_eligible": False,
            "certified_max_speakers": None,
            "verdict": "diagnostic",
        }
        if candidate_execution is not None:
            result["candidate_execution"] = candidate_execution
        await join_cleanup(
            asyncio.create_task(
                asyncio.to_thread(_write_json, output / "result.partial.json", result)
            )
        )
        await join_cleanup(asyncio.create_task(asyncio.to_thread(_check_inputs, prepared)))
        if verify_candidate is not None and dict(await verify_candidate()) != candidate_execution:
            raise ValueError("candidate execution observation changed before commit")
        if verify_commit is not None:
            verify_commit()
        _check_input_stamps(prepared)
        # No await between the exclusive commit and return: cancellation while
        # writing evidence leaves only a partial artifact, never a completed result.
        os.link(output / "result.partial.json", output / "result.json", follow_symlinks=False)
        with contextlib.suppress(OSError):
            (output / "result.partial.json").unlink()
        return result
    except BaseException as exc:
        with contextlib.suppress(Exception):
            await join_cleanup(
                asyncio.create_task(
                    asyncio.to_thread(
                        _write_json,
                        output / "failure.json",
                        {
                            **identity,
                            "status": "failed",
                            "reason": "cancelled"
                            if isinstance(exc, asyncio.CancelledError)
                            else "execution_or_evidence_invalid",
                        },
                    )
                )
            )
        if isinstance(exc, asyncio.CancelledError):
            raise
        raise RuntimeError("development_fixture_failed") from None


def _paired_metrics(
    rows: list[dict[str, Any]], *, policy: Mapping[str, Any]
) -> dict[str, dict[str, list[float]]] | None:
    grouped: dict[str, list[tuple[float, float, float, float]]] = {}
    seen: set[str] = set()
    for row in rows:
        fixture = row["fixture_id"]
        if fixture in seen:
            raise ValueError("duplicate fixture is not an independent repeat")
        seen.add(fixture)
        errors, total, cp_errors, cp_total = standard_metric_totals(row, policy)
        if total <= 0 or cp_errors is None or cp_total is None:
            return None
        grouped.setdefault(row["source_meeting_id"], []).append(
            (errors, total, cp_errors, cp_total)
        )
    metrics: dict[str, dict[str, list[float]]] = {"der": {}, "cp_cer": {}}
    for group, values in grouped.items():
        metrics["der"][group] = [math.fsum(v[0] for v in values) / math.fsum(v[1] for v in values)]
        metrics["cp_cer"][group] = [
            math.fsum(v[2] for v in values) / math.fsum(v[3] for v in values)
        ]
    return metrics


async def evaluate_development_checkpoint(
    manifest: Mapping[str, Any],
    split_lock: Mapping[str, Any],
    *,
    schedule: CommonPrefixSchedule,
    candidate_ids: Mapping[str, str],
    activity_factories: Mapping[str, Callable[[], ActivitySession]],
    artifact_root: Path,
    scorer_policy: Mapping[str, Any],
    output_directory: Path,
    input_mode: str = "throughput",
    timeout_seconds: float = 1800,
    candidate_verifiers: Mapping[str, Callable[[], Awaitable[Mapping[str, object]]]] | None = None,
    verify_checkpoint: Callable[[], Awaitable[None]] | None = None,
    verify_commit: Callable[[], None] | None = None,
) -> dict[str, Any]:
    """Run one complete paired prefix, score it and return the next immutable state.

    Every surviving candidate and C0 (where applicable) is run serially over
    every fixture in the requested source groups. No partial round is recorded.
    Product/C0 scores are diagnostic until runtime, latency and holdout gates
    are connected by an independently validated execution composition root.
    """
    request = schedule.request()
    candidate_ids, activity_factories = dict(candidate_ids), dict(activity_factories)
    if candidate_verifiers is not None:
        candidate_verifiers = dict(candidate_verifiers)
        if set(candidate_verifiers) != set(request["candidates"]):
            raise ValueError("development checkpoint verifier set differs from request")
    frozen = json.loads(
        json.dumps(
            {"manifest": manifest, "lock": split_lock, "policy": scorer_policy}, allow_nan=False
        )
    )
    manifest, split_lock, scorer_policy = (frozen[k] for k in ("manifest", "lock", "policy"))
    count = schedule.speakers_count
    if (
        request["status"] != "pending"
        or dict(candidate_ids) != schedule.candidate_ids
        or set(activity_factories) != set(request["candidates"])
        or canonical_digest(manifest) != schedule.manifest_sha256
        or canonical_digest(scorer_policy) != schedule.scorer_policy_sha256
        or manifest.get("group_order", {}).get(str(count)) != schedule.as_dict()["source_groups"]
    ):
        raise ValueError("development checkpoint differs from frozen request")
    selected = [
        row
        for group in request["source_group_ids"]
        for row in manifest["fixtures"]
        if row["source_group_id"] == group and row["speakers_count"] == count
    ]
    if (
        len(selected) > 4096
        or len({r["id"] for r in selected}) != len(selected)
        or {r["source_group_id"] for r in selected} != set(request["source_group_ids"])
    ):
        raise ValueError("development checkpoint requires every requested source group")
    # Complete shared-source preflight before constructing the first worker.
    prepared = []
    for fixture in selected:
        item = await join_cleanup(
            asyncio.create_task(
                asyncio.to_thread(
                    _prepare,
                    manifest,
                    split_lock,
                    root=artifact_root,
                    policy=scorer_policy,
                    fixture_id=fixture["id"],
                    candidate_sha256=candidate_ids[request["candidates"][0]],
                )
            )
        )
        # Keep only file fingerprints across meetings, never all reference texts.
        prepared.append({key: item[key] for key in ("fixture", "root", "stamps")})
        del item
    output = await join_cleanup(
        asyncio.create_task(asyncio.to_thread(_create_output, output_directory))
    )
    identity = {
        "schema_version": 1,
        "manifest_sha256": schedule.manifest_sha256,
        "scorer_policy_sha256": schedule.scorer_policy_sha256,
        "speakers_count": count,
        "checkpoint": request["checkpoint"],
        "source_group_ids": request["source_group_ids"],
        "candidate_ids": schedule.candidate_ids,
    }
    await join_cleanup(
        asyncio.create_task(
            asyncio.to_thread(
                _write_json, output / "attempt.json", {**identity, "status": "started"}
            )
        )
    )
    observations: dict[str, list[dict[str, Any]]] = {}
    try:
        for name in request["candidates"]:
            rows = []
            for fixture in selected:
                # Each call confirms exact-child cleanup before the next model.
                rows.append(
                    await evaluate_development_fixture(
                        manifest,
                        split_lock,
                        artifact_root=artifact_root,
                        scorer_policy=scorer_policy,
                        fixture_id=fixture["id"],
                        candidate_sha256=candidate_ids[name],
                        activity_factory=activity_factories[name],
                        output_directory=output / name / fixture["id"],
                        input_mode=input_mode,
                        timeout_seconds=timeout_seconds,
                        verify_candidate=(
                            candidate_verifiers[name] if candidate_verifiers is not None else None
                        ),
                        verify_commit=verify_commit,
                    )
                )
            observations[name] = rows
        comparisons: dict[str, Any] = {}
        evidence: dict[str, Any] = {}
        for name, rows in observations.items():
            summary = await join_cleanup(
                asyncio.create_task(
                    asyncio.to_thread(
                        summarize_meeting_quality,
                        rows,
                        required_strata=list(range(1, count + 1)),
                        policy=scorer_policy,
                    )
                )
            )
            product = summary["strata"][str(count)]
            nondegradation = None
            if count <= 4 and name != "C0":
                baseline_metrics = _paired_metrics(observations["C0"], policy=scorer_policy)
                candidate_metrics = _paired_metrics(rows, policy=scorer_policy)
                nondegradation = (
                    await join_cleanup(
                        asyncio.create_task(
                            asyncio.to_thread(
                                nondegradation_gate,
                                baseline_metrics,
                                candidate_metrics,
                                policy=scorer_policy,
                            )
                        )
                    )
                    if baseline_metrics is not None and candidate_metrics is not None
                    else {"decision": "not_observed", "quality_gate": "fail"}
                )
            scenes = {}
            for scene in ("near", "far"):
                by_scene = await join_cleanup(
                    asyncio.create_task(
                        asyncio.to_thread(
                            summarize_meeting_quality,
                            [row for row in rows if row["scene"] == scene],
                            required_strata=list(range(1, count + 1)),
                            policy=scorer_policy,
                        )
                    )
                )
                scenes[scene] = by_scene["strata"][str(count)]
            comparisons[name] = {
                "product": product,
                "nondegradation": nondegradation,
                "scenes": scenes,
            }
            evidence[name] = {
                "candidate_sha256": candidate_ids[name],
                "source_group_ids": request["source_group_ids"],
                "product_decision": product["decision"],
                "nondegradation_decision": nondegradation["decision"] if nondegradation else None,
            }
        next_state = schedule.record(evidence)
        for item in prepared:
            await join_cleanup(asyncio.create_task(asyncio.to_thread(_check_inputs, item)))
        result = {
            **identity,
            "status": "completed",
            "schedule": next_state.as_dict(),
            "request": next_state.request(),
            "comparisons": comparisons,
            "observations": observations,
            "verdict": "diagnostic",
            "runtime_identity_verified": False,
            "certification_eligible": False,
            "certified_max_speakers": None,
        }
        await join_cleanup(
            asyncio.create_task(
                asyncio.to_thread(_write_json, output / "checkpoint.partial.json", result)
            )
        )
        for item in prepared:
            await join_cleanup(asyncio.create_task(asyncio.to_thread(_check_inputs, item)))
        if candidate_verifiers is not None:
            for verify in candidate_verifiers.values():
                await verify()
        if verify_checkpoint is not None:
            await verify_checkpoint()
        if verify_commit is not None:
            verify_commit()
        for item in prepared:
            _check_input_stamps(item)
        os.link(
            output / "checkpoint.partial.json", output / "checkpoint.json", follow_symlinks=False
        )
        with contextlib.suppress(OSError):
            (output / "checkpoint.partial.json").unlink()
        return result
    except BaseException as exc:
        with contextlib.suppress(Exception):
            await join_cleanup(
                asyncio.create_task(
                    asyncio.to_thread(
                        _write_json,
                        output / "failure.json",
                        {
                            **identity,
                            "status": "failed",
                            "reason": "cancelled"
                            if isinstance(exc, asyncio.CancelledError)
                            else "execution_or_evidence_invalid",
                        },
                    )
                )
            )
        if isinstance(exc, asyncio.CancelledError):
            raise
        raise RuntimeError("development_checkpoint_failed") from None
