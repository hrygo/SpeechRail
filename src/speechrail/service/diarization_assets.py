"""Prepare the immutable diarization assets required by a fresh macOS install."""
# ruff: noqa: E501

from __future__ import annotations

import asyncio
import hashlib
import os
import tempfile
from collections.abc import Callable, Iterator, Sequence
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Literal

import httpx

from speechrail.backends.diarization.coreml import (
    MODEL_BUNDLE_NAME,
    MODEL_DTYPE,
    MODEL_FILE_SHA256,
    MODEL_REVISION,
)
from speechrail.config.model_catalog import (
    ModelArtifact,
    ModelCatalog,
    SourceLocation,
    load_catalog,
)
from speechrail.service.model_store import (
    _read_integrity_cache,
    _write_integrity_cache,
    cached_file_hash,
)
from speechrail.service.modelscope import ModelScopeDownloader

_COREML_REPOSITORY = "FluidInference/diar-streaming-sortformer-coreml"
_COREML_PREFIX = "v3/fp16/SortformerNvidiaLow_v2.1.mlmodelc"
_COREML_FILE_SIZES = (202, 1094, 108, 633, 32524, 8948544, 108, 593, 1710332, 235580992)
_COREML_KEY = "diarization-coreml"
_COREML_PROVIDER = "huggingface"
ProgressCallback = Callable[[dict[str, object]], None]
DiarizationIntegrity = Literal["verified", "mismatch", "not_checked"]
DiarizationState = Literal["not_downloaded", "verified", "invalid"]


@dataclass(frozen=True, slots=True)
class DiarizationArtifactStatus:
    """Path-free status for one locked diarization asset."""

    key: str
    state: DiarizationState
    integrity: DiarizationIntegrity
    verified_file_count: int
    total_file_count: int


def _emit(progress: ProgressCallback | None, event: dict[str, object]) -> None:
    if progress is None:
        return
    try:
        progress(event)
    except asyncio.CancelledError:
        raise
    except Exception:
        return


@dataclass(frozen=True, slots=True)
class DiarizationAssetPaths:
    """Verified local paths consumed by the managed installer."""

    coreml_model_path: Path
    aligner_model_dir: Path


class DiarizationAssetError(RuntimeError):
    """A locked diarization asset could not be safely prepared."""


def _validated_relative(path: str) -> PurePosixPath:
    candidate = PurePosixPath(path)
    if candidate.is_absolute() or any(part in {"", ".", ".."} for part in candidate.parts):
        raise DiarizationAssetError("invalid locked diarization artifact path")
    return candidate


def _huggingface_fetch(
    client: httpx.Client, *, repository: str, revision: str, prefix: str
) -> Callable[[str], Iterator[bytes]]:
    def fetch(relative_path: str) -> Iterator[bytes]:
        relative = _validated_relative(relative_path)
        remote = f"{prefix}/{relative.as_posix()}" if prefix else relative.as_posix()
        url = f"https://huggingface.co/{repository}/resolve/{revision}/{remote}"
        try:
            with client.stream("GET", url, follow_redirects=True) as response:
                response.raise_for_status()
                yield from response.iter_bytes(chunk_size=1024 * 1024)
        except httpx.HTTPError as exc:
            raise DiarizationAssetError("locked diarization artifact download failed") from exc

    return fetch


def _modelscope_fetch(
    downloader: ModelScopeDownloader, source: SourceLocation
) -> Callable[[str], Iterator[bytes]]:
    def fetch(relative_path: str) -> Iterator[bytes]:
        return downloader.download(source, relative_path)

    return fetch


def _write_file(
    blocks: Iterator[bytes],
    destination: Path,
    *,
    expected_size: int,
    expected_sha256: str,
    progress: ProgressCallback | None = None,
    cancel_event: asyncio.Event | None = None,
    artifact_key: str | None = None,
    prepared_id: str | None = None,
) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    digest = hashlib.sha256()
    size = 0
    try:
        with destination.open("xb") as output:
            for block in blocks:
                if cancel_event is not None and cancel_event.is_set():
                    raise asyncio.CancelledError
                if not isinstance(block, bytes):
                    raise DiarizationAssetError("downloader returned a non-byte block")
                size += len(block)
                if size > expected_size:
                    raise DiarizationAssetError("locked diarization artifact exceeds its manifest")
                digest.update(block)
                output.write(block)
                _emit(
                    progress,
                    {
                        "phase": "download",
                        "prepared_id": prepared_id,
                        "artifact": artifact_key,
                        "file": destination.name,
                        "bytes": size,
                        "expected_bytes": expected_size,
                    },
                )
            output.flush()
            os.fsync(output.fileno())
    except (httpx.HTTPError, OSError) as exc:
        raise DiarizationAssetError("locked diarization artifact download failed") from exc
    if size != expected_size or digest.hexdigest() != expected_sha256:
        raise DiarizationAssetError("locked diarization artifact integrity check failed")


def _verify_directory(root: Path, files: dict[str, tuple[int, str]]) -> bool:
    if root.is_symlink() or not root.is_dir():
        return False
    return all(
        (path := root / relative).is_file()
        and path.stat().st_size == expected[0]
        and _sha256(path) == expected[1]
        for relative, expected in files.items()
    )


def _inspect_directory(
    root: Path,
    files: dict[str, tuple[int, str]],
    *,
    persistent_cache: dict[str, dict[str, object]] | None = None,
) -> tuple[DiarizationIntegrity, int]:
    if root.is_symlink() or not root.is_dir():
        return "not_checked", 0
    actual: set[str] = set()
    verified = 0
    try:
        for current, directories, names in os.walk(root, followlinks=False):
            current_path = Path(current)
            if any((current_path / name).is_symlink() for name in directories):
                return "mismatch", verified
            for name in names:
                path = current_path / name
                if path.is_symlink() or not path.is_file():
                    return "mismatch", verified
                actual.add(path.relative_to(root).as_posix())
        integrity: DiarizationIntegrity = "verified" if actual == set(files) else "mismatch"
        for relative, (expected_size, expected_digest) in files.items():
            path = root / relative
            if (
                path.is_symlink()
                or not path.is_file()
                or path.stat().st_size != expected_size
                or cached_file_hash(path, persistent_cache=persistent_cache) != expected_digest
            ):
                integrity = "mismatch"
            else:
                verified += 1
        return integrity, verified
    except (OSError, ValueError, RuntimeError):
        return "mismatch", verified


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _publish_bundle(
    *,
    base: Path,
    name: str,
    files: dict[str, tuple[int, str]],
    fetch: Callable[[str], Iterator[bytes]],
    progress: ProgressCallback | None = None,
    cancel_event: asyncio.Event | None = None,
    prepared_id: str | None = None,
) -> Path:
    target = base / name
    if target.is_symlink():
        raise DiarizationAssetError("refusing symlink diarization asset")
    if target.exists():
        if not target.is_dir() or not _verify_directory(target, files):
            raise DiarizationAssetError("existing diarization asset does not match the locked manifest")
        _emit(
            progress,
            {"phase": "cache_hit", "prepared_id": prepared_id, "artifact": name},
        )
        return target
    staging_root = base / ".staging"
    if staging_root.is_symlink():
        raise DiarizationAssetError("refusing symlink diarization staging directory")
    staging_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    staging = Path(tempfile.mkdtemp(prefix=f"{name}.", dir=staging_root))
    try:
        _emit(
            progress,
            {"phase": "download", "prepared_id": prepared_id, "artifact": name},
        )
        for relative, (size, digest) in files.items():
            _write_file(
                fetch(relative),
                staging / relative,
                expected_size=size,
                expected_sha256=digest,
                progress=progress,
                cancel_event=cancel_event,
                artifact_key=name,
                prepared_id=prepared_id,
            )
        _emit(
            progress,
            {"phase": "verifying", "prepared_id": prepared_id, "artifact": name},
        )
        if cancel_event is not None and cancel_event.is_set():
            raise asyncio.CancelledError
        if not _verify_directory(staging, files):
            raise DiarizationAssetError("staged diarization asset failed verification")
        _emit(
            progress,
            {"phase": "publishing", "prepared_id": prepared_id, "artifact": name},
        )
        staging.replace(target)
        target.chmod(0o700)
        return target
    except BaseException:
        if staging.exists():
            import shutil
            shutil.rmtree(staging, ignore_errors=True)
        raise


def _artifact_for(catalog: ModelCatalog, key: str) -> ModelArtifact:
    for artifact in catalog.artifacts:
        if artifact.key == key:
            return artifact
    raise DiarizationAssetError(f"diarization asset is not in the catalog: {key}")


def _canonical_source(artifact: ModelArtifact) -> SourceLocation:
    for source in artifact.sources:
        if source.provider == "modelscope":
            return source
    raise DiarizationAssetError(f"diarization asset has no ModelScope source: {artifact.key}")


def prepare_diarization_assets(
    app_home: Path,
    *,
    preset_id: str,
    downloader: ModelScopeDownloader,
    catalog: ModelCatalog | None = None,
    progress: ProgressCallback | None = None,
    cancel_event: asyncio.Event | None = None,
    prepared_id: str | None = None,
) -> DiarizationAssetPaths | None:
    """Provision the diarization assets a profile requires, or ``None`` when gated off."""
    try:
        selected_catalog = load_catalog() if catalog is None else catalog
        preset = selected_catalog.preset(preset_id)
    except KeyError as exc:
        raise DiarizationAssetError(f"unknown diarization preset: {preset_id}") from exc
    if not preset.diarization:
        return None

    base = app_home / "diarization"
    if base.is_symlink():
        raise DiarizationAssetError("refusing symlink diarization directory")
    base.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not base.is_dir() or base.is_symlink():
        raise DiarizationAssetError("diarization path is not a directory")

    coreml_files = {
        key: (size, MODEL_FILE_SHA256[key])
        for key, size in zip(MODEL_FILE_SHA256, _COREML_FILE_SIZES, strict=True)
    }
    coreml = _publish_bundle(
        base=base,
        name=MODEL_BUNDLE_NAME,
        files=coreml_files,
        fetch=_huggingface_fetch(
            downloader.client, repository=_COREML_REPOSITORY, revision=MODEL_REVISION, prefix=_COREML_PREFIX
        ),
        progress=progress,
        cancel_event=cancel_event,
        prepared_id=prepared_id,
    )

    aligner_key = preset.aligner
    if aligner_key is None:
        raise DiarizationAssetError(f"preset declares diarization without an aligner: {preset_id}")
    aligner_artifact = _artifact_for(selected_catalog, aligner_key)
    aligner_files = {file.path: (file.size, file.sha256) for file in aligner_artifact.files}
    aligner = _publish_bundle(
        base=base,
        name=aligner_key,
        files=aligner_files,
        fetch=_modelscope_fetch(downloader, _canonical_source(aligner_artifact)),
        progress=progress,
        cancel_event=cancel_event,
        prepared_id=prepared_id,
    )

    return DiarizationAssetPaths(coreml_model_path=coreml, aligner_model_dir=aligner)


def inspect_diarization_assets(
    app_home: Path,
    *,
    preset_id: str,
    catalog: ModelCatalog | None = None,
) -> tuple[DiarizationArtifactStatus, ...]:
    """Return path-free status for the CoreML and aligner assets of a preset."""
    if not isinstance(app_home, Path) or not app_home.is_absolute():
        raise DiarizationAssetError("app_home must be an absolute path")
    if app_home.is_symlink():
        raise DiarizationAssetError("app_home cannot be a symlink")
    selected_catalog = load_catalog() if catalog is None else catalog
    if not isinstance(selected_catalog, ModelCatalog):
        raise DiarizationAssetError("catalog must be a ModelCatalog")
    try:
        preset = selected_catalog.preset(preset_id)
    except KeyError as exc:
        raise DiarizationAssetError(f"unknown diarization preset: {preset_id}") from exc
    if not preset.diarization:
        return ()
    resolved_app_home = app_home.resolve()
    base = resolved_app_home / "diarization"
    base_is_symlink = base.is_symlink()
    persistent_cache = _read_integrity_cache(resolved_app_home)
    initial_cache_len = len(persistent_cache)

    coreml_files = {
        key: (size, MODEL_FILE_SHA256[key])
        for key, size in zip(MODEL_FILE_SHA256, _COREML_FILE_SIZES, strict=True)
    }
    aligner_key = preset.aligner
    if aligner_key is None:
        raise DiarizationAssetError(f"preset declares diarization without an aligner: {preset_id}")
    aligner_artifact = _artifact_for(selected_catalog, aligner_key)
    aligner_files = {file.path: (file.size, file.sha256) for file in aligner_artifact.files}

    result: list[DiarizationArtifactStatus] = []
    for key, root, files in (
        (_COREML_KEY, base / MODEL_BUNDLE_NAME, coreml_files),
        (aligner_key, base / aligner_key, aligner_files),
    ):
        integrity: DiarizationIntegrity
        if base_is_symlink:
            integrity, verified_count = "mismatch", 0
        else:
            integrity, verified_count = _inspect_directory(
                root, files, persistent_cache=persistent_cache
            )
        state: DiarizationState = (
            "not_downloaded"
            if integrity == "not_checked"
            else "verified"
            if integrity == "verified"
            else "invalid"
        )
        result.append(
            DiarizationArtifactStatus(
                key=key,
                state=state,
                integrity=integrity,
                verified_file_count=verified_count,
                total_file_count=len(files),
            )
        )
    if len(persistent_cache) != initial_cache_len:
        _write_integrity_cache(resolved_app_home, persistent_cache)
    return tuple(result)


def coreml_diarization_row(*, required_by: Sequence[str]) -> dict[str, object]:
    """Describe the locked CoreML asset with the same fields as a catalog artifact.

    The asset is not a catalog artifact: it ships as a CoreML bundle with its own
    manifest, so ``prepare_models`` and the model store never touch it. Emitting
    the same row shape lets the control plane hand the UI one table of every file
    a profile needs, instead of the same asset being listed both as a diarization
    input and as a file that is not registered for the profile (2026-09-23).
    """
    return {
        "key": _COREML_KEY,
        "model_id": _COREML_REPOSITORY,
        "family": "coreml_sortformer",
        "variant": "diarization",
        "revision": MODEL_REVISION,
        "provider": _COREML_PROVIDER,
        "repository": _COREML_REPOSITORY,
        # 没有量化，精度由上游发布的 FP16 变体决定——和目录里 `aligner-bf16` 同一形状。
        "quantization": {
            "bits": None,
            "group_size": None,
            "format": "none",
            "dtype": MODEL_DTYPE,
        },
        "size_bytes": sum(_COREML_FILE_SIZES),
        "file_count": len(MODEL_FILE_SHA256),
        "required_by": list(required_by),
    }


__all__ = [
    "DiarizationArtifactStatus",
    "DiarizationAssetError",
    "DiarizationAssetPaths",
    "coreml_diarization_row",
    "inspect_diarization_assets",
    "prepare_diarization_assets",
]
