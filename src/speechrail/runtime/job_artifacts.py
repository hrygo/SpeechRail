"""Ownership rules for durable-job result artifacts under the external spool."""

from __future__ import annotations

import shutil
from pathlib import Path

RESULTS_SUBDIR = "results"

_CONTENT_TYPES: dict[str, str] = {
    ".json": "application/json",
    ".pcm": "audio/x-pcm",
    ".wav": "audio/wav",
    ".mp3": "audio/mpeg",
}


def resolve_result_artifact(
    *, spool_dir: Path, job_id: str, result_ref: str
) -> tuple[Path, str] | None:
    """Resolve a completed job's relative ref to a streamable artifact.

    Returns ``(path, media_type)`` only when ``result_ref`` is a relative path
    that stays inside ``<spool_dir>/results/<job_id>/`` and points at a regular
    file. Anything else (opaque non-file refs, absolute paths, traversal, a ref
    bound to another job) returns ``None`` so the caller keeps the JSON shape.
    """

    try:
        candidate = _validated_artifact_path(
            spool_dir=spool_dir, job_id=job_id, result_ref=result_ref
        )
    except OSError:
        return None
    if candidate is None or not candidate.is_file():
        return None
    media_type = _CONTENT_TYPES.get(candidate.suffix.lower(), "application/octet-stream")
    return candidate, media_type


def delete_job_result_artifact(
    *, spool_dir: Path, job_id: str, result_ref: str
) -> bool:
    """Delete one job's spooled artifact tree before releasing its reference.

    The caller keeps the durable reference until this succeeds, so a failed or
    interrupted cleanup is retried instead of orphaning the artifact.
    Returns ``True`` when the reference addresses the job's local artifact tree
    and ``False`` for an opaque non-file reference.
    """

    candidate = _validated_artifact_path(
        spool_dir=spool_dir, job_id=job_id, result_ref=result_ref
    )
    if candidate is None:
        return False
    job_root = candidate.parent
    if job_root.is_symlink():
        raise OSError("refusing to delete a symlinked job artifact directory")
    if job_root.exists():
        shutil.rmtree(job_root)
    return True


def _validated_artifact_path(
    *, spool_dir: Path, job_id: str, result_ref: str
) -> Path | None:
    if not result_ref or "/" in job_id or "\\" in job_id or job_id in {"", ".", ".."}:
        return None
    reference = Path(result_ref)
    if reference.is_absolute() or ".." in reference.parts:
        return None
    raw_results_root = spool_dir / RESULTS_SUBDIR
    if raw_results_root.is_symlink():
        raise OSError("refusing to resolve a symlinked results directory")
    try:
        results_root = raw_results_root.resolve()
        job_root = results_root / job_id
        candidate = (spool_dir / reference).resolve()
    except RuntimeError as exc:
        raise OSError("unsafe job artifact path") from exc
    if candidate.parent != job_root:
        return None
    return candidate


__all__ = [
    "RESULTS_SUBDIR",
    "delete_job_result_artifact",
    "resolve_result_artifact",
]
