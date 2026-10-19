"""Explicit serial native development checkpoints; every result remains diagnostic.

An independent checkpoint lock binds paths and canonical JSON digests for the
manifest, split lock, scorer and three candidate specs. A resume file contains
only the previous result's ``schedule`` object; restore replays its finite
history against that independent lock, without granting certification.
"""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable, Mapping
from pathlib import Path
from typing import Any

from meeting_c0 import C0_IMPLEMENTATION
from meeting_candidate_execution import (
    CandidateArtifacts,
    EvaluationPortLease,
    NativeCandidateRun,
    read_control_json,
)
from meeting_candidate_schedule import CommonPrefixSchedule
from meeting_development_fixture import evaluate_development_checkpoint
from meeting_evaluation_identity import MeetingCandidateSpec, candidate_digest, canonical_digest

from speechrail.domain.resource_limits import GovernorLimits
from speechrail.runtime.cleanup import join_cleanup
from speechrail.runtime.resource_governor import ResourceGovernor


def _fields(value: object, names: set[str]) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != names:
        raise ValueError("checkpoint control fields differ from schema")
    return value


def _path(value: object) -> Path:
    if not isinstance(value, str) or not value or not Path(value).is_absolute():
        raise ValueError("checkpoint paths must be explicit absolute paths")
    path = Path(value)
    if path.is_symlink():
        raise ValueError("checkpoint paths must not be symlinks")
    return path


def _stamp(path: Path) -> tuple[int, ...]:
    value = path.stat(follow_symlinks=False)
    return value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns


class CheckpointControls:
    """Frozen bounded JSON controls; no input paths or contents enter evidence."""

    def __init__(self, path: Path) -> None:
        self._documents: list[tuple[Path, tuple[int, ...], str]] = []
        self._paths: list[tuple[Path, Path, tuple[int, ...]]] = []
        self.lock = _fields(
            self.read(path),
            {
                "schema_version",
                "speakers_count",
                "service_port",
                "manifest",
                "split_lock",
                "scorer_policy",
                "artifact_root",
                "candidates",
            },
        )
        if type(self.lock["schema_version"]) is not int or self.lock["schema_version"] != 1:
            raise ValueError("checkpoint lock schema version invalid")
        port = self.lock["service_port"]
        if type(port) is not int or not 1 <= port <= 65535:
            raise ValueError("checkpoint service port invalid")
        self.manifest = self.document(self.lock["manifest"])
        self.split_lock = self.document(self.lock["split_lock"])
        self.policy = self.document(self.lock["scorer_policy"])
        self.artifact_root = self.bind_path(self.lock["artifact_root"], directory=True)
        candidates = _fields(self.lock["candidates"], {"C0", "C1", "C2"})
        self.candidates: dict[str, tuple[MeetingCandidateSpec, Path, Path]] = {}
        for name, entry in candidates.items():
            entry = _fields(entry, {"spec", "worker", "model_directory"})
            spec = MeetingCandidateSpec(**self.document(entry["spec"]))
            if name == "C0":
                valid = spec.implementation_id == C0_IMPLEMENTATION and (
                    type(spec.preset.get("num_speakers")) is int
                    and spec.preset["num_speakers"] == 4
                )
            else:
                valid = (
                    spec.implementation_id == "nemotron3-streaming-candidate-v1"
                    and spec.preset.get("name") == {"C1": "fast32", "C2": "fast128"}[name]
                    and type(spec.preset.get("num_speakers")) is int
                    and spec.preset["num_speakers"] == 8
                )
            if not valid or spec.scorer.get("policy_sha256") != canonical_digest(self.policy):
                raise ValueError("checkpoint candidate role or scorer identity invalid")
            self.candidates[name] = (
                spec,
                self.bind_path(entry["worker"], directory=False),
                self.bind_path(entry["model_directory"], directory=True),
            )
        count = self.lock["speakers_count"]
        ids = {
            name: candidate_digest(row[0])
            for name, row in self.candidates.items()
            if name != "C0" or (type(count) is int and count <= 4)
        }
        self.initial_schedule = CommonPrefixSchedule(
            count,
            ids,
            self.manifest["group_order"][str(count)],
            manifest_sha256=canonical_digest(self.manifest),
            scorer_policy_sha256=canonical_digest(self.policy),
        )

    def read(self, path: Path) -> dict[str, Any]:
        path = _path(str(path))
        before = _stamp(path)
        value = read_control_json(path)
        if before != _stamp(path):
            raise ValueError("checkpoint control changed during read")
        self._documents.append((path, before, canonical_digest(value)))
        return value

    def document(self, descriptor: object) -> dict[str, Any]:
        row = _fields(descriptor, {"path", "sha256"})
        value = self.read(_path(row["path"]))
        if canonical_digest(value) != row["sha256"]:
            raise ValueError("checkpoint document differs from independent lock")
        return value

    def bind_path(self, value: object, *, directory: bool) -> Path:
        path = _path(value)
        resolved = path.resolve(strict=True)
        if directory != resolved.is_dir() or (not directory and not resolved.is_file()):
            raise ValueError("checkpoint artifact path type invalid")
        self._paths.append((path, resolved, _stamp(path)))
        return resolved

    def restore(self, saved: dict[str, Any]) -> CommonPrefixSchedule:
        initial = self.initial_schedule.as_dict()
        _fields(saved, set(initial))
        # The library replays scheduling rules; the external boundary also
        # rejects JSON type substitutions (e.g. true for speaker count 1).
        if canonical_digest({k: v for k, v in saved.items() if k != "rounds"}) != (
            canonical_digest({k: v for k, v in initial.items() if k != "rounds"})
        ) or not isinstance(saved["rounds"], list):
            raise ValueError("resume schedule differs from independent initial lock")
        if any(not isinstance(row, dict) for row in saved["rounds"]):
            raise ValueError("resume schedule round must be an object")
        return CommonPrefixSchedule.restore(saved, expected=self.initial_schedule)

    def verify(self) -> None:
        for path, before, digest in self._documents:
            if _stamp(path) != before or canonical_digest(read_control_json(path)) != digest:
                raise ValueError("checkpoint controls changed")
            if _stamp(path) != before:
                raise ValueError("checkpoint controls changed during verification")
        self.verify_stamps()

    def verify_stamps(self) -> None:
        for path, before, _ in self._documents:
            if path.is_symlink() or _stamp(path) != before:
                raise ValueError("checkpoint controls changed before commit")
        for path, resolved, stamp in self._paths:
            # Directory mtimes change as artifacts are added, so check identity
            # for directories; CandidateArtifacts checks their complete contents.
            current = _stamp(path)
            if (
                path.is_symlink()
                or path.resolve(strict=True) != resolved
                or (current[:2] != stamp[:2] if resolved.is_dir() else current != stamp)
            ):
                raise ValueError("checkpoint artifact paths changed")


async def evaluate_native_checkpoint(
    *,
    checkpoint_lock: Path,
    output_directory: Path,
    resume_schedule: Path | None = None,
    input_mode: str = "throughput",
    timeout_seconds: float = 1800,
) -> dict[str, Any]:
    """Run the exact next live set, under one configured-port lease for the round."""
    controls = await join_cleanup(
        asyncio.create_task(asyncio.to_thread(CheckpointControls, checkpoint_lock))
    )
    schedule = controls.initial_schedule
    if resume_schedule is not None:
        saved = await join_cleanup(
            asyncio.create_task(asyncio.to_thread(controls.read, resume_schedule))
        )
        schedule = controls.restore(saved)
    request = schedule.request()
    if request["status"] != "pending":
        raise ValueError("checkpoint schedule has no pending native request")
    with EvaluationPortLease(controls.lock["service_port"]) as port:
        # Preflight every registered candidate before the shared evaluator may
        # construct any worker, including eliminated candidates and unused C0.
        artifacts = {}
        for name, (spec, worker, models) in controls.candidates.items():
            artifacts[name] = await join_cleanup(
                asyncio.create_task(asyncio.to_thread(CandidateArtifacts, spec, worker, models))
            )
        governor = ResourceGovernor(GovernorLimits(2, 1, 8), allow_heavy_overlap=False)
        runs = {
            name: NativeCandidateRun(artifacts[name], port, governor)
            for name in request["candidates"]
        }

        async def verify_controls() -> None:
            await join_cleanup(asyncio.create_task(asyncio.to_thread(controls.verify)))

        async def verify_checkpoint() -> None:
            await verify_controls()
            for artifact in artifacts.values():
                await join_cleanup(asyncio.create_task(asyncio.to_thread(artifact.verify)))

        def verify_commit() -> None:
            controls.verify_stamps()
            for artifact in artifacts.values():
                artifact.verify_stamps()
            if governor.diarization_owner.occupied:
                raise ValueError("candidate cleanup is unconfirmed before commit")

        def verifier(name: str) -> Callable[[], Awaitable[Mapping[str, object]]]:
            async def verify() -> Mapping[str, object]:
                await verify_controls()
                return await runs[name].verify()

            return verify

        await verify_checkpoint()
        return await evaluate_development_checkpoint(
            controls.manifest,
            controls.split_lock,
            schedule=schedule,
            candidate_ids=schedule.candidate_ids,
            activity_factories={name: run.activity_factory for name, run in runs.items()},
            candidate_verifiers={name: verifier(name) for name in runs},
            verify_checkpoint=verify_checkpoint,
            verify_commit=verify_commit,
            artifact_root=controls.artifact_root,
            scorer_policy=controls.policy,
            output_directory=output_directory,
            input_mode=input_mode,
            timeout_seconds=timeout_seconds,
        )
