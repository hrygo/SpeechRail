"""Operator-owned external roots for selected catalog model artifacts."""

from __future__ import annotations

import json
import re
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType
from typing import NoReturn

MODEL_LOCATIONS_FILENAME = "model_locations.json"
_SCHEMA_VERSION = 1
_KEY_RE = re.compile(r"^[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?$")
_MANAGED_SUBDIRS = ("models", "diarization")


class ModelLocationError(ValueError):
    """A declared model location is unusable."""


@dataclass(frozen=True, slots=True)
class ModelLocations:
    """Read-only map from artifact key to an external snapshot root."""

    bindings: Mapping[str, Path]

    def root_for(self, key: str) -> Path | None:
        """Return the declared external root for one artifact key."""
        return self.bindings.get(key)


def _reject(message: str) -> NoReturn:
    raise ModelLocationError(f"model location config invalid: {message}")


def _validate_root(app_home: Path, raw: object, key: str) -> Path:
    if not isinstance(raw, str) or not raw.strip():
        _reject(f"{key} must be a non-empty path string")
    if not Path(raw).is_absolute():
        _reject(f"{key} must be an absolute path: {raw}")
    root = Path(raw).expanduser()
    if root.is_symlink():
        _reject(f"{key} external root must not be a symlink: {root}")
    if ".staging" in root.parts:
        _reject(f"{key} external root must not be a staging directory: {root}")
    if not root.is_dir():
        _reject(f"{key} external root is missing: {root}")
    resolved_root = root.resolve()
    resolved_app_home = app_home.resolve()
    for name in _MANAGED_SUBDIRS:
        try:
            resolved_root.relative_to(resolved_app_home / name)
        except ValueError:
            continue
        _reject(f"{key} external root must not live inside app-home {name}/")
    return root


def load_model_locations(app_home: Path) -> ModelLocations:
    """Load ``config/model_locations.json``; an absent file means no bindings."""
    path = app_home / "config" / MODEL_LOCATIONS_FILENAME
    if not path.is_file():
        return ModelLocations(bindings=MappingProxyType({}))
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        _reject(f"{MODEL_LOCATIONS_FILENAME} is unreadable: {exc}")
    if not isinstance(payload, Mapping):
        _reject("payload must be an object")
    if payload.get("schema_version") != _SCHEMA_VERSION:
        _reject(f"unsupported schema_version {payload.get('schema_version')!r}")
    raw_bindings = payload.get("bindings", {})
    if not isinstance(raw_bindings, Mapping):
        _reject("bindings must be an object")
    resolved: dict[str, Path] = {}
    for key, raw in raw_bindings.items():
        if not isinstance(key, str) or not _KEY_RE.match(key) or ".." in key:
            _reject(f"invalid artifact key {key!r}")
        resolved[key] = _validate_root(app_home, raw, key)
    return ModelLocations(bindings=MappingProxyType(resolved))


def resolve_artifact_dir(app_home: Path, key: str, locations: ModelLocations | None) -> Path:
    """Return the directory holding one artifact: external binding or managed default."""
    if locations is not None:
        bound = locations.root_for(key)
        if bound is not None:
            return bound
    return app_home / "models" / key


__all__ = [
    "MODEL_LOCATIONS_FILENAME",
    "ModelLocationError",
    "ModelLocations",
    "load_model_locations",
    "resolve_artifact_dir",
]
