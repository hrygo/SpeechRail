"""Prepare the immutable diarization assets required by a fresh macOS install."""
# ruff: noqa: E501

from __future__ import annotations

import hashlib
import os
import tempfile
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

import httpx

from speechrail.backends.diarization.coreml import (
    MODEL_BUNDLE_NAME,
    MODEL_FILE_SHA256,
    MODEL_REVISION,
)
from speechrail.config.model_catalog import (
    ModelArtifact,
    ModelCatalog,
    SourceLocation,
    load_catalog,
)
from speechrail.service.modelscope import ModelScopeDownloader

_COREML_REPOSITORY = "FluidInference/diar-streaming-sortformer-coreml"
_COREML_PREFIX = "v3/fp16/SortformerNvidiaLow_v2.1.mlmodelc"
_COREML_FILE_SIZES = (202, 1094, 108, 633, 32524, 8948544, 108, 593, 1710332, 235580992)


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
    blocks: Iterator[bytes], destination: Path, *, expected_size: int, expected_sha256: str
) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    digest = hashlib.sha256()
    size = 0
    try:
        with destination.open("xb") as output:
            for block in blocks:
                size += len(block)
                digest.update(block)
                output.write(block)
            output.flush()
            os.fsync(output.fileno())
    except (httpx.HTTPError, OSError) as exc:
        raise DiarizationAssetError("locked diarization artifact download failed") from exc
    if size != expected_size or digest.hexdigest() != expected_sha256:
        raise DiarizationAssetError("locked diarization artifact integrity check failed")


def _verify_directory(root: Path, files: dict[str, tuple[int, str]]) -> bool:
    return all(
        (path := root / relative).is_file()
        and path.stat().st_size == expected[0]
        and _sha256(path) == expected[1]
        for relative, expected in files.items()
    )


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _publish_bundle(
    *, base: Path, name: str, files: dict[str, tuple[int, str]], fetch: Callable[[str], Iterator[bytes]]
) -> Path:
    target = base / name
    if target.exists():
        if not target.is_dir() or not _verify_directory(target, files):
            raise DiarizationAssetError("existing diarization asset does not match the locked manifest")
        return target
    staging_root = base / ".staging"
    staging_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    staging = Path(tempfile.mkdtemp(prefix=f"{name}.", dir=staging_root))
    try:
        for relative, (size, digest) in files.items():
            _write_file(fetch(relative), staging / relative, expected_size=size, expected_sha256=digest)
        if not _verify_directory(staging, files):
            raise DiarizationAssetError("staged diarization asset failed verification")
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
    app_home: Path, *, preset_id: str, downloader: ModelScopeDownloader
) -> DiarizationAssetPaths | None:
    """Provision the diarization assets a profile requires, or ``None`` when gated off."""
    try:
        catalog = load_catalog()
        preset = catalog.preset(preset_id)
    except KeyError as exc:
        raise DiarizationAssetError(f"unknown diarization preset: {preset_id}") from exc
    if not preset.diarization:
        return None

    base = app_home / "diarization"
    base.mkdir(parents=True, exist_ok=True, mode=0o700)

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
    )

    aligner_key = preset.aligner
    if aligner_key is None:
        raise DiarizationAssetError(f"preset declares diarization without an aligner: {preset_id}")
    aligner_artifact = _artifact_for(catalog, aligner_key)
    aligner_files = {file.path: (file.size, file.sha256) for file in aligner_artifact.files}
    aligner = _publish_bundle(
        base=base,
        name=aligner_key,
        files=aligner_files,
        fetch=_modelscope_fetch(downloader, _canonical_source(aligner_artifact)),
    )

    return DiarizationAssetPaths(coreml_model_path=coreml, aligner_model_dir=aligner)


__all__ = ["DiarizationAssetError", "DiarizationAssetPaths", "prepare_diarization_assets"]
