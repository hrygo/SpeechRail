"""Offline tests for the shared pinned vendor runtime bootstrap."""

from __future__ import annotations

import asyncio
import hashlib
import json
import subprocess
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import cast

import pytest

import speechrail.service.bootstrap as bootstrap
from speechrail.config.model_catalog import RuntimeLock
from speechrail.service.bootstrap import (
    RuntimeBootstrapError,
    RuntimeCurrentSnapshot,
    RuntimePaths,
    prepare_runtime,
    restore_runtime_current,
    runtime_key,
    snapshot_runtime_current,
)
from speechrail.service.paths import ServiceLayout
from speechrail.service.preflight import PreflightResult, run_preflight

_HASH = "a" * 64


def _role_file_hash(requirements: tuple[str, ...]) -> str:
    payload = ("\n".join(requirements) + "\n").encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _lock(
    *,
    lock_id: str = "fixture-runtime-v1",
    python: str = "3.12.14",
    ffmpeg: str = "imageio-ffmpeg==0.6.0",
    file_hashes: Mapping[str, str] | None = None,
) -> RuntimeLock:
    requirement = f"fixture-asr==1.0 --hash=sha256:{_HASH}"
    tts_requirement = f"fixture-tts==2.0 --hash=sha256:{_HASH}"
    return RuntimeLock(
        id=lock_id,
        python=python,
        asr_requirements=(requirement,),
        tts_requirements=(tts_requirement,),
        ffmpeg_artifact=ffmpeg,
        file_hashes=file_hashes
        or {
            "runtime/asr.txt": _role_file_hash((requirement,)),
            "runtime/tts.txt": _role_file_hash((tts_requirement,)),
        },
    )


class FakeRunner:
    """Record fixed argv and create only the files a fake uv runner owns."""

    def __init__(
        self,
        *,
        failure: Callable[[tuple[str, ...]], bool] | None = None,
        cancel: bool = False,
    ) -> None:
        self.calls: list[tuple[str, ...]] = []
        self.failure = failure
        self.cancel = cancel

    def __call__(self, command: tuple[str, ...]) -> subprocess.CompletedProcess[str]:
        self.calls.append(command)
        if self.cancel:
            raise asyncio.CancelledError
        if self.failure is not None and self.failure(command):
            return subprocess.CompletedProcess(command, 1, stdout="", stderr="fake failure")
        if command[:2] == ("uv", "venv"):
            environment = Path(command[-1])
            python = environment / "bin" / "python"
            python.parent.mkdir(parents=True, exist_ok=True)
            python.write_text("fake python\n", encoding="utf-8")
            python.chmod(0o700)
        if command[:3] == ("uv", "pip", "install") and "--prefix" in command:
            prefix = Path(command[command.index("--prefix") + 1])
            ffmpeg = prefix / "bin" / "ffmpeg"
            ffmpeg.parent.mkdir(parents=True, exist_ok=True)
            ffmpeg.write_text("fake ffmpeg\n", encoding="utf-8")
            ffmpeg.chmod(0o700)
        if len(command) >= 4 and any("export-ffmpeg" in item for item in command):
            ffmpeg = Path(command[-1])
            ffmpeg.parent.mkdir(parents=True, exist_ok=True)
            ffmpeg.write_text("fake ffmpeg\n", encoding="utf-8")
            ffmpeg.chmod(0o700)
        return subprocess.CompletedProcess(command, 0, stdout="", stderr="")


def _write_private_config(layout: ServiceLayout) -> None:
    layout.ensure_directories()
    layout.config_file.write_text(
        "SPEECHRAIL_ALLOW_MODEL_DOWNLOADS=false\n"
        "SPEECHRAIL_TTS_ALLOW_MODEL_DOWNLOADS=false\n",
        encoding="utf-8",
    )
    layout.config_file.chmod(0o600)


def _check(result: object, name: str) -> bool:
    checks = cast(PreflightResult, result).checks
    return next(check for check in checks if check.name == name).ok


def test_runtime_identity_does_not_depend_on_preset() -> None:
    lock = {"python": "3.12.0", "asr": ["a==1"], "tts": ["b==1"], "ffmpeg": "f1"}

    assert runtime_key(lock) == runtime_key(dict(lock))


def test_runtime_identity_accepts_lock_model_and_normalized_mapping() -> None:
    lock = _lock()

    assert runtime_key(lock) == runtime_key(lock.model_dump())


def test_runtime_identity_changes_when_any_lock_content_changes() -> None:
    lock = _lock()

    assert runtime_key(lock) != runtime_key(lock.model_copy(update={"python": "3.12.13"}))
    assert runtime_key(lock) != runtime_key(lock.model_copy(update={"id": "other"}))
    assert runtime_key(lock) != runtime_key(
        lock.model_copy(update={"file_hashes": {"runtime/asr.txt": "b" * 64}})
    )


@pytest.mark.parametrize(
    "value",
    [
        {},
        {"python": "3.12.0", "asr": [], "tts": ["b==1"], "ffmpeg": "f1"},
        {
            "python": "3.12.0",
            "asr": ["a==1"],
            "tts": ["b==1"],
            "ffmpeg": "f1",
            "unknown": True,
        },
        {"python": "3.12.0", "asr": [object()], "tts": ["b==1"], "ffmpeg": "f1"},
    ],
)
def test_runtime_identity_rejects_unknown_incomplete_or_nonserializable_mapping(
    value: Mapping[str, object],
) -> None:
    with pytest.raises(RuntimeBootstrapError, match="lock"):
        runtime_key(value)


def test_prepare_runtime_uses_one_release_per_lock_and_shared_python_version(
    tmp_path: Path,
) -> None:
    lock = _lock()
    runner = FakeRunner()

    result = prepare_runtime(lock, tmp_path, runner)

    assert isinstance(result, RuntimePaths)
    assert result.release == tmp_path / "vendor" / runtime_key(lock)
    assert result.asr_python.is_absolute()
    assert result.tts_python.is_absolute()
    assert result.ffmpeg.is_absolute()
    assert result.asr_python.is_relative_to(result.release)
    assert result.tts_python.is_relative_to(result.release)
    assert result.ffmpeg.is_relative_to(result.release)
    assert result.asr_python.parent.parent == result.release
    assert result.tts_python.parent.parent == result.release
    assert result.asr_python == result.tts_python
    assert result.asr_python.is_file()
    assert result.tts_python.is_file()
    assert result.ffmpeg.is_file()
    install_calls = [command for command in runner.calls if command[:2] == ("uv", "pip")]
    assert install_calls
    assert all("--only-binary" in command for command in install_calls)
    assert all("--require-hashes" in command for command in install_calls)
    assert all("--python-platform" not in command for command in install_calls)
    sync_call = next(command for command in runner.calls if command[:3] == ("uv", "pip", "sync"))
    assert "-r" not in sync_call
    assert sync_call[-2].endswith("/requirements/asr.txt")
    assert sync_call[-1].endswith("/requirements/tts.txt")
    assert all("sh" not in command and "bash" not in command for command in runner.calls)

    metadata = json.loads((result.release / "runtime.json").read_text(encoding="utf-8"))
    assert metadata["runtime_key"] == runtime_key(lock)
    assert metadata["lock_id"] == lock.id
    assert metadata["python"] == lock.python


def test_prepare_runtime_is_idempotent_for_same_lock(tmp_path: Path) -> None:
    lock = _lock()
    first_runner = FakeRunner()
    first = prepare_runtime(lock, tmp_path, first_runner)
    second_runner = FakeRunner()

    second = prepare_runtime(lock, tmp_path, second_runner)

    assert second == first
    assert second_runner.calls == []


def test_prepare_runtime_reuses_verified_inactive_release(tmp_path: Path) -> None:
    first_lock = _lock(lock_id="fixture-runtime-first")
    second_lock = _lock(lock_id="fixture-runtime-second")
    first = prepare_runtime(first_lock, tmp_path, FakeRunner())
    second = prepare_runtime(second_lock, tmp_path, FakeRunner())

    runner = FakeRunner()
    reused = prepare_runtime(first_lock, tmp_path, runner)

    assert reused == first
    assert runner.calls == []
    assert second.release.is_dir()
    assert (tmp_path / "vendor" / "current").resolve() == first.release.resolve()


def test_runtime_current_snapshot_restores_after_later_failure(tmp_path: Path) -> None:
    first_lock = _lock(lock_id="fixture-runtime-first")
    second_lock = _lock(lock_id="fixture-runtime-second")
    first = prepare_runtime(first_lock, tmp_path, FakeRunner())
    snapshot = snapshot_runtime_current(tmp_path)

    second = prepare_runtime(second_lock, tmp_path, FakeRunner())
    assert second.release != first.release
    assert (tmp_path / "vendor" / "current").resolve() == second.release.resolve()

    assert isinstance(snapshot, RuntimeCurrentSnapshot)
    restore_runtime_current(snapshot)

    assert (tmp_path / "vendor" / "current").resolve() == first.release.resolve()
    assert first.release.is_dir()
    assert second.release.is_dir()


def test_runtime_current_snapshot_restores_missing_pointer_after_failure(
    tmp_path: Path,
) -> None:
    lock = _lock()
    snapshot = snapshot_runtime_current(tmp_path)

    prepared = prepare_runtime(lock, tmp_path, FakeRunner())
    assert (tmp_path / "vendor" / "current").is_symlink()

    restore_runtime_current(snapshot)

    current = tmp_path / "vendor" / "current"
    assert not current.exists()
    assert not current.is_symlink()
    assert prepared.release.is_dir()


def test_prepare_runtime_reads_hashed_role_files_and_checks_tokens(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    lock = _lock()
    assets = tmp_path / "assets"
    runtime = assets / "runtime"
    runtime.mkdir(parents=True)
    (runtime / "asr.txt").write_bytes(
        ("\n".join(lock.asr_requirements) + "\n").encode("utf-8")
    )
    (runtime / "tts.txt").write_bytes(
        ("\n".join(lock.tts_requirements) + "\n").encode("utf-8")
    )
    monkeypatch.setattr(bootstrap, "_ASSET_ROOT", assets)

    result = prepare_runtime(lock, tmp_path / "app", FakeRunner())

    assert (result.release / "requirements" / "asr.txt").read_bytes() == (
        runtime / "asr.txt"
    ).read_bytes()
    assert (result.release / "requirements" / "tts.txt").read_bytes() == (
        runtime / "tts.txt"
    ).read_bytes()


def test_prepare_runtime_rejects_role_file_hash_mismatch(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    lock = _lock()
    assets = tmp_path / "assets"
    runtime = assets / "runtime"
    runtime.mkdir(parents=True)
    (runtime / "asr.txt").write_text("not-the-locked-requirement\n", encoding="utf-8")
    (runtime / "tts.txt").write_bytes(
        ("\n".join(lock.tts_requirements) + "\n").encode("utf-8")
    )
    monkeypatch.setattr(bootstrap, "_ASSET_ROOT", assets)

    with pytest.raises(RuntimeBootstrapError, match="hash"):
        prepare_runtime(lock, tmp_path / "app", FakeRunner())


def test_prepare_runtime_rejects_role_file_token_mismatch(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    lock = _lock()
    wrong_asr = ("other-asr==9.0 --hash=sha256:" + _HASH + "\n").encode("utf-8")
    assets = tmp_path / "assets"
    runtime = assets / "runtime"
    runtime.mkdir(parents=True)
    (runtime / "asr.txt").write_bytes(wrong_asr)
    (runtime / "tts.txt").write_bytes(
        ("\n".join(lock.tts_requirements) + "\n").encode("utf-8")
    )
    mismatched_hashes = {
        "runtime/asr.txt": hashlib.sha256(wrong_asr).hexdigest(),
        "runtime/tts.txt": lock.file_hashes["runtime/tts.txt"],
    }
    lock = _lock(file_hashes=mismatched_hashes)
    monkeypatch.setattr(bootstrap, "_ASSET_ROOT", assets)

    with pytest.raises(RuntimeBootstrapError, match=r"requirement|token"):
        prepare_runtime(lock, tmp_path / "app", FakeRunner())


def test_prepare_runtime_installs_ffmpeg_from_hashed_requirements_file(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    lock = _lock()
    runner = FakeRunner()
    result = prepare_runtime(lock, tmp_path, runner)

    ffmpeg_calls = [
        command
        for command in runner.calls
        if command[:3] == ("uv", "pip", "install")
        and "-r" in command
        and command[command.index("-r") + 1].endswith("/requirements/ffmpeg.txt")
    ]
    assert len(ffmpeg_calls) == 1
    ffmpeg_call = ffmpeg_calls[0]
    assert ffmpeg_call[-1].endswith("/requirements/ffmpeg.txt")
    assert all(
        "imageio-ffmpeg==0.6.0 --hash=" not in argument for argument in ffmpeg_call
    )
    assert "imageio-ffmpeg==0.6.0" in (
        result.release / "requirements" / "ffmpeg.txt"
    ).read_text(encoding="utf-8")


def test_prepare_runtime_uses_new_release_for_changed_lock_and_keeps_old_current(
    tmp_path: Path,
) -> None:
    old_lock = _lock()
    new_lock = _lock(lock_id="fixture-runtime-v2")
    old_runner = FakeRunner()
    old = prepare_runtime(old_lock, tmp_path, old_runner)
    new_runner = FakeRunner()

    new = prepare_runtime(new_lock, tmp_path, new_runner)

    current = tmp_path / "vendor" / "current"
    assert new.release != old.release
    assert current.is_symlink()
    assert current.resolve() == new.release.resolve()
    assert old.release.is_dir()


@pytest.mark.parametrize(
    "label, failure",
    [
        ("no arm64 wheel", lambda command: command[:3] == ("uv", "pip", "install")),
        (
            "hash failure",
            lambda command: "--require-hashes" in command and command[:2] == ("uv", "pip"),
        ),
        ("network failure", lambda command: command[:2] == ("uv", "venv")),
        ("runner nonzero", lambda command: command[:2] == ("uv", "venv")),
    ],
)
def test_prepare_runtime_failure_preserves_old_current_and_leaves_recoverable_staging(
    tmp_path: Path, label: str, failure: Callable[[tuple[str, ...]], bool]
) -> None:
    old = prepare_runtime(_lock(), tmp_path, FakeRunner())
    new_lock = _lock(lock_id=f"failed-{label.replace(' ', '-')}")
    current = tmp_path / "vendor" / "current"
    old_target = current.resolve()

    with pytest.raises(RuntimeBootstrapError):
        prepare_runtime(new_lock, tmp_path, FakeRunner(failure=failure))

    assert current.resolve() == old_target
    staging = tmp_path / "vendor" / ".staging"
    assert staging.is_dir()
    assert any(staging.iterdir())
    assert not (tmp_path / "vendor" / runtime_key(new_lock)).exists()
    assert old.release.is_dir()


def test_prepare_runtime_cancellation_preserves_old_current(tmp_path: Path) -> None:
    old = prepare_runtime(_lock(), tmp_path, FakeRunner())
    current = tmp_path / "vendor" / "current"

    with pytest.raises(asyncio.CancelledError):
        prepare_runtime(_lock(lock_id="cancelled"), tmp_path, FakeRunner(cancel=True))

    assert current.resolve() == old.release.resolve()
    assert (tmp_path / "vendor" / ".staging").is_dir()


def test_prepare_runtime_rejects_symlink_escape_from_runner(tmp_path: Path) -> None:
    outside = tmp_path / "outside"
    outside.mkdir()

    class EscapingRunner(FakeRunner):
        def __call__(self, command: tuple[str, ...]) -> subprocess.CompletedProcess[str]:
            result = super().__call__(command)
            if command[:2] == ("uv", "venv"):
                environment = Path(command[-1])
                python = environment / "bin" / "python"
                python.unlink()
                python.symlink_to(outside / "python")
            return result

    with pytest.raises(RuntimeBootstrapError, match=r"path|symlink"):
        prepare_runtime(_lock(), tmp_path, EscapingRunner())


def test_prepare_runtime_accepts_uv_style_external_python_symlink(tmp_path: Path) -> None:
    outside = tmp_path / "uv-managed-python" / "bin"
    outside.mkdir(parents=True)
    interpreter = outside / "python3.12"
    interpreter.write_text("fake managed python\n", encoding="utf-8")
    interpreter.chmod(0o700)

    class UvStyleRunner(FakeRunner):
        def __call__(self, command: tuple[str, ...]) -> subprocess.CompletedProcess[str]:
            result = super().__call__(command)
            if command[:2] == ("uv", "venv"):
                environment = Path(command[-1])
                python = environment / "bin" / "python"
                python.unlink()
                python.symlink_to(interpreter)
            return result

    result = prepare_runtime(_lock(), tmp_path / "app", UvStyleRunner())

    assert result.asr_python.is_symlink()
    assert result.asr_python.resolve() == interpreter.resolve()
    assert result.asr_python == result.tts_python


def test_preflight_accepts_prepared_runtime_without_external_paths(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    lock = _lock()
    prepare_runtime(lock, tmp_path, FakeRunner())
    layout = ServiceLayout.for_app_home(tmp_path)
    _write_private_config(layout)
    monkeypatch.setattr("speechrail.service.preflight.load_runtime_lock", lambda: lock)
    monkeypatch.setattr("speechrail.service.preflight.shutil.which", lambda _: None)
    monkeypatch.setattr("speechrail.service.preflight.FFMPEG_FALLBACKS", ())

    result = run_preflight(layout, require_tts=True, runner=FakeRunner())

    assert result.ok is False
    assert _check(result, "managed_runtime") is True
    assert _check(result, "managed_runtime_identity") is True
    assert _check(result, "managed_asr_runtime") is True
    assert _check(result, "managed_tts_runtime") is True
    assert _check(result, "managed_ffmpeg") is True


def test_preflight_rejects_prepared_runtime_identity_mismatch_without_model_load(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    lock = _lock()
    result_paths = prepare_runtime(lock, tmp_path, FakeRunner())
    metadata_path = result_paths.release / "runtime.json"
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    metadata["lock_id"] = "stale-lock"
    metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
    layout = ServiceLayout.for_app_home(tmp_path)
    _write_private_config(layout)
    monkeypatch.setattr("speechrail.service.preflight.load_runtime_lock", lambda: lock)
    monkeypatch.setattr("speechrail.service.preflight.shutil.which", lambda _: None)
    runner = FakeRunner()

    result = run_preflight(layout, require_tts=True, runner=runner)

    assert result.ok is False
    assert _check(result, "managed_runtime_identity") is False
    assert all("load" not in command for command in runner.calls)
    managed_message = next(
        check.message for check in result.checks if check.name == "managed_runtime_identity"
    )
    assert str(tmp_path) not in managed_message
    assert "vendor" not in managed_message


def test_prepare_runtime_registry_write_failure_preserves_current_and_registry(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    first_lock = _lock(lock_id="fixture-runtime-first")
    first = prepare_runtime(first_lock, tmp_path, FakeRunner())
    registry_path = tmp_path / "vendor" / "runtime-preparations.json"
    registry_before = registry_path.read_bytes()

    def fail_registry(*args: object, **kwargs: object) -> None:
        raise RuntimeBootstrapError("registry failed")

    monkeypatch.setattr(bootstrap, "_write_registry", fail_registry)
    with pytest.raises(RuntimeBootstrapError, match="registry failed"):
        prepare_runtime(_lock(lock_id="fixture-runtime-second"), tmp_path, FakeRunner())

    assert (tmp_path / "vendor" / "current").resolve() == first.release.resolve()
    assert registry_path.read_bytes() == registry_before
    assert first.release.is_dir()


def test_prepare_runtime_current_switch_failure_preserves_current_and_registry(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    first_lock = _lock(lock_id="fixture-runtime-first")
    first = prepare_runtime(first_lock, tmp_path, FakeRunner())
    registry_path = tmp_path / "vendor" / "runtime-preparations.json"
    registry_before = registry_path.read_bytes()

    def fail_switch(*args: object, **kwargs: object) -> Path | None:
        raise RuntimeBootstrapError("switch failed")

    monkeypatch.setattr(bootstrap, "_switch_current", fail_switch)
    with pytest.raises(RuntimeBootstrapError, match="switch failed"):
        prepare_runtime(_lock(lock_id="fixture-runtime-second"), tmp_path, FakeRunner())

    assert (tmp_path / "vendor" / "current").resolve() == first.release.resolve()
    assert registry_path.read_bytes() == registry_before


def test_preflight_rejects_worker_import_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    prepare_runtime(_lock(), tmp_path, FakeRunner())
    layout = ServiceLayout.for_app_home(tmp_path)
    _write_private_config(layout)
    monkeypatch.setattr("speechrail.service.preflight.load_runtime_lock", lambda: _lock())
    monkeypatch.setattr("speechrail.service.preflight.shutil.which", lambda _: None)

    def fail_import(command: tuple[str, ...]) -> bool:
        return "import" in command[-1] if command else False

    result = run_preflight(layout, require_tts=True, runner=FakeRunner(failure=fail_import))

    assert result.ok is False
    assert _check(result, "managed_asr_runtime") is False
    assert _check(result, "managed_tts_runtime") is False
