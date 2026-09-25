"""Durable, bounded output-validation evidence for custom voices.

Validation is an observation about a voice revision and a concrete runtime
binding.  It is deliberately stored separately from ``custom_voices.json`` so
that recording a probe result never creates a new acoustic voice revision.
The store contains only bounded metadata; it never persists reference audio,
prompts, transcripts, or local paths.
"""

from __future__ import annotations

import json
import os
import tempfile
import threading
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from speechrail.domain.file_locks import exclusive_file_lock


class VoiceValidationStoreUnavailableError(RuntimeError):
    """The validation evidence store cannot be read or safely updated."""


@dataclass(frozen=True, slots=True)
class VoiceValidationArtifact:
    """The artifact identity needed by the shared validation gate.

    The full catalog model is intentionally not required by the durable
    evidence layer.  Durable gates only compare the public artifact key and
    catalog revision, which also lets the async job processor use the same
    gate without importing the model catalog loader.
    """

    key: str
    revision: str


_MAX_STRING_LENGTH = 512
_ALLOWED_KEYS = frozenset(
    {
        "voice_id",
        "voice_revision",
        "status",
        "identity_status",
        "run_id",
        "tested_at",
        "policy_version",
        "model_artifact",
        "model_source",
        "model_variant",
        "model_catalog_revision",
        "model_runtime_revision",
        "runtime_fingerprint",
        "preprocess_version",
        "generation_recipe_revision",
        "capability_key",
        "probe_set",
        "repetitions",
        "failure_codes",
        "validated_for",
    }
)


def _atomic_write_json(path: Path, records: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(records, ensure_ascii=False, separators=(",", ":")))
            handle.flush()
            os.fsync(handle.fileno())
        tmp_path.chmod(0o600)
        tmp_path.replace(path)
        try:
            dir_fd = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
        except OSError:
            # The file replacement is still atomic when directory fsync is not
            # available on a particular filesystem.
            pass
    except Exception:
        tmp_path.unlink(missing_ok=True)
        raise


class VoiceValidationRepository:
    """Atomic JSON evidence store with deterministic bounded retention."""

    def __init__(self, path: Path, *, max_entries: int = 256) -> None:
        if max_entries < 1:
            raise ValueError("max_entries must be positive")
        self._path = Path(path)
        self._max_entries = max_entries
        self._lock = threading.RLock()

    @property
    def path(self) -> Path:
        """Return the private storage path for diagnostics and tests."""

        return self._path

    def _load_locked(self) -> list[dict[str, Any]]:
        if not self._path.exists():
            return []
        try:
            if self._path.is_symlink() or not self._path.is_file():
                raise ValueError("voice validation store is not a regular file")
            raw = json.loads(self._path.read_text(encoding="utf-8"))
            if not isinstance(raw, list):
                raise ValueError("voice validation store must be a JSON list")
            return [self._validate_record(item) for item in raw]
        except Exception as exc:
            raise VoiceValidationStoreUnavailableError(
                "voice validation store is unavailable"
            ) from exc

    @staticmethod
    def _validate_record(value: object) -> dict[str, Any]:
        if not isinstance(value, dict) or not set(value).issubset(_ALLOWED_KEYS):
            raise ValueError("invalid voice validation record")
        record = dict(value)
        for key in (
            "voice_id",
            "voice_revision",
            "status",
            "identity_status",
            "run_id",
            "tested_at",
            "policy_version",
            "model_artifact",
            "model_source",
            "model_variant",
            "model_catalog_revision",
            "model_runtime_revision",
            "runtime_fingerprint",
            "preprocess_version",
            "generation_recipe_revision",
            "capability_key",
            "probe_set",
        ):
            item = record.get(key)
            if item is not None and (
                not isinstance(item, str) or not item or len(item) > _MAX_STRING_LENGTH
            ):
                raise ValueError(f"invalid voice validation field: {key}")
        for key in ("repetitions",):
            item = record.get(key)
            if item is not None and (type(item) is not int or item < 1 or item > 32):
                raise ValueError(f"invalid voice validation field: {key}")
        for key in ("failure_codes", "validated_for"):
            item = record.get(key, [])
            if not isinstance(item, list) or len(item) > 64 or not all(
                isinstance(entry, str) and entry and len(entry) <= 128 for entry in item
            ):
                raise ValueError(f"invalid voice validation field: {key}")
            record[key] = list(item)
        voice_id = record.get("voice_id")
        voice_revision = record.get("voice_revision")
        if not isinstance(voice_id, str) or not voice_id:
            raise ValueError("voice validation voice_id is required")
        if not isinstance(voice_revision, str) or not voice_revision:
            raise ValueError("voice validation voice_revision is required")
        status = record.get("status")
        if status not in {"pass", "warn", "reject", "unevaluated"}:
            raise ValueError("invalid voice validation status")
        return record

    @staticmethod
    def _identity(record: Mapping[str, Any]) -> tuple[object, ...]:
        return (
            record.get("voice_id"),
            record.get("voice_revision"),
            record.get("model_artifact"),
            record.get("model_catalog_revision"),
            record.get("model_runtime_revision"),
            record.get("runtime_fingerprint"),
            record.get("preprocess_version"),
            record.get("generation_recipe_revision"),
            record.get("policy_version"),
            record.get("capability_key"),
        )

    def get(
        self,
        *,
        voice_id: str,
        voice_revision: str | None,
        model_artifact: str | None,
        model_catalog_revision: str | None,
        model_runtime_revision: str | None = None,
        runtime_fingerprint: str | None = None,
        preprocess_version: str | None = None,
        generation_recipe_revision: str | None = None,
        policy_version: str | None = None,
        capability_key: str | None = None,
        require_current_binding: bool = False,
    ) -> dict[str, Any] | None:
        """Return evidence matching the requested acoustic/runtime binding.

        The legacy form (without ``require_current_binding``) remains useful
        for diagnostics and migration.  Production gates must set
        ``require_current_binding=True`` and provide every binding dimension;
        an unknown runtime then returns no evidence instead of selecting the
        newest record from an unrelated worker generation.
        """

        if voice_revision is None:
            return None
        if require_current_binding and any(
            value is None
            for value in (
                model_runtime_revision,
                runtime_fingerprint,
                preprocess_version,
                generation_recipe_revision,
                policy_version,
            )
        ):
            return None
        with self._lock:
            try:
                with exclusive_file_lock(self._path):
                    records = self._load_locked()
            except VoiceValidationStoreUnavailableError:
                raise
            except Exception as exc:
                raise VoiceValidationStoreUnavailableError(
                    "voice validation store is unavailable"
                ) from exc
        matches = [
            item
            for item in records
            if item.get("voice_id") == voice_id
            and item.get("voice_revision") == voice_revision
            and item.get("model_artifact") == model_artifact
            and item.get("model_catalog_revision") == model_catalog_revision
            and (
                model_runtime_revision is None
                or item.get("model_runtime_revision") == model_runtime_revision
            )
            and (
                runtime_fingerprint is None
                or item.get("runtime_fingerprint") == runtime_fingerprint
            )
            and (
                preprocess_version is None
                or item.get("preprocess_version") == preprocess_version
            )
            and (
                generation_recipe_revision is None
                or item.get("generation_recipe_revision") == generation_recipe_revision
            )
            and (policy_version is None or item.get("policy_version") == policy_version)
            and (capability_key is None or item.get("capability_key") == capability_key)
        ]
        if not matches:
            return None
        return dict(matches[-1])

    def put(self, validation: Mapping[str, Any]) -> dict[str, Any]:
        """Atomically append or replace one bounded evidence record."""

        record = self._validate_record(dict(validation))
        with self._lock:
            try:
                with exclusive_file_lock(self._path):
                    records = self._load_locked()
                    identity = self._identity(record)
                    records = [item for item in records if self._identity(item) != identity]
                    records.append(record)
                    records = records[-self._max_entries :]
                    _atomic_write_json(self._path, records)
            except VoiceValidationStoreUnavailableError:
                raise
            except Exception as exc:
                raise VoiceValidationStoreUnavailableError(
                    "voice validation store is unavailable"
                ) from exc
        return dict(record)


__all__ = [
    "VoiceValidationArtifact",
    "VoiceValidationRepository",
    "VoiceValidationStoreUnavailableError",
]
