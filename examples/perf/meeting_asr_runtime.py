"""Explicit private ASR composition, preload byte locks and formal replay.

Importing this module does not construct services or start models. The async
entry point is an explicit model-loading operation; its caller must already
have authorization. It creates two private production child owners, never
borrows a running service, starts the lifecycle, or discovers dependencies.

Filesystem stability is evidence about named files, not what an interpreter
imported or a model loader consumed. The ready ASR revision fingerprints model
structure. Neither that revision nor these hashes attest loaded weight bytes.
Silero's host-process cache remains shared and is deliberately not cleared.
"""

from __future__ import annotations

import asyncio
import hashlib
import math
import os
import stat
import sys
from collections.abc import AsyncIterator, Mapping
from contextlib import asynccontextmanager
from dataclasses import dataclass, replace
from pathlib import Path
from types import MappingProxyType
from typing import Any

from meeting_asr_source import LockedAsrCase, evaluate_locked_asr_case
from meeting_evaluation_identity import (
    MeetingCandidateSpec,
    canonical_digest,
    validate_execution_identity,
)
from meeting_realtime_asr_replay import realtime_replay_preset, replay_realtime_session
from probe_meeting_asr_quality import ASR_SCORER, RuntimeObservation, replay_long_blocks

import speechrail.application.services as services_module
import speechrail.backends.neural_vad as vad_module
from speechrail.application.alignment import FixedTextAligner
from speechrail.application.services import AppOverrides, AppServices, build_app_services
from speechrail.backends.model_identity import is_observed_runtime_revision
from speechrail.backends.qwen3_alignment import Qwen3AlignmentWorker
from speechrail.backends.qwen3_native import Qwen3BackendConfig
from speechrail.backends.qwen3_shared import Qwen3SharedWorker
from speechrail.backends.qwen3_window import NativeWindowAsrFactory
from speechrail.config import Settings
from speechrail.domain.asr_window import WindowIdentity
from speechrail.infrastructure.voice_registry import FileVoiceRegistry
from speechrail.runtime.cleanup import join_cleanup
from speechrail.runtime.server_lock import ServerInstanceLock
from speechrail.runtime.worker_process import AsyncFramedWorkerProcess

_MAX_FILES = 250_000
_MAX_BYTES = 128 * 1024**3
_REPOSITORY = Path(__file__).resolve().parents[2]
_Stamp = tuple[int, int, int, int, int, int]


@dataclass(frozen=True, slots=True)
class AsrReplayPlan:
    """Independent, immutable replay choices; never a production policy."""

    mode: str = "formal_realtime_session_diagnostic"
    block_seconds: int | None = None
    decode_timeout_seconds: float | None = None

    def __post_init__(self) -> None:
        if self.mode == "formal_realtime_session_diagnostic":
            if self.block_seconds is not None or self.decode_timeout_seconds is not None:
                raise ValueError("formal replay does not accept long-block choices")
        elif self.mode == "bounded_long_block_diagnostic":
            if (
                type(self.block_seconds) is not int
                or not 1 <= self.block_seconds <= 30
                or self.decode_timeout_seconds is None
                or type(self.decode_timeout_seconds) not in (int, float)
                or not math.isfinite(self.decode_timeout_seconds)
                or not 0 < self.decode_timeout_seconds <= 300
            ):
                raise ValueError("long-block replay requires explicit bounded choices")
        else:
            raise ValueError("unknown ASR replay mode")

    @classmethod
    def from_wire(cls, value: object) -> AsrReplayPlan:
        if not isinstance(value, dict):
            raise ValueError("ASR replay plan must be an object")
        mode = value.get("mode")
        expected = (
            {"mode"}
            if mode == "formal_realtime_session_diagnostic"
            else {"mode", "block_seconds", "decode_timeout_seconds"}
        )
        if set(value) != expected:
            raise ValueError("ASR replay fields differ from frozen schema")
        return cls(**value)

    def as_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {"mode": self.mode}
        if self.mode == "bounded_long_block_diagnostic":
            result.update(
                block_seconds=self.block_seconds, decode_timeout_seconds=self.decode_timeout_seconds
            )
        return result


_FORMAL_REPLAY = AsrReplayPlan()


def _guard_path(port: int) -> Path:
    return ServerInstanceLock(port).path


@dataclass(frozen=True, slots=True)
class _InheritedGuard:
    descriptors: tuple[int, ...]
    port: int
    uid: int
    stamps: tuple[_Stamp, ...]

    @classmethod
    def capture(cls, descriptors: tuple[int, ...], port: int) -> _InheritedGuard:
        if (
            not isinstance(descriptors, tuple)
            or len(descriptors) > 16
            or any(type(fd) is not int or fd < 3 for fd in descriptors)
            or len(set(descriptors)) != len(descriptors)
        ):
            raise ValueError("invalid inherited ASR runtime guard")
        try:
            guard = cls(
                descriptors, port, os.getuid(), tuple(_stamp(os.fstat(fd)) for fd in descriptors)
            )
            guard.verify()
            return guard
        except OSError, ValueError:
            raise ValueError("inherited ASR runtime guard is unavailable or changed") from None

    def verify(self) -> None:
        try:
            if os.getuid() != self.uid:
                raise ValueError("runtime guard user changed")
            if not self.descriptors:
                return
            path_info = _guard_path(self.port).lstat()
            if not stat.S_ISREG(path_info.st_mode) or path_info.st_uid != self.uid:
                raise ValueError("runtime guard file changed")
            for descriptor, expected in zip(self.descriptors, self.stamps, strict=True):
                info = os.fstat(descriptor)
                if (
                    _stamp(info) != expected
                    or _stamp(path_info) != expected
                    or info.st_uid != self.uid
                    or not stat.S_ISREG(info.st_mode)
                ):
                    raise ValueError("runtime guard file changed")
        except OSError, ValueError:
            raise ValueError("inherited ASR runtime guard is unavailable or changed") from None

    def configuration(self) -> dict[str, object]:
        # Stable candidate identity describes lock semantics. Numeric descriptors
        # and inode/stamp evidence belong only to this run's replacement guard.
        return {
            "namespace": "speechrail-user-port-lock-v1",
            "port": self.port,
            "uid": self.uid,
            "asr_descriptor_count": len(self.descriptors),
            "aligner_descriptor_count": len(self.descriptors),
        }


@dataclass(frozen=True, slots=True)
class RuntimeDependencyRoots:
    """Explicit local roots, separately declared for each interpreter role.

    A directory means all its files, including bytecode and native libraries.
    Missing/empty roles and symlink directories fail closed. File symlinks are
    supported and bind both the link and resolved target. These declarations
    do not establish actual import resolution, dependency completeness, or SDK
    provenance. No package manager, interpreter, or network discovery runs.
    """

    host: tuple[Path, ...]
    asr: tuple[Path, ...]
    aligner: tuple[Path, ...]

    def __post_init__(self) -> None:
        for role in (self.host, self.asr, self.aligner):
            if (
                not isinstance(role, tuple)
                or not 1 <= len(role) <= 16
                or any(not isinstance(path, Path) or not path.is_absolute() for path in role)
            ):
                raise ValueError("explicit absolute dependency roots are required for each role")


def _stamp(value: os.stat_result) -> _Stamp:
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


@dataclass(frozen=True, slots=True)
class _Entry:
    resolved: Path
    link_stamp: _Stamp
    target_stamp: _Stamp
    sha256: str | None


def _entry(path: Path, *, hash_bytes: bool) -> _Entry:
    resolved = path.resolve(strict=True)
    link_stamp, target = _stamp(path.lstat()), path.stat()
    if stat.S_ISDIR(target.st_mode):
        if path.is_symlink():
            raise ValueError("symlink directories are outside the frozen closure")
        return _Entry(resolved, link_stamp, _stamp(target), None)
    if not stat.S_ISREG(target.st_mode):
        raise ValueError("runtime artifacts must be local regular files")
    if target.st_size > _MAX_BYTES:
        raise ValueError("runtime artifact exceeds byte bound")
    digest = hashlib.sha256()
    if hash_bytes:
        descriptor = os.open(resolved, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        with os.fdopen(descriptor, "rb") as handle:
            if _stamp(os.fstat(handle.fileno())) != _stamp(target):
                raise ValueError("runtime artifact changed while opening")
            while block := handle.read(1024 * 1024):
                digest.update(block)
            if _stamp(os.fstat(handle.fileno())) != _stamp(target):
                raise ValueError("runtime artifact changed while reading")
    if (
        path.resolve(strict=True) != resolved
        or _stamp(path.lstat()) != link_stamp
        or _stamp(path.stat()) != _stamp(target)
    ):
        raise ValueError("runtime artifact changed while reading")
    return _Entry(resolved, link_stamp, _stamp(target), digest.hexdigest() if hash_bytes else None)


def _walk_error(error: OSError) -> None:
    raise error


def _paths(root: Path, *, recursive: bool = True) -> dict[str, Path]:
    if not root.is_dir():
        return {".": root}
    if root.is_symlink():
        raise ValueError("symlink directories are outside the frozen closure")
    result = {".": root}
    for directory, names, files in os.walk(root, followlinks=False, onerror=_walk_error):
        for name in (*names, *files):
            path = Path(directory) / name
            if path.is_symlink() and path.is_dir():
                raise ValueError("symlink directories are outside the frozen closure")
            result[path.relative_to(root).as_posix()] = path
            if len(result) > _MAX_FILES:
                raise ValueError("runtime artifact count exceeds bound")
        if not recursive:
            break
    return result


def _source_paths() -> dict[str, Path]:
    package = Path(services_module.__file__).resolve().parents[1]
    perf = Path(__file__).resolve().parent
    result = {
        "source/" + name: path
        for name, path in _paths(package).items()
        if path.suffix == ".py" and not path.is_dir()
    }
    result.update(
        {
            "perf/" + name: path
            for name, path in _paths(perf, recursive=False).items()
            if path.suffix == ".py" and not path.is_dir()
        }
    )
    result["adapter"] = package / "backends/qwen3_window.py"
    result["worker"] = package / "backends/qwen3_worker.py"
    return result


@dataclass(frozen=True, slots=True)
class _Inventory:
    roots: Mapping[str, Path]
    sources: Mapping[str, Path]
    entries: Mapping[tuple[str, str], _Entry]

    @classmethod
    def capture(cls, roots: Mapping[str, Path]) -> _Inventory:
        try:
            return cls._capture(roots)
        except OSError, RuntimeError:
            raise ValueError("frozen ASR runtime bytes are unavailable") from None

    @classmethod
    def _capture(cls, roots: Mapping[str, Path]) -> _Inventory:
        sources = _source_paths()
        if not {"adapter", "worker"} <= sources.keys():
            raise ValueError("production adapter and worker source are required")
        all_roots = {**roots, **{"source:" + name: path for name, path in sources.items()}}
        entries: dict[tuple[str, str], _Entry] = {}
        cache: dict[Path, _Entry] = {}
        total_bytes = 0
        for label, root in all_roots.items():
            for relative, path in _paths(root).items():
                entry = cache.get(path)
                if entry is None:
                    entry = _entry(path, hash_bytes=True)
                    total_bytes += entry.target_stamp[3] if entry.sha256 is not None else 0
                    cache[path] = entry
                entries[(label, relative)] = entry
                if len(entries) > _MAX_FILES or total_bytes > _MAX_BYTES:
                    raise ValueError("runtime artifact closure exceeds bound")
        return cls(
            MappingProxyType(all_roots), MappingProxyType(sources), MappingProxyType(entries)
        )

    def verify(self, *, hash_bytes: bool = True) -> None:
        try:
            if _source_paths() != self.sources:
                raise ValueError("runtime source set changed")
            paths = {
                (label, relative): path
                for label, root in self.roots.items()
                for relative, path in _paths(root).items()
            }
            if paths.keys() != self.entries.keys():
                raise ValueError("runtime artifact set changed")
            cache: dict[Path, _Entry] = {}
            for key, path in paths.items():
                observed = cache.get(path)
                if observed is None:
                    observed = _entry(path, hash_bytes=hash_bytes)
                    cache[path] = observed
                expected = self.entries[key]
                if (
                    observed.resolved != expected.resolved
                    or observed.link_stamp != expected.link_stamp
                    or observed.target_stamp != expected.target_stamp
                    or (hash_bytes and observed.sha256 != expected.sha256)
                ):
                    raise ValueError("runtime artifact changed")
        except OSError, RuntimeError, ValueError:
            raise ValueError("frozen ASR runtime bytes changed or are unavailable") from None

    def files(self, label: str) -> dict[str, str]:
        return {
            name: entry.sha256
            for (role, name), entry in self.entries.items()
            if role == label and entry.sha256 is not None
        }

    def digest(self, prefix: str) -> str:
        return canonical_digest(
            {
                role + "/" + name: entry.sha256
                for (role, name), entry in self.entries.items()
                if role.startswith(prefix) and entry.sha256 is not None
            }
        )


@dataclass(slots=True)
class _Owners:
    services: AppServices
    factory: NativeWindowAsrFactory
    asr: Qwen3SharedWorker
    aligner_adapter: FixedTextAligner
    aligner: Qwen3AlignmentWorker
    asr_transport: AsyncFramedWorkerProcess
    alignment_transport: AsyncFramedWorkerProcess
    process_pair: tuple[object, object] | None = None
    guard: _InheritedGuard | None = None

    @property
    def asr_config(self) -> Qwen3BackendConfig:
        config = self.asr.config
        if type(config) is not Qwen3BackendConfig:
            raise ValueError("ASR runtime owner configuration changed")
        return config

    @classmethod
    def cold(cls, services: AppServices) -> _Owners:
        factory, adapter = services.window_asr_factory, services.text_aligner
        if type(factory) is not NativeWindowAsrFactory or type(adapter) is not FixedTextAligner:
            raise ValueError("private root requires native ASR and fixed-text alignment owners")
        asr, aligner = factory._worker, adapter._client
        if (
            type(asr) is not Qwen3SharedWorker
            or type(aligner) is not Qwen3AlignmentWorker
            or type(asr.config) is not Qwen3BackendConfig
            or services.asr_worker is None
            or services.asr_worker.shared_owner is not asr
        ):
            raise ValueError("private root requires one actual production ASR owner")
        if (
            asr.ready
            or asr.alive
            or aligner.ready
            or aligner.alive
            or asr.generation != 0
            or asr._transport._process is not None
            or aligner._process._process is not None
            or factory._session is not None
            or asr._start_lock.locked()
            or asr._sessions
            or asr._requests
            or asr.mode_gate.active_count
            or asr._window_owner is not None
        ):
            raise ValueError("private root requires cold never-published production owners")
        return cls(services, factory, asr, adapter, aligner, asr._transport, aligner._process)

    def check_objects(self) -> None:
        if (
            self.services.window_asr_factory is not self.factory
            or self.services.text_aligner is not self.aligner_adapter
            or self.factory._worker is not self.asr
            or self.aligner_adapter._client is not self.aligner
            or self.services.asr_worker is None
            or self.services.asr_worker.shared_owner is not self.asr
            or self.asr._transport is not self.asr_transport
            or self.aligner._process is not self.alignment_transport
        ):
            raise ValueError("ASR runtime owner composition changed")
        if self.guard is not None:
            self.guard.verify()
            if (
                self.services.settings.port != self.guard.port
                or self.asr_transport._spec.pass_fds != self.guard.descriptors
                or self.alignment_transport._spec.pass_fds != self.guard.descriptors
            ):
                raise ValueError("inherited ASR runtime guard configuration changed")

    async def close(self) -> None:
        # These exact objects were created privately, prior to any await/yield.
        # An unexpected transport/process is never closed on assumed ownership.
        current = (self.asr_transport._process, self.alignment_transport._process)
        confirmed = [
            self.asr._transport is self.asr_transport,
            self.aligner._process is self.alignment_transport,
        ]
        if self.process_pair is not None:
            confirmed = [
                same and (now is None or now is owned)
                for same, now, owned in zip(confirmed, current, self.process_pair, strict=True)
            ]
        workers: tuple[Qwen3SharedWorker | Qwen3AlignmentWorker, ...] = (self.asr, self.aligner)
        results = await asyncio.gather(
            *(worker.close() for worker, same in zip(workers, confirmed, strict=True) if same),
            return_exceptions=True,
        )
        if not all(confirmed):
            raise RuntimeError("ASR runtime cleanup ownership is unconfirmed")
        if any(isinstance(result, BaseException) for result in results):
            raise RuntimeError("owned ASR runtime child cleanup failed") from None
        if (
            self.asr.alive
            or self.aligner.alive
            or self.asr_transport._process is not None
            or self.alignment_transport._process is not None
            or (
                self.process_pair is not None
                and any(
                    getattr(process, "returncode", None) is None for process in self.process_pair
                )
            )
        ):
            raise RuntimeError("owned ASR runtime child cleanup is unconfirmed")


def _configuration(owners: _Owners) -> str:
    settings = owners.services.settings
    return canonical_digest(
        {
            "asr_command": owners.asr_config.command(),
            "aligner_command": owners.aligner.config.command(),
            "asr_cwd": str(owners.asr_transport._spec.cwd),
            "aligner_cwd": str(owners.alignment_transport._spec.cwd),
            "asr_launch": list(owners.asr_transport._spec.command),
            "aligner_launch": list(owners.alignment_transport._spec.command),
            "asr_no_bytecode": owners.asr_transport._spec.env.get("PYTHONDONTWRITEBYTECODE"),
            "aligner_no_bytecode": owners.alignment_transport._spec.env.get(
                "PYTHONDONTWRITEBYTECODE"
            ),
            "asr_environment_sha256": canonical_digest(dict(owners.asr_transport._spec.env)),
            "aligner_environment_sha256": canonical_digest(
                dict(owners.alignment_transport._spec.env)
            ),
            "preset": realtime_replay_preset(owners.services),
            "model_id": settings.model_id,
            "frame_bytes": settings.max_realtime_frame_bytes,
            "buffer_bytes": settings.max_realtime_buffer_bytes,
            "timeout": settings.request_timeout_seconds,
            "revision_windows_enabled": settings.asr_revision_windows_enabled,
            "asr_timeout": owners.asr.config.timeout_seconds,
            "aligner_timeout": owners.aligner.config.timeout_seconds,
            "inherited_guard": owners.guard.configuration() if owners.guard is not None else None,
        }
    )


def _candidate_spec(
    owners: _Owners,
    inventory: _Inventory,
    configuration: object,
    *,
    revision: str,
    language: str | None,
) -> MeetingCandidateSpec:
    return MeetingCandidateSpec(
        implementation_id="production_revision_window_asr",
        adapter_sha256=inventory.files("source:adapter")["."],
        worker_sha256=inventory.files("source:worker")["."],
        sdk_revision="filesystem-closure:"
        + canonical_digest({"files": inventory.digest(""), "configuration": configuration}),
        model_revision=revision,
        model_files_sha256=inventory.files("asr_model"),
        dtype=owners.asr_config.dtype,
        compute_units=owners.asr_config.device,
        preset=realtime_replay_preset(owners.services, language=language),
        decoder={"max_tokens": owners.asr_config.max_new_tokens or 512, "timestamps": False},
        attribution={"algorithm": "none"},
        scorer=ASR_SCORER,
    )


def _expected_language(expected: MeetingCandidateSpec) -> str | None:
    language = expected.preset.get("language")
    if language is not None and not isinstance(language, str):
        raise ValueError("invalid frozen ASR language")
    return language


def _ready_identity(owners: _Owners) -> tuple[object, ...]:
    owners.check_objects()
    cap, identity, revision = (
        owners.factory.window_decode_max_new_tokens,
        owners.asr.identity,
        owners.asr.runtime_revision,
    )
    if (
        not owners.services.revision_window_ready
        or not owners.aligner.alive
        or type(cap) is not int
        or not 32 <= cap <= 2048
        or cap != (owners.asr_config.max_new_tokens or 512)
        or identity != (owners.asr.config.device, owners.asr.config.dtype)
        or not isinstance(revision, str)
        or not is_observed_runtime_revision(revision)
        or owners.asr_transport._process is None
        or owners.alignment_transport._process is None
    ):
        raise ValueError("ASR runtime owner is not ready with observed decoder evidence")
    return (
        owners.asr.generation,
        identity,
        revision,
        cap,
        id(owners.asr_transport._process),
        id(owners.alignment_transport._process),
        canonical_digest(dict(owners.aligner.identity or {})),
        _configuration(owners),
    )


class FrozenAsrRuntime:
    """Prepared replay handle and, after successful cleanup, commit guards."""

    def __init__(self, owners: _Owners, inventory: _Inventory) -> None:
        self._owners, self._inventory = owners, inventory
        self._identity = _ready_identity(owners)
        self._active = True
        self._invalid = False
        self._evaluating = False
        self._closing = False
        self._commit_ready = False
        self._inflight: asyncio.Task[Any] | None = None
        self._full_checks = 0
        self._verified_replays = 0
        owners.process_pair = (owners.asr_transport._process, owners.alignment_transport._process)

    def _check(self) -> None:
        try:
            if not self._active or self._invalid or _ready_identity(self._owners) != self._identity:
                raise ValueError("runtime identity changed")
        except AttributeError, TypeError, ValueError:
            self._invalid = True
            raise ValueError(
                "ASR runtime owner or generation changed, or handle is closed"
            ) from None

    async def verify(self) -> None:
        """Join full byte checks; never abandon a hashing thread on cancellation."""
        self._check()
        try:
            await join_cleanup(
                asyncio.create_task(
                    asyncio.to_thread(self._inventory.verify), name="frozen-asr-verify"
                )
            )
            self._check()
            self._full_checks += 1
        except BaseException:
            self._invalid = True
            raise

    def _check_closed(self) -> None:
        try:
            owners = self._owners
            owners.check_objects()
            if (
                self._active
                or not self._closing
                or self._invalid
                or owners.asr.ready
                or owners.aligner.ready
                or owners.asr_transport._process is not None
                or owners.alignment_transport._process is not None
                or owners.asr.generation != self._identity[0]
                or _configuration(owners) != self._identity[-1]
                or owners.process_pair is None
                or any(
                    getattr(process, "returncode", None) is None for process in owners.process_pair
                )
            ):
                raise ValueError("runtime cleanup is unconfirmed")
        except AttributeError, TypeError, ValueError:
            self._invalid = True
            self._commit_ready = False
            raise ValueError("closed ASR runtime verification is unavailable or changed") from None

    async def _verify_closed_bytes(self) -> None:
        self._check_closed()
        try:
            await join_cleanup(
                asyncio.create_task(
                    asyncio.to_thread(self._inventory.verify), name="frozen-asr-closed-verify"
                )
            )
            self._check_closed()
        except BaseException:
            self._invalid = True
            self._commit_ready = False
            raise

    async def verify_closed(self) -> dict[str, object]:
        """Rehash after successful context exit and confirmed child reaping."""
        if not self._commit_ready:
            raise ValueError("closed ASR runtime verification is unavailable or changed")
        await self._verify_closed_bytes()
        return self.proof()

    def verify_commit(self) -> None:
        """No await or file hashing; guard immediately before atomic submission."""
        if not self._commit_ready:
            raise ValueError("closed ASR runtime verification is unavailable or changed")
        try:
            self._check_closed()
            self._inventory.verify(hash_bytes=False)
        except BaseException:
            self._invalid = True
            self._commit_ready = False
            raise

    def candidate_spec(self, *, language: str | None = None) -> MeetingCandidateSpec:
        """Build comparison identity from frozen bytes and actual ready owners.

        SDK revision here binds the entire named-file closure and configuration;
        it is not an imported SDK version. Model revision is the observed
        structural handshake. These limitations remain explicit in proof().
        """
        self._check()
        self._inventory.verify(hash_bytes=False)
        owner = self._owners.asr
        assert owner.identity is not None and owner.runtime_revision is not None
        return _candidate_spec(
            self._owners,
            self._inventory,
            self._identity[-1],
            revision=owner.runtime_revision,
            language=language,
        )

    def proof(self) -> dict[str, object]:
        if self._active:
            self._check()
            self._inventory.verify(hash_bytes=False)
        else:
            self.verify_commit()
        return {
            "schema_version": 1,
            "preload_bytes_frozen": True,
            "post_prepare_bytes_stable": self._full_checks >= 1,
            "post_replay_bytes_stable": self._verified_replays > 0,
            "frozen_files_sha256": self._inventory.digest(""),
            "asr_model_files_sha256": self._inventory.digest("asr_model"),
            "aligner_model_files_sha256": self._inventory.digest("aligner_model"),
            "vad_files_sha256": self._inventory.digest("vad_model"),
            "interpreter_files_sha256": self._inventory.digest("interpreter:"),
            "declared_dependencies_sha256": self._inventory.digest("dependency:"),
            "source_files_sha256": self._inventory.digest("source:"),
            "actual_owner_generation_guarded": True,
            "window_decode_max_new_tokens": self._identity[3],
            "loaded_model_bytes_verified": False,
            "actual_imports_verified": False,
            "source_import_bytes_verified": False,
            "aligner_generation": "not_exposed_process_object_and_ready_identity_guarded",
            "model_revision_scope": "ready_structural_identity_not_weight_content",
            "dependency_scope": "explicit_files_not_actual_import_resolution",
            "sdk_revision_scope": "entire_frozen_file_closure_and_configuration_digest",
            "source_scope": "python_source_files_not_loaded_module_bytes",
            "host_dependency_writes": "any_change_in_declared_roots_rejected",
            "worker_lifecycle_owner": "private_root_two_children",
            "vad_lifecycle_owner": "host_process_shared_cache_not_cleared",
            "inherited_guard_descriptor_count": (
                len(self._owners.guard.descriptors) if self._owners.guard is not None else 0
            ),
            "owned_children_reaped": self._commit_ready,
            "post_close_bytes_stable": self._commit_ready,
            "commit_guard_ready": self._commit_ready,
        }

    async def evaluate(
        self,
        source: LockedAsrCase,
        spec: MeetingCandidateSpec,
        *,
        replay_plan: AsrReplayPlan = _FORMAL_REPLAY,
    ) -> dict[str, Any]:
        """Run a registered diagnostic over the same guarded private owners."""
        if self._evaluating or self._closing:
            raise ValueError("private ASR runtime permits one replay at a time")
        self._evaluating = True
        self._inflight = asyncio.current_task()
        try:
            await self.verify()
            language = spec.as_dict()["preset"].get("language")
            if language is not None and not isinstance(language, str):
                raise ValueError("invalid frozen ASR language")

            def observe() -> RuntimeObservation:
                measured = self.candidate_spec(language=language)
                return RuntimeObservation(measured.as_dict(), "runtime_observed")

            async def replay(data: Any) -> dict[str, Any]:
                if replay_plan.mode == "bounded_long_block_diagnostic":
                    assert replay_plan.block_seconds is not None
                    assert replay_plan.decode_timeout_seconds is not None
                    session = self._owners.factory.create(
                        identity=WindowIdentity("asr-diagnostic", 0, "long-block")
                    )
                    return await replay_long_blocks(
                        data,
                        spec,
                        session,
                        observe=observe,
                        block_seconds=replay_plan.block_seconds,
                        decode_timeout_seconds=replay_plan.decode_timeout_seconds,
                    )
                return await replay_realtime_session(
                    data,
                    spec,
                    self._owners.services,
                    observe=observe,
                )

            try:
                result = await evaluate_locked_asr_case(source, replay)
            finally:
                await self.verify()
            self._verified_replays += 1
            return {
                **result,
                "runtime_freeze": self.proof(),
                "a0_execution": "not_certified",
                "runtime_verification": "preload_files_and_owners_guarded_loaded_bytes_unproven",
            }
        finally:
            self._evaluating = False
            self._inflight = None

    async def _finish(self) -> None:
        self._closing = True
        if self._inflight is not None and not self._inflight.done():
            self._inflight.cancel()
            await asyncio.gather(self._inflight, return_exceptions=True)
            self._invalid = True
        self._active = False


def _private_settings(settings: Settings) -> Settings:
    if (
        not settings.asr_revision_windows_enabled
        or settings.qwen3_model_dir is None
        or settings.qwen3_aligner_model_dir is None
        or settings.qwen3_python is None
        or any(
            value is not None
            for value in (
                settings.qwen3_tts_model_dir,
                settings.qwen3_tts_clone_model_dir,
                settings.qwen3_tts_design_model_dir,
                settings.qwen3_tts_python,
                settings.diarization_coreml_model_path,
                settings.diarization_dynamic_model_dir,
                settings.job_spool_dir,
            )
        )
        or settings.diarization_dynamic_enabled
    ):
        raise ValueError("private runtime requires explicit ASR-only settings and aligner")
    return settings.model_copy(
        deep=True,
        update={
            "worker_idle_timeout_seconds": 0,
            "voice_design_idle_timeout_seconds": 0,
        },
    )


def _roots(owners: _Owners, dependencies: RuntimeDependencyRoots) -> dict[str, Path]:
    result = {
        "asr_model": owners.asr.config.model_dir,
        "aligner_model": owners.aligner.config.model_dir,
        "interpreter:host": Path(sys.executable),
        "interpreter:asr": owners.asr_config.python_executable,
        "interpreter:aligner": owners.aligner.config.python_executable,
    }
    settings = owners.services.settings
    if settings.resolves_to_silero_vad or settings.realtime_vad_shadow_enabled:
        path = settings.realtime_vad_model_path
        if path is None or not path.is_absolute():
            raise ValueError("explicit local VAD model is required")
        # Never certify a previously loaded host cache against a later hash.
        with vad_module._shared_sessions_lock:
            if any(Path(key).resolve() == path.resolve() for key in vad_module._shared_sessions):
                raise ValueError("private runtime requires a cold VAD cache key")
        result["vad_model"] = path
    for role, paths in (
        ("host", dependencies.host),
        ("asr", dependencies.asr),
        ("aligner", dependencies.aligner),
    ):
        for index, path in enumerate(paths):
            result[f"dependency:{role}:{index}"] = path
    return result


@asynccontextmanager
async def prepare_frozen_asr_runtime(
    settings: Settings,
    *,
    dependencies: RuntimeDependencyRoots,
    expected_spec: MeetingCandidateSpec | None = None,
    inherited_fds: tuple[int, ...] = (),
) -> AsyncIterator[FrozenAsrRuntime]:
    """Construct privately, freeze before loading, prepare, and own two children.

    Calling this API authorizes no operations by itself. It is deliberately not
    a CLI and never starts a managed service or RuntimeLifecycle. Cancellation
    joins preparation and cleanup before returning. A root that unexpectedly
    returns hot/shared owners is rejected without touching those workers.
    """
    if expected_spec is not None and type(expected_spec) is not MeetingCandidateSpec:
        raise ValueError("expected ASR candidate must be an immutable candidate spec")
    private = _private_settings(settings)
    # Constructor only: do not open/load the user's persistent voice registry.
    unused_voices = FileVoiceRegistry(
        Path("unused-asr-root/custom_voices.json"), Path("unused-asr-root/voices")
    )
    try:
        services = build_app_services(private, AppOverrides(voice_store=unused_voices))
    except Exception:
        raise ValueError("private ASR runtime construction failed") from None
    owners = _Owners.cold(services)
    runtime: FrozenAsrRuntime | None = None
    completed = False
    try:
        owners.guard = _InheritedGuard.capture(inherited_fds, private.port)
        for transport in (owners.asr_transport, owners.alignment_transport):
            transport._spec = replace(
                transport._spec,
                env={
                    **transport._spec.env,
                    "PYTHONDONTWRITEBYTECODE": "1",
                },
                pass_fds=inherited_fds,
            )
        try:
            roots = _roots(owners, dependencies)
            before_configuration = _configuration(owners)
            inventory = await join_cleanup(
                asyncio.create_task(
                    asyncio.to_thread(_Inventory.capture, roots), name="frozen-asr-preload-freeze"
                )
            )
            if any(
                entry.resolved.is_relative_to(_REPOSITORY)
                for (role, _), entry in inventory.entries.items()
                if role in {"asr_model", "aligner_model", "vad_model"}
            ):
                raise ValueError("model artifacts must remain outside repository")
            owners.check_objects()
            if _configuration(owners) != before_configuration:
                raise ValueError("ASR runtime owner configuration changed while freezing")
            if expected_spec is not None:
                # Preregistered model_revision is deliberately copied only for
                # this static comparison. It is independently measured after
                # ready and the complete identity must match before publication.
                before_spec = _candidate_spec(
                    owners,
                    inventory,
                    before_configuration,
                    revision=expected_spec.model_revision,
                    language=_expected_language(expected_spec),
                )
                validate_execution_identity(expected_spec, before_spec.as_dict())
            await join_cleanup(
                asyncio.create_task(services.prepare_revision_window(), name="frozen-asr-prepare")
            )
            if _configuration(owners) != before_configuration:
                raise ValueError("ASR runtime owner configuration changed while preparing")
            runtime = FrozenAsrRuntime(owners, inventory)
            await runtime.verify()
            if expected_spec is not None:
                validate_execution_identity(
                    expected_spec,
                    runtime.candidate_spec(language=_expected_language(expected_spec)).as_dict(),
                )
        except OSError, RuntimeError:
            raise ValueError("private ASR runtime preparation failed") from None
        yield runtime
        completed = True
    finally:
        if runtime is not None and not completed:
            runtime._invalid = True

        async def close() -> None:
            if runtime is not None:
                await runtime._finish()
            await owners.close()

        try:
            await join_cleanup(asyncio.create_task(close(), name="frozen-asr-owned-close"))
            if runtime is not None and completed and not runtime._invalid:
                await runtime._verify_closed_bytes()
                # Set only in the awaiting caller after joined checks returned;
                # cancellation cannot leave a successful proof in a background task.
                runtime._commit_ready = True
        except BaseException:
            if runtime is not None:
                runtime._invalid = True
                runtime._commit_ready = False
            raise
