"""Offline tests for verified model artifact preparation and cache reuse."""

from __future__ import annotations

import asyncio
import hashlib
import json
import stat
from collections import Counter
from collections.abc import AsyncIterator, Mapping
from pathlib import Path
from types import SimpleNamespace

import pytest

from speechrail.config.model_catalog import (
    ModelCatalog,
    RuntimeLock,
    SourceLocation,
)
from speechrail.service import model_store
from speechrail.service.model_store import (
    ModelStoreError,
    PreparedModelSet,
    prepare_models,
    resolve_prepared_models,
    resolve_prepared_selection,
    safe_artifact_path,
)

_HASH = "b" * 64
_REVISIONS = {"asr": "a" * 40, "design": "c" * 40, "custom": "d" * 40}


def _runtime_lock(lock_id: str = "fixture-lock") -> RuntimeLock:
    requirement = f"fixture==1.0 --hash=sha256:{_HASH}"
    return RuntimeLock(
        id=lock_id,
        python="3.12.14",
        asr_requirements=(requirement,),
        tts_requirements=(requirement,),
        ffmpeg_artifact="ffmpeg==1.0",
        file_hashes={"runtime/asr.txt": _HASH},
    )


def _artifact_size(catalog: ModelCatalog, key: str) -> int:
    artifact = next(item for item in catalog.artifacts if item.key == key)
    return sum(item.size for item in artifact.files)


def _artifact_files(key: str, family: str) -> tuple[dict[str, object], dict[str, bytes]]:
    names = [
        "config.json",
        "model.safetensors",
        "tokenizer_config.json",
        "vocab.json",
        "merges.txt",
    ]
    if family == "qwen3_tts":
        names.extend(["speech_tokenizer/config.json", "speech_tokenizer/model.safetensors"])
    payloads = {
        name: f"{key}:{name}".encode()
        for name in names
    }
    files = tuple(
        {
            "path": name,
            "size": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
        }
        for name, payload in payloads.items()
    )
    return files, payloads


def _catalog(*, mirror: bool = False, revision_suffix: str = "") -> tuple[
    ModelCatalog, dict[tuple[str, str], bytes]
]:
    definitions = (
        ("asr", "qwen3_asr", "asr"),
        ("design", "qwen3_tts", "voice_design"),
        ("custom", "qwen3_tts", "custom_voice"),
    )
    artifacts: list[dict[str, object]] = []
    payloads: dict[tuple[str, str], bytes] = {}
    for key, family, variant in definitions:
        files, artifact_payloads = _artifact_files(key, family)
        revision = (
            _REVISIONS[key][:-len(revision_suffix)] + revision_suffix
            if revision_suffix
            else _REVISIONS[key]
        )
        repository = f"fixture/{key}"
        sources: list[dict[str, str]] = [
            {"provider": "fixture", "repository": repository, "revision": revision}
        ]
        if mirror:
            sources.append(
                {
                    "provider": "mirror",
                    "repository": f"mirror/{key}",
                    "revision": "e" * 40,
                }
            )
        artifacts.append(
            {
                "key": key,
                "model_id": f"fixture/{key}",
                "revision": revision,
                "family": family,
                "variant": variant,
                "quantization": {"bits": 8, "group_size": 64, "format": "fixture"},
                "files": list(files),
                "sources": sources,
            }
        )
        for name, payload in artifact_payloads.items():
            payloads[(repository, name)] = payload
            if mirror:
                payloads[(f"mirror/{key}", name)] = payload
    catalog = ModelCatalog.model_validate(
        {
            "schema_version": 1,
            "artifacts": artifacts,
            "presets": [
                {"id": "quality", "asr": "asr", "tts": "design"},
                {"id": "balanced", "asr": "asr", "tts": "custom"},
                {"id": "light", "asr": "asr", "tts": "custom"},
            ],
        }
    )
    return catalog, payloads


class FakeDownloader:
    """Downloader returning bounded local byte streams for deterministic tests."""

    def __init__(self, payloads: Mapping[tuple[str, str], bytes]) -> None:
        self.payloads = dict(payloads)
        self.responses: dict[tuple[str, str], list[object]] = {}
        self.calls: list[tuple[str, str, str]] = []

    def queue(self, repository: str, path: str, *responses: object) -> None:
        self.responses[(repository, path)] = list(responses)

    async def download(
        self, source: SourceLocation, relative_path: str
    ) -> AsyncIterator[bytes]:
        key = (source.repository, relative_path)
        self.calls.append((source.provider, source.repository, relative_path))
        queued = self.responses.get(key)
        value = queued.pop(0) if queued and len(queued) > 1 else (
            queued[0] if queued else self.payloads[key]
        )
        if isinstance(value, BaseException):
            raise value
        assert isinstance(value, bytes)

        async def chunks() -> AsyncIterator[bytes]:
            for offset in range(0, len(value), 3):
                yield value[offset : offset + 3]

        return chunks()


class BlockingDownloader:
    def __init__(self) -> None:
        self.started = asyncio.Event()

    async def download(
        self, source: SourceLocation, relative_path: str
    ) -> AsyncIterator[bytes]:
        del source, relative_path
        self.started.set()
        await asyncio.Event().wait()
        yield b"unreachable"


class TrackingAsyncStream:
    def __init__(
        self,
        chunks: list[bytes],
        *,
        started: asyncio.Event | None = None,
        close_error: BaseException | None = None,
    ) -> None:
        self._chunks = list(chunks)
        self._position = 0
        self._started = started
        self._close_error = close_error
        self.close_calls = 0

    def __aiter__(self) -> TrackingAsyncStream:
        return self

    async def __anext__(self) -> bytes:
        if self._started is not None:
            self._started.set()
        if self._position >= len(self._chunks):
            raise StopAsyncIteration
        chunk = self._chunks[self._position]
        self._position += 1
        await asyncio.sleep(0)
        return chunk

    async def aclose(self) -> None:
        self.close_calls += 1
        if self._close_error is not None:
            raise self._close_error


class TrackingSyncStream:
    def __init__(self, chunks: list[bytes]) -> None:
        self._chunks = list(chunks)
        self.close_calls = 0

    def __iter__(self) -> TrackingSyncStream:
        return self

    def __next__(self) -> bytes:
        if not self._chunks:
            raise StopIteration
        return self._chunks.pop(0)

    def close(self) -> None:
        self.close_calls += 1


class TrackingDownloader:
    def __init__(self, payloads: Mapping[tuple[str, str], bytes], *, sync: bool = False) -> None:
        self.payloads = dict(payloads)
        self.sync = sync
        self.streams: list[TrackingAsyncStream | TrackingSyncStream] = []

    async def download(
        self, source: SourceLocation, relative_path: str
    ) -> TrackingAsyncStream | TrackingSyncStream:
        payload = self.payloads[(source.repository, relative_path)]
        stream = TrackingSyncStream([payload]) if self.sync else TrackingAsyncStream([payload])
        self.streams.append(stream)
        return stream


async def _prepare(
    tmp_path: Path,
    catalog: ModelCatalog,
    lock: RuntimeLock,
    downloader: object,
    *,
    preset: str = "quality",
    **kwargs: object,
) -> str:
    return await prepare_models(
        preset,
        app_home=tmp_path,
        catalog=catalog,
        runtime_lock=lock,
        downloader=downloader,
        **kwargs,
    )


def test_catalog_path_cannot_escape_model_store(tmp_path: Path) -> None:
    with pytest.raises(ValueError):
        safe_artifact_path(tmp_path, "../config/.env")


@pytest.mark.parametrize(
    "relative",
    [
        "",
        ".",
        "..",
        " ",
        "foo/../../model.safetensors",
        "/tmp/model",
        "C:\\model",
        "foo\x00bar",
    ],
)
def test_safe_artifact_path_rejects_abnormal_paths(tmp_path: Path, relative: str) -> None:
    with pytest.raises(ValueError):
        safe_artifact_path(tmp_path, relative)


def test_safe_artifact_path_rejects_symlink_escape(tmp_path: Path) -> None:
    root = tmp_path / "models"
    root.mkdir()
    outside = tmp_path / "outside"
    outside.mkdir()
    (root / "nested").symlink_to(outside, target_is_directory=True)

    with pytest.raises(ValueError, match=r"symlink|escape"):
        safe_artifact_path(root, "nested/file.bin")


@pytest.mark.anyio
async def test_prepare_streams_locked_files_and_publishes_atomic_registry(tmp_path: Path) -> None:
    catalog, payloads = _catalog()
    downloader = FakeDownloader(payloads)
    progress: list[dict[str, object]] = []

    prepared_id = await _prepare(
        tmp_path,
        catalog,
        _runtime_lock(),
        downloader,
        progress=progress.append,
    )

    assert prepared_id.startswith("prepared_")
    for key in ("asr", "design"):
        artifact = next(item for item in catalog.artifacts if item.key == key)
        for item in artifact.files:
            assert (tmp_path / "models" / key / item.path).read_bytes() == payloads[
                (f"fixture/{key}", item.path)
            ]
    registry_path = tmp_path / "state" / "model-preparations.json"
    registry = json.loads(registry_path.read_text(encoding="utf-8"))
    assert registry["prepared"][prepared_id]["preset"] == "quality"
    assert registry["prepared"][prepared_id]["runtime_lock_id"] == "fixture-lock"
    assert not (tmp_path / "models" / ".staging").exists()
    assert any(event.get("phase") == "verified" for event in progress)


@pytest.mark.anyio
async def test_registry_parent_fsync_failure_keeps_committed_models_reusable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    catalog, payloads = _catalog()
    first_downloader = FakeDownloader(payloads)
    original_fsync = model_store.os.fsync

    def fsync_without_directory_fsync(fd: int) -> None:
        if stat.S_ISDIR(model_store.os.fstat(fd).st_mode):
            raise OSError("directory fsync unavailable")
        original_fsync(fd)

    monkeypatch.setattr(model_store.os, "fsync", fsync_without_directory_fsync)
    prepared_id = await _prepare(tmp_path, catalog, _runtime_lock(), first_downloader)

    registry_path = tmp_path / "state" / "model-preparations.json"
    registry = json.loads(registry_path.read_text(encoding="utf-8"))
    assert prepared_id in registry["prepared"]
    assert (tmp_path / "models" / "asr").is_dir()
    assert (tmp_path / "models" / "design").is_dir()

    second_downloader = FakeDownloader(payloads)
    assert await _prepare(tmp_path, catalog, _runtime_lock(), second_downloader) == prepared_id
    assert not second_downloader.calls


@pytest.mark.anyio
async def test_download_async_streams_close_once_on_success_and_hash_failure(
    tmp_path: Path,
) -> None:
    catalog, payloads = _catalog()
    downloader = TrackingDownloader(payloads)

    await _prepare(tmp_path, catalog, _runtime_lock(), downloader)
    assert downloader.streams
    assert all(stream.close_calls == 1 for stream in downloader.streams)

    failed_catalog, failed_payloads = _catalog(revision_suffix="f")
    failed_payloads["fixture/asr", "config.json"] = b"wrong"
    failed_downloader = TrackingDownloader(failed_payloads)
    with pytest.raises(ModelStoreError):
        await _prepare(
            tmp_path / "failed",
            failed_catalog,
            _runtime_lock(),
            failed_downloader,
            max_retries=0,
        )
    assert failed_downloader.streams
    assert all(stream.close_calls == 1 for stream in failed_downloader.streams)


@pytest.mark.anyio
async def test_download_sync_iterables_close_once(tmp_path: Path) -> None:
    catalog, payloads = _catalog()
    downloader = TrackingDownloader(payloads, sync=True)

    await _prepare(tmp_path, catalog, _runtime_lock(), downloader)

    assert downloader.streams
    assert all(stream.close_calls == 1 for stream in downloader.streams)


@pytest.mark.anyio
async def test_download_stream_close_error_is_stable(tmp_path: Path) -> None:
    catalog, payloads = _catalog()

    class ClosingErrorDownloader(TrackingDownloader):
        async def download(
            self, source: SourceLocation, relative_path: str
        ) -> TrackingAsyncStream:
            payload = self.payloads[(source.repository, relative_path)]
            stream = TrackingAsyncStream([payload], close_error=RuntimeError("secret/body"))
            self.streams.append(stream)
            return stream

    downloader = ClosingErrorDownloader(payloads)
    with pytest.raises(ModelStoreError) as exc_info:
        await _prepare(tmp_path, catalog, _runtime_lock(), downloader, max_retries=0)
    assert "secret/body" not in str(exc_info.value)
    assert downloader.streams[0].close_calls == 1


@pytest.mark.anyio
async def test_download_async_stream_closes_on_cancellation(tmp_path: Path) -> None:
    catalog, _ = _catalog()
    started = asyncio.Event()

    class BlockingStreamDownloader:
        def __init__(self) -> None:
            self.stream: TrackingAsyncStream | None = None

        async def download(
            self, source: SourceLocation, relative_path: str
        ) -> TrackingAsyncStream:
            del source, relative_path
            self.stream = TrackingAsyncStream([b"unreachable"], started=started)
            return self.stream

    downloader = BlockingStreamDownloader()
    task = asyncio.create_task(_prepare(tmp_path, catalog, _runtime_lock(), downloader))
    await started.wait()
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task

    assert downloader.stream is not None
    assert downloader.stream.close_calls == 1


@pytest.mark.anyio
async def test_progress_callback_failure_does_not_retry_or_break_prepare(tmp_path: Path) -> None:
    catalog, payloads = _catalog()
    downloader = FakeDownloader(payloads)
    callback_calls = 0

    def progress(_: dict[str, object]) -> None:
        nonlocal callback_calls
        callback_calls += 1
        if callback_calls == 1:
            raise RuntimeError("observer failed")

    prepared_id = await _prepare(
        tmp_path,
        catalog,
        _runtime_lock(),
        downloader,
        progress=progress,
    )

    assert prepared_id.startswith("prepared_")
    assert callback_calls > 1
    assert len(downloader.calls) == 12


@pytest.mark.anyio
async def test_metadata_change_gets_new_identity_and_reuses_verified_files(tmp_path: Path) -> None:
    catalog, payloads = _catalog()
    changed_payload = catalog.model_dump(mode="json")
    for artifact in changed_payload["artifacts"]:
        if artifact["key"] == "asr":
            artifact["model_id"] = "fixture/asr-renamed"
            artifact["quantization"]["group_size"] = 32
    changed_catalog = ModelCatalog.model_validate(changed_payload)

    first_downloader = FakeDownloader(payloads)
    first_id = await _prepare(tmp_path, catalog, _runtime_lock(), first_downloader)
    second_downloader = FakeDownloader(payloads)
    second_id = await _prepare(tmp_path, changed_catalog, _runtime_lock(), second_downloader)

    assert second_id != first_id
    assert not second_downloader.calls
    registry = json.loads(
        (tmp_path / "state" / "model-preparations.json").read_text(encoding="utf-8")
    )
    entry = registry["prepared"][second_id]["artifacts"]["asr"]
    assert entry["model_id"] == "fixture/asr-renamed"
    assert entry["quantization"] == {"bits": 8, "group_size": 32, "format": "fixture"}


@pytest.mark.anyio
async def test_repeat_prepare_reuses_verified_cache_without_download(tmp_path: Path) -> None:
    catalog, payloads = _catalog()
    downloader = FakeDownloader(payloads)
    lock = _runtime_lock()

    first = await _prepare(tmp_path, catalog, lock, downloader)
    calls_after_first = len(downloader.calls)
    second = await _prepare(tmp_path, catalog, lock, downloader)

    assert second == first
    assert len(downloader.calls) == calls_after_first


@pytest.mark.anyio
async def test_prepare_reuses_shared_asr_cache_across_presets(tmp_path: Path) -> None:
    catalog, payloads = _catalog()
    downloader = FakeDownloader(payloads)
    lock = _runtime_lock()

    await _prepare(tmp_path, catalog, lock, downloader, preset="quality")
    calls_after_quality = len(downloader.calls)
    await _prepare(tmp_path, catalog, lock, downloader, preset="balanced")

    new_calls = downloader.calls[calls_after_quality:]
    assert new_calls
    assert all(
        path.startswith(("config", "model", "speech"))
        or path in {"tokenizer_config.json", "vocab.json", "merges.txt"}
        for _, repository, path in new_calls
        if repository == "fixture/custom"
    )
    assert all(repository == "fixture/custom" for _, repository, _ in new_calls)


@pytest.mark.anyio
async def test_cache_snapshot_hashes_each_reused_artifact_file_once(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    catalog, payloads = _catalog()
    lock = _runtime_lock()
    await _prepare(tmp_path, catalog, lock, FakeDownloader(payloads), preset="quality")

    counts: Counter[str] = Counter()
    original_hash = model_store._snapshot_file_hash

    def counted_hash(path: Path) -> str:
        counts[path.relative_to(tmp_path).as_posix()] += 1
        return original_hash(path)

    monkeypatch.setattr(model_store, "_snapshot_file_hash", counted_hash)
    await _prepare(tmp_path, catalog, lock, FakeDownloader(payloads), preset="balanced")

    asr = next(item for item in catalog.artifacts if item.key == "asr")
    for item in asr.files:
        assert counts[f"models/asr/{item.path}"] == 1


@pytest.mark.anyio
async def test_downloaded_snapshot_has_single_post_write_hash_validation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    catalog, payloads = _catalog()
    observed: list[Path] = []
    original_hash = model_store._snapshot_file_hash

    def counted_hash(path: Path) -> str:
        observed.append(path)
        return original_hash(path)

    monkeypatch.setattr(model_store, "_snapshot_file_hash", counted_hash)
    await _prepare(tmp_path, catalog, _runtime_lock(), FakeDownloader(payloads))

    for key in ("asr", "design"):
        artifact = next(item for item in catalog.artifacts if item.key == key)
        for item in artifact.files:
            suffix = f"/{key}/{item.path}"
            assert sum(path.as_posix().endswith(suffix) for path in observed) == 1


@pytest.mark.anyio
async def test_hash_mismatch_does_not_register_or_remove_existing_valid_cache(
    tmp_path: Path,
) -> None:
    catalog, payloads = _catalog()
    lock = _runtime_lock()
    initial_downloader = FakeDownloader(payloads)
    await _prepare(tmp_path, catalog, lock, initial_downloader)
    original = (tmp_path / "models" / "asr" / "model.safetensors").read_bytes()

    changed_catalog, changed_payloads = _catalog(revision_suffix="f")
    changed_downloader = FakeDownloader(changed_payloads)
    changed_downloader.queue("fixture/asr", "model.safetensors", b"wrong")

    with pytest.raises(ModelStoreError, match=r"hash|size|download"):
        await _prepare(tmp_path, changed_catalog, lock, changed_downloader, max_retries=0)

    assert (tmp_path / "models" / "asr" / "model.safetensors").read_bytes() == original
    assert not list((tmp_path / "models" / ".staging").glob("**/*"))


@pytest.mark.anyio
async def test_registry_failure_rolls_back_publish_and_preserves_previous_snapshot(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    catalog, payloads = _catalog()
    lock = _runtime_lock()
    await _prepare(tmp_path, catalog, lock, FakeDownloader(payloads))
    registry_path = tmp_path / "state" / "model-preparations.json"
    original_registry = registry_path.read_bytes()
    original_snapshot = (tmp_path / "models" / "asr" / "config.json").read_bytes()

    changed_catalog, changed_payloads = _catalog(revision_suffix="f")

    def _fail_registry(*_: object, **__: object) -> None:
        raise ModelStoreError("registry write failed")

    monkeypatch.setattr(model_store, "_write_registry", _fail_registry)
    with pytest.raises(ModelStoreError, match="registry"):
        await _prepare(tmp_path, changed_catalog, lock, FakeDownloader(changed_payloads))

    assert registry_path.read_bytes() == original_registry
    assert (tmp_path / "models" / "asr" / "config.json").read_bytes() == original_snapshot


@pytest.mark.anyio
async def test_transient_download_failure_is_retried_within_bound(tmp_path: Path) -> None:
    catalog, payloads = _catalog()
    downloader = FakeDownloader(payloads)
    downloader.queue(
        "fixture/asr",
        "config.json",
        OSError("temporary"),
        payloads[("fixture/asr", "config.json")],
    )

    await _prepare(tmp_path, catalog, _runtime_lock(), downloader, max_retries=1)

    config_calls = [
        call for call in downloader.calls if call[1] == "fixture/asr" and call[2] == "config.json"
    ]
    assert len(config_calls) == 2


@pytest.mark.anyio
async def test_mirror_with_non_equivalent_content_fails_over_to_matching_source(
    tmp_path: Path,
) -> None:
    catalog, payloads = _catalog(mirror=True)
    downloader = FakeDownloader(payloads)
    downloader.queue("fixture/asr", "config.json", b"mirror-does-not-match")

    await _prepare(tmp_path, catalog, _runtime_lock(), downloader, max_retries=0)

    config_calls = [
        call
        for call in downloader.calls
        if call[2] == "config.json" and call[1] in {"fixture/asr", "mirror/asr"}
    ]
    assert [repository for _, repository, _ in config_calls] == ["fixture/asr", "mirror/asr"]
    assert (tmp_path / "models" / "asr" / "config.json").read_bytes() == payloads[
        ("fixture/asr", "config.json")
    ]


@pytest.mark.anyio
async def test_all_non_equivalent_mirrors_fail_closed(tmp_path: Path) -> None:
    catalog, payloads = _catalog(mirror=True)
    downloader = FakeDownloader(payloads)
    downloader.queue("fixture/asr", "config.json", b"wrong-canonical")
    downloader.queue("mirror/asr", "config.json", b"wrong-mirror")

    with pytest.raises(ModelStoreError, match=r"hash|size|download"):
        await _prepare(tmp_path, catalog, _runtime_lock(), downloader, max_retries=0)

    assert not (tmp_path / "models" / "asr").exists()
    assert not (tmp_path / "state" / "model-preparations.json").exists()


@pytest.mark.anyio
async def test_missing_tts_codec_file_is_not_published(tmp_path: Path) -> None:
    catalog, payloads = _catalog()
    payloads.pop(("fixture/design", "speech_tokenizer/model.safetensors"))
    downloader = FakeDownloader(payloads)

    with pytest.raises(ModelStoreError, match=r"download|missing|hash|size"):
        await _prepare(tmp_path, catalog, _runtime_lock(), downloader, max_retries=0)

    assert not (tmp_path / "models" / "design").exists()
    assert not (tmp_path / "state" / "model-preparations.json").exists()


@pytest.mark.anyio
async def test_oversized_stream_is_aborted_before_publish(tmp_path: Path) -> None:
    catalog, payloads = _catalog()
    downloader = FakeDownloader(payloads)
    downloader.queue("fixture/asr", "model.safetensors", b"x" * 10_000)

    with pytest.raises(ModelStoreError, match=r"size"):
        await _prepare(tmp_path, catalog, _runtime_lock(), downloader, max_retries=0)

    assert not (tmp_path / "models" / "asr").exists()
    assert not (tmp_path / "state" / "model-preparations.json").exists()


@pytest.mark.anyio
async def test_cancellation_cleans_staging_and_leaves_registry_untouched(tmp_path: Path) -> None:
    catalog, _ = _catalog()
    downloader = BlockingDownloader()
    task = asyncio.create_task(_prepare(tmp_path, catalog, _runtime_lock(), downloader))
    await downloader.started.wait()

    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task

    assert not (tmp_path / "models" / ".staging").exists()
    assert not (tmp_path / "state" / "model-preparations.json").exists()
    assert not (tmp_path / "models" / "asr").exists()


@pytest.mark.anyio
async def test_disk_space_preflight_fails_before_downloader(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    catalog, payloads = _catalog()
    downloader = FakeDownloader(payloads)
    monkeypatch.setattr(model_store.shutil, "disk_usage", lambda _: SimpleNamespace(free=0))

    with pytest.raises(ModelStoreError, match="disk"):
        await _prepare(tmp_path, catalog, _runtime_lock(), downloader)

    assert not downloader.calls
    assert not (tmp_path / "state" / "model-preparations.json").exists()


@pytest.mark.anyio
async def test_old_cache_is_not_double_counted_in_disk_preflight(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    catalog, payloads = _catalog()
    lock = _runtime_lock()
    await _prepare(tmp_path, catalog, lock, FakeDownloader(payloads), preset="quality")

    old_cache = tmp_path / "models" / ".releases" / "old" / "asr"
    old_cache.mkdir(parents=True)
    (old_cache / "large.bin").write_bytes(b"x" * 10_000)

    downloader = FakeDownloader(payloads)
    missing_tts_bytes = _artifact_size(catalog, "custom")
    monkeypatch.setattr(
        model_store.shutil,
        "disk_usage",
        lambda _: SimpleNamespace(free=missing_tts_bytes),
    )

    await _prepare(tmp_path, catalog, lock, downloader, preset="balanced")

    assert all(repository == "fixture/custom" for _, repository, _ in downloader.calls)


@pytest.mark.anyio
async def test_shared_asr_cache_hit_is_excluded_from_staging_requirement(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    catalog, payloads = _catalog()
    lock = _runtime_lock()
    await _prepare(tmp_path, catalog, lock, FakeDownloader(payloads), preset="quality")

    downloader = FakeDownloader(payloads)
    monkeypatch.setattr(
        model_store.shutil,
        "disk_usage",
        lambda _: SimpleNamespace(free=_artifact_size(catalog, "custom")),
    )

    await _prepare(tmp_path, catalog, lock, downloader, preset="balanced")

    assert downloader.calls
    assert all(repository == "fixture/custom" for _, repository, _ in downloader.calls)


@pytest.mark.anyio
async def test_disk_space_shortfall_is_rejected_before_any_download(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    catalog, payloads = _catalog()
    downloader = FakeDownloader(payloads)
    missing_bytes = _artifact_size(catalog, "asr") + _artifact_size(catalog, "design")
    monkeypatch.setattr(
        model_store.shutil,
        "disk_usage",
        lambda _: SimpleNamespace(free=missing_bytes - 1),
    )

    with pytest.raises(ModelStoreError, match=r"disk"):
        await _prepare(tmp_path, catalog, _runtime_lock(), downloader)

    assert not downloader.calls


@pytest.mark.anyio
async def test_unknown_preset_is_rejected_without_download(tmp_path: Path) -> None:
    catalog, payloads = _catalog()
    downloader = FakeDownloader(payloads)

    with pytest.raises(ModelStoreError, match="preset"):
        await _prepare(tmp_path, catalog, _runtime_lock(), downloader, preset="unknown")

    assert not downloader.calls
    assert not (tmp_path / "models").exists()


@pytest.mark.anyio
async def test_external_catalog_paths_are_never_requested(tmp_path: Path) -> None:
    catalog, payloads = _catalog()
    downloader = FakeDownloader(payloads)

    await _prepare(tmp_path, catalog, _runtime_lock(), downloader)

    requested = {path for _, _, path in downloader.calls}
    expected = {item.path for artifact in catalog.artifacts[:2] for item in artifact.files}
    assert requested == expected
    assert all(not Path(path).is_absolute() and ".." not in Path(path).parts for path in requested)


@pytest.mark.anyio
async def test_resolve_prepared_models_returns_verified_immutable_identity(
    tmp_path: Path,
) -> None:
    catalog, payloads = _catalog()
    lock = _runtime_lock()
    prepared_id = await _prepare(tmp_path, catalog, lock, FakeDownloader(payloads))

    result = resolve_prepared_models(
        prepared_id,
        app_home=tmp_path,
        catalog=catalog,
        runtime_lock=lock,
    )

    assert isinstance(result, PreparedModelSet)
    assert result.prepared_id == prepared_id
    assert result.preset == "quality"
    assert result.runtime_lock_id == lock.id
    assert result.asr.path == (tmp_path / "models" / "asr").resolve()
    assert result.tts.path == (tmp_path / "models" / "design").resolve()
    assert result.asr.model_id == "fixture/asr"
    assert result.asr.family == "qwen3_asr"
    assert result.asr.variant == "asr"
    assert result.asr.files[0]["path"] == "config.json"
    with pytest.raises(TypeError):
        result.asr.files[0]["path"] = "changed"  # type: ignore[index]
    with pytest.raises(TypeError):
        result.asr.identity["model_id"] = "changed"  # type: ignore[index]


@pytest.mark.anyio
async def test_resolve_prepared_selection_uses_catalog_and_lock_identity(tmp_path: Path) -> None:
    catalog, payloads = _catalog()
    lock = _runtime_lock()
    prepared_id = await _prepare(tmp_path, catalog, lock, FakeDownloader(payloads))
    selected = catalog.preset("quality")
    selection = {
        "schema_version": 1,
        "preset": "quality",
        "generation": 1,
        "asr": selected.asr,
        "tts": selected.tts,
        "runtime_lock_id": lock.id,
    }

    result = resolve_prepared_selection(
        selection,
        app_home=tmp_path,
        catalog=catalog,
        runtime_lock=lock,
    )

    assert result.prepared_id == prepared_id
    assert result.asr.path.is_absolute()
    assert result.tts.path.is_absolute()


@pytest.mark.anyio
async def test_resolve_prepared_models_rejects_unknown_id_without_path_leak(
    tmp_path: Path,
) -> None:
    catalog, _ = _catalog()
    lock = _runtime_lock()

    with pytest.raises(ModelStoreError) as exc_info:
        resolve_prepared_models(
            "prepared-unknown",
            app_home=tmp_path,
            catalog=catalog,
            runtime_lock=lock,
        )

    assert str(tmp_path) not in str(exc_info.value)


@pytest.mark.anyio
@pytest.mark.parametrize("field", ["preset", "runtime_lock_id", "artifacts"])
async def test_resolve_prepared_models_rejects_inconsistent_registry_entry(
    tmp_path: Path, field: str
) -> None:
    catalog, payloads = _catalog()
    lock = _runtime_lock()
    prepared_id = await _prepare(tmp_path, catalog, lock, FakeDownloader(payloads))
    registry_path = tmp_path / "state" / "model-preparations.json"
    registry = json.loads(registry_path.read_text(encoding="utf-8"))
    candidate = registry["prepared"][prepared_id]
    if field == "preset":
        candidate[field] = "balanced"
    elif field == "runtime_lock_id":
        candidate[field] = "other-lock"
    else:
        candidate[field]["unexpected"] = candidate[field]["asr"]
    registry_path.write_text(json.dumps(registry), encoding="utf-8")

    with pytest.raises(ModelStoreError):
        resolve_prepared_models(
            prepared_id,
            app_home=tmp_path,
            catalog=catalog,
            runtime_lock=lock,
        )


@pytest.mark.anyio
async def test_resolve_prepared_models_rejects_corrupt_snapshot_and_symlink_escape(
    tmp_path: Path,
) -> None:
    catalog, payloads = _catalog()
    lock = _runtime_lock()
    prepared_id = await _prepare(tmp_path, catalog, lock, FakeDownloader(payloads))
    corrupt = tmp_path / "models" / "asr" / "config.json"
    corrupt.write_bytes(b"corrupt")
    with pytest.raises(ModelStoreError):
        resolve_prepared_models(
            prepared_id,
            app_home=tmp_path,
            catalog=catalog,
            runtime_lock=lock,
        )

    corrupt.unlink()
    outside = tmp_path / "outside"
    outside.write_bytes(b"outside")
    corrupt.symlink_to(outside)
    with pytest.raises(ModelStoreError):
        resolve_prepared_models(
            prepared_id,
            app_home=tmp_path,
            catalog=catalog,
            runtime_lock=lock,
        )


def test_resolve_prepared_selection_rejects_missing_registry(tmp_path: Path) -> None:
    catalog, _ = _catalog()
    lock = _runtime_lock()
    selected = catalog.preset("quality")
    selection = {
        "schema_version": 1,
        "preset": "quality",
        "generation": 1,
        "asr": selected.asr,
        "tts": selected.tts,
        "runtime_lock_id": lock.id,
    }

    with pytest.raises(ModelStoreError):
        resolve_prepared_selection(
            selection,
            app_home=tmp_path,
            catalog=catalog,
            runtime_lock=lock,
        )
