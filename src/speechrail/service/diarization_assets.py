"""Prepare the immutable diarization assets required by a fresh macOS install."""
# ruff: noqa: E501

from __future__ import annotations

import hashlib
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

import httpx

from speechrail.backends.diarization.coreml import (
    MODEL_BUNDLE_NAME,
    MODEL_FILE_SHA256,
    MODEL_REVISION,
)

_ALIGNER_REPOSITORY = "Qwen/Qwen3-ForcedAligner-0.6B"
_ALIGNER_REVISION = "c7cbfc2048c462b0d63a45797104fc9db3ad62b7"
_COREML_REPOSITORY = "FluidInference/diar-streaming-sortformer-coreml"
_COREML_PREFIX = "v3/fp16/SortformerNvidiaLow_v2.1.mlmodelc"
_ALIGNER_FILES = {
    ".gitattributes": (2176, "8ed34f37f96b1fa39d6bf0a0bf050a6a73ee22e4d9ff46de66f2522a63aec472"),
    "README.md": (57456, "5058416891bc47a2051557765997e8c42f8eb78a0e33c3e775bd17d4b0ba4d50"),
    "chat_template.json": (1161, "75a8cfca24f00de72d796fbfed6858fc9614ef3dabd8696684cc3bc03a9c58ff"),
    "config.json": (5982, "d616c65d46c4b90bdc651b0a0963ea932732241140f337f9bb6b0335a9c8ef09"),
    "configuration.json": (56, "c57f6a580d63f7465c6a22ba95847aee05a1ae1181f5abddffb943d9febda061"),
    "generation_config.json": (115, "948d089b23bca1d214e768d59c4438365665f52ec6d33678f4062206b3fbbb8c"),
    "merges.txt": (1671853, "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
    "model.safetensors": (1835544544, "47831d0e82f96b20e9034dba01a075ee06436654719f6a68289e49f1b65ce0e7"),
    "preprocessor_config.json": (330, "45e120a4eda2c20c5d7f2ea9354e63536bf35e27aa573fb7cdf78017b378770d"),
    "tokenizer_config.json": (12666, "3ab80063f8511deb9566e6ad438d17b7a6277fcffd52d92854112f19d36bd81c"),
    "vocab.json": (2776833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
}


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


def _download_file(
    client: httpx.Client, *, repository: str, revision: str, relative_path: str, destination: Path,
    expected_size: int, expected_sha256: str,
) -> None:
    relative = _validated_relative(relative_path)
    url = f"https://huggingface.co/{repository}/resolve/{revision}/{relative.as_posix()}"
    digest = hashlib.sha256()
    size = 0
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        with client.stream("GET", url, follow_redirects=True) as response:
            response.raise_for_status()
            with destination.open("xb") as output:
                for block in response.iter_bytes(chunk_size=1024 * 1024):
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
    client: httpx.Client, *, base: Path, name: str, repository: str, revision: str,
    files: dict[str, tuple[int, str]], prefix: str = "",
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
            remote = f"{prefix}/{relative}" if prefix else relative
            _download_file(client, repository=repository, revision=revision, relative_path=remote,
                           destination=staging / relative, expected_size=size, expected_sha256=digest)
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


def prepare_diarization_assets(app_home: Path, *, client: httpx.Client) -> DiarizationAssetPaths:
    """Download, hash-check and atomically publish both fresh-install assets."""
    base = app_home / "diarization"
    base.mkdir(parents=True, exist_ok=True, mode=0o700)
    # CoreML byte sizes are also locked so a truncated, hash-collision-free fixture cannot publish.
    coreml_sizes = (202, 1094, 108, 633, 32524, 8948544, 108, 593, 1710332, 235580992)
    coreml_files = {key: (size, MODEL_FILE_SHA256[key]) for key, size in zip(MODEL_FILE_SHA256, coreml_sizes, strict=True)}
    coreml = _publish_bundle(client, base=base, name=MODEL_BUNDLE_NAME, repository=_COREML_REPOSITORY,
                             revision=MODEL_REVISION, files=coreml_files, prefix=_COREML_PREFIX)
    aligner = _publish_bundle(client, base=base, name="Qwen3-ForcedAligner-0.6B", repository=_ALIGNER_REPOSITORY,
                              revision=_ALIGNER_REVISION, files=_ALIGNER_FILES)
    return DiarizationAssetPaths(coreml_model_path=coreml, aligner_model_dir=aligner)


__all__ = ["DiarizationAssetError", "DiarizationAssetPaths", "prepare_diarization_assets"]
