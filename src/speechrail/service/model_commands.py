"""Safe model catalog, status and preparation commands for the local control plane."""

from __future__ import annotations

import asyncio
import os
import shutil
from collections.abc import Mapping
from pathlib import Path

from speechrail.config.model_catalog import (
    ModelArtifact,
    ModelCatalog,
    RuntimeLock,
    load_catalog,
    load_runtime_lock,
)
from speechrail.domain.model_spec import ModelRole, required_spec_artifact, required_spec_bindings
from speechrail.service.diarization_assets import inspect_diarization_assets
from speechrail.service.model_store import (
    DiskUsage,
    Downloader,
    ModelStoreError,
    ProgressCallback,
    inspect_prepared_artifacts,
    model_store_root,
    prepare_spec_models,
)


def _selected_catalog(catalog: ModelCatalog | None) -> ModelCatalog:
    selected = load_catalog() if catalog is None else catalog
    if not isinstance(selected, ModelCatalog):
        raise ModelStoreError("catalog must be a ModelCatalog")
    return selected


def _canonical_source(artifact: ModelArtifact) -> Mapping[str, str]:
    for source in artifact.sources:
        if source.revision == artifact.revision:
            return {
                "provider": source.provider,
                "repository": source.repository,
            }
    raise ModelStoreError("model catalog source is inconsistent")


_SPEC_ORDER: tuple[str, ...] = ("fast", "quality", "reference")
_SUMMARY_ROLES: tuple[tuple[str, ModelRole], ...] = (
    ("asr", "asr"),
    ("tts", "tts_custom_voice"),
    ("tts_base", "tts_base"),
    ("voice_design", "voice_design"),
    ("aligner", "alignment"),
)


def _artifact_required_by(catalog: ModelCatalog, key: str) -> list[str]:
    """Return the spec tiers that explicitly bind this artifact key."""
    bound: list[str] = []
    for tier, _role, artifact_key in required_spec_bindings():
        if artifact_key == key and tier not in bound:
            bound.append(tier)
    return sorted(bound, key=_SPEC_ORDER.index)


def model_catalog_payload(*, catalog: ModelCatalog | None = None) -> dict[str, object]:
    """Return the locked model catalog without paths, URLs or file hashes.

    Rows cover every file a profile needs: the catalog artifacts plus the locked
    CoreML diarization asset, which is not a catalog artifact but is supplied per
    profile by the diarization lane.
    """
    selected = _selected_catalog(catalog)
    artifacts_by_key = {artifact.key: artifact for artifact in selected.artifacts}
    artifacts: list[dict[str, object]] = []
    bound_keys = {artifact_key for _tier, _role, artifact_key in required_spec_bindings()}
    for artifact in selected.artifacts:
        if artifact.key not in bound_keys:
            continue
        required_by = _artifact_required_by(selected, artifact.key)
        if not required_by:
            continue
        source = _canonical_source(artifact)
        artifacts.append(
            {
                "key": artifact.key,
                "model_id": artifact.model_id,
                "family": artifact.family,
                "variant": artifact.variant,
                "revision": artifact.revision,
                "provider": source["provider"],
                "repository": source["repository"],
                "quantization": artifact.quantization.model_dump(mode="json"),
                "size_bytes": sum(item.size for item in artifact.files),
                "file_count": len(artifact.files),
                "required_by": required_by,
            }
        )

    profiles = [
        _profile_payload(tier, artifacts_by_key) for tier in _SPEC_ORDER
    ]
    # 「这一档要用的文件」还包括一份不在目录里的 CoreML 分人资产 (它是 CoreML
    # bundle, 有自己的 manifest, 不走 prepare_models)。分人是任务 opt-in, 不再
    # 绑定档位, 用 required_by=["diarization"] 标记它可按任务准备。
    from speechrail.service.diarization_assets import coreml_diarization_row

    artifacts.append(coreml_diarization_row(required_by=["diarization"]))
    return {
        "schema_version": 2,
        "command": "model.catalog",
        "status": "ok",
        "artifacts": artifacts,
        "profiles": profiles,
    }


def _profile_payload(
    tier: str, artifacts_by_key: Mapping[str, ModelArtifact]
) -> dict[str, object]:
    """Build one spec-tier row from its explicit role bindings."""
    # ModelCatalog exposes immutable Pydantic models; keep this helper private so
    # the public payload stays a plain, path-free mapping.
    bindings = {
        name: required_spec_artifact(tier, role)  # type: ignore[arg-type]
        for name, role in _SUMMARY_ROLES
    }
    download_bytes = sum(
        item.size
        for key in bindings.values()
        if key is not None and key in artifacts_by_key
        for item in artifacts_by_key[key].files
    )
    return {
        "id": tier,
        "asr": bindings["asr"],
        "tts": bindings["tts"],
        "tts_base": bindings["tts_base"],
        "voice_design": bindings["voice_design"],
        "aligner": bindings["aligner"],
        "download_bytes": download_bytes,
    }


def _model_bytes(models_root: Path) -> int:
    if not models_root.is_dir() or models_root.is_symlink():
        return 0
    total = 0
    for current, directories, files in os.walk(models_root, followlinks=False):
        current_path = Path(current)
        directories[:] = [
            name for name in directories if not (current_path / name).is_symlink()
        ]
        for name in files:
            path = current_path / name
            if path.is_symlink():
                continue
            try:
                total += path.stat().st_size
            except OSError:
                continue
    return total


def _read_disk_usage(
    root: Path, models_root: Path, disk_usage: DiskUsage | None
) -> tuple[int, int]:
    usage = disk_usage(root) if disk_usage is not None else shutil.disk_usage(root)
    free = getattr(usage, "free", None)
    if type(free) is not int or free < 0:
        raise ModelStoreError("disk space information is unavailable")
    return free, _model_bytes(models_root)


def model_status_payload(
    app_home: Path,
    *,
    catalog: ModelCatalog | None = None,
    runtime_lock: RuntimeLock | None = None,
    disk_usage: DiskUsage | None = None,
) -> dict[str, object]:
    """Return current preparation state and disk summary without local paths."""
    selected = _selected_catalog(catalog)
    if runtime_lock is not None and not isinstance(runtime_lock, RuntimeLock):
        raise ModelStoreError("runtime_lock must be a RuntimeLock")
    if not isinstance(app_home, Path) or not app_home.is_absolute():
        raise ModelStoreError("app_home must be an absolute path")
    resolved_home = app_home.resolve()
    statuses = inspect_prepared_artifacts(
        resolved_home,
        catalog=selected,
        runtime_lock=runtime_lock,
    )
    diarization_by_key = {}
    for aligner_key in sorted(
        {
            artifact_key
            for _tier, role, artifact_key in required_spec_bindings()
            if role == "alignment"
        }
    ):
        for item in inspect_diarization_assets(
            resolved_home,
            aligner_key=aligner_key,
            catalog=selected,
        ):
            diarization_by_key[item.key] = item
    usage_root = resolved_home if resolved_home.exists() else resolved_home.parent
    free_bytes, model_bytes = _read_disk_usage(
        usage_root, model_store_root(resolved_home), disk_usage
    )
    return {
        "schema_version": 1,
        "command": "model.status",
        "status": "ok",
        "artifacts": [
            {
                "key": item.key,
                "state": item.state,
                "integrity": item.integrity,
                "verified_file_count": item.verified_file_count,
                "total_file_count": item.total_file_count,
            }
            for item in statuses
        ],
        "diarization": [
            {
                "key": item.key,
                "state": item.state,
                "integrity": item.integrity,
                "verified_file_count": item.verified_file_count,
                "total_file_count": item.total_file_count,
            }
            for item in diarization_by_key.values()
        ],
        "disk": {"model_bytes": model_bytes, "free_bytes": free_bytes},
    }


async def prepare_selected_models(
    asr_spec: str,
    tts_spec: str,
    app_home: Path,
    *,
    progress: ProgressCallback | None = None,
    cancel_event: asyncio.Event | None = None,
    downloader: Downloader | None = None,
    catalog: ModelCatalog | None = None,
    runtime_lock: RuntimeLock | None = None,
    disk_usage: DiskUsage | None = None,
) -> str:
    """Prepare only the two explicitly selected spec artifacts, opt-in only."""
    if downloader is None:
        raise ModelStoreError("downloader must be injected")
    selected = _selected_catalog(catalog)
    selected_lock = load_runtime_lock() if runtime_lock is None else runtime_lock
    if not isinstance(selected_lock, RuntimeLock):
        raise ModelStoreError("runtime_lock must be a RuntimeLock")
    if asr_spec not in _SPEC_ORDER or tts_spec not in _SPEC_ORDER:
        raise ModelStoreError("unknown spec tier")
    return await prepare_spec_models(
        asr_spec,  # type: ignore[arg-type]
        tts_spec,  # type: ignore[arg-type]
        app_home=app_home,
        progress=progress,
        downloader=downloader,
        catalog=selected,
        runtime_lock=selected_lock,
        cancel_event=cancel_event,
        disk_usage=disk_usage,
    )


__all__ = [
    "model_catalog_payload",
    "model_status_payload",
    "prepare_selected_models",
]
