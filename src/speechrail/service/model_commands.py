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
    ModelPreset,
    PresetId,
    RuntimeLock,
    load_catalog,
    load_runtime_lock,
)
from speechrail.service.diarization_assets import (
    inspect_diarization_assets,
    prepare_diarization_assets,
)
from speechrail.service.model_store import (
    DiskUsage,
    Downloader,
    ModelStoreError,
    ProgressCallback,
    inspect_prepared_artifacts,
    prepare_models,
)
from speechrail.service.modelscope import ModelScopeDownloader


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


def _artifact_required_by(catalog: ModelCatalog, key: str) -> list[PresetId]:
    required_by: list[PresetId] = []
    for profile in catalog.presets:
        references = (profile.asr, profile.tts, profile.tts_clone, profile.aligner)
        if key in references:
            required_by.append(profile.id)
    return required_by


def model_catalog_payload(*, catalog: ModelCatalog | None = None) -> dict[str, object]:
    """Return the locked model catalog without paths, URLs or file hashes."""
    selected = _selected_catalog(catalog)
    artifacts_by_key = {artifact.key: artifact for artifact in selected.artifacts}
    artifacts: list[dict[str, object]] = []
    for artifact in selected.artifacts:
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
        _profile_payload(profile, artifacts_by_key)
        for profile in selected.presets
    ]
    return {
        "schema_version": 1,
        "command": "model.catalog",
        "status": "ok",
        "artifacts": artifacts,
        "profiles": profiles,
    }


def _profile_payload(
    profile: ModelPreset, artifacts_by_key: Mapping[str, ModelArtifact]
) -> dict[str, object]:
    """Build a profile row after the catalog has supplied its references."""
    # ModelCatalog exposes immutable Pydantic models; keep this helper private so
    # the public payload stays a plain, path-free mapping.
    keys = [profile.asr, profile.tts]
    if profile.tts_clone is not None:
        keys.append(profile.tts_clone)
    if profile.aligner is not None:
        keys.append(profile.aligner)
    download_bytes = sum(
        item.size for key in keys for item in artifacts_by_key[key].files
    )
    if profile.diarization:
        from speechrail.service.diarization_assets import _COREML_FILE_SIZES

        download_bytes += sum(_COREML_FILE_SIZES)
    return {
        "id": profile.id,
        "asr": profile.asr,
        "tts": profile.tts,
        "tts_clone": profile.tts_clone,
        "aligner": profile.aligner,
        "diarization": profile.diarization,
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
    for preset in selected.presets:
        if not preset.diarization:
            continue
        for item in inspect_diarization_assets(
            resolved_home,
            preset_id=preset.id,
            catalog=selected,
        ):
            diarization_by_key[item.key] = item
    usage_root = resolved_home if resolved_home.exists() else resolved_home.parent
    free_bytes, model_bytes = _read_disk_usage(
        usage_root, resolved_home / "models", disk_usage
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


async def prepare_profile_models(
    preset: PresetId,
    app_home: Path,
    *,
    progress: ProgressCallback | None = None,
    cancel_event: asyncio.Event | None = None,
    downloader: Downloader | None = None,
    catalog: ModelCatalog | None = None,
    runtime_lock: RuntimeLock | None = None,
    disk_usage: DiskUsage | None = None,
) -> str:
    """Prepare one profile's locked models without changing active selection."""
    if downloader is None:
        raise ModelStoreError("downloader must be injected")
    selected = _selected_catalog(catalog)
    selected_lock = load_runtime_lock() if runtime_lock is None else runtime_lock
    if not isinstance(selected_lock, RuntimeLock):
        raise ModelStoreError("runtime_lock must be a RuntimeLock")
    try:
        selected_profile = selected.preset(preset)
    except KeyError as exc:
        raise ModelStoreError("unknown preset") from exc

    prepared_id = await prepare_models(
        preset,
        app_home=app_home,
        progress=progress,
        downloader=downloader,
        catalog=selected,
        runtime_lock=selected_lock,
        cancel_event=cancel_event,
        disk_usage=disk_usage,
    )
    if cancel_event is not None and cancel_event.is_set():
        raise asyncio.CancelledError
    if selected_profile.diarization:
        if not isinstance(downloader, ModelScopeDownloader):
            raise ModelStoreError("diarization preparation requires the ModelScope downloader")
        try:
            await asyncio.to_thread(
                prepare_diarization_assets,
                app_home,
                preset_id=preset,
                downloader=downloader,
                catalog=selected,
                progress=progress,
                cancel_event=cancel_event,
                prepared_id=prepared_id,
            )
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            raise ModelStoreError("diarization asset preparation failed") from exc
        if progress is not None:
            progress(
                {
                    "phase": "diarization_verified",
                    "prepared_id": prepared_id,
                    "preset": preset,
                }
            )
    return prepared_id


__all__ = [
    "model_catalog_payload",
    "model_status_payload",
    "prepare_profile_models",
]
