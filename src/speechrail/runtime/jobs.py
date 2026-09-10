"""Durable, owner-scoped job metadata for asynchronous speech work."""

from __future__ import annotations

import base64
import json
import sqlite3
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Literal
from uuid import uuid4

JobKind = Literal["speech", "transcription"]
JobState = Literal["queued", "running", "completed", "failed", "cancelled", "expired"]

_CURSOR_SEPARATOR = "\x1f"


@dataclass(frozen=True, slots=True)
class JobRecord:
    id: str
    kind: JobKind
    state: JobState
    owner: str
    request: dict[str, Any]
    error_code: str | None
    result_ref: str | None
    error_message: str | None = None
    attempts: int = 0


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

    @property
    def spool_dir(self) -> Path:
        """Return the external directory that owns this repository and its artifacts."""
        return self._spool_dir

    def create(self, *, kind: JobKind, owner: str, request: dict[str, Any]) -> JobRecord:
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
                SELECT id, kind, state, owner, request_json, error_code, result_ref,
                       error_message, attempts
                FROM jobs WHERE id = ? AND owner = ?
                """,
                (job_id, owner),
            ).fetchone()
        return _record(row)

    def queue_position(self, job_id: str, *, owner: str) -> int | None:
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT updated_at, id FROM jobs
                WHERE id = ? AND owner = ? AND state = 'queued'
                """,
                (job_id, owner),
            ).fetchone()
            if row is None:
                return None
            ahead = connection.execute(
                """
                SELECT COUNT(*) AS ahead FROM jobs
                WHERE owner = ? AND state = 'queued'
                  AND (updated_at < ? OR (updated_at = ? AND id < ?))
                """,
                (owner, row["updated_at"], row["updated_at"], row["id"]),
            ).fetchone()
        return int(ahead["ahead"]) + 1

    def timing(self, job_id: str, *, owner: str) -> str | None:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT updated_at FROM jobs WHERE id = ? AND owner = ?",
                (job_id, owner),
            ).fetchone()
        return str(row["updated_at"]) if row is not None else None

    def list_page(
        self, *, owner: str, limit: int, cursor: str | None
    ) -> tuple[list[JobRecord], str | None]:
        if limit < 1:
            raise ValueError("limit must be positive")
        columns = (
            "id, kind, state, owner, request_json, error_code, result_ref, "
            "error_message, attempts, updated_at"
        )
        if cursor is None:
            statement = f"""
                SELECT {columns} FROM jobs WHERE owner = ?
                ORDER BY updated_at DESC, id DESC LIMIT ?
            """
            parameters: tuple[object, ...] = (owner, limit + 1)
        else:
            updated_at, cursor_id = _decode_cursor(cursor)
            statement = f"""
                SELECT {columns} FROM jobs
                WHERE owner = ? AND (updated_at < ? OR (updated_at = ? AND id < ?))
                ORDER BY updated_at DESC, id DESC LIMIT ?
            """
            parameters = (owner, updated_at, updated_at, cursor_id, limit + 1)
        with self._connect() as connection:
            rows = connection.execute(statement, parameters).fetchall()
        has_more = len(rows) > limit
        page_rows = rows[:limit]
        next_cursor = None
        if has_more and page_rows:
            last = page_rows[-1]
            next_cursor = _encode_cursor(str(last["updated_at"]), str(last["id"]))
        records = [record for row in page_rows if (record := _record(row)) is not None]
        return records, next_cursor

    def claim_next(self, *, prefer_kind: JobKind | None = None) -> JobRecord | None:
        # ``prefer_kind`` only changes which queued row is selected; the
        # queued->running transition below stays the same atomic guard. When the
        # preferred kind has no queued work the sort falls back to the overall
        # oldest row, so a single-kind queue still drains in FIFO order.
        if prefer_kind is not None and prefer_kind not in {"speech", "transcription"}:
            raise ValueError("unsupported job kind")
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            if prefer_kind is None:
                row = connection.execute(
                    """
                    SELECT id, kind, state, owner, request_json, error_code, result_ref,
                           error_message, attempts
                    FROM jobs WHERE state = 'queued' ORDER BY updated_at, id LIMIT 1
                    """
                ).fetchone()
            else:
                row = connection.execute(
                    """
                    SELECT id, kind, state, owner, request_json, error_code, result_ref,
                           error_message, attempts
                    FROM jobs WHERE state = 'queued'
                    ORDER BY CASE WHEN kind = ? THEN 0 ELSE 1 END, updated_at, id
                    LIMIT 1
                    """,
                    (prefer_kind,),
                ).fetchone()
            if row is None:
                return None
            updated = connection.execute(
                """
                UPDATE jobs
                SET state = 'running', attempts = attempts + 1, updated_at = ?
                WHERE id = ? AND state = 'queued'
                """,
                (_now(), row["id"]),
            )
            if updated.rowcount != 1:
                return None
            return _record(
                {**dict(row), "state": "running", "attempts": int(row["attempts"]) + 1}
            )

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

    def fail(
        self, job_id: str, *, error_code: str, error_message: str | None = None
    ) -> JobRecord:
        if not error_code or len(error_code) > 200:
            raise ValueError("error_code must be between one and 200 characters")
        if error_message is not None and len(error_message) > 256:
            raise ValueError("error_message must not exceed 256 characters")
        with self._connect() as connection:
            updated = connection.execute(
                """
                UPDATE jobs
                SET state = 'failed', error_code = ?, error_message = ?, updated_at = ?
                WHERE id = ? AND state = 'running'
                """,
                (error_code, error_message, _now(), job_id),
            )
        if updated.rowcount != 1:
            raise ValueError("job is not running")
        record = self._get_any(job_id)
        if record is None:
            raise RuntimeError("failed job disappeared")
        return record

    def cancel(self, job_id: str, *, owner: str) -> JobRecord | None:
        with self._connect() as connection:
            connection.execute(
                """
                UPDATE jobs
                SET
                    state = CASE WHEN state = 'queued' THEN 'cancelled' ELSE state END,
                    result_ref = CASE WHEN state = 'completed' THEN NULL ELSE result_ref END,
                    updated_at = ?
                WHERE id = ? AND owner = ? AND state IN ('queued', 'completed')
                """,
                (_now(), job_id, owner),
            )
        return self.get(job_id, owner=owner)

    def recover_interrupted(self, *, max_attempts: int = 1) -> int:
        # Restart-only bounded retry. Under-budget running rows return to the
        # queue with their counted attempt intact; the remainder fail terminally.
        # The two updates are ordered so rows already requeued are not failed by
        # the second statement. JobRunner processor/timeout failures stay
        # terminal and never flow through here, avoiding deterministic loops.
        if max_attempts < 1:
            raise ValueError("max_attempts must be positive")
        with self._connect() as connection:
            requeued = connection.execute(
                """
                UPDATE jobs SET state = 'queued', updated_at = ?
                WHERE state = 'running' AND attempts < ?
                """,
                (_now(), max_attempts),
            )
            exhausted = connection.execute(
                """
                UPDATE jobs
                SET state = 'failed', error_code = 'worker_interrupted', updated_at = ?
                WHERE state = 'running'
                """,
                (_now(),),
            )
        return requeued.rowcount + exhausted.rowcount

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
                    error_message TEXT,
                    attempts INTEGER NOT NULL DEFAULT 0,
                    updated_at TEXT NOT NULL
                )
                """
            )
            columns = {
                str(row["name"])
                for row in connection.execute("PRAGMA table_info(jobs)").fetchall()
            }
            if "error_message" not in columns:
                connection.execute("ALTER TABLE jobs ADD COLUMN error_message TEXT")
            if "attempts" not in columns:
                connection.execute(
                    "ALTER TABLE jobs ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0"
                )

    def _connect(self) -> sqlite3.Connection:
        # busy_timeout makes concurrent claim_next BEGIN IMMEDIATE transactions
        # wait for the writer instead of failing outright with "database is locked".
        connection = sqlite3.connect(self._database, timeout=5.0)
        connection.row_factory = sqlite3.Row
        return connection

    def _get_any(self, job_id: str) -> JobRecord | None:
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT id, kind, state, owner, request_json, error_code, result_ref,
                       error_message, attempts
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
        error_message=(
            str(row["error_message"]) if row["error_message"] is not None else None
        ),
        attempts=int(str(row["attempts"])),
    )


def _encode_cursor(updated_at: str, job_id: str) -> str:
    raw = f"{updated_at}{_CURSOR_SEPARATOR}{job_id}".encode()
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _decode_cursor(cursor: str) -> tuple[str, str]:
    padded = cursor + "=" * (-len(cursor) % 4)
    try:
        raw = base64.b64decode(padded.encode("ascii"), altchars=b"-_", validate=True)
        decoded = raw.decode("utf-8")
    except ValueError as error:
        raise ValueError("invalid cursor") from error
    updated_at, separator, job_id = decoded.partition(_CURSOR_SEPARATOR)
    if not separator or not updated_at or not job_id:
        raise ValueError("invalid cursor")
    return updated_at, job_id


def _now() -> str:
    return datetime.now(UTC).isoformat()
