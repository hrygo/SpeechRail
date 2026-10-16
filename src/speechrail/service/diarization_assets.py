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
    aligner_key: str,
    downloader: ModelScopeDownloader,
    catalog: ModelCatalog | None = None,
    progress: ProgressCallback | None = None,
    cancel_event: asyncio.Event | None = None,
    prepared_id: str | None = None,
) -> DiarizationAssetPaths:
    """Provision the explicit opt-in diarization assets for a task.

    Diarization is a task-time option, not a spec tier, so the caller names the
    aligner artifact it wants instead of inheriting one from a removed preset.
    """
    selected_catalog = load_catalog() if catalog is None else catalog
    aligner_artifact = _artifact_for(selected_catalog, aligner_key)
    if aligner_artifact.family != "qwen3_forced_aligner" or aligner_artifact.variant != "aligner":
        raise DiarizationAssetError(
            f"diarization aligner artifact has the wrong role: {aligner_key}"
        )

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
    aligner_key: str,
    catalog: ModelCatalog | None = None,
) -> tuple[DiarizationArtifactStatus, ...]:
    """Return path-free status for the CoreML bundle plus one explicit aligner."""
    if not isinstance(app_home, Path) or not app_home.is_absolute():
        raise DiarizationAssetError("app_home must be an absolute path")
    if app_home.is_symlink():
        raise DiarizationAssetError("app_home cannot be a symlink")
    selected_catalog = load_catalog() if catalog is None else catalog
    if not isinstance(selected_catalog, ModelCatalog):
        raise DiarizationAssetError("catalog must be a ModelCatalog")
    resolved_app_home = app_home.resolve()
    base = resolved_app_home / "diarization"
    base_is_symlink = base.is_symlink()
    persistent_cache = _read_integrity_cache(resolved_app_home)
    initial_cache_len = len(persistent_cache)

    coreml_files = {
        key: (size, MODEL_FILE_SHA256[key])
        for key, size in zip(MODEL_FILE_SHA256, _COREML_FILE_SIZES, strict=True)
    }
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
        # 没有量化, 精度由上游发布的 FP16 变体决定——和目录里 `aligner-bf16` 同一形状。
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


MEETING_MODEL_REVISION = '7eab74f3463c736418d0eb10296261ae581146c9'
MEETING_MODEL_REPOSITORY = 'FluidInference/speaker-diarization-coreml'
MEETING_MODEL_FILES: dict[str, tuple[int, str]] = {
    'Embedding.mlmodelc/analytics/coremldata.bin': (243, '8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682'),
    'Embedding.mlmodelc/coremldata.bin': (704, '4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004'),
    'Embedding.mlmodelc/metadata.json': (2818, '1854371eb6b438fb8aeac96afb45c999af7902581c06afdfcd7ff3cb1ce66be5'),
    'Embedding.mlmodelc/model.mil': (78432, '22fa958aef72a561c21f874a07cbdcd30fdf40ee961c0bc2fb67c119273b46d3'),
    'Embedding.mlmodelc/weights/weight.bin': (13412288, '99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b'),
    'FBank.mlmodelc/analytics/coremldata.bin': (243, '0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a'),
    'FBank.mlmodelc/coremldata.bin': (853, '57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759'),
    'FBank.mlmodelc/metadata.json': (3409, '2623785f5d186893b82d01e84aa33a7704ef763c3309e02055f22dc9d871ce9a'),
    'FBank.mlmodelc/model.mil': (15667, '27aaeb21569e81bdbe2eef87789f50a37cfea800039bd134448a9417de2f30ed'),
    'FBank.mlmodelc/weights/weight.bin': (1776896, '9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36'),
    'NOTICE.md': (4247, 'd8e53d399c5345cabc4763732ba096e7e18ff42c861d57b73edb73b0c9ce9356'),
    'PROVENANCE.md': (3377, '0032bc1b7d01b6af2bb6eb8548a39c9a28fe5c1909f74166bc2ea2eb1cc27df6'),
    'PldaRho.mlmodelc/analytics/coremldata.bin': (243, '8940ea6044dbcbefa22da8cc41e0b485e1fb5ed89aecaf37c6e0c483a97ddcd7'),
    'PldaRho.mlmodelc/coremldata.bin': (763, '4d9741477f721c79b09fcdfe455110c4b7d4272e2de3496bf1729d966d3ee418'),
    'PldaRho.mlmodelc/metadata.json': (2749, 'b314cf25a93e46b4076883a6f5a2f8848b73c3851bd9d36074d067f35a1c7945'),
    'PldaRho.mlmodelc/model.mil': (7613, '83aee2e5310d19b5f202aea97d07a0e12102556d1b32ef3ed08b36f7f9725041'),
    'PldaRho.mlmodelc/weights/weight.bin': (200192, '80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36'),
    'Segmentation.mlmodelc/analytics/coremldata.bin': (243, '64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb'),
    'Segmentation.mlmodelc/coremldata.bin': (812, 'ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc'),
    'Segmentation.mlmodelc/metadata.json': (3410, '88dbf0b07208fe142e1729c2b4c974ad3599fcb2ae5d5f18fce782b225384124'),
    'Segmentation.mlmodelc/model.mil': (43063, 'd37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f'),
    'Segmentation.mlmodelc/weights/weight.bin': (5959360, 'c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2'),
    'plda-parameters.json': (89416, '38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f'),
    'provenance.json': (10048, '0353430db062715c411ba32e66cb435b9caee2662bccdb298f9e5d1bae760872'),
}


def inspect_meeting_dynamic_assets(root: Path, *, files: dict[str, tuple[int, str]] | None = None) -> bool:
    """Verify only local bytes; this function never prepares, loads or downloads."""
    expected = MEETING_MODEL_FILES if files is None else files
    if _inspect_directory(root, expected)[0] != "verified":
        return False
    try:
        import base64
        import json
        import math
        import struct
        tensors = json.loads((root / "plda-parameters.json").read_text())["tensors"]
        raw = base64.b64decode(tensors["psi"]["data_base64"], validate=True)
        if not raw or len(raw) % 4:
            return False
        values = struct.unpack("<" + "f" * (len(raw) // 4), raw)
        return all(math.isfinite(value) and value > 0 for value in values)
    except (KeyError, TypeError, ValueError, OSError):
        return False


def prepare_meeting_dynamic_assets(base: Path, *,
    fetch: Callable[[str], Iterator[bytes]] | None = None,
    files: dict[str, tuple[int, str]] | None = None,
    progress: ProgressCallback | None = None) -> Path:
    """Explicit preparation, same verified staging/publish chain as Sortformer."""
    if not base.is_absolute() or base.is_symlink():
        raise DiarizationAssetError("invalid meeting diarization preparation directory")
    locked = MEETING_MODEL_FILES if files is None else files
    name = "meeting-dynamic-" + MEETING_MODEL_REVISION
    if fetch is not None:
        return _publish_bundle(base=base, name=name, files=locked, fetch=fetch, progress=progress)
    with httpx.Client(timeout=60, follow_redirects=True) as client:
        return _publish_bundle(base=base, name=name, files=locked,
            fetch=_huggingface_fetch(client, repository=MEETING_MODEL_REPOSITORY,
                revision=MEETING_MODEL_REVISION, prefix=""), progress=progress)
