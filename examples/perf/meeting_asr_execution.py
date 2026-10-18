"""Execute one independently locked ASR development fixture, without a service.

The configured port lease excludes that per-user port only. Named-file hashes
and private owner checks establish diagnostic reproducibility, not imported or
loaded model bytes, source provenance, trusted receipts, or A0 certification.
JSON controls, references and model directories reject leaf symlinks. Explicit
interpreter/dependency file symlinks retain their link paths for the runtime's
link-and-target freeze; directory symlinks and dependency discovery are refused.
"""

from __future__ import annotations

import asyncio
import contextlib
import hashlib
import os
import re
import stat
from dataclasses import dataclass, fields
from pathlib import Path, PurePosixPath
from typing import Any, get_args, get_origin

from meeting_asr_runtime import (
    AsrReplayPlan,
    RuntimeDependencyRoots,
    _private_settings,
    prepare_frozen_asr_runtime,
)
from meeting_asr_source import load_locked_asr_case
from meeting_candidate_execution import EvaluationPortLease, read_control_json
from meeting_checkpoint_execution import _fields, _path, _stamp
from meeting_development_fixture import _create_output, _write_json
from meeting_evaluation_identity import (
    MeetingCandidateSpec,
    candidate_digest,
    canonical_digest,
    validate_execution_identity,
)
from pydantic import model_validator
from pydantic_settings import BaseSettings, PydanticBaseSettingsSource, SettingsConfigDict

from speechrail.config import Settings
from speechrail.runtime.cleanup import join_cleanup

_ROOT = Path(__file__).resolve().parents[2]
_MAX_FILE_BYTES = 16 * 1024 * 1024
_MAX_TOTAL_BYTES = 32 * 1024 * 1024
_SHA = re.compile(r"[0-9a-f]{64}")
_SOURCES = (
    "examples/perf/meeting_asr_execution.py",
    "examples/perf/probe_meeting_asr_development.py",
    "examples/perf/meeting_asr_source.py",
    "examples/perf/meeting_asr_runtime.py",
    "examples/perf/meeting_realtime_asr_replay.py",
    "examples/perf/probe_meeting_asr_quality.py",
    "examples/perf/meeting_evaluation_identity.py",
    "examples/perf/meeting_candidate_execution.py",
    "examples/perf/meeting_checkpoint_execution.py",
    "examples/perf/meeting_development_fixture.py",
    "examples/perf/prepare_meeting_evaluation_manifest.py",
    "src/speechrail/config/__init__.py",
    "src/speechrail/runtime/cleanup.py",
)


class _LockedSettings(Settings):
    """Accept init JSON alone, including validators that otherwise inspect env."""

    model_config = SettingsConfigDict(env_file=None, extra="forbid", strict=True)

    @classmethod
    def settings_customise_sources(
        cls,
        settings_cls: type[BaseSettings],
        init_settings: PydanticBaseSettingsSource,
        env_settings: PydanticBaseSettingsSource,
        dotenv_settings: PydanticBaseSettingsSource,
        file_secret_settings: PydanticBaseSettingsSource,
    ) -> tuple[PydanticBaseSettingsSource, ...]:
        return (init_settings,)

    @model_validator(mode="before")
    @classmethod
    def reject_legacy_diarization_configuration(cls, data: Any) -> Any:
        # Public Settings also checks legacy environment keys in this validator.
        # This boundary rejects unknown JSON fields without consulting os.environ.
        return data


def _settings(value: dict[str, Any], port: int) -> Settings:
    if set(value) - Settings.model_fields.keys() or value.get("api_key") is not None:
        raise ValueError("ASR settings contain unknown fields or a service secret")
    configured = dict(value)
    for name, item in value.items():
        annotation = Settings.model_fields[name].annotation
        variants = (annotation, *get_args(annotation))
        if Path in variants and item is not None:
            if name == "qwen3_python":
                if not isinstance(item, str) or not Path(item).is_absolute():
                    raise ValueError("ASR interpreter requires an explicit absolute path")
                interpreter = Path(item)
                if not interpreter.resolve(strict=True).is_file() or not os.access(
                    interpreter, os.X_OK
                ):
                    raise ValueError("ASR interpreter must resolve to a regular executable")
                configured[name] = interpreter
            else:
                configured[name] = _path(item)
        elif get_origin(annotation) is tuple and isinstance(item, list):
            configured[name] = tuple(item)
    settings = _LockedSettings(**configured)
    if settings.host != "127.0.0.1" or settings.port != port or settings.api_key is not None:
        raise ValueError("ASR settings must bind the declared loopback port without a key")
    _private_settings(settings)  # Validate the same ASR-only boundary before any composition.
    _check_external_models(settings)
    return settings


def _walk_error(error: OSError) -> None:
    raise error


def _check_external_models(settings: Settings) -> None:
    count = 0
    for model in (
        settings.qwen3_model_dir,
        settings.qwen3_aligner_model_dir,
        settings.realtime_vad_model_path,
    ):
        if model is None:
            continue
        if model.resolve(strict=True).is_relative_to(_ROOT):
            raise ValueError("ASR model artifacts must remain external")
        if not model.is_dir():
            continue
        for directory, names, files in os.walk(model, followlinks=False, onerror=_walk_error):
            for name in (*names, *files):
                path = Path(directory) / name
                count += 1
                if count > 250_000:
                    raise ValueError("ASR model path count exceeds bound")
                if path.resolve(strict=True).is_relative_to(_ROOT):
                    raise ValueError("ASR model artifacts must remain external")
                if path.is_symlink() and path.is_dir():
                    raise ValueError("ASR model directories must not be symlinks")


def _regular(path: Path) -> None:
    if path.is_symlink() or not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError("ASR controls and source must remain regular files")


def _byte_digest(path: Path) -> str:
    before = _stamp(path)
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as handle:
        value = os.fstat(handle.fileno())
        observed = (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
        if observed != before or not stat.S_ISREG(value.st_mode) or value.st_size > _MAX_FILE_BYTES:
            raise ValueError("ASR implementation source changed or exceeds budget")
        contents = handle.read(_MAX_FILE_BYTES + 1)
        after = os.fstat(handle.fileno())
        if (
            len(contents) > _MAX_FILE_BYTES
            or (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
            != before
        ):
            raise ValueError("ASR implementation source changed while reading")
    return hashlib.sha256(contents).hexdigest()


@dataclass(frozen=True, slots=True)
class _File:
    path: Path
    resolved: Path
    stamp: tuple[int, ...]
    digest: str

    def verify_stamps(self) -> None:
        _regular(self.path)
        if self.path.resolve(strict=True) != self.resolved or _stamp(self.path) != self.stamp:
            raise ValueError("ASR frozen control or implementation changed")


@dataclass(frozen=True, slots=True)
class _Output:
    path: Path
    identity: tuple[int, int, int, int]

    @classmethod
    def create(cls, path: Path) -> _Output:
        output = _create_output(_path(str(path)))
        output.chmod(0o700)
        value = output.lstat()
        return cls(output, (value.st_dev, value.st_ino, value.st_mode, value.st_uid))

    def verify(self) -> None:
        value = self.path.lstat()
        if (
            self.path.resolve(strict=True) != self.path
            or not stat.S_ISDIR(value.st_mode)
            or (value.st_dev, value.st_ino, value.st_mode, value.st_uid) != self.identity
        ):
            raise ValueError("ASR output directory identity changed")

    def freeze_report(self, report: dict[str, Any]) -> _File:
        self.verify()
        path = self.path / "result.partial.json"
        _regular(path)
        bound = _File(path, path.resolve(strict=True), _stamp(path), canonical_digest(report))
        if canonical_digest(read_control_json(path)) != bound.digest:
            raise ValueError("ASR partial report differs from verified result")
        bound.verify_stamps()
        self.verify()
        return bound


class _AsrControls:
    """Bind control documents, path identities and executor bytes before loading."""

    def __init__(self, path: Path) -> None:
        self._documents: list[_File] = []
        self._paths: list[tuple[Path, Path, tuple[int, ...]]] = []
        self._bytes = 0
        self._sources: dict[str, _File] = {}
        for name in _SOURCES:
            source = _path(str(_ROOT / name))
            resolved, before = source.resolve(strict=True), _stamp(source)
            _regular(source)
            bound = _File(source, resolved, before, _byte_digest(source))
            bound.verify_stamps()
            self._sources[name] = bound
        self.lock = _fields(
            self.read(path),
            {
                "schema_version",
                "replay",
                "fixture_id",
                "service_port",
                "artifact_root",
                "manifest",
                "split_lock",
                "scorer_policy",
                "primary_reference",
                "settings",
                "dependencies",
                "candidate_spec",
            },
        )
        port = self.lock["service_port"]
        if (
            type(self.lock["schema_version"]) is not int
            or self.lock["schema_version"] != 2
            or type(port) is not int
            or not 1 <= port <= 65535
            or not isinstance(self.lock["fixture_id"], str)
            or not self.lock["fixture_id"]
        ):
            raise ValueError("ASR evaluation version, port or fixture invalid")
        self.replay = AsrReplayPlan.from_wire(self.lock["replay"])
        self.port, self.fixture_id = port, self.lock["fixture_id"]
        self.artifact_root = self.bind_path(self.lock["artifact_root"], directory=True)
        if self.artifact_root.is_relative_to(_ROOT):
            raise ValueError("ASR artifacts must remain external")
        self.manifest = self.document(self.lock["manifest"])
        self.split_lock = self.document(self.lock["split_lock"])
        self.policy = self.document(self.lock["scorer_policy"])
        self.settings = _settings(self.document(self.lock["settings"]), port)
        specification = _fields(
            self.document(self.lock["candidate_spec"]),
            {field.name for field in fields(MeetingCandidateSpec)},
        )
        self.expected_spec = MeetingCandidateSpec(**specification)
        dependencies = _fields(self.lock["dependencies"], {"host", "asr", "aligner"})
        declared: dict[str, tuple[Path, ...]] = {}
        for role, paths in dependencies.items():
            if not isinstance(paths, list) or not 1 <= len(paths) <= 16:
                raise ValueError("explicit dependency arrays are required for all roles")
            declared[role] = tuple(self.bind_path(item, file_symlink=True) for item in paths)
        self.dependencies = RuntimeDependencyRoots(**declared)
        self.primary = _fields(self.lock["primary_reference"], {"path", "sha256"})
        relative = self.primary["path"]
        if (
            not isinstance(relative, str)
            or not relative
            or PurePosixPath(relative).is_absolute()
            or ".." in PurePosixPath(relative).parts
            or not isinstance(self.primary["sha256"], str)
            or _SHA.fullmatch(self.primary["sha256"]) is None
        ):
            raise ValueError("ASR primary reference descriptor invalid")
        primary = self.artifact_root / relative
        _regular(primary)
        self._account(primary)
        self.verify()

    def _account(self, path: Path) -> None:
        size = path.lstat().st_size
        self._bytes += size
        if size > _MAX_FILE_BYTES or self._bytes > _MAX_TOTAL_BYTES:
            raise ValueError("ASR controls exceed bounded input budget")

    def read(self, path: Path) -> dict[str, Any]:
        path = _path(str(path))
        resolved, before = path.resolve(strict=True), _stamp(path)
        _regular(path)
        self._account(path)
        value = read_control_json(path)
        bound = _File(path, resolved, before, canonical_digest(value))
        bound.verify_stamps()
        self._documents.append(bound)
        return value

    def document(self, descriptor: object) -> dict[str, Any]:
        entry = _fields(descriptor, {"path", "sha256"})
        if not isinstance(entry["sha256"], str) or _SHA.fullmatch(entry["sha256"]) is None:
            raise ValueError("ASR control descriptor digest invalid")
        value = self.read(_path(entry["path"]))
        if canonical_digest(value) != entry["sha256"]:
            raise ValueError("ASR control differs from independent lock")
        return value

    def bind_path(
        self,
        value: object,
        *,
        directory: bool | None = None,
        file_symlink: bool = False,
    ) -> Path:
        if file_symlink:
            if not isinstance(value, str) or not Path(value).is_absolute():
                raise ValueError("ASR dependencies require explicit absolute paths")
            path = Path(value)
        else:
            path = _path(value)
        resolved, before = path.resolve(strict=True), _stamp(path)
        mode = path.stat().st_mode
        if (
            not (stat.S_ISDIR(mode) or stat.S_ISREG(mode))
            or (path.is_symlink() and not (file_symlink and stat.S_ISREG(mode)))
            or (directory is not None and directory != stat.S_ISDIR(mode))
        ):
            raise ValueError("ASR declared path type invalid")
        self._paths.append((path, resolved, before))
        return path if file_symlink else resolved

    @property
    def source_digests(self) -> dict[str, str]:
        return {name: bound.digest for name, bound in self._sources.items()}

    def verify_stamps(self) -> None:
        for bound in (*self._documents, *self._sources.values()):
            bound.verify_stamps()
        for path, resolved, before in self._paths:
            current = _stamp(path)
            if path.resolve(strict=True) != resolved or (
                current[:2] != before[:2] if resolved.is_dir() else current != before
            ):
                raise ValueError("ASR declared path changed")

    def verify(self) -> None:
        self.verify_stamps()
        _check_external_models(self.settings)
        for bound in self._documents:
            if canonical_digest(read_control_json(bound.path)) != bound.digest:
                raise ValueError("ASR frozen control bytes changed")
        for bound in self._sources.values():
            if _byte_digest(bound.path) != bound.digest:
                raise ValueError("ASR frozen implementation bytes changed")
        self.verify_stamps()


async def execute_asr_development(
    *,
    evaluation_lock: Path,
    output_directory: Path,
) -> dict[str, Any]:
    """Replay one development fixture; commit only after both owners are reaped.

    Every blocking read, verification and write joins before cancellation can
    return. No await separates the final stamp/owner guards from exclusive link.
    Failed work may retain fixed failure/partial diagnostics, never result.json.
    """
    output: Path | None = None
    output_owner: _Output | None = None
    try:
        controls = await join_cleanup(
            asyncio.create_task(asyncio.to_thread(_AsrControls, evaluation_lock))
        )
        source = await join_cleanup(
            asyncio.create_task(
                asyncio.to_thread(
                    load_locked_asr_case,
                    controls.manifest,
                    controls.split_lock,
                    artifact_root=controls.artifact_root,
                    scorer_policy=controls.policy,
                    fixture_id=controls.fixture_id,
                    candidate_sha256=candidate_digest(controls.expected_spec),
                    primary_reference=controls.primary,
                )
            )
        )
        creating = asyncio.create_task(asyncio.to_thread(_Output.create, output_directory))
        try:
            output_owner = await join_cleanup(creating)
        except BaseException:
            if creating.done() and not creating.cancelled() and creating.exception() is None:
                output_owner = creating.result()
                output = output_owner.path
            raise
        output = output_owner.path
        with EvaluationPortLease(controls.port) as port:
            async with prepare_frozen_asr_runtime(
                controls.settings,
                dependencies=controls.dependencies,
                expected_spec=controls.expected_spec,
                inherited_fds=(port.descriptor,),
            ) as runtime:
                language = controls.expected_spec.preset.get("language")
                if language is not None and not isinstance(language, str):
                    raise ValueError("ASR candidate language invalid")
                validate_execution_identity(
                    controls.expected_spec, runtime.candidate_spec(language=language).as_dict()
                )
                result = await runtime.evaluate(
                    source, controls.expected_spec, replay_plan=controls.replay
                )
                if result.get("mode") != controls.replay.mode:
                    raise ValueError("ASR replay mode differs from registration")
                if controls.replay.mode == "bounded_long_block_diagnostic" and result.get(
                    "replay_policy_sha256"
                ) != canonical_digest(controls.replay.as_dict()):
                    raise ValueError("ASR long-block policy differs from registration")
            proof = await runtime.verify_closed()
            await join_cleanup(asyncio.create_task(asyncio.to_thread(source.verify)))
            await join_cleanup(asyncio.create_task(asyncio.to_thread(controls.verify)))
            report = {
                **result,
                "runtime_freeze": proof,
                "diagnostic_replay": controls.replay.as_dict(),
                "runtime_identity_verified": False,
                "certification_eligible": False,
                "a0_execution": "not_certified",
                "asr_control_sha256": canonical_digest(controls.lock),
                "asr_executor_sha256": canonical_digest(controls.source_digests),
                "development_execution": {
                    "configured_port_exclusion": True,
                    "exclusion_scope": "per_user_configured_port",
                    "private_runtime_closed_verified": True,
                    "input_files_verified": True,
                    "trusted_receipt": False,
                    "production_certification": False,
                },
            }
            output_owner.verify()
            await join_cleanup(
                asyncio.create_task(
                    asyncio.to_thread(_write_json, output / "result.partial.json", report)
                )
            )
            partial = await join_cleanup(
                asyncio.create_task(asyncio.to_thread(output_owner.freeze_report, report))
            )
            await runtime.verify_closed()
            await join_cleanup(asyncio.create_task(asyncio.to_thread(source.verify)))
            await join_cleanup(asyncio.create_task(asyncio.to_thread(controls.verify)))
            controls.verify_stamps()
            source.verify_stamps()
            runtime.verify_commit()
            output_owner.verify()
            partial.verify_stamps()
            # No asynchronous boundary remains before the exclusive commit.
            os.link(output / "result.partial.json", output / "result.json", follow_symlinks=False)
            return report
    except BaseException as error:
        if output is not None and output_owner is not None:
            with contextlib.suppress(Exception):
                output_owner.verify()
                await join_cleanup(
                    asyncio.create_task(
                        asyncio.to_thread(
                            _write_json,
                            output / "failure.json",
                            {
                                "schema_version": 1,
                                "status": "cancelled"
                                if isinstance(error, asyncio.CancelledError)
                                else "failed",
                                "code": "asr_development_execution_failed",
                            },
                        )
                    )
                )
        if isinstance(error, Exception):
            raise ValueError("locked ASR development execution failed") from None
        raise
