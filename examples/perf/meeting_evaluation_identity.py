"""Immutable evaluation identities and durable, single-use holdout claims.

Digests establish local reproducibility, not an external certification authority.
The caller must measure evidence before issuing a development receipt.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
from collections.abc import Mapping
from dataclasses import dataclass, fields
from pathlib import Path, PurePosixPath
from types import MappingProxyType
from typing import Any


def _freeze(value: object) -> object:
    if value is None or type(value) in (str, bool, int):
        return value
    if isinstance(value, float) and math.isfinite(value):
        return value
    if isinstance(value, Mapping) and all(isinstance(k, str) for k in value):
        return MappingProxyType({k: _freeze(v) for k, v in value.items()})
    if isinstance(value, (list, tuple)):
        return tuple(_freeze(v) for v in value)
    raise ValueError("candidate must contain finite JSON values and string keys")


def _thaw(value: object) -> Any:
    if isinstance(value, Mapping):
        return {k: _thaw(v) for k, v in value.items()}
    if isinstance(value, tuple):
        return [_thaw(v) for v in value]
    return value


def canonical_digest(value: Mapping[str, object]) -> str:
    canonical = json.dumps(
        _thaw(_freeze(value)),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def _require_digest(value: object, name: str) -> None:
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise ValueError(f"{name} must be a SHA-256 hex digest")


@dataclass(frozen=True, slots=True)
class MeetingCandidateSpec:
    implementation_id: str
    adapter_sha256: str
    sdk_revision: str
    worker_sha256: str
    model_revision: str
    model_files_sha256: Mapping[str, str]
    dtype: str
    preset: Mapping[str, object]
    compute_units: str
    decoder: Mapping[str, object]
    attribution: Mapping[str, object]
    scorer: Mapping[str, object]

    def __post_init__(self) -> None:
        for name in (
            "implementation_id",
            "sdk_revision",
            "model_revision",
            "dtype",
            "compute_units",
        ):
            if not isinstance(getattr(self, name), str) or not getattr(self, name).strip():
                raise ValueError(f"{name} must be a nonempty string")
        for name in ("adapter_sha256", "worker_sha256"):
            _require_digest(getattr(self, name), name)
        for name in ("model_files_sha256", "preset", "decoder", "attribution", "scorer"):
            value = getattr(self, name)
            if not isinstance(value, Mapping) or not value:
                raise ValueError(f"{name} must be a nonempty JSON mapping")
            object.__setattr__(self, name, _freeze(value))
        for name, digest in self.model_files_sha256.items():
            if PurePosixPath(name).is_absolute() or ".." in PurePosixPath(name).parts:
                raise ValueError("model files must have relative bundle paths")
            _require_digest(digest, "model_files_sha256")

    def as_dict(self) -> dict[str, Any]:
        return {field.name: _thaw(getattr(self, field.name)) for field in fields(self)}


def candidate_digest(spec: MeetingCandidateSpec) -> str:
    return canonical_digest(spec.as_dict())


def validate_execution_identity(
    spec: MeetingCandidateSpec,
    observed: Mapping[str, object],
) -> None:
    expected = spec.as_dict()
    if set(observed) != set(expected):
        missing = sorted(set(expected) - set(observed))
        extra = sorted(set(observed) - set(expected))
        raise ValueError(f"execution identity fields differ: missing={missing}, extra={extra}")
    for name, value in expected.items():
        # JSON bytes distinguish e.g. True from 1, which Python equality does not.
        if canonical_digest({name: value}) != canonical_digest({name: observed[name]}):
            raise ValueError(f"execution identity mismatch: {name}")


@dataclass(frozen=True, slots=True)
class EvaluationLocks:
    development_manifest_sha256: str
    holdout_manifest_sha256: str
    scorer_policy_sha256: str
    runtime_policy_sha256: str

    def __post_init__(self) -> None:
        for field in fields(self):
            _require_digest(getattr(self, field.name), field.name)
        if self.development_manifest_sha256 == self.holdout_manifest_sha256:
            raise ValueError("development and holdout manifests must be distinct")

    def as_dict(self) -> dict[str, str]:
        return {field.name: getattr(self, field.name) for field in fields(self)}


def development_receipt(
    spec: MeetingCandidateSpec,
    locks: EvaluationLocks,
    *,
    all_required_strata_observed: bool,
    quality_passed: bool,
) -> dict[str, object]:
    if type(all_required_strata_observed) is not bool or type(quality_passed) is not bool:
        raise ValueError("evidence flags must be explicit booleans")
    return {
        "schema_version": 2,
        "split_role": "development",
        "candidate_sha256": candidate_digest(spec),
        **locks.as_dict(),
        "all_required_strata_observed": all_required_strata_observed,
        "quality_passed": quality_passed,
        "verdict": "go" if all_required_strata_observed and quality_passed else "no-go",
    }


def validate_development_receipt(
    receipt: Mapping[str, object],
    spec: MeetingCandidateSpec,
    locks: EvaluationLocks,
) -> None:
    if type(receipt.get("schema_version")) is not int or receipt["schema_version"] != 2:
        raise ValueError("schema_version=2 is required; legacy receipts cannot unlock holdout")
    if receipt.get("candidate_sha256") != candidate_digest(spec):
        raise ValueError("development receipt candidate differs from execution candidate")
    for name, digest in locks.as_dict().items():
        if receipt.get(name) != digest:
            raise ValueError(f"development receipt {name} differs from frozen lock")
    if (
        receipt.get("split_role") != "development"
        or receipt.get("all_required_strata_observed") is not True
        or receipt.get("quality_passed") is not True
        or receipt.get("verdict") != "go"
    ):
        raise ValueError("development evidence did not pass all required gates")


def claim_holdout_attempt(
    receipt: Mapping[str, object],
    spec: MeetingCandidateSpec,
    locks: EvaluationLocks,
    *,
    observed: Mapping[str, object],
    attempts_directory: Path,
) -> Path:
    """Consume a holdout before inference, even if the process later fails.

    Key by holdout manifest, not candidate: changing parameters must never grant
    a fresh attempt on the same holdout. No implicit retry or unlink is provided.
    """
    validate_development_receipt(receipt, spec, locks)
    validate_execution_identity(spec, observed)
    directory = attempts_directory.expanduser().resolve()
    if directory.is_relative_to(Path(__file__).resolve().parents[2]):
        raise ValueError("holdout attempts must remain outside the repository")
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{locks.holdout_manifest_sha256}.attempt.json"
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError as exc:
        raise ValueError("holdout attempt already consumed") from exc
    # A failed write leaves an occupied claim; fail closed rather than retrying.
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(
            {
                "schema_version": 2,
                "status": "claimed",
                "candidate_sha256": candidate_digest(spec),
                **locks.as_dict(),
            },
            handle,
            sort_keys=True,
            allow_nan=False,
        )
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    directory_fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
    return path


def file_digest(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def model_file_digests(directory: Path) -> dict[str, str]:
    root = directory.resolve(strict=True)
    result = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError("model bundles must not contain symlinks")
        if path.is_file():
            result[path.relative_to(root).as_posix()] = file_digest(path)
    if not result:
        raise ValueError("model bundle contains no files")
    return result
