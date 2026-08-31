"""Durable, owner-scoped job metadata for asynchronous speech work."""

from __future__ import annotations

import json
import sqlite3
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Literal
from uuid import uuid4

JobKind = Literal["speech", "transcription"]
JobState = Literal["queued", "running", "completed", "failed", "cancelled", "expired"]


@dataclass(frozen=True, slots=True)
class JobRecord:
    id: str
    kind: JobKind
    state: JobState
    owner: str
    request: dict[str, str]
    error_code: str | None
    result_ref: str | None


class JobRepository:
    """SQLite WAL repository that never stores credentials or raw audio."""

    def __init__(self, spool_dir: Path) -> None:
        if not spool_dir.is_absolute():
            raise ValueError("job spool directory must be absolute")
        self._spool_dir = spool_dir
        spool_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        spool_dir.chmod(0o700)
        self._database = spool_dir / "jobs.sqlite3"
        self._initialize()
        self._database.chmod(0o600)

    def create(self, *, kind: JobKind, owner: str, request: dict[str, str]) -> JobRecord:
        if kind not in {"speech", "transcription"}:
            raise ValueError("unsupported job kind")
        if not owner:
            raise ValueError("owner must not be empty")
        job_id = f"job_{uuid4().hex}"
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO jobs (id, kind, state, owner, request_json, error_code, updated_at)
                VALUES (?, ?, 'queued', ?, ?, NULL, ?)
                """,
                (job_id, kind, owner, json.dumps(request, separators=(",", ":")), _now()),
            )
        return JobRecord(job_id, kind, "queued", owner, dict(request), None, None)

    def get(self, job_id: str, *, owner: str) -> JobRecord | None:
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT id, kind, state, owner, request_json, error_code, result_ref
                FROM jobs WHERE id = ? AND owner = ?
                """,
                (job_id, owner),
            ).fetchone()
        return _record(row)

    def claim_next(self) -> JobRecord | None:
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                """
                SELECT id, kind, state, owner, request_json, error_code, result_ref
                FROM jobs WHERE state = 'queued' ORDER BY updated_at, id LIMIT 1
                """
            ).fetchone()
            if row is None:
                return None
            updated = connection.execute(
                """
                UPDATE jobs SET state = 'running', updated_at = ?
                WHERE id = ? AND state = 'queued'
                """,
                (_now(), row["id"]),
            )
            if updated.rowcount != 1:
                return None
            return _record({**dict(row), "state": "running"})

    def complete(self, job_id: str, *, result_ref: str) -> JobRecord:
        if not result_ref:
            raise ValueError("result_ref must not be empty")
        with self._connect() as connection:
            updated = connection.execute(
                """
                UPDATE jobs
                SET state = 'completed', result_ref = ?, completed_at = ?, updated_at = ?
                WHERE id = ? AND state = 'running'
                """,
                (result_ref, _now(), _now(), job_id),
            )
        if updated.rowcount != 1:
            raise ValueError("job is not running")
        record = self._get_any(job_id)
        if record is None:
            raise RuntimeError("completed job disappeared")
        return record

    def cancel(self, job_id: str, *, owner: str) -> JobRecord | None:
        with self._connect() as connection:
            connection.execute(
                """
                UPDATE jobs SET state = 'cancelled', updated_at = ?
                WHERE id = ? AND owner = ? AND state = 'queued'
                """,
                (_now(), job_id, owner),
            )
        return self.get(job_id, owner=owner)

    def recover_interrupted(self) -> int:
        with self._connect() as connection:
            updated = connection.execute(
                """
                UPDATE jobs SET state = 'failed', error_code = 'worker_interrupted', updated_at = ?
                WHERE state = 'running'
                """,
                (_now(),),
            )
        return updated.rowcount

    def delete_result(self, job_id: str, *, owner: str) -> JobRecord | None:
        with self._connect() as connection:
            connection.execute(
                "UPDATE jobs SET result_ref = NULL, updated_at = ? WHERE id = ? AND owner = ?",
                (_now(), job_id, owner),
            )
        return self.get(job_id, owner=owner)

    def expire_completed(self, *, before: str) -> int:
        with self._connect() as connection:
            updated = connection.execute(
                """
                UPDATE jobs SET state = 'expired', result_ref = NULL, updated_at = ?
                WHERE state = 'completed' AND completed_at IS NOT NULL AND completed_at < ?
                """,
                (_now(), before),
            )
        return updated.rowcount

    def _initialize(self) -> None:
        with self._connect() as connection:
            connection.execute("PRAGMA journal_mode = WAL")
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS jobs (
                    id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    state TEXT NOT NULL,
                    owner TEXT NOT NULL,
                    request_json TEXT NOT NULL,
                    error_code TEXT,
                    result_ref TEXT,
                    completed_at TEXT,
                    updated_at TEXT NOT NULL
                )
                """
            )

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self._database)
        connection.row_factory = sqlite3.Row
        return connection

    def _get_any(self, job_id: str) -> JobRecord | None:
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT id, kind, state, owner, request_json, error_code, result_ref
                FROM jobs WHERE id = ?
                """,
                (job_id,),
            ).fetchone()
        return _record(row)


def _record(row: sqlite3.Row | dict[str, object] | None) -> JobRecord | None:
    if row is None:
        return None
    return JobRecord(
        id=str(row["id"]),
        kind=str(row["kind"]),  # type: ignore[arg-type]
        state=str(row["state"]),  # type: ignore[arg-type]
        owner=str(row["owner"]),
        request=json.loads(str(row["request_json"])),
        error_code=str(row["error_code"]) if row["error_code"] is not None else None,
        result_ref=str(row["result_ref"]) if row["result_ref"] is not None else None,
    )


def _now() -> str:
    return datetime.now(UTC).isoformat()
