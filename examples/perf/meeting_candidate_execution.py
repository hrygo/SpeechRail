"""Serial development execution; no holdout, service control or model discovery.

The configured port's guard excludes that service, not arbitrary other ports.
The exact child inherits it: closing the parent descriptor must not unlock a
still-live child. Evidence remains diagnostic until provenance/joint gates pass.
"""

from __future__ import annotations

import asyncio
import fcntl
import json
import os
import stat
import time
from collections.abc import AsyncIterator, Awaitable, Callable, Mapping
from pathlib import Path
from typing import Any

from meeting_c0 import C0_IMPLEMENTATION, C0WorkerProcess, open_c0_session
from meeting_candidate_session import (
    CandidateWorkerProcess,
    open_candidate_session,
)
from meeting_development_fixture import evaluate_development_fixture
from meeting_evaluation_identity import MeetingCandidateSpec, candidate_digest
from meeting_live_text import LiveTextChannel
from meeting_pcm_feed import PcmChunk

from speechrail.backends.diarization.coreml import CoreMLActivitySession
from speechrail.domain.diarization.ports import ActivitySession
from speechrail.domain.diarization.types import ActivityUpdate
from speechrail.domain.resource_limits import GovernorLimits
from speechrail.runtime.cleanup import join_cleanup
from speechrail.runtime.phase_trace import PhaseTrace
from speechrail.runtime.resource_governor import ResourceGovernor
from speechrail.runtime.server_lock import ServerInstanceLock


class EvaluationPortLease:
    """Same per-user/per-port flock as serve, without writing service metadata."""

    def __init__(self, port: int, *, directory: Path | None = None) -> None:
        self._path = ServerInstanceLock(port, directory=directory).path
        self._descriptor: int | None = None

    @property
    def descriptor(self) -> int:
        if self._descriptor is None:
            raise RuntimeError("evaluation_port_not_active")
        return self._descriptor

    def __enter__(self) -> EvaluationPortLease:
        if self._descriptor is not None:
            raise RuntimeError("evaluation_port_already_active")
        fd = os.open(self._path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                raise ValueError("evaluation guard must be an owned regular file")
            os.fchmod(fd, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RuntimeError("evaluation_port_busy") from None
        except BaseException:
            os.close(fd)
            raise
        self._descriptor = fd
        return self

    def __exit__(self, *_: object) -> None:
        descriptor, self._descriptor = self._descriptor, None
        if descriptor is not None:
            # LOCK_UN would unlock the child's shared open-file description.
            # Close only: the kernel releases it after the last holder exits.
            os.close(descriptor)


def _pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate evaluation control field")
        result[key] = value
    return result


def read_control_json(path: Path) -> dict[str, Any]:
    """Bounded local control input; never block on FIFO or follow a symlink."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as handle:
        info = os.fstat(handle.fileno())
        limit = 16 * 1024 * 1024
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise ValueError("evaluation control exceeds file budget")
        contents = handle.read(limit + 1)
        if len(contents) > limit:
            raise ValueError("evaluation control exceeds file budget")
    value = json.loads(contents, object_pairs_hook=_pairs)
    if not isinstance(value, dict):
        raise ValueError("evaluation control must be an object")
    # Also reject nonfinite JSON numbers anywhere in the input.
    json.dumps(value, allow_nan=False)
    return value


class CandidateArtifacts:
    """Bind actual files before construction, and reject changes through reaping."""

    def __init__(self, spec: MeetingCandidateSpec, worker: Path, models: Path) -> None:
        self.spec = spec
        if worker.is_symlink() or models.is_symlink():
            raise ValueError("evaluation artifacts must not be symlinks")
        self.worker = worker.resolve(strict=True)
        self.models = models.resolve(strict=True)
        before = self._stamps()
        self._preflight()
        if before != self._stamps():
            raise ValueError("candidate artifacts changed during preflight")
        self._baseline = before

    def _preflight(self) -> None:
        from probe_meeting_candidate import artifact_preflight

        artifact_preflight(self.spec, worker=self.worker, model_directory=self.models)

    def _stamps(self) -> dict[str, tuple[int, ...]]:
        from probe_meeting_candidate import candidate_source_paths

        result: dict[str, tuple[int, ...]] = {}
        entries = [
            ("worker", self.worker),
            ("models", self.models),
            *[(f"model/{path.relative_to(self.models)}", path) for path in self.models.rglob("*")],
            *[(f"source/{i}", path) for i, path in enumerate(candidate_source_paths(self.spec))],
        ]
        for key, path in entries:
            value = path.stat(follow_symlinks=False)
            if not stat.S_ISREG(value.st_mode) and not (
                key.startswith("model") and stat.S_ISDIR(value.st_mode)
            ):
                raise ValueError(
                    "candidate artifacts must remain regular files or model directories"
                )
            result[key] = (
                value.st_dev,
                value.st_ino,
                value.st_size,
                value.st_mtime_ns,
                value.st_ctime_ns,
            )
        return result

    def verify_stamps(self) -> None:
        """No hashes or awaits: close observable changes just before commit."""
        if self._stamps() != self._baseline:
            raise ValueError("candidate artifacts changed before commit")

    def verify(self) -> None:
        if self._stamps() != self._baseline:
            raise ValueError("candidate artifacts changed during execution")
        self._preflight()  # Includes new/removed model files and adapter/scorer source hashes.
        if self._stamps() != self._baseline:
            raise ValueError("candidate artifacts changed during verification")


class CheckedCandidateSession:
    """Artifact checks run outside native compute; original exact-child lease owns cleanup."""

    def __init__(self, session: CoreMLActivitySession, artifacts: CandidateArtifacts) -> None:
        self._session, self._artifacts = session, artifacts

    async def append(self, *, start_sample: int, pcm16: bytes) -> None:
        await self._session.append(start_sample=start_sample, pcm16=pcm16)

    def updates(self) -> AsyncIterator[ActivityUpdate]:
        return self._session.updates()

    async def finish(self, *, through_sample: int) -> None:
        await self._session.finish(through_sample=through_sample)
        await self._verify()

    async def cancel(self) -> None:
        await self._session.cancel()
        await self._verify()

    async def _verify(self) -> None:
        await join_cleanup(asyncio.create_task(asyncio.to_thread(self._artifacts.verify)))

    def drain_phase_events(self) -> tuple[dict[str, object], ...]:
        return self._session.drain_phase_events()

    def phase_trace_status(self) -> dict[str, object]:
        return self._session.phase_trace_status()


class NativeCandidateRun:
    """Reuse one frozen artifact set and shared owner; construct only after claim."""

    def __init__(
        self,
        artifacts: CandidateArtifacts,
        port: EvaluationPortLease,
        governor: ResourceGovernor,
    ) -> None:
        self.artifacts, self.port, self.governor = artifacts, port, governor
        self._governor = governor
        self._shared_active = False
        self.transport: CandidateWorkerProcess | C0WorkerProcess | None = None

    async def evaluate_shared_pcm(
        self,
        pcm: bytes,
        frames: AsyncIterator[PcmChunk],
        *,
        governor: ResourceGovernor,
        sink: Callable[[Mapping[str, Any]], Awaitable[None]],
        text_channel: LiveTextChannel | None = None,
        timeout_seconds: float = 1800,
        sink_timeout_seconds: float = 5,
        clock: Callable[[], float] = time.monotonic,
    ) -> dict[str, Any]:
        """Use this native owner's lane, inherited guard and checked artifacts.

        No text sidecar, model discovery or joint runtime certification. The
        caller owns the outer common-feed scope and any separate ASR runtime.
        """
        from meeting_activity_workload import run_shared_activity_stream

        delegated = claimed = False

        def check_owner() -> None:
            if self.governor is not self._governor or governor is not self._governor:
                raise ValueError("shared activity governor differs from native owner")

        def construct() -> ActivitySession:
            check_owner()
            self.artifacts.verify_stamps()
            return self.activity_factory()

        try:
            check_owner()
            if self._shared_active or governor.diarization_owner.occupied:
                raise ValueError("native shared activity owner is busy")
            self._shared_active = claimed = True
            _ = self.port.descriptor
            await join_cleanup(asyncio.create_task(asyncio.to_thread(self.artifacts.verify)))
            check_owner()
            delegated = True
            result = await run_shared_activity_stream(
                pcm, frames, activity_factory=construct, epoch="session", sink=sink,
                text_channel=text_channel,
                timeout_seconds=timeout_seconds, sink_timeout_seconds=sink_timeout_seconds,
                clock=clock,
            )
            check_owner()
            observation = await self.verify()
            check_owner()
            return {**result, "candidate_execution": dict(observation)}
        except BaseException:
            if text_channel is not None:
                text_channel.fail()
            raise
        finally:
            if claimed:
                self._shared_active = False
            if not delegated:
                if text_channel is not None:
                    await text_channel.aclose()
                close = getattr(frames, "aclose", None)
                if close is not None:
                    await join_cleanup(
                        asyncio.create_task(close(), name="native-activity-source-close")
                    )

    def activity_factory(self) -> ActivitySession:
        spec, artifacts = self.artifacts.spec, self.artifacts
        if spec.implementation_id == C0_IMPLEMENTATION:

            def construct_c0() -> C0WorkerProcess:
                self.transport = C0WorkerProcess(
                    executable=artifacts.worker,
                    model_path=artifacts.models / str(spec.preset["model_file_name"]),
                    inherited_guard_fd=self.port.descriptor,
                )
                return self.transport

            return CheckedCandidateSession(
                open_c0_session(
                    worker_factory=construct_c0, governor=self.governor, phase_trace=PhaseTrace()
                ),
                artifacts,
            )

        def construct() -> CandidateWorkerProcess:
            self.transport = CandidateWorkerProcess(
                executable=artifacts.worker,
                model_path=artifacts.models,
                preset=str(spec.preset["name"]),
                compute_units=spec.compute_units,
                inherited_guard_fd=self.port.descriptor,
            )
            return self.transport

        session = open_candidate_session(
            epoch="session",
            governor=self.governor,
            worker_factory=construct,
            phase_trace=PhaseTrace(),
        )
        return CheckedCandidateSession(session, artifacts)

    def verify_commit(self) -> None:
        self.artifacts.verify_stamps()
        if (
            self.transport is None
            or not self.transport.preflight_observed
            or (self.governor.diarization_owner.occupied)
        ):
            raise ValueError("candidate execution observation changed before commit")

    async def verify(self) -> Mapping[str, object]:
        await join_cleanup(asyncio.create_task(asyncio.to_thread(self.artifacts.verify)))
        if (
            self.transport is None
            or not self.transport.preflight_observed
            or self.governor.diarization_owner.occupied
        ):
            raise ValueError("candidate preflight or child reclamation is unconfirmed")
        return {
            "configured_port_exclusion": True,
            "exclusion_scope": "per_user_configured_port",
            "native_preflight_observed": True,
            "artifact_checks_through_cleanup": True,
            "exact_child_reaped": True,
            "model_revision_provenance_verified": False,
            "joint_asr_latency_observed": False,
            "production_certification": False,
        }


async def evaluate_candidate_development(
    *,
    spec: MeetingCandidateSpec,
    worker: Path,
    model_directory: Path,
    manifest: Mapping[str, Any],
    split_lock: Mapping[str, Any],
    scorer_policy: Mapping[str, Any],
    artifact_root: Path,
    output_directory: Path,
    fixture_id: str,
    service_port: int,
    input_mode: str = "throughput",
    timeout_seconds: float = 1800,
) -> dict[str, Any]:
    """Explicit native execution, after input/scorer validation by the fixture runner.

    One candidate/fixture is diagnostic; this entry does not select a winner,
    issue a development receipt, certify a speaker count or accept holdout.
    """
    with EvaluationPortLease(service_port) as port:
        artifacts = await join_cleanup(
            asyncio.create_task(
                asyncio.to_thread(CandidateArtifacts, spec, worker, model_directory)
            )
        )
        run = NativeCandidateRun(
            artifacts,
            port,
            ResourceGovernor(GovernorLimits(2, 1, 8), allow_heavy_overlap=False),
        )

        return await evaluate_development_fixture(
            manifest,
            split_lock,
            artifact_root=artifact_root,
            scorer_policy=scorer_policy,
            fixture_id=fixture_id,
            candidate_sha256=candidate_digest(spec),
            activity_factory=run.activity_factory,
            output_directory=output_directory,
            input_mode=input_mode,
            timeout_seconds=timeout_seconds,
            verify_candidate=run.verify,
            verify_commit=run.verify_commit,
        )
