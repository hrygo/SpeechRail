"""Offline comparison of independently frozen development ASR results.

JSON identities are consistency evidence, never a trusted A0 or receipt.
No model, reference text, audio, service discovery or holdout is opened.
"""

from __future__ import annotations

import asyncio
import contextlib
import hashlib
import os
import re
import stat
from pathlib import Path
from typing import Any

from meeting_candidate_execution import read_control_json
from meeting_checkpoint_execution import _fields, _path, _stamp
from meeting_development_fixture import _create_output, _write_json
from meeting_evaluation_identity import canonical_digest
from meeting_quality_metrics import _validate_policy
from probe_meeting_asr_quality import ASR_SCORER, compare_asr_runs

from speechrail.runtime.cleanup import join_cleanup

_ROOT = Path(__file__).resolve().parents[2]
_MAX_BYTES = 32 * 1024 * 1024
_IDENTITY = {
    "source_group_sha256",
    "case_sha256",
    "pcm_sha256",
    "reference_sha256",
    "manifest_sha256",
    "scorer_sha256",
}
_SOURCES = (
    "examples/perf/meeting_asr_comparison.py",
    "examples/perf/probe_meeting_asr_development.py",
    "examples/perf/probe_meeting_asr_quality.py",
    "examples/perf/meeting_quality_metrics.py",
    "examples/perf/meeting_latency_policy.py",
    "examples/perf/meeting_evaluation_identity.py",
    "examples/perf/meeting_candidate_execution.py",
    "examples/perf/meeting_checkpoint_execution.py",
    "examples/perf/meeting_development_fixture.py",
    "src/speechrail/runtime/cleanup.py",
)


def _sha(value: object) -> str:
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise ValueError("comparison identity requires SHA-256")
    return value


def _regular(path: Path) -> None:
    if not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError("comparison requires regular files")


def _source_digest(path: Path) -> str:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as handle:
        if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
            raise ValueError("comparison implementation must be regular")
        contents = handle.read(16 * 1024 * 1024 + 1)
        if len(contents) > 16 * 1024 * 1024:
            raise ValueError("comparison source exceeds budget")
    return hashlib.sha256(contents).hexdigest()


class _Controls:
    def __init__(self, path: Path) -> None:
        self.files: list[tuple[Path, Path, tuple[int, ...], str]] = []
        self.bytes = 0
        self.lock = _fields(
            self.read(path),
            {
                "schema_version",
                "cases",
                "scorer_policy",
                "baseline",
                "candidate",
                "key_facts_review",
            },
        )
        if type(self.lock["schema_version"]) is not int or self.lock["schema_version"] != 1:
            raise ValueError("comparison control version invalid")
        if self.lock["key_facts_review"] not in {"not_observed", "pass", "fail"}:
            raise ValueError("comparison manual review invalid")
        self.policy = self.document(self.lock["scorer_policy"])
        _validate_policy(self.policy)
        cases = self.lock["cases"]
        if not isinstance(cases, list) or not 1 <= len(cases) <= 1024:
            raise ValueError("comparison requires bounded preregistered cases")
        self.cases: dict[str, dict[str, Any]] = {}
        for value in cases:
            entry = _fields(value, _IDENTITY | {"expected_samples"})
            identity = {key: _sha(entry[key]) for key in _IDENTITY}
            case = identity.pop("case_sha256")
            if (
                case in self.cases
                or case != canonical_digest(identity)
                or identity["scorer_sha256"] != canonical_digest(ASR_SCORER)
                or type(entry["expected_samples"]) is not int
                or not 0 < entry["expected_samples"] <= 600 * 16000
            ):
                raise ValueError("comparison case identity or samples invalid")
            self.cases[case] = entry
        self.baseline = self.arm(self.lock["baseline"])
        self.candidate = self.arm(self.lock["candidate"])
        self.sources = {
            _ROOT / name: (_stamp(_ROOT / name), _source_digest(_ROOT / name)) for name in _SOURCES
        }
        if (
            self.sources[_ROOT / "examples/perf/probe_meeting_asr_quality.py"][1]
            != (ASR_SCORER["implementation_sha256"])
        ):
            raise ValueError("loaded ASR scorer differs from source")
        self.verify()

    def read(self, path: Path) -> dict[str, Any]:
        path = _path(str(path))
        _regular(path)
        resolved, before = path.resolve(strict=True), _stamp(path)
        self.bytes += before[2]
        if self.bytes > _MAX_BYTES:
            raise ValueError("comparison inputs exceed total budget")
        value = read_control_json(path)
        if path.resolve(strict=True) != resolved or _stamp(path) != before:
            raise ValueError("comparison input changed while reading")
        self.files.append((path, resolved, before, canonical_digest(value)))
        return value

    def document(self, value: object) -> dict[str, Any]:
        descriptor = _fields(value, {"path", "sha256"})
        result = self.read(_path(descriptor["path"]))
        if canonical_digest(result) != _sha(descriptor["sha256"]):
            raise ValueError("comparison document differs from frozen digest")
        return result

    def arm(self, value: object) -> list[dict[str, Any]]:
        arm = _fields(value, {"candidate_sha256", "replay_policy_sha256", "mode", "reports"})
        candidate, replay = _sha(arm["candidate_sha256"]), _sha(arm["replay_policy_sha256"])
        if arm["mode"] not in {
            "production_window",
            "bounded_long_block_diagnostic",
            "formal_realtime_session_diagnostic",
        }:
            raise ValueError("comparison mode invalid")
        descriptors = arm["reports"]
        if not isinstance(descriptors, list) or len(descriptors) != len(self.cases):
            raise ValueError("comparison arm does not cover preregistered cases")
        reports, seen = [], set()
        for descriptor in descriptors:
            row = self.document(descriptor)
            case = row.get("case_sha256")
            if not isinstance(case, str) or case in seen or case not in self.cases:
                raise ValueError("comparison report case missing or duplicated")
            expected = self.cases[case]
            if (
                any(row.get(key) != expected[key] for key in _IDENTITY)
                or type(row.get("coverage_samples")) is not int
                or type(row.get("expected_samples")) is not int
                or row["expected_samples"] != expected["expected_samples"]
                or row.get("candidate_sha256") != candidate
                or row.get("replay_policy_sha256") != replay
                or row.get("mode") != arm["mode"]
                or row.get("split_role") != "development"
                or row.get("runtime_identity_verified") is not False
                or row.get("certification_eligible") is not False
            ):
                raise ValueError("comparison report differs from diagnostic registration")
            seen.add(case)
            reports.append(row)
        return reports

    def verify_stamps(self) -> None:
        for path, resolved, before, _ in self.files:
            _regular(path)
            if path.resolve(strict=True) != resolved or _stamp(path) != before:
                raise ValueError("comparison input changed before commit")
        for path, (before, _) in self.sources.items():
            _regular(path)
            if _stamp(path) != before:
                raise ValueError("comparison implementation changed before commit")

    def verify(self) -> None:
        self.verify_stamps()
        for path, _, _, digest in self.files:
            if canonical_digest(read_control_json(path)) != digest:
                raise ValueError("comparison input content changed")
        for path, (_, digest) in self.sources.items():
            if _source_digest(path) != digest:
                raise ValueError("comparison implementation content changed")
        self.verify_stamps()


async def execute_asr_comparison(
    *, comparison_lock: Path, output_directory: Path
) -> dict[str, Any]:
    """Join offline work; commit only after input, source and partial guards."""
    output: Path | None = None
    output_identity: tuple[int, int, int, int] | None = None

    def verify_output() -> None:
        assert output is not None
        value = output.lstat()
        if (
            not stat.S_ISDIR(value.st_mode)
            or output.resolve(strict=True) != output
            or (value.st_dev, value.st_ino, value.st_mode, value.st_uid) != output_identity
        ):
            raise ValueError("comparison output directory changed")

    async def joined(callback: Any, *args: Any) -> Any:
        return await join_cleanup(asyncio.create_task(asyncio.to_thread(callback, *args)))

    try:
        controls = await joined(_Controls, comparison_lock)
        output = await joined(_create_output, _path(str(output_directory)))
        value = output.lstat()
        output_identity = value.st_dev, value.st_ino, value.st_mode, value.st_uid
        result = await join_cleanup(
            asyncio.create_task(
                asyncio.to_thread(
                    compare_asr_runs,
                    controls.baseline,
                    controls.candidate,
                    policy=controls.policy,
                    key_facts_review=controls.lock["key_facts_review"],
                )
            )
        )
        report = {
            **result,
            "verdict": "diagnostic",
            "runtime_identity_verified": False,
            "certification_eligible": False,
            "quality_gate": "fail",
            "input_files_verified": True,
            "comparison_control_sha256": canonical_digest(controls.lock),
            "comparison_executor_sha256": canonical_digest(
                {
                    str(path.relative_to(_ROOT)): digest
                    for path, (_, digest) in controls.sources.items()
                }
            ),
            "case_count": len(controls.cases),
        }
        await joined(controls.verify)
        verify_output()
        partial = output / "comparison.partial.json"
        await joined(_write_json, partial, report)
        _regular(partial)
        partial_stamp = _stamp(partial)
        if canonical_digest(await joined(read_control_json, partial)) != canonical_digest(report):
            raise ValueError("comparison partial differs from result")
        await joined(controls.verify)
        controls.verify_stamps()
        verify_output()
        _regular(partial)
        if _stamp(partial) != partial_stamp:
            raise ValueError("comparison partial changed before commit")
        # All asynchronous work joined; no await before the exclusive commit.
        os.link(partial, output / "comparison.json", follow_symlinks=False)
        return report
    except BaseException as error:
        if output is not None and output_identity is not None:
            with contextlib.suppress(Exception):
                verify_output()
                await joined(
                    _write_json,
                    output / "failure.json",
                    {
                        "schema_version": 1,
                        "status": "cancelled"
                        if isinstance(error, asyncio.CancelledError)
                        else "failed",
                        "code": "asr_comparison_failed",
                    },
                )
        if isinstance(error, Exception):
            raise ValueError("locked ASR comparison failed") from None
        raise
