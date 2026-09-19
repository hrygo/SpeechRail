"""Small durable idempotency journal for local create operations."""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Literal


class IdempotencyConflictError(RuntimeError):
    """The same owner/operation/key was reused with a different payload."""


class IdempotencyStoreUnavailableError(RuntimeError):
    """The durable journal cannot be trusted or persisted."""


@dataclass(frozen=True, slots=True)
class IdempotencyDecision:
    state: Literal["new", "pending", "completed"]
    result_id: str | None = None


class DurableIdempotencyJournal:
    """Bounded JSON journal with atomic writes and crash-visible pending records."""

    def __init__(self, path: Path, *, max_entries: int = 128) -> None:
        if max_entries < 1:
            raise ValueError("max_entries must be positive")
        self._path = Path(path)
        self._max_entries = max_entries
        self._lock = threading.RLock()

    @staticmethod
    def key_hash(key: str) -> str:
        if not key:
            raise ValueError("idempotency key must not be empty")
        return hashlib.sha256(key.encode("utf-8")).hexdigest()

    def _load_locked(self) -> list[dict[str, object]]:
        if not self._path.exists():
            return []
        try:
            if self._path.is_symlink() or not self._path.is_file():
                raise ValueError("unsafe idempotency journal")
            raw = json.loads(self._path.read_text(encoding="utf-8"))
            if not isinstance(raw, list):
                raise ValueError("invalid idempotency journal")
            records: list[dict[str, object]] = []
            for item in raw:
                if not isinstance(item, dict):
                    raise ValueError("invalid idempotency record")
                required = {
                    "owner",
                    "operation",
                    "key_hash",
                    "fingerprint",
                    "state",
                    "created_at",
                }
                if not required.issubset(item):
                    raise ValueError("incomplete idempotency record")
                if item["state"] not in {"pending", "completed"}:
                    raise ValueError("invalid idempotency state")
                records.append(item)
            return records
        except Exception as exc:
            raise IdempotencyStoreUnavailableError(
                "idempotency journal is unavailable"
            ) from exc

    def _bounded_locked(
        self, records: list[dict[str, object]]
    ) -> list[dict[str, object]]:
        if len(records) <= self._max_entries:
            return records

        overflow = len(records) - self._max_entries
        kept: list[dict[str, object]] = []
        for record in records:
            if overflow and record["state"] == "completed":
                overflow -= 1
                continue
            kept.append(record)

        if overflow:
            raise IdempotencyStoreUnavailableError(
                "idempotency journal is full of unresolved operations"
            )
        return kept

    def _save_locked(self, records: list[dict[str, object]]) -> None:
        try:
            if self._path.parent.is_symlink():
                raise OSError("unsafe idempotency journal parent")
            self._path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            bounded = self._bounded_locked(records)
            payload = json.dumps(
                bounded,
                ensure_ascii=False,
                indent=2,
            ).encode()
            fd, tmp_name = tempfile.mkstemp(
                prefix=f".{self._path.name}.",
                suffix=".tmp",
                dir=self._path.parent,
            )
            tmp = Path(tmp_name)
            try:
                with os.fdopen(fd, "wb") as handle:
                    handle.write(payload)
                    handle.flush()
                    os.fsync(handle.fileno())
                tmp.chmod(0o600)
                tmp.replace(self._path)
                dir_fd = os.open(self._path.parent, os.O_RDONLY)
                try:
                    os.fsync(dir_fd)
                finally:
                    os.close(dir_fd)
            finally:
                if tmp.exists():
                    tmp.unlink(missing_ok=True)
        except IdempotencyStoreUnavailableError:
            raise
        except Exception as exc:
            raise IdempotencyStoreUnavailableError(
                "idempotency journal cannot be persisted"
            ) from exc

    def begin(
        self,
        *,
        owner: str,
        operation: str,
        key: str,
        fingerprint: str,
        provisional_result_id: str | None = None,
    ) -> IdempotencyDecision:
        """Persist pending before side effects, or replay an existing decision."""

        key_hash = self.key_hash(key)
        with self._lock:
            records = self._load_locked()
            for record in reversed(records):
                if (
                    record["owner"] == owner
                    and record["operation"] == operation
                    and record["key_hash"] == key_hash
                ):
                    if record["fingerprint"] != fingerprint:
                        raise IdempotencyConflictError(
                            "idempotency key payload conflict"
                        )
                    result = record.get("result_id")
                    result_id = result if isinstance(result, str) else None
                    if record["state"] == "completed":
                        return IdempotencyDecision("completed", result_id)
                    return IdempotencyDecision("pending", result_id)

            record: dict[str, object] = {
                "owner": owner,
                "operation": operation,
                "key_hash": key_hash,
                "fingerprint": fingerprint,
                "state": "pending",
                "created_at": time.time(),
            }
            if provisional_result_id is not None:
                record["result_id"] = provisional_result_id
            records.append(record)
            self._save_locked(records)
            return IdempotencyDecision("new", provisional_result_id)

    def lookup(
        self,
        *,
        owner: str,
        operation: str,
        key: str,
    ) -> IdempotencyDecision | None:
        """Return durable state to a caller that proves possession of the key."""

        key_hash = self.key_hash(key)
        with self._lock:
            records = self._load_locked()
            for record in reversed(records):
                if (
                    record["owner"] == owner
                    and record["operation"] == operation
                    and record["key_hash"] == key_hash
                ):
                    result = record.get("result_id")
                    result_id = result if isinstance(result, str) else None
                    if record["state"] == "completed":
                        return IdempotencyDecision("completed", result_id)
                    return IdempotencyDecision("pending", result_id)
        return None

    def complete(
        self,
        *,
        owner: str,
        operation: str,
        key: str,
        fingerprint: str,
        result_id: str,
    ) -> str:
        """Atomically commit a pending record; a concurrent winner is preserved."""

        key_hash = self.key_hash(key)
        with self._lock:
            records = self._load_locked()
            for record in reversed(records):
                if (
                    record["owner"] == owner
                    and record["operation"] == operation
                    and record["key_hash"] == key_hash
                ):
                    if record["fingerprint"] != fingerprint:
                        raise IdempotencyConflictError(
                            "idempotency key payload conflict"
                        )
                    if record["state"] == "completed":
                        existing = record.get("result_id")
                        if isinstance(existing, str):
                            return existing
                        raise IdempotencyStoreUnavailableError(
                            "completed idempotency record has no result"
                        )
                    record["state"] = "completed"
                    record["result_id"] = result_id
                    record["completed_at"] = time.time()
                    self._save_locked(records)
                    return result_id
            raise IdempotencyStoreUnavailableError(
                "pending idempotency record is missing"
            )

    def abort(
        self,
        *,
        owner: str,
        operation: str,
        key: str,
        fingerprint: str,
    ) -> None:
        """Remove only a matching pending record when no side effect occurred."""

        key_hash = self.key_hash(key)
        with self._lock:
            records = self._load_locked()
            kept: list[dict[str, object]] = []
            removed = False
            for record in records:
                if (
                    not removed
                    and record["owner"] == owner
                    and record["operation"] == operation
                    and record["key_hash"] == key_hash
                    and record["fingerprint"] == fingerprint
                    and record["state"] == "pending"
                ):
                    removed = True
                    continue
                kept.append(record)
            if removed:
                self._save_locked(kept)
