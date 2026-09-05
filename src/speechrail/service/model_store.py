"""Prepare and verify model snapshots without exposing download paths to requests."""

from __future__ import annotations

import asyncio
import contextlib
import copy
import hashlib
import inspect
import json
import os
import shutil
import tempfile
from collections.abc import AsyncIterable, Awaitable, Callable, Iterable, Mapping
from pathlib import Path, PurePosixPath, PureWindowsPath
from typing import Protocol, cast
from uuid import uuid4

from speechrail.config.model_catalog import (
    ModelArtifact,
    ModelCatalog,
    RuntimeLock,
    SourceLocation,
    load_catalog,
    load_runtime_lock,
)

_REGISTRY_SCHEMA_VERSION = 1
_REGISTRY_FILENAME = "model-preparations.json"
_CHUNK_SIZE = 1024 * 1024
_MAX_RETRIES = 3

DownloadStream = bytes | AsyncIterable[bytes] | Iterable[bytes]
DownloadResult = DownloadStream | Awaitable[DownloadStream]
ProgressCallback = Callable[[dict[str, object]], None]
DiskUsage = Callable[[Path], object]


class Downloader(Protocol):
    """Injected source adapter; it must return a bounded byte stream for one manifest file."""

    def download(self, source: SourceLocation, relative_path: str) -> DownloadResult:
        """Return bytes for the exact locked source and relative file path."""


class ModelStoreError(ValueError):
    """Raised when a model preparation cannot produce a fully verified snapshot."""


class _DownloadStreamCloseError(ModelStoreError):
    """A downloaded stream could not be closed after a successful transfer."""


def safe_artifact_path(root: Path, relative: str) -> Path:
    """Resolve a manifest-relative path while rejecting traversal and symlink escapes."""
    if not isinstance(root, Path) or not root.is_absolute():
        raise ValueError("artifact root must be an absolute path")
    if not isinstance(relative, str) or not relative or "\x00" in relative:
        raise ValueError("artifact path must be a non-empty relative string")

    normalized = relative.replace("\\", "/")
    posix = PurePosixPath(normalized)
    windows = PureWindowsPath(relative)
    raw_parts = normalized.split("/")
    if (
        posix.is_absolute()
        or windows.is_absolute()
        or windows.drive
        or any(part in {"", ".", ".."} or not part.strip() for part in raw_parts)
    ):
        raise ValueError("artifact path must be a safe relative path")

    try:
        resolved_root = root.resolve()
    except (OSError, RuntimeError) as exc:
        raise ValueError("artifact root cannot be resolved") from exc
    if root.is_symlink():
        raise ValueError("artifact root cannot be a symlink")

    candidate = resolved_root.joinpath(*posix.parts)
    cursor = resolved_root
    for part in posix.parts:
        cursor /= part
        if cursor.is_symlink():
            raise ValueError("artifact path contains a symlink")
    try:
        resolved_candidate = candidate.resolve()
        resolved_candidate.relative_to(resolved_root)
    except (OSError, RuntimeError, ValueError) as exc:
        raise ValueError("artifact path escapes its root") from exc
    return resolved_candidate


def _ensure_directory(path: Path, *, mode: int = 0o700) -> None:
    if path.is_symlink():
        raise ModelStoreError(f"refusing symlink directory: {path.name}")
    try:
        path.mkdir(parents=True, exist_ok=True, mode=mode)
    except OSError as exc:
        raise ModelStoreError(f"could not create model store directory: {path.name}") from exc
    if not path.is_dir() or path.is_symlink():
        raise ModelStoreError(f"model store path is not a directory: {path.name}")
    try:
        path.chmod(mode)
    except OSError as exc:
        raise ModelStoreError(f"could not secure model store directory: {path.name}") from exc


def _remove_tree(path: Path) -> None:
    if path.is_symlink():
        raise ModelStoreError("refusing to remove a symlink in model staging")
    if not path.exists():
        return
    try:
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink()
    except OSError as exc:
        raise ModelStoreError("could not clean model staging") from exc


def _file_manifest(artifact: ModelArtifact) -> list[dict[str, object]]:
    return [
        {"path": item.path, "size": item.size, "sha256": item.sha256}
        for item in artifact.files
    ]


def _quantization_manifest(artifact: ModelArtifact) -> dict[str, object]:
    return {
        "bits": artifact.quantization.bits,
        "group_size": artifact.quantization.group_size,
        "format": artifact.quantization.format,
    }


def _source_manifest(source: SourceLocation) -> dict[str, str]:
    return {
        "provider": source.provider,
        "repository": source.repository,
        "revision": source.revision,
    }


def _sources_manifest(artifact: ModelArtifact) -> list[dict[str, str]]:
    return [_source_manifest(source) for source in artifact.sources]


def _lock_manifest(lock: RuntimeLock) -> dict[str, object]:
    return {
        "id": lock.id,
        "python": lock.python,
        "asr_requirements": list(lock.asr_requirements),
        "tts_requirements": list(lock.tts_requirements),
        "ffmpeg_artifact": lock.ffmpeg_artifact,
        "file_hashes": dict(lock.file_hashes),
    }


def _prepared_id(preset_id: str, lock: RuntimeLock, artifacts: tuple[ModelArtifact, ...]) -> str:
    payload = {
        "preset": preset_id,
        "runtime_lock": _lock_manifest(lock),
        "artifacts": [
            {
                "key": artifact.key,
                "model_id": artifact.model_id,
                "revision": artifact.revision,
                "family": artifact.family,
                "variant": artifact.variant,
                "quantization": _quantization_manifest(artifact),
                "sources": _sources_manifest(artifact),
                "files": _file_manifest(artifact),
            }
            for artifact in artifacts
        ],
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return f"prepared_{hashlib.sha256(encoded).hexdigest()}"


def _emit(progress: ProgressCallback | None, event: dict[str, object]) -> None:
    if progress is not None:
        try:
            progress(event)
        except asyncio.CancelledError:
            raise
        except Exception:
            # Progress is observational and must not change preparation outcome.
            return


def _check_cancel(cancel_event: asyncio.Event | None) -> None:
    if cancel_event is not None and cancel_event.is_set():
        raise asyncio.CancelledError


def _registry_path(app_home: Path) -> Path:
    return app_home / "state" / _REGISTRY_FILENAME


def _empty_registry() -> dict[str, object]:
    return {"schema_version": _REGISTRY_SCHEMA_VERSION, "prepared": {}}


def _read_registry(path: Path) -> dict[str, object]:
    if path.is_symlink():
        raise ModelStoreError("model preparation registry cannot be a symlink")
    if not path.exists():
        return _empty_registry()
    if not path.is_file():
        raise ModelStoreError("model preparation registry is not a file")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ModelStoreError("model preparation registry is corrupt") from exc
    if (
        not isinstance(payload, dict)
        or type(payload.get("schema_version")) is not int
        or payload["schema_version"] != _REGISTRY_SCHEMA_VERSION
        or not isinstance(payload.get("prepared"), dict)
    ):
        raise ModelStoreError("model preparation registry schema is invalid")
    return cast(dict[str, object], payload)


def _write_registry(path: Path, payload: Mapping[str, object]) -> None:
    _ensure_directory(path.parent)
    if path.is_symlink():
        raise ModelStoreError("model preparation registry cannot be a symlink")
    descriptor, temporary_name = tempfile.mkstemp(prefix=".model-preparations-", dir=path.parent)
    temporary = Path(temporary_name)
    committed = False
    try:
        raw = (json.dumps(payload, ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8")
        with os.fdopen(descriptor, "wb") as output:
            os.fchmod(output.fileno(), 0o600)
            output.write(raw)
            output.flush()
            os.fsync(output.fileno())
        temporary.replace(path)
        committed = True
    except OSError as exc:
        raise ModelStoreError("could not atomically write model preparation registry") from exc
    finally:
        with contextlib.suppress(OSError):
            temporary.unlink(missing_ok=True)

    if committed:
        # The rename is the commit point.  Directory fsync improves crash
        # durability when available, but failure here must not roll back model
        # directories after the new registry is already visible.
        try:
            parent_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
            try:
                os.fsync(parent_fd)
            finally:
                os.close(parent_fd)
        except OSError:
            pass


def _artifact_entry(
    artifact: ModelArtifact,
    *,
    path: str,
    source: SourceLocation,
) -> dict[str, object]:
    return {
        "path": path,
        "model_id": artifact.model_id,
        "revision": artifact.revision,
        "quantization": _quantization_manifest(artifact),
        "source": _source_manifest(source),
        "sources": _sources_manifest(artifact),
        "files": _file_manifest(artifact),
    }


def _entry_content_matches_artifact(entry: object, artifact: ModelArtifact) -> bool:
    if not isinstance(entry, dict):
        return False
    expected_sources = _sources_manifest(artifact)
    return (
        entry.get("revision") == artifact.revision
        and entry.get("sources") == expected_sources
        and entry.get("files") == _file_manifest(artifact)
        and isinstance(entry.get("source"), dict)
        and entry["source"] in expected_sources
    )


def _entry_matches_artifact(entry: object, artifact: ModelArtifact) -> bool:
    if not _entry_content_matches_artifact(entry, artifact):
        return False
    if not isinstance(entry, dict):
        return False
    return (
        entry.get("model_id") == artifact.model_id
        and entry.get("quantization") == _quantization_manifest(artifact)
    )


def _entry_path(entry: object, app_home: Path) -> Path | None:
    if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
        return None
    relative = cast(str, entry["path"])
    try:
        return safe_artifact_path(app_home, relative)
    except ValueError:
        return None


def _snapshot_file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as source:
            while chunk := source.read(_CHUNK_SIZE):
                digest.update(chunk)
    except OSError as exc:
        raise ModelStoreError("could not read prepared model file") from exc
    return digest.hexdigest()


def _verify_snapshot(directory: Path, artifact: ModelArtifact) -> bool:
    if directory.is_symlink() or not directory.is_dir():
        return False
    try:
        resolved_directory = directory.resolve()
    except (OSError, RuntimeError):
        return False

    actual: set[str] = set()
    for current, directories, files in os.walk(resolved_directory, followlinks=False):
        current_path = Path(current)
        if any((current_path / name).is_symlink() for name in directories):
            return False
        for name in files:
            path = current_path / name
            if path.is_symlink() or not path.is_file():
                return False
            try:
                relative = path.relative_to(resolved_directory).as_posix()
            except ValueError:
                return False
            actual.add(relative)

    expected = {item.path for item in artifact.files}
    if actual != expected:
        return False
    for item in artifact.files:
        try:
            path = safe_artifact_path(resolved_directory, item.path)
            if path.is_symlink() or not path.is_file() or path.stat().st_size != item.size:
                return False
            if _snapshot_file_hash(path) != item.sha256:
                return False
        except (OSError, ValueError, ModelStoreError):
            return False
    return True


def _cache_path(
    registry: Mapping[str, object], app_home: Path, models_root: Path, artifact: ModelArtifact
) -> Path | None:
    prepared = registry.get("prepared")
    if not isinstance(prepared, dict):
        return None
    destination = models_root / artifact.key
    if destination.is_symlink() or not destination.is_dir():
        return None
    has_matching_entry = False
    for candidate in prepared.values():
        if not isinstance(candidate, dict):
            continue
        artifacts = candidate.get("artifacts")
        if not isinstance(artifacts, dict) or not _entry_content_matches_artifact(
            artifacts.get(artifact.key), artifact
        ):
            continue
        entry_path = _entry_path(artifacts[artifact.key], app_home)
        if entry_path == destination:
            has_matching_entry = True
            break
    if has_matching_entry and _verify_snapshot(destination, artifact):
        return destination
    return None


def _prepared_entry_is_complete(
    registry: Mapping[str, object],
    prepared_id: str,
    app_home: Path,
    artifacts: tuple[ModelArtifact, ...],
    lock: RuntimeLock,
    preset_id: str,
) -> bool:
    prepared = registry.get("prepared")
    if not isinstance(prepared, dict):
        return False
    candidate = prepared.get(prepared_id)
    if not isinstance(candidate, dict):
        return False
    if candidate.get("preset") != preset_id or candidate.get("runtime_lock_id") != lock.id:
        return False
    candidate_artifacts = candidate.get("artifacts")
    if not isinstance(candidate_artifacts, dict):
        return False
    for artifact in artifacts:
        entry = candidate_artifacts.get(artifact.key)
        if not _entry_matches_artifact(entry, artifact):
            return False
        path = _entry_path(entry, app_home)
        if path is None or not _verify_snapshot(path, artifact):
            return False
    return True


def _validate_model_store_paths(root: Path) -> None:
    if not root.exists():
        return
    if root.is_symlink():
        raise ModelStoreError("model store cannot contain a symlink root")
    for current, directories, files in os.walk(root, followlinks=False):
        current_path = Path(current)
        if any((current_path / name).is_symlink() for name in directories):
            raise ModelStoreError("model store contains a symlink directory")
        for name in files:
            path = current_path / name
            if path.is_symlink():
                raise ModelStoreError("model store contains a symlink file")


def _required_staging_bytes(
    cache_paths: Mapping[str, Path | None],
    artifacts: tuple[ModelArtifact, ...],
) -> int:
    return sum(
        item.size
        for artifact in artifacts
        if cache_paths[artifact.key] is None
        for item in artifact.files
    )


def _check_disk_space(
    models_root: Path,
    artifacts: tuple[ModelArtifact, ...],
    cache_paths: Mapping[str, Path | None],
    disk_usage: DiskUsage | None,
) -> None:
    usage = disk_usage(models_root) if disk_usage is not None else shutil.disk_usage(models_root)
    free = getattr(usage, "free", None)
    if type(free) is not int or free < 0:
        raise ModelStoreError("disk space information is unavailable")
    _validate_model_store_paths(models_root)
    required_bytes = _required_staging_bytes(cache_paths, artifacts)
    if free < required_bytes:
        raise ModelStoreError("insufficient disk space for missing model staging")


def _resolve_app_home(app_home: Path) -> Path:
    if not isinstance(app_home, Path) or not app_home.is_absolute():
        raise ModelStoreError("app_home must be an absolute path")
    try:
        resolved_app_home = app_home.resolve()
    except (OSError, RuntimeError) as exc:
        raise ModelStoreError("app_home cannot be resolved") from exc
    if app_home.is_symlink():
        raise ModelStoreError("app_home cannot be a symlink")
    return resolved_app_home


async def _stream_result(result: DownloadResult) -> DownloadStream:
    if inspect.isawaitable(result):
        return await result
    return result


async def _close_download_result(
    result: object, active_error: BaseException | None
) -> None:
    close = getattr(result, "aclose", None)
    if not callable(close):
        close = getattr(result, "close", None)
    if not callable(close):
        return

    try:
        close_result = close()
        if inspect.isawaitable(close_result):
            await close_result
    except asyncio.CancelledError:
        if isinstance(active_error, asyncio.CancelledError):
            return
        raise
    except Exception as exc:
        if active_error is not None:
            raise active_error from None
        raise _DownloadStreamCloseError("download stream close failed") from exc
    except BaseException:
        if isinstance(active_error, asyncio.CancelledError):
            return
        raise


async def _write_download(
    downloader: Downloader,
    source: SourceLocation,
    artifact: ModelArtifact,
    item_path: str,
    expected_size: int,
    expected_sha256: str,
    target: Path,
    *,
    prepared_id: str,
    progress: ProgressCallback | None,
    cancel_event: asyncio.Event | None,
) -> None:
    _check_cancel(cancel_event)
    total = 0
    digest = hashlib.sha256()

    async def write_chunk(chunk: object, output: object) -> None:
        nonlocal total
        _check_cancel(cancel_event)
        if not isinstance(chunk, (bytes, bytearray, memoryview)):
            raise ModelStoreError("downloader returned a non-byte chunk")
        data = bytes(chunk)
        if total + len(data) > expected_size:
            raise ModelStoreError(f"artifact file size exceeds manifest: {item_path}")
        assert hasattr(output, "write")
        output.write(data)
        digest.update(data)
        total += len(data)
        _emit(
            progress,
            {
                "phase": "download",
                "prepared_id": prepared_id,
                "artifact": artifact.key,
                "file": item_path,
                "bytes": total,
                "expected_bytes": expected_size,
            },
        )

    result = await _stream_result(downloader.download(source, item_path))
    active_error: BaseException | None = None
    try:
        try:
            descriptor = os.open(
                target,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
                0o600,
            )
        except OSError as exc:
            raise ModelStoreError("could not create staged model file") from exc
        with os.fdopen(descriptor, "wb") as output:
            if isinstance(result, (bytes, bytearray, memoryview)):
                await write_chunk(result, output)
            elif hasattr(result, "__aiter__"):
                async for chunk in cast(AsyncIterable[object], result):
                    await write_chunk(chunk, output)
            elif isinstance(result, Iterable):
                for chunk in result:
                    await write_chunk(chunk, output)
            else:
                raise ModelStoreError("downloader did not return a byte stream")
            if total != expected_size:
                raise ModelStoreError(f"artifact file size differs from manifest: {item_path}")
            if digest.hexdigest() != expected_sha256:
                raise ModelStoreError(f"artifact file hash differs from manifest: {item_path}")
            output.flush()
            os.fsync(output.fileno())
    except BaseException as exc:
        active_error = exc
        raise
    finally:
        await _close_download_result(result, active_error)


async def _download_artifact(
    artifact: ModelArtifact,
    stage_directory: Path,
    downloader: Downloader,
    *,
    prepared_id: str,
    progress: ProgressCallback | None,
    cancel_event: asyncio.Event | None,
    max_retries: int,
) -> SourceLocation:
    failure_kind = "download"
    for source in artifact.sources:
        for attempt in range(max_retries + 1):
            _check_cancel(cancel_event)
            _remove_tree(stage_directory)
            _ensure_directory(stage_directory)
            current_file = "<unknown>"
            try:
                for item in artifact.files:
                    current_file = item.path
                    target = safe_artifact_path(stage_directory, item.path)
                    _ensure_directory(target.parent)
                    await _write_download(
                        downloader,
                        source,
                        artifact,
                        item.path,
                        item.size,
                        item.sha256,
                        target,
                        prepared_id=prepared_id,
                        progress=progress,
                        cancel_event=cancel_event,
                    )
                if not _verify_snapshot(stage_directory, artifact):
                    raise ModelStoreError("staged snapshot does not match manifest")
                return source
            except asyncio.CancelledError:
                raise
            except _DownloadStreamCloseError:
                raise
            except Exception as exc:
                message = str(exc).lower()
                if "hash" in message:
                    failure_kind = "hash"
                elif "size" in message:
                    failure_kind = "size"
                elif "missing" in message:
                    failure_kind = "missing"
                _emit(
                    progress,
                    {
                        "phase": "retry",
                        "prepared_id": prepared_id,
                        "artifact": artifact.key,
                        "file": current_file,
                        "attempt": attempt + 1,
                    },
                )
    raise ModelStoreError(f"could not verify artifact {artifact.key} ({failure_kind})")


def _rollback_publication(
    published: list[Path], backups: list[tuple[Path, Path]]
) -> None:
    for destination in reversed(published):
        if destination.exists() or destination.is_symlink():
            _remove_tree(destination)
    for backup, destination in reversed(backups):
        if backup.exists() or backup.is_symlink():
            if destination.exists() or destination.is_symlink():
                _remove_tree(destination)
            backup.replace(destination)


def _move_existing_to_backup(
    destination: Path, models_root: Path, operation_id: str, artifact_key: str
) -> Path:
    backup = safe_artifact_path(
        models_root, f".releases/{operation_id}/{artifact_key}"
    )
    _ensure_directory(backup.parent.parent)
    _ensure_directory(backup.parent)
    if backup.exists() or backup.is_symlink():
        raise ModelStoreError("model rollback destination already exists")
    try:
        destination.replace(backup)
    except OSError as exc:
        raise ModelStoreError("could not preserve previous model snapshot") from exc
    return backup


def _update_moved_registry_paths(
    registry: dict[str, object], moved: Mapping[str, str]
) -> None:
    prepared = registry.get("prepared")
    if not isinstance(prepared, dict):
        return
    for candidate in prepared.values():
        if not isinstance(candidate, dict):
            continue
        artifacts = candidate.get("artifacts")
        if not isinstance(artifacts, dict):
            continue
        for entry in artifacts.values():
            if not isinstance(entry, dict):
                continue
            old_path = entry.get("path")
            if isinstance(old_path, str) and old_path in moved:
                entry["path"] = moved[old_path]


async def prepare_models(
    preset_id: str,
    *,
    app_home: Path,
    progress: ProgressCallback | None = None,
    downloader: Downloader,
    catalog: ModelCatalog | None = None,
    runtime_lock: RuntimeLock | None = None,
    cancel_event: asyncio.Event | None = None,
    max_retries: int = 2,
    disk_usage: DiskUsage | None = None,
) -> str:
    """Download a catalog preset into verified local snapshots and return its prepared ID."""
    if not isinstance(preset_id, str) or not preset_id:
        raise ModelStoreError("preset must be a non-empty string")
    if (
        not isinstance(max_retries, int)
        or isinstance(max_retries, bool)
        or not 0 <= max_retries <= _MAX_RETRIES
    ):
        raise ModelStoreError(f"max_retries must be between 0 and {_MAX_RETRIES}")
    if downloader is None or not callable(getattr(downloader, "download", None)):
        raise ModelStoreError("downloader must be injected")
    if catalog is None:
        catalog = load_catalog()
    elif not isinstance(catalog, ModelCatalog):
        raise ModelStoreError("catalog must be a ModelCatalog")
    if runtime_lock is None:
        runtime_lock = load_runtime_lock()
    elif not isinstance(runtime_lock, RuntimeLock):
        raise ModelStoreError("runtime_lock must be a RuntimeLock")

    try:
        selected_preset = catalog.preset(preset_id)
    except KeyError as exc:
        raise ModelStoreError(f"unknown preset: {preset_id}") from exc
    artifacts_by_key = {artifact.key: artifact for artifact in catalog.artifacts}
    try:
        artifacts = (artifacts_by_key[selected_preset.asr], artifacts_by_key[selected_preset.tts])
    except KeyError as exc:
        raise ModelStoreError(f"preset {preset_id} references an unknown artifact") from exc

    for artifact in artifacts:
        if not artifact.sources or not artifact.files:
            raise ModelStoreError(f"artifact {artifact.key} has no locked source or files")

    resolved_app_home = _resolve_app_home(app_home)

    prepared_id = _prepared_id(preset_id, runtime_lock, artifacts)
    models_root = resolved_app_home / "models"
    registry_path = _registry_path(resolved_app_home)
    registry = _read_registry(registry_path)
    if _prepared_entry_is_complete(
        registry, prepared_id, resolved_app_home, artifacts, runtime_lock, preset_id
    ):
        return prepared_id

    _ensure_directory(resolved_app_home)
    _ensure_directory(models_root)
    cache_paths = {
        artifact.key: _cache_path(registry, resolved_app_home, models_root, artifact)
        for artifact in artifacts
    }
    _check_disk_space(
        models_root,
        artifacts,
        cache_paths,
        disk_usage,
    )
    staging_root = models_root / ".staging"
    _ensure_directory(staging_root)
    operation_id = f"op_{uuid4().hex}"
    operation_root = safe_artifact_path(staging_root, operation_id)
    _ensure_directory(operation_root)
    stage_artifacts: dict[str, Path] = {}
    selected_sources: dict[str, SourceLocation] = {}

    try:
        for artifact in artifacts:
            destination = models_root / artifact.key
            if cache_paths[artifact.key] is not None:
                stage_artifacts[artifact.key] = safe_artifact_path(operation_root, artifact.key)
                _emit(
                    progress,
                    {"phase": "cache_hit", "prepared_id": prepared_id, "artifact": artifact.key},
                )
                continue
            stage_directory = safe_artifact_path(operation_root, artifact.key)
            stage_artifacts[artifact.key] = stage_directory
            source = await _download_artifact(
                artifact,
                stage_directory,
                downloader,
                prepared_id=prepared_id,
                progress=progress,
                cancel_event=cancel_event,
                max_retries=max_retries,
            )
            selected_sources[artifact.key] = source

        _check_cancel(cancel_event)
        next_registry = copy.deepcopy(registry)
        next_prepared = next_registry.get("prepared")
        if not isinstance(next_prepared, dict):
            raise ModelStoreError("model preparation registry schema is invalid")
        published: list[Path] = []
        backups: list[tuple[Path, Path]] = []
        moved_paths: dict[str, str] = {}
        try:
            entries: dict[str, object] = {}
            for artifact in artifacts:
                destination = models_root / artifact.key
                stage_directory = stage_artifacts[artifact.key]
                cache_hit = cache_paths[artifact.key]
                if cache_hit is not None:
                    source = artifact.sources[0]
                    entries[artifact.key] = _artifact_entry(
                        artifact, path=f"models/{artifact.key}", source=source
                    )
                    _remove_tree(stage_directory)
                    continue

                if destination.is_symlink():
                    raise ModelStoreError("refusing symlink model destination")
                if stage_directory.is_symlink() or not stage_directory.is_dir():
                    raise ModelStoreError("verified staged snapshot is unavailable")
                if destination.exists():
                    backup = _move_existing_to_backup(
                        destination, models_root, operation_id, artifact.key
                    )
                    backups.append((backup, destination))
                    moved_paths[
                        f"models/{artifact.key}"
                    ] = f"models/.releases/{operation_id}/{artifact.key}"
                try:
                    stage_directory.replace(destination)
                except OSError as exc:
                    raise ModelStoreError("could not publish verified model snapshot") from exc
                published.append(destination)
                source = selected_sources.get(artifact.key, artifact.sources[0])
                entries[artifact.key] = _artifact_entry(
                    artifact, path=f"models/{artifact.key}", source=source
                )

            _update_moved_registry_paths(next_registry, moved_paths)
            next_prepared[prepared_id] = {
                "preset": preset_id,
                "runtime_lock_id": runtime_lock.id,
                "artifacts": entries,
            }
            _write_registry(registry_path, next_registry)
        except BaseException:
            _rollback_publication(published, backups)
            raise

        _emit(progress, {"phase": "verified", "prepared_id": prepared_id, "preset": preset_id})
        return prepared_id
    finally:
        _remove_tree(operation_root)
        if staging_root.exists() and not any(staging_root.iterdir()):
            staging_root.rmdir()


__all__ = ["Downloader", "ModelStoreError", "prepare_models", "safe_artifact_path"]
