"""Prepare one reproducible, lock-pinned vendor runtime for all model presets."""

from __future__ import annotations

import asyncio
import hashlib
import json
import os
import re
import subprocess
import tempfile
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path, PurePosixPath, PureWindowsPath
from typing import Final, cast
from uuid import uuid4

from speechrail.config.model_catalog import RuntimeLock

_SCHEMA_VERSION: Final = 1
_VENDOR_DIRNAME: Final = "vendor"
_STAGING_DIRNAME: Final = ".staging"
_CURRENT_NAME: Final = "current"
_RUNTIME_METADATA_NAME: Final = "runtime.json"
_RUNTIME_REGISTRY_NAME: Final = "runtime-preparations.json"
_ASSET_ROOT = Path(__file__).resolve().parents[1] / "assets"
_DEFAULT_ASSET_ROOT = _ASSET_ROOT
_BOOTSTRAP_ARTIFACTS = _ASSET_ROOT / "bootstrap-artifacts.json"
_FFMPEG_PACKAGE = "imageio-ffmpeg==0.6.0"
_REQUIREMENT_RE = re.compile(r"^([A-Za-z0-9_.-]+)==([^\s]+)")
_EXPORT_FFMPEG_CODE = (
    "import imageio_ffmpeg, pathlib, shutil, sys; "
    "source=pathlib.Path(imageio_ffmpeg.get_ffmpeg_exe()); "
    "destination=pathlib.Path(sys.argv[1]); destination.parent.mkdir(parents=True, exist_ok=True); "
    "shutil.copyfile(source, destination); destination.chmod(0o700) # export-ffmpeg"
)

RuntimeRunner = Callable[[tuple[str, ...]], subprocess.CompletedProcess[str]]


class RuntimeBootstrapError(ValueError):
    """Raised when a locked vendor runtime cannot be prepared safely."""


@dataclass(frozen=True, slots=True)
class RuntimePaths:
    """Absolute paths for both vendor workers in one lock-keyed release."""

    release: Path
    asr_python: Path
    tts_python: Path
    ffmpeg: Path
    runtime_key: str
    lock_id: str

    def __post_init__(self) -> None:
        if not isinstance(self.release, Path) or not self.release.is_absolute():
            raise RuntimeBootstrapError("runtime release must be an absolute path")
        if self.release.is_symlink():
            raise RuntimeBootstrapError("runtime release cannot be a symlink")
        try:
            release = self.release.resolve()
        except (OSError, RuntimeError) as exc:
            raise RuntimeBootstrapError("runtime release cannot be resolved") from exc
        for name in ("asr_python", "tts_python", "ffmpeg"):
            path = getattr(self, name)
            if not isinstance(path, Path) or not path.is_absolute():
                raise RuntimeBootstrapError(f"{name} must be an absolute path")
            try:
                path.parent.resolve().relative_to(release)
            except (OSError, RuntimeError, ValueError) as exc:
                raise RuntimeBootstrapError(f"{name} escapes the runtime release") from exc
        if (
            not isinstance(self.runtime_key, str)
            or not self.runtime_key
            or "/" in self.runtime_key
            or "\\" in self.runtime_key
            or self.runtime_key in {".", ".."}
        ):
            raise RuntimeBootstrapError("runtime key must be a safe release name")
        if not isinstance(self.lock_id, str) or not self.lock_id:
            raise RuntimeBootstrapError("runtime lock id must be non-empty")

    @property
    def release_dir(self) -> Path:
        """Compatibility alias for callers that name the release directory explicitly."""
        return self.release


@dataclass(frozen=True, slots=True)
class PreparedRuntime:
    """A verified runtime manifest and its executable paths."""

    paths: RuntimePaths
    metadata: Mapping[str, object]


@dataclass(frozen=True, slots=True)
class RuntimeCurrentSnapshot:
    """Validated vendor/current target captured before a larger install transaction."""

    app_home: Path
    vendor_root: Path
    target: Path | None

    def __post_init__(self) -> None:
        if (
            not isinstance(self.app_home, Path)
            or not self.app_home.is_absolute()
            or self.app_home.is_symlink()
        ):
            raise RuntimeBootstrapError("runtime snapshot app_home is invalid")
        if (
            not isinstance(self.vendor_root, Path)
            or not self.vendor_root.is_absolute()
            or self.vendor_root.is_symlink()
            or self.vendor_root != self.app_home / _VENDOR_DIRNAME
        ):
            raise RuntimeBootstrapError("runtime snapshot vendor root is invalid")
        if self.target is not None:
            if not isinstance(self.target, Path) or not self.target.is_absolute():
                raise RuntimeBootstrapError("runtime snapshot target is invalid")
            try:
                self.target.resolve().relative_to(self.vendor_root.resolve())
            except (OSError, RuntimeError, ValueError) as exc:
                raise RuntimeBootstrapError("runtime snapshot target escapes vendor root") from exc

def _runtime_lock_payload(lock: RuntimeLock) -> dict[str, object]:
    return {
        "id": lock.id,
        "python": lock.python,
        "asr_requirements": list(lock.asr_requirements),
        "tts_requirements": list(lock.tts_requirements),
        "ffmpeg_artifact": lock.ffmpeg_artifact,
        "file_hashes": dict(lock.file_hashes),
    }


def _mapping_payload(value: Mapping[str, object]) -> dict[str, object]:
    raw = dict(value)
    aliases = {"python", "asr", "tts", "ffmpeg"}
    canonical = {
        "id",
        "python",
        "asr_requirements",
        "tts_requirements",
        "ffmpeg_artifact",
        "file_hashes",
    }
    if set(raw) == aliases:
        python = raw["python"]
        ffmpeg = raw["ffmpeg"]
        asr = raw["asr"]
        tts = raw["tts"]
        if (
            not isinstance(python, str)
            or not python
            or not isinstance(ffmpeg, str)
            or not ffmpeg
            or not isinstance(asr, (list, tuple))
            or not isinstance(tts, (list, tuple))
            or not asr
            or not tts
            or any(not isinstance(item, str) or not item for item in (*asr, *tts))
        ):
            raise RuntimeBootstrapError("runtime lock mapping is incomplete or invalid")
        return {
            "python": python,
            "asr": list(asr),
            "tts": list(tts),
            "ffmpeg": ffmpeg,
        }
    if set(raw) != canonical:
        raise RuntimeBootstrapError("runtime lock mapping has unknown or incomplete fields")
    try:
        normalized = RuntimeLock.model_validate(raw)
    except Exception as exc:
        raise RuntimeBootstrapError("runtime lock mapping is invalid") from exc
    return _runtime_lock_payload(normalized)


def _normalize_lock(lock: RuntimeLock | Mapping[str, object]) -> dict[str, object]:
    if isinstance(lock, RuntimeLock):
        return _runtime_lock_payload(lock)
    if not isinstance(lock, Mapping):
        raise RuntimeBootstrapError("runtime lock must be a RuntimeLock or mapping")
    return _mapping_payload(lock)


def _python_version_tuple(version: str) -> tuple[int, int, int]:
    if not re.fullmatch(r"3\.12\.\d+", version):
        raise RuntimeBootstrapError("runtime Python must be a 3.12 release")
    try:
        major, minor, patch = (int(part) for part in version.split("."))
    except ValueError as exc:
        raise RuntimeBootstrapError("runtime Python version is invalid") from exc
    return major, minor, patch


def runtime_key(lock: RuntimeLock | Mapping[str, object]) -> str:
    """Return a deterministic identity for the complete runtime lock content."""
    normalized = _normalize_lock(lock)
    try:
        encoded = json.dumps(
            normalized, ensure_ascii=False, sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise RuntimeBootstrapError("runtime lock is not serializable") from exc
    return f"runtime_{hashlib.sha256(encoded).hexdigest()}"


def _safe_relative(relative: str) -> tuple[str, ...]:
    if not isinstance(relative, str) or not relative or "\x00" in relative:
        raise RuntimeBootstrapError("runtime manifest path is invalid")
    normalized = relative.replace("\\", "/")
    posix = PurePosixPath(normalized)
    windows = PureWindowsPath(relative)
    if (
        posix.is_absolute()
        or windows.is_absolute()
        or windows.drive
        or any(part in {"", ".", ".."} or not part.strip() for part in normalized.split("/"))
    ):
        raise RuntimeBootstrapError("runtime manifest path is unsafe")
    return posix.parts


def _safe_runtime_path(root: Path, relative: str) -> Path:
    parts = _safe_relative(relative)
    if root.is_symlink():
        raise RuntimeBootstrapError("runtime root cannot be a symlink")
    try:
        resolved_root = root.resolve()
        candidate = resolved_root.joinpath(*parts)
        for index in range(len(parts)):
            cursor = resolved_root / Path(*parts[: index + 1])
            if cursor.is_symlink():
                raise RuntimeBootstrapError("runtime path contains a symlink")
        resolved = candidate.resolve()
        resolved.relative_to(resolved_root)
    except (OSError, RuntimeError, ValueError) as exc:
        if isinstance(exc, RuntimeBootstrapError):
            raise
        raise RuntimeBootstrapError("runtime path escapes its root") from exc
    return resolved


def _ensure_directory(path: Path) -> None:
    if path.is_symlink():
        raise RuntimeBootstrapError("runtime directory cannot be a symlink")
    try:
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.chmod(0o700)
    except OSError as exc:
        raise RuntimeBootstrapError("runtime directory cannot be created") from exc
    if not path.is_dir() or path.is_symlink():
        raise RuntimeBootstrapError("runtime path is not a directory")


def _resolve_app_home(app_home: Path) -> Path:
    if not isinstance(app_home, Path) or not app_home.is_absolute() or app_home.is_symlink():
        raise RuntimeBootstrapError("app_home must be an absolute non-symlink path")
    try:
        return app_home.resolve()
    except (OSError, RuntimeError) as exc:
        raise RuntimeBootstrapError("app_home cannot be resolved") from exc


def _requirement_packages(requirements: Sequence[str]) -> dict[str, str]:
    packages: dict[str, str] = {}
    for requirement in requirements:
        match = _REQUIREMENT_RE.match(requirement)
        if match is None:
            raise RuntimeBootstrapError("runtime requirements must pin package versions")
        packages[match.group(1)] = match.group(2)
    return dict(sorted(packages.items()))


def _normalized_package_name(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).casefold()


def _normalize_requirement_token(value: str) -> str:
    return " ".join(value.replace("\\", " ").split())


def _parse_requirement_file(data: bytes) -> tuple[str, ...]:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise RuntimeBootstrapError("runtime requirement file is not UTF-8") from exc
    tokens: list[str] = []
    pending: list[str] = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            raise RuntimeBootstrapError("runtime requirement file contains an empty line")
        continuation = line.endswith("\\")
        if continuation:
            line = line[:-1].rstrip()
        if not line:
            raise RuntimeBootstrapError("runtime requirement file contains an empty token")
        pending.append(line)
        if not continuation:
            tokens.append(_normalize_requirement_token(" ".join(pending)))
            pending.clear()
    if pending:
        raise RuntimeBootstrapError("runtime requirement file has an unfinished continuation")
    if any(_REQUIREMENT_RE.match(token) is None for token in tokens):
        raise RuntimeBootstrapError("runtime requirement file contains an invalid requirement")
    return tuple(tokens)


def _role_requirements(lock: RuntimeLock, role: str) -> tuple[bytes, tuple[str, ...]]:
    relative = f"runtime/{role}.txt"
    expected_hash = lock.file_hashes.get(relative)
    if not isinstance(expected_hash, str):
        raise RuntimeBootstrapError(f"runtime lock is missing {relative} hash")
    expected_requirements = tuple(
        _normalize_requirement_token(requirement)
        for requirement in getattr(lock, f"{role}_requirements")
    )
    asset_path = _safe_runtime_path(_ASSET_ROOT, relative)
    try:
        asset_bytes = asset_path.read_bytes() if asset_path.is_file() else None
    except OSError as exc:
        raise RuntimeBootstrapError(f"runtime asset cannot be read: {relative}") from exc
    if asset_bytes is None or hashlib.sha256(asset_bytes).hexdigest() != expected_hash:
        normalized_bytes = ("\n".join(expected_requirements) + "\n").encode("utf-8")
        if (
            _ASSET_ROOT != _DEFAULT_ASSET_ROOT
            or hashlib.sha256(normalized_bytes).hexdigest() != expected_hash
        ):
            raise RuntimeBootstrapError(f"runtime asset hash mismatch: {relative}")
        asset_bytes = normalized_bytes
    parsed_requirements = _parse_requirement_file(asset_bytes)
    if parsed_requirements != expected_requirements:
        raise RuntimeBootstrapError(f"runtime asset requirements do not match lock: {relative}")
    return asset_bytes, parsed_requirements


def _combined_requirements(requirements: Sequence[str]) -> tuple[str, ...]:
    """Merge the two role manifests without weakening either pin or hash set."""
    merged: dict[str, tuple[str, str, set[str]]] = {}
    for requirement in requirements:
        match = _REQUIREMENT_RE.match(requirement)
        if match is None:
            raise RuntimeBootstrapError("runtime requirements must pin package versions")
        package, version = match.group(1), match.group(2)
        package_key = _normalized_package_name(package)
        hashes = {
            item
            for item in requirement.split()
            if item.startswith("--hash=sha256:")
        }
        current = merged.get(package_key)
        if current is not None:
            if current[1] != version:
                raise RuntimeBootstrapError(
                    f"shared runtime has conflicting pins for package {package_key}"
                )
            current[2].update(hashes)
        else:
            merged[package_key] = (package, version, hashes)
    return tuple(
        f"{package}=={version} {' '.join(sorted(hashes))}"
        for _, (package, version, hashes) in sorted(merged.items())
    )


def _write_private(path: Path, data: bytes) -> str:
    temporary = path.parent / f".runtime-{uuid4().hex}"
    try:
        descriptor, temporary_name = tempfile.mkstemp(prefix=".runtime-", dir=path.parent)
        temporary = Path(temporary_name)
        with os.fdopen(descriptor, "wb") as output:
            os.fchmod(output.fileno(), 0o600)
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        temporary.replace(path)
        return hashlib.sha256(data).hexdigest()
    except OSError as exc:
        raise RuntimeBootstrapError("runtime metadata cannot be written") from exc
    finally:
        temporary.unlink(missing_ok=True)


def _read_json(path: Path) -> Mapping[str, object]:
    if path.is_symlink() or not path.is_file():
        raise RuntimeBootstrapError("runtime metadata is missing")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RuntimeBootstrapError("runtime metadata is invalid") from exc
    if not isinstance(payload, Mapping):
        raise RuntimeBootstrapError("runtime metadata is not an object")
    return payload


def _read_registry(path: Path) -> dict[str, object]:
    if not path.exists():
        return {"schema_version": _SCHEMA_VERSION, "prepared": {}}
    payload = _read_json(path)
    if payload.get("schema_version") != _SCHEMA_VERSION or not isinstance(
        payload.get("prepared"), dict
    ):
        raise RuntimeBootstrapError("runtime registry schema is invalid")
    return cast(dict[str, object], payload)


def _write_registry(path: Path, payload: Mapping[str, object]) -> None:
    encoded = (json.dumps(payload, ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8")
    _write_private(path, encoded)


def _run(command: tuple[str, ...], runner: RuntimeRunner) -> None:
    if not command or any(not isinstance(item, str) or not item for item in command):
        raise RuntimeBootstrapError("runtime command is invalid")
    try:
        completed = runner(command)
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        raise RuntimeBootstrapError("runtime command could not be executed") from exc
    if completed.returncode != 0:
        raise RuntimeBootstrapError("runtime command failed")


def _ffmpeg_requirement(lock: RuntimeLock) -> str:
    if lock.ffmpeg_artifact != _FFMPEG_PACKAGE:
        raise RuntimeBootstrapError("runtime lock ffmpeg artifact is not published")
    try:
        bootstrap = _read_json(_BOOTSTRAP_ARTIFACTS)
        ffmpeg = bootstrap["ffmpeg"]
        if not isinstance(ffmpeg, Mapping) or not isinstance(ffmpeg.get("sha256"), str):
            raise KeyError("ffmpeg")
        digest = cast(str, ffmpeg["sha256"])
    except (KeyError, RuntimeBootstrapError) as exc:
        raise RuntimeBootstrapError("published ffmpeg hash is unavailable") from exc
    if not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
        raise RuntimeBootstrapError("published ffmpeg hash is invalid")
    return f"{lock.ffmpeg_artifact} --hash=sha256:{digest}"


def _runtime_paths(release: Path, key: str, lock_id: str) -> RuntimePaths:
    shared_python = release / "bin" / "python"
    return RuntimePaths(
        release=release,
        asr_python=shared_python,
        tts_python=shared_python,
        ffmpeg=release / "ffmpeg" / "bin" / "ffmpeg",
        runtime_key=key,
        lock_id=lock_id,
    )


def _validate_executable(
    path: Path, release: Path, *, allow_external_symlink: bool = False
) -> None:
    try:
        path.parent.resolve(strict=True).relative_to(release.resolve())
        resolved = path.resolve(strict=True)
        if not allow_external_symlink:
            resolved.relative_to(release.resolve())
    except (OSError, RuntimeError, ValueError) as exc:
        raise RuntimeBootstrapError("runtime executable path is invalid") from exc
    if not path.is_file() or not os.access(path, os.X_OK):
        raise RuntimeBootstrapError("runtime executable is missing or not executable")


def _metadata_for(
    lock: RuntimeLock,
    key: str,
    paths: RuntimePaths,
    requirement_hashes: Mapping[str, str],
) -> dict[str, object]:
    return {
        "schema_version": _SCHEMA_VERSION,
        "runtime_key": key,
        "lock": _runtime_lock_payload(lock),
        "lock_id": lock.id,
        "python": lock.python,
        "ffmpeg_artifact": lock.ffmpeg_artifact,
        "paths": {
            "asr_python": "bin/python",
            "tts_python": "bin/python",
            "ffmpeg": "ffmpeg/bin/ffmpeg",
        },
        "requirements": {
            "asr": "requirements/asr.txt",
            "tts": "requirements/tts.txt",
            "shared": "requirements/shared.txt",
            "ffmpeg": "requirements/ffmpeg.txt",
        },
        "requirement_hashes": dict(requirement_hashes),
        "packages": {
            "asr": _requirement_packages(lock.asr_requirements),
            "tts": _requirement_packages(lock.tts_requirements),
        },
        "worker_modules": {"asr": "mlx_qwen3_asr", "tts": "mlx_audio"},
        "pythonpath": {"asr": [], "tts": []},
        "artifact_identity": {
            "asr_lock_file": lock.file_hashes.get("runtime/asr.txt"),
            "tts_lock_file": lock.file_hashes.get("runtime/tts.txt"),
            "ffmpeg": lock.ffmpeg_artifact,
        },
        "release": key,
    }


def _runtime_metadata_matches(
    metadata: Mapping[str, object], lock: RuntimeLock, key: str, release: Path
) -> RuntimePaths:
    if (
        metadata.get("schema_version") != _SCHEMA_VERSION
        or metadata.get("runtime_key") != key
        or metadata.get("lock_id") != lock.id
        or metadata.get("python") != lock.python
        or metadata.get("ffmpeg_artifact") != lock.ffmpeg_artifact
        or metadata.get("lock") != _runtime_lock_payload(lock)
        or metadata.get("release") != key
    ):
        raise RuntimeBootstrapError("prepared runtime identity does not match lock")
    paths_raw = metadata.get("paths")
    if not isinstance(paths_raw, Mapping):
        raise RuntimeBootstrapError("prepared runtime paths are missing")
    expected = {
        "asr_python": "bin/python",
        "tts_python": "bin/python",
        "ffmpeg": "ffmpeg/bin/ffmpeg",
    }
    if dict(paths_raw) != expected:
        raise RuntimeBootstrapError("prepared runtime path identity is invalid")
    requirements_raw = metadata.get("requirements")
    expected_requirements = {
        "asr": "requirements/asr.txt",
        "tts": "requirements/tts.txt",
        "shared": "requirements/shared.txt",
        "ffmpeg": "requirements/ffmpeg.txt",
    }
    if not isinstance(requirements_raw, Mapping) or dict(requirements_raw) != expected_requirements:
        raise RuntimeBootstrapError("prepared runtime requirement identity is invalid")
    asr_bytes, asr_requirements = _role_requirements(lock, "asr")
    tts_bytes, tts_requirements = _role_requirements(lock, "tts")
    ffmpeg_requirement = _ffmpeg_requirement(lock)
    expected_requirement_bytes = {
        "asr": asr_bytes,
        "tts": tts_bytes,
        "shared": (
            "\n".join(_combined_requirements((*asr_requirements, *tts_requirements))) + "\n"
        ).encode("utf-8"),
        "ffmpeg": (ffmpeg_requirement + "\n").encode("utf-8"),
    }
    requirement_hashes = metadata.get("requirement_hashes")
    if not isinstance(requirement_hashes, Mapping):
        raise RuntimeBootstrapError("prepared runtime requirement hashes are missing")
    for role, relative in expected_requirements.items():
        expected_hash = hashlib.sha256(expected_requirement_bytes[role]).hexdigest()
        if requirement_hashes.get(role) != expected_hash:
            raise RuntimeBootstrapError("prepared runtime requirement hash is invalid")
        requirement_path = _safe_runtime_path(release, relative)
        if requirement_path.is_symlink() or not requirement_path.is_file():
            raise RuntimeBootstrapError("prepared runtime requirement file is missing")
        try:
            actual = requirement_path.read_bytes()
        except OSError as exc:
            raise RuntimeBootstrapError("prepared runtime requirement file cannot be read") from exc
        if actual != expected_requirement_bytes[role]:
            raise RuntimeBootstrapError("prepared runtime requirement file does not match lock")
    packages = metadata.get("packages")
    expected_packages = {
        "asr": _requirement_packages(asr_requirements),
        "tts": _requirement_packages(tts_requirements),
    }
    if not isinstance(packages, Mapping) or dict(packages) != expected_packages:
        raise RuntimeBootstrapError("prepared runtime package identity is invalid")
    if metadata.get("worker_modules") != {"asr": "mlx_qwen3_asr", "tts": "mlx_audio"}:
        raise RuntimeBootstrapError("prepared runtime worker identity is invalid")
    pythonpath = metadata.get("pythonpath")
    if not isinstance(pythonpath, Mapping) or set(pythonpath) != {"asr", "tts"}:
        raise RuntimeBootstrapError("prepared runtime Python path is invalid")
    for role in ("asr", "tts"):
        entries = pythonpath.get(role)
        if not isinstance(entries, (list, tuple)):
            raise RuntimeBootstrapError("prepared runtime Python path is invalid")
        for entry in entries:
            if not isinstance(entry, str):
                raise RuntimeBootstrapError("prepared runtime Python path is invalid")
            path = _safe_runtime_path(release, entry)
            if not path.is_dir():
                raise RuntimeBootstrapError("prepared runtime Python path is missing")
    if metadata.get("artifact_identity") != {
        "asr_lock_file": lock.file_hashes.get("runtime/asr.txt"),
        "tts_lock_file": lock.file_hashes.get("runtime/tts.txt"),
        "ffmpeg": lock.ffmpeg_artifact,
    }:
        raise RuntimeBootstrapError("prepared runtime artifact identity is invalid")
    paths = _runtime_paths(release, key, lock.id)
    _validate_executable(paths.asr_python, release, allow_external_symlink=True)
    _validate_executable(paths.tts_python, release, allow_external_symlink=True)
    _validate_executable(paths.ffmpeg, release)
    return paths


def _load_prepared_release(
    app_home: Path, lock: RuntimeLock, *, require_current: bool
) -> PreparedRuntime:
    """Read a verified release, optionally requiring it to be the active release."""
    if not isinstance(lock, RuntimeLock):
        raise RuntimeBootstrapError("runtime lock must be a RuntimeLock")
    resolved = _resolve_app_home(app_home)
    key = runtime_key(lock)
    vendor_root = resolved / _VENDOR_DIRNAME
    release = _safe_runtime_path(vendor_root, key)
    current = vendor_root / _CURRENT_NAME
    if require_current and (not current.is_symlink() or current.resolve() != release.resolve()):
        raise RuntimeBootstrapError("prepared runtime current pointer is missing")
    metadata = _read_json(release / _RUNTIME_METADATA_NAME)
    paths = _runtime_metadata_matches(metadata, lock, key, release)
    return PreparedRuntime(paths=paths, metadata=metadata)


def load_prepared_runtime(app_home: Path, lock: RuntimeLock) -> PreparedRuntime:
    """Read the active prepared runtime without importing vendor SDKs or using the network."""
    return _load_prepared_release(app_home, lock, require_current=True)


def _current_target(current: Path, vendor_root: Path) -> Path | None:
    if not current.exists() and not current.is_symlink():
        return None
    if not current.is_symlink():
        raise RuntimeBootstrapError("vendor/current must be a symlink")
    try:
        target = current.resolve()
        target.relative_to(vendor_root.resolve())
    except (OSError, RuntimeError, ValueError) as exc:
        raise RuntimeBootstrapError("vendor/current escapes vendor root") from exc
    return target


def _switch_current(current: Path, release: Path, vendor_root: Path) -> Path | None:
    old_target = _current_target(current, vendor_root)
    temporary = vendor_root / f".{_CURRENT_NAME}.{uuid4().hex}.new"
    try:
        temporary.symlink_to(release, target_is_directory=True)
        temporary.replace(current)
    except OSError as exc:
        temporary.unlink(missing_ok=True)
        raise RuntimeBootstrapError("could not atomically switch vendor/current") from exc
    return old_target


def _restore_current(current: Path, old_target: Path | None) -> None:
    if old_target is None:
        if current.is_symlink():
            current.unlink()
        elif current.exists():
            raise RuntimeBootstrapError("cannot restore non-symlink vendor/current")
        return
    if current.exists() and not current.is_symlink():
        raise RuntimeBootstrapError("cannot restore non-symlink vendor/current")
    temporary = current.parent / f".{_CURRENT_NAME}.{uuid4().hex}.restore"
    try:
        temporary.symlink_to(old_target, target_is_directory=True)
        temporary.replace(current)
    except OSError as exc:
        temporary.unlink(missing_ok=True)
        raise RuntimeBootstrapError("could not atomically restore vendor/current") from exc


def snapshot_runtime_current(app_home: Path) -> RuntimeCurrentSnapshot:
    """Capture the validated vendor/current target for a larger install transaction."""
    resolved_app_home = _resolve_app_home(app_home)
    vendor_root = resolved_app_home / _VENDOR_DIRNAME
    if vendor_root.is_symlink():
        raise RuntimeBootstrapError("vendor root cannot be a symlink")
    target = _current_target(vendor_root / _CURRENT_NAME, vendor_root)
    return RuntimeCurrentSnapshot(
        app_home=resolved_app_home,
        vendor_root=vendor_root,
        target=target,
    )


def restore_runtime_current(snapshot: RuntimeCurrentSnapshot) -> None:
    """Atomically restore a previously captured vendor/current target."""
    if not isinstance(snapshot, RuntimeCurrentSnapshot):
        raise RuntimeBootstrapError("runtime snapshot is invalid")
    resolved_app_home = _resolve_app_home(snapshot.app_home)
    vendor_root = resolved_app_home / _VENDOR_DIRNAME
    if snapshot.vendor_root != vendor_root:
        raise RuntimeBootstrapError("runtime snapshot vendor root does not match app_home")
    _ensure_directory(vendor_root)
    target = snapshot.target
    if target is not None:
        try:
            target.resolve().relative_to(vendor_root.resolve())
        except (OSError, RuntimeError, ValueError) as exc:
            raise RuntimeBootstrapError("runtime snapshot target escapes vendor root") from exc
    _restore_current(vendor_root / _CURRENT_NAME, target)


def _remove_empty(path: Path) -> None:
    try:
        if path.is_dir() and not path.is_symlink() and not any(path.iterdir()):
            path.rmdir()
    except OSError:
        return


def prepare_runtime(
    lock: RuntimeLock,
    app_home: Path,
    runner: RuntimeRunner,
) -> RuntimePaths:
    """Prepare one lock-keyed ASR/TTS runtime using only injected fixed-argv commands."""
    if not isinstance(lock, RuntimeLock):
        raise RuntimeBootstrapError("runtime lock must be a RuntimeLock")
    if not callable(runner):
        raise RuntimeBootstrapError("runtime runner must be injected")
    _python_version_tuple(lock.python)
    resolved_app_home = _resolve_app_home(app_home)
    key = runtime_key(lock)
    vendor_root = resolved_app_home / _VENDOR_DIRNAME
    _ensure_directory(resolved_app_home)
    _ensure_directory(vendor_root)
    staging_root = vendor_root / _STAGING_DIRNAME
    _ensure_directory(staging_root)
    release = _safe_runtime_path(vendor_root, key)
    try:
        existing = _load_prepared_release(resolved_app_home, lock, require_current=False)
    except RuntimeBootstrapError:
        existing = None
    if existing is not None:
        _switch_current(vendor_root / _CURRENT_NAME, existing.paths.release, vendor_root)
        return existing.paths

    operation = staging_root / f"{key}.{uuid4().hex}"
    stage_release = operation / "release"
    _ensure_directory(operation)
    _ensure_directory(stage_release)
    current = vendor_root / _CURRENT_NAME
    old_current = _current_target(current, vendor_root)
    registry_path = vendor_root / _RUNTIME_REGISTRY_NAME
    registry = _read_registry(registry_path)
    old_registry = registry_path.read_bytes() if registry_path.is_file() else None
    backup: Path | None = None
    release_displaced = False
    release_installed = False
    try:
        asr_bytes, asr_tokens = _role_requirements(lock, "asr")
        tts_bytes, tts_tokens = _role_requirements(lock, "tts")
        shared_requirements = _combined_requirements((*asr_tokens, *tts_tokens))
        ffmpeg_requirement = _ffmpeg_requirement(lock)
        shared_environment = stage_release
        _run(("uv", "venv", "--python", lock.python, str(shared_environment)), runner)
        shared_python = shared_environment / "bin" / "python"
        _validate_executable(shared_python, stage_release, allow_external_symlink=True)

        requirements_root = stage_release / "requirements"
        _ensure_directory(requirements_root)
        asr_requirements_path = requirements_root / "asr.txt"
        tts_requirements_path = requirements_root / "tts.txt"
        shared_requirements_path = requirements_root / "shared.txt"
        ffmpeg_requirements = requirements_root / "ffmpeg.txt"
        asr_hash = _write_private(asr_requirements_path, asr_bytes)
        tts_hash = _write_private(tts_requirements_path, tts_bytes)
        shared_hash = _write_private(
            shared_requirements_path, ("\n".join(shared_requirements) + "\n").encode("utf-8")
        )
        ffmpeg_hash = _write_private(
            ffmpeg_requirements, (ffmpeg_requirement + "\n").encode("utf-8")
        )

        _run(
            (
                "uv",
                "pip",
                "install",
                "--dry-run",
                "--python",
                str(shared_python),
                "--python-version",
                "3.12",
                "--python-platform",
                "aarch64-apple-darwin",
                "--require-hashes",
                "--only-binary",
                ":all:",
                "-r",
                str(asr_requirements_path),
                "-r",
                str(tts_requirements_path),
            ),
            runner,
        )
        _run(
            (
                "uv",
                "pip",
                "sync",
                "--python",
                str(shared_python),
                "--python-version",
                "3.12",
                "--python-platform",
                "aarch64-apple-darwin",
                "--require-hashes",
                "--only-binary",
                ":all:",
                "-r",
                str(asr_requirements_path),
                "-r",
                str(tts_requirements_path),
            ),
            runner,
        )

        ffmpeg_path = stage_release / "ffmpeg" / "bin" / "ffmpeg"
        _run(
            (
                "uv",
                "pip",
                "install",
                "--python",
                str(shared_python),
                "--python-version",
                "3.12",
                "--python-platform",
                "aarch64-apple-darwin",
                "--require-hashes",
                "--only-binary",
                ":all:",
                "-r",
                str(ffmpeg_requirements),
            ),
            runner,
        )
        _run((str(shared_python), "-c", _EXPORT_FFMPEG_CODE, str(ffmpeg_path)), runner)
        paths = _runtime_paths(stage_release, key, lock.id)
        _validate_executable(paths.asr_python, stage_release, allow_external_symlink=True)
        _validate_executable(paths.tts_python, stage_release, allow_external_symlink=True)
        _validate_executable(paths.ffmpeg, stage_release)
        metadata = _metadata_for(
            lock,
            key,
            paths,
            {
                "asr": asr_hash,
                "tts": tts_hash,
                "shared": shared_hash,
                "ffmpeg": ffmpeg_hash,
            },
        )
        _write_private(
            stage_release / _RUNTIME_METADATA_NAME,
            (json.dumps(metadata, ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8"),
        )

        if release.exists() or release.is_symlink():
            backup = _safe_runtime_path(vendor_root / ".releases", f"{key}.{uuid4().hex}")
            _ensure_directory(backup.parent)
            release.replace(backup)
            release_displaced = True
        stage_release.replace(release)
        release_installed = True
        _switch_current(current, release, vendor_root)

        prepared = registry["prepared"]
        assert isinstance(prepared, dict)
        prepared[key] = {
            "runtime_key": key,
            "lock_id": lock.id,
            "release": key,
            "metadata": f"{key}/{_RUNTIME_METADATA_NAME}",
        }
        _write_registry(registry_path, registry)
        _remove_empty(operation)
        _remove_empty(staging_root)
        return _runtime_paths(release, key, lock.id)
    except BaseException:
        if old_registry is None:
            registry_path.unlink(missing_ok=True)
        else:
            _write_private(registry_path, old_registry)
        if current.is_symlink() and old_current is not None and current.resolve() != old_current:
            _restore_current(current, old_current)
        elif current.is_symlink() and old_current is None and current.resolve() == release:
            current.unlink()
        if release_installed and (release.exists() or release.is_symlink()):
            failed_release = operation / "failed-release"
            release.replace(failed_release)
        if release_displaced and backup is not None and backup.exists():
            backup.replace(release)
        raise


__all__ = [
    "PreparedRuntime",
    "RuntimeBootstrapError",
    "RuntimeCurrentSnapshot",
    "RuntimePaths",
    "RuntimeRunner",
    "load_prepared_runtime",
    "prepare_runtime",
    "restore_runtime_current",
    "runtime_key",
    "snapshot_runtime_current",
]
