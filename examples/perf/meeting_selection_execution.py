"""Explicit offline development selection; no model or service operations.

Independent controls bind the initial schedules and final checkpoint documents.
Mutable JSON is reproducibility evidence, never a trusted production receipt.
"""

from __future__ import annotations

import asyncio
import contextlib
import hashlib
import os
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from meeting_candidate_execution import read_control_json
from meeting_candidate_schedule import CommonPrefixSchedule
from meeting_candidate_selection import select_development_candidate
from meeting_checkpoint_execution import _fields, _path, _stamp
from meeting_development_fixture import _create_output, _write_json
from meeting_evaluation_identity import canonical_digest

from speechrail.runtime.cleanup import join_cleanup

_MAX_BYTES = 32 * 1024 * 1024
_ROOT = Path(__file__).resolve().parents[2]
_SOURCES = (
    "examples/perf/meeting_selection_execution.py",
    "examples/perf/meeting_candidate_selection.py",
    "examples/perf/meeting_candidate_schedule.py",
    "examples/perf/meeting_evaluation_identity.py",
    "examples/perf/meeting_quality_metrics.py",
    "examples/perf/meeting_candidate_execution.py",
    "examples/perf/meeting_checkpoint_execution.py",
    "examples/perf/meeting_development_fixture.py",
    "examples/perf/probe_meeting_candidate.py",
    "src/speechrail/runtime/cleanup.py",
)


class _SelectionControls:
    def __init__(self, path: Path) -> None:
        self._documents: list[tuple[Path, Path, tuple[int, ...], str]] = []
        self._bytes = 0
        self.lock = _fields(
            self.read(path),
            {
                "schema_version",
                "required_max",
                "manifest",
                "scorer_policy",
                "strata",
            },
        )
        maximum = self.lock["required_max"]
        if (
            type(self.lock["schema_version"]) is not int
            or self.lock["schema_version"] != 1
            or type(maximum) is not int
            or not 1 <= maximum <= 8
        ):
            raise ValueError("selection control version or range invalid")
        self.maximum = maximum
        self.manifest = self.document(self.lock["manifest"])
        self.policy = self.document(self.lock["scorer_policy"])
        strata = _fields(self.lock["strata"], {str(n) for n in range(1, maximum + 1)})
        self.initial: dict[int, CommonPrefixSchedule] = {}
        self.checkpoints: dict[int, Mapping[str, Any]] = {}
        for count in range(1, maximum + 1):
            entry = _fields(strata[str(count)], {"initial_schedule", "checkpoint"})
            initial = _fields(
                self.document(entry["initial_schedule"]),
                {
                    "schema_version",
                    "speakers_count",
                    "manifest_sha256",
                    "scorer_policy_sha256",
                    "candidate_ids",
                    "source_groups",
                    "rounds",
                },
            )
            if (
                type(initial["schema_version"]) is not int
                or initial["schema_version"] != 1
                or type(initial["speakers_count"]) is not int
                or initial["speakers_count"] != count
                or initial["rounds"] != []
            ):
                raise ValueError("selection requires independent empty initial schedules")
            state = CommonPrefixSchedule(
                count,
                initial["candidate_ids"],
                initial["source_groups"],
                manifest_sha256=initial["manifest_sha256"],
                scorer_policy_sha256=initial["scorer_policy_sha256"],
            )
            if canonical_digest(state.as_dict()) != canonical_digest(initial):
                raise ValueError("selection initial schedule differs from schema")
            self.initial[count] = state
            self.checkpoints[count] = self.document(entry["checkpoint"])
        self._sources = {name: _ROOT / name for name in _SOURCES}
        self._source_stamps = {name: _stamp(path) for name, path in self._sources.items()}
        self.source_digests = {
            name: hashlib.sha256(path.read_bytes()).hexdigest()
            for name, path in self._sources.items()
        }
        self.verify()

    def read(self, path: Path) -> dict[str, Any]:
        path = _path(str(path))
        resolved, before = path.resolve(strict=True), _stamp(path)
        self._bytes += before[2]
        if self._bytes > _MAX_BYTES:
            raise ValueError("selection controls exceed total input budget")
        value = read_control_json(path)
        if _stamp(path) != before or path.resolve(strict=True) != resolved:
            raise ValueError("selection input changed during read")
        self._documents.append((path, resolved, before, canonical_digest(value)))
        return value

    def document(self, descriptor: object) -> dict[str, Any]:
        entry = _fields(descriptor, {"path", "sha256"})
        value = self.read(_path(entry["path"]))
        if canonical_digest(value) != entry["sha256"]:
            raise ValueError("selection document differs from frozen lock")
        return value

    def verify_stamps(self) -> None:
        for path, resolved, before, _ in self._documents:
            if path.is_symlink() or path.resolve(strict=True) != resolved or _stamp(path) != before:
                raise ValueError("selection inputs changed before commit")
        if any(
            _stamp(path) != self._source_stamps[name] or path.is_symlink()
            for name, path in self._sources.items()
        ):
            raise ValueError("selection sources changed before commit")

    def verify(self) -> None:
        self.verify_stamps()
        for path, _, _, digest in self._documents:
            if canonical_digest(read_control_json(path)) != digest:
                raise ValueError("selection input bytes changed")
        for name, path in self._sources.items():
            if hashlib.sha256(path.read_bytes()).hexdigest() != self.source_digests[name]:
                raise ValueError("selection implementation bytes changed")
        self.verify_stamps()


async def execute_development_selection(
    *,
    selection_lock: Path,
    output_directory: Path,
) -> dict[str, Any]:
    """Join input reads/scoring/writes, then commit without an await window.

    Each invocation needs a fresh external output directory. Failed/cancelled
    work may retain a partial diagnostic, never selection.json. No native worker
    or model files are required, opened or constructed by this offline entry.
    """
    output: Path | None = None
    try:
        controls = await join_cleanup(
            asyncio.create_task(asyncio.to_thread(_SelectionControls, selection_lock))
        )
        output = await join_cleanup(
            asyncio.create_task(asyncio.to_thread(_create_output, output_directory))
        )
        result = await join_cleanup(
            asyncio.create_task(
                asyncio.to_thread(
                    select_development_candidate,
                    initial_schedules=controls.initial,
                    checkpoints=controls.checkpoints,
                    manifest=controls.manifest,
                    policy=controls.policy,
                    required_max=controls.maximum,
                )
            )
        )
        if (
            result["selection_identity"]["implementation_sha256"]
            != (controls.source_digests["examples/perf/meeting_candidate_selection.py"])
        ):
            raise ValueError("loaded selector differs from frozen implementation")
        report = {
            **result,
            "input_files_verified": True,
            "selection_control_sha256": canonical_digest(controls.lock),
            "selection_executor_sha256": canonical_digest(controls.source_digests),
        }
        await join_cleanup(asyncio.create_task(asyncio.to_thread(controls.verify)))
        await join_cleanup(
            asyncio.create_task(
                asyncio.to_thread(_write_json, output / "selection.partial.json", report)
            )
        )
        await join_cleanup(asyncio.create_task(asyncio.to_thread(controls.verify)))
        controls.verify_stamps()
        # All asynchronous verification/writes have joined. No await before commit.
        os.link(output / "selection.partial.json", output / "selection.json", follow_symlinks=False)
        return report
    except BaseException as error:
        if output is not None:
            with contextlib.suppress(Exception):
                await join_cleanup(
                    asyncio.create_task(
                        asyncio.to_thread(
                            _write_json,
                            output / "failure.json",
                            {
                                "schema_version": 1,
                                "status": "cancelled"
                                if isinstance(error, asyncio.CancelledError)
                                else "failed",
                                "code": "development_selection_failed",
                            },
                        )
                    )
                )
        if isinstance(error, Exception):
            raise ValueError("locked development selection failed") from None
        raise
