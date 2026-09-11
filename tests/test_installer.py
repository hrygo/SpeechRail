from __future__ import annotations

import hashlib
import importlib.util
import json
import subprocess
import sys
from collections.abc import Iterator
from pathlib import Path
from typing import cast, final, override

import httpx
import pytest

from speechrail.config import Settings
from speechrail.config.model_catalog import (
    ModelCatalog,
    SourceLocation,
    load_catalog,
    load_runtime_lock,
)
from speechrail.config.selection import resolve_selection
from speechrail.runtime.server_lock import ServerInstanceLock
from speechrail.service import diarization_assets
from speechrail.service.bootstrap import RuntimePaths
from speechrail.service.diarization_assets import DiarizationAssetError
from speechrail.service.modelscope import ModelScopeDownloader
from speechrail.service.paths import ServiceLayout
from speechrail.service.preflight import PreflightResult
from speechrail.service.profile_store import recover_selection

_INSTALLER_PATH = Path(__file__).parents[1] / "tools" / "install_macos.py"
_SPEC = importlib.util.spec_from_file_location("speechrail_test_installer", _INSTALLER_PATH)
assert _SPEC is not None and _SPEC.loader is not None
install_macos = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = install_macos
_SPEC.loader.exec_module(install_macos)

_REAL_MANAGED_DIARIZATION_PROVISIONING = install_macos._provision_managed_diarization_assets


@pytest.fixture(autouse=True)
def _isolate_managed_service_lock(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    original = install_macos.install_managed

    def isolated_install_managed(*args: object, **kwargs: object):
        kwargs.setdefault("server_lock_directory", tmp_path)
        return original(*args, **kwargs)

    monkeypatch.setattr(install_macos, "install_managed", isolated_install_managed)


@pytest.fixture(autouse=True)
def _stub_managed_diarization_provisioning(monkeypatch: pytest.MonkeyPatch) -> None:
    """Keep offline tests from downloading assets; the upgrade regression opts back in."""

    def fake_provisioning(app_home: Path, *, preset_id: str, downloader: object) -> None:
        del app_home, preset_id, downloader

    monkeypatch.setattr(
        install_macos, "_provision_managed_diarization_assets", fake_provisioning
    )


def _runner_that_creates_python(calls: list[tuple[str, ...]]):
    def runner(command: tuple[str, ...]) -> subprocess.CompletedProcess[str]:
        calls.append(command)
        if command[:2] == ("uv", "venv"):
            venv = Path(command[-1])
            venv.joinpath("bin").mkdir(parents=True)
            venv.joinpath("bin", "python").touch()
        return subprocess.CompletedProcess(command, 0, stdout="", stderr="")

    return runner


def _inputs(tmp_path: Path) -> tuple[Path, Path]:
    wheel = tmp_path / "speechrail-2.3.1-py3-none-any.whl"
    wheel.touch()
    app_home = tmp_path / "Application Support" / "SpeechRail"
    return wheel, app_home


def _fake_runtime(tmp_path: Path) -> RuntimePaths:
    release = tmp_path / "vendor" / "runtime-test"
    python = release / "bin" / "python"
    ffmpeg = release / "ffmpeg" / "bin" / "ffmpeg"
    python.parent.mkdir(parents=True)
    ffmpeg.parent.mkdir(parents=True)
    python.touch()
    ffmpeg.touch()
    return RuntimePaths(
        release=release,
        asr_python=python,
        tts_python=python,
        ffmpeg=ffmpeg,
        runtime_key="runtime-test",
        lock_id="runtime-v1",
    )


def _fake_runtime_switching(app_home: Path) -> RuntimePaths:
    vendor_root = app_home / "vendor"
    release = vendor_root / "runtime-next"
    python = release / "bin" / "python"
    ffmpeg = release / "ffmpeg" / "bin" / "ffmpeg"
    python.parent.mkdir(parents=True, exist_ok=True)
    ffmpeg.parent.mkdir(parents=True, exist_ok=True)
    python.touch()
    ffmpeg.touch()
    current = vendor_root / "current"
    if current.is_symlink():
        current.unlink()
    current.symlink_to(release, target_is_directory=True)
    return RuntimePaths(
        release=release,
        asr_python=python,
        tts_python=python,
        ffmpeg=ffmpeg,
        runtime_key="runtime-next",
        lock_id=load_runtime_lock().id,
    )


def _selection_payload() -> bytes:
    catalog = load_catalog()
    lock = load_runtime_lock()
    selected = catalog.preset("quality")
    return (
        json.dumps(
            {
                "schema_version": 1,
                "preset": "quality",
                "generation": 7,
                "asr": selected.asr,
                "tts": selected.tts,
                "runtime_lock_id": lock.id,
            },
            sort_keys=True,
        )
        + "\n"
    ).encode()


def test_managed_install_rejects_an_active_service_before_staging(tmp_path: Path) -> None:
    wheel, app_home = _inputs(tmp_path)
    lock = ServerInstanceLock(8201, directory=tmp_path)
    lock.acquire()
    try:
        with pytest.raises(install_macos.InstallerError, match="service to be stopped"):
            install_macos.install_managed(
                wheel,
                app_home=app_home,
                preset_id="quality",
                downloader=object(),
                server_lock_directory=tmp_path,
            )
    finally:
        lock.release()

    releases = app_home / "runtime" / "releases"
    assert releases.is_dir()
    assert list(releases.iterdir()) == []


def test_managed_state_remains_outside_release(tmp_path: Path) -> None:
    layout = ServiceLayout.for_app_home(tmp_path, user_home=tmp_path)

    assert layout.config_file == tmp_path / "config" / ".env"
    assert layout.current_runtime == tmp_path / "runtime" / "current"
    assert layout.models_root == tmp_path / "models"
    assert layout.vendor_root == tmp_path / "vendor"


def test_managed_install_prepares_preset_and_keeps_service_disabled(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    wheel, app_home = _inputs(tmp_path)
    calls: list[tuple[str, ...]] = []
    model_calls: list[str] = []
    runtime_calls: list[tuple[str, ...]] = []
    runtime = _fake_runtime(tmp_path)

    async def fake_prepare_models(preset_id: str, **kwargs: object) -> str:
        model_calls.append(preset_id)
        return "prepared-quality"

    def fake_prepare_runtime(lock: object, app_home: Path, runner: object) -> RuntimePaths:
        del lock, app_home, runner
        runtime_calls.append(("prepare-runtime",))
        return runtime

    monkeypatch.setattr(install_macos, "prepare_models", fake_prepare_models)
    monkeypatch.setattr(install_macos, "prepare_runtime", fake_prepare_runtime)
    monkeypatch.setattr(
        install_macos,
        "run_preflight",
        lambda *args, **kwargs: PreflightResult(ok=True, checks=()),
    )

    result = install_macos.install_managed(
        wheel,
        app_home=app_home,
        preset_id="quality",
        downloader=object(),
        runtime_runner=lambda command: subprocess.CompletedProcess(
            command, 0, stdout="", stderr=""
        ),
        runner=_runner_that_creates_python(calls),
    )

    layout = ServiceLayout.for_app_home(app_home)
    assert result.enabled is False
    assert result.prepared_id == "prepared-quality"
    assert result.runtime_key == "runtime-test"
    assert model_calls == ["quality"]
    assert runtime_calls == [("prepare-runtime",)]
    assert layout.current_runtime.is_symlink()
    assert layout.config_file.stat().st_mode & 0o777 == 0o600
    assert (app_home / "SpeechRail 设置.command").stat().st_mode & 0o777 == 0o700
    config = layout.config_file.read_text(encoding="utf-8")
    assert "SPEECHRAIL_HOST=127.0.0.1" in config
    stable_vendor_python = layout.vendor_current / "bin" / "python"
    assert f"SPEECHRAIL_QWEN3_PYTHON={stable_vendor_python}" in config
    assert f"SPEECHRAIL_QWEN3_TTS_PYTHON={stable_vendor_python}" in config
    assert (
        f"SPEECHRAIL_FFMPEG_PATH={layout.vendor_current / 'ffmpeg' / 'bin' / 'ffmpeg'}"
        in config
    )
    assert "SPEECHRAIL_API_KEY" not in config
    selection = json.loads((app_home / "config" / "selection.json").read_text())
    assert selection["preset"] == "quality"
    assert not any("launchctl" in part for command in calls for part in command)


def test_managed_install_defaults_to_mcp_extra(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    wheel, app_home = _inputs(tmp_path)
    calls: list[tuple[str, ...]] = []
    runtime = _fake_runtime(tmp_path)

    async def fake_prepare_models(preset_id: str, **kwargs: object) -> str:
        del preset_id, kwargs
        return "prepared-quality"

    monkeypatch.setattr(install_macos, "prepare_models", fake_prepare_models)
    monkeypatch.setattr(install_macos, "prepare_runtime", lambda *args, **kwargs: runtime)
    monkeypatch.setattr(
        install_macos,
        "run_preflight",
        lambda *args, **kwargs: PreflightResult(ok=True, checks=()),
    )

    install_macos.install_managed(
        wheel,
        app_home=app_home,
        preset_id="quality",
        downloader=object(),
        runtime_runner=lambda command: subprocess.CompletedProcess(
            command, 0, stdout="", stderr=""
        ),
        runner=_runner_that_creates_python(calls),
    )

    pip_installs = [command for command in calls if command[:2] == ("uv", "pip")]
    assert pip_installs, "expected a uv pip install call"
    requirement = pip_installs[0][-1]
    assert requirement.endswith("[mcp]"), requirement
    assert "[diarization]" not in requirement


def test_managed_install_adds_diarization_when_configured(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    wheel, app_home = _inputs(tmp_path)
    calls: list[tuple[str, ...]] = []
    runtime = _fake_runtime(tmp_path)
    env_file = tmp_path / "diarization.env"
    env_file.write_text(
        "SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH=/models/diar/SortformerNvidiaLow_v2.1.mlmodelc\n",
        encoding="utf-8",
    )

    async def fake_prepare_models(preset_id: str, **kwargs: object) -> str:
        del preset_id, kwargs
        return "prepared-quality"

    monkeypatch.setattr(install_macos, "prepare_models", fake_prepare_models)
    monkeypatch.setattr(install_macos, "prepare_runtime", lambda *args, **kwargs: runtime)
    monkeypatch.setattr(
        install_macos,
        "run_preflight",
        lambda *args, **kwargs: PreflightResult(ok=True, checks=()),
    )

    install_macos.install_managed(
        wheel,
        app_home=app_home,
        preset_id="quality",
        downloader=object(),
        runtime_runner=lambda command: subprocess.CompletedProcess(
            command, 0, stdout="", stderr=""
        ),
        runner=_runner_that_creates_python(calls),
        env_file=env_file,
    )

    pip_installs = [command for command in calls if command[:2] == ("uv", "pip")]
    assert pip_installs, "expected a uv pip install call"
    requirement = pip_installs[0][-1]
    assert requirement.endswith("[mcp,diarization]"), requirement


def test_managed_install_writes_verified_diarization_paths_for_fresh_install(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    wheel, app_home = _inputs(tmp_path)
    calls: list[tuple[str, ...]] = []
    runtime = _fake_runtime(tmp_path)
    coreml = tmp_path / "SortformerNvidiaLow_v2.1.mlmodelc"
    aligner = tmp_path / "Qwen3-ForcedAligner-0.6B"
    coreml.mkdir()
    aligner.mkdir()

    async def fake_prepare_models(preset_id: str, **kwargs: object) -> str:
        del preset_id, kwargs
        return "prepared-quality"

    monkeypatch.setattr(install_macos, "prepare_models", fake_prepare_models)
    monkeypatch.setattr(install_macos, "prepare_runtime", lambda *args, **kwargs: runtime)
    monkeypatch.setattr(
        install_macos,
        "run_preflight",
        lambda *args, **kwargs: PreflightResult(ok=True, checks=()),
    )

    install_macos.install_managed(
        wheel,
        app_home=app_home,
        preset_id="quality",
        downloader=object(),
        runtime_runner=lambda command: subprocess.CompletedProcess(
            command, 0, stdout="", stderr=""
        ),
        runner=_runner_that_creates_python(calls),
        diarization_assets=install_macos.DiarizationInstallPaths(coreml, aligner),
    )

    requirement = next(command[-1] for command in calls if command[:2] == ("uv", "pip"))
    assert requirement.endswith("[mcp,diarization]")
    config = (app_home / "config" / ".env").read_text(encoding="utf-8")
    assert f"SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH={coreml}" in config
    assert f"SPEECHRAIL_QWEN3_ALIGNER_MODEL_DIR={aligner}" in config


def test_managed_install_without_diarization_assets_omits_diarization_config(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    wheel, app_home = _inputs(tmp_path)
    calls: list[tuple[str, ...]] = []
    runtime = _fake_runtime(tmp_path)

    async def fake_prepare_models(preset_id: str, **kwargs: object) -> str:
        del preset_id, kwargs
        return "prepared-light"

    monkeypatch.setattr(install_macos, "prepare_models", fake_prepare_models)
    monkeypatch.setattr(install_macos, "prepare_runtime", lambda *args, **kwargs: runtime)
    monkeypatch.setattr(
        install_macos,
        "run_preflight",
        lambda *args, **kwargs: PreflightResult(ok=True, checks=()),
    )

    install_macos.install_managed(
        wheel,
        app_home=app_home,
        preset_id="light",
        downloader=object(),
        runtime_runner=lambda command: subprocess.CompletedProcess(
            command, 0, stdout="", stderr=""
        ),
        runner=_runner_that_creates_python(calls),
        diarization_assets=None,
    )

    requirement = next(command[-1] for command in calls if command[:2] == ("uv", "pip"))
    assert requirement.endswith("[mcp]")
    assert "[diarization]" not in requirement
    config = (app_home / "config" / ".env").read_text(encoding="utf-8")
    assert "SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH" not in config
    assert "SPEECHRAIL_QWEN3_ALIGNER_MODEL_DIR" not in config


def test_managed_install_same_preset_reuses_wheel_release(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    wheel, app_home = _inputs(tmp_path)
    calls: list[tuple[str, ...]] = []
    runtime = _fake_runtime(tmp_path)

    async def fake_prepare_models(preset_id: str, **kwargs: object) -> str:
        del preset_id, kwargs
        return "prepared-quality"

    monkeypatch.setattr(install_macos, "prepare_models", fake_prepare_models)
    monkeypatch.setattr(
        install_macos,
        "prepare_runtime",
        lambda *args, **kwargs: runtime,
    )
    monkeypatch.setattr(
        install_macos,
        "run_preflight",
        lambda *args, **kwargs: PreflightResult(ok=True, checks=()),
    )
    runner = _runner_that_creates_python(calls)

    install_macos.install_managed(
        wheel,
        app_home=app_home,
        preset_id="quality",
        downloader=object(),
        runtime_runner=lambda command: subprocess.CompletedProcess(
            command, 0, stdout="", stderr=""
        ),
        runner=runner,
    )
    selection_path = app_home / "config" / "selection.json"
    selection_before = selection_path.read_bytes()
    second = install_macos.install_managed(
        wheel,
        app_home=app_home,
        preset_id="quality",
        downloader=object(),
        runtime_runner=lambda command: subprocess.CompletedProcess(
            command, 0, stdout="", stderr=""
        ),
        runner=runner,
    )

    assert second.enabled is False
    assert sum(command[:2] == ("uv", "venv") for command in calls) == 1
    assert selection_path.read_bytes() == selection_before


@pytest.mark.parametrize("failure_stage", ["runtime", "preflight", "service", "profile"])
def test_managed_failure_restores_app_and_vendor_currents(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    failure_stage: str,
) -> None:
    wheel, app_home = _inputs(tmp_path)
    layout = ServiceLayout.for_app_home(app_home)
    layout.ensure_directories()
    old_release = layout.runtime_root / "releases" / "old"
    old_release.mkdir(parents=True)
    layout.current_runtime.symlink_to(old_release, target_is_directory=True)
    vendor_root = layout.vendor_root
    old_vendor = vendor_root / "runtime-old"
    old_vendor.mkdir(parents=True)
    vendor_current = layout.vendor_current
    vendor_current.symlink_to(old_vendor, target_is_directory=True)
    original_config = b"SPEECHRAIL_HOST=127.0.0.1\r\nSPEECHRAIL_API_KEY=keep\r\n"
    layout.config_file.write_bytes(original_config)
    layout.config_file.chmod(0o600)
    selection_path = app_home / "config" / "selection.json"
    original_selection = _selection_payload()
    selection_path.write_bytes(original_selection)
    selection_path.chmod(0o600)
    calls: list[tuple[str, ...]] = []

    async def fake_prepare_models(preset_id: str, **kwargs: object) -> str:
        del preset_id, kwargs
        return "prepared-quality"

    def fake_prepare_runtime(lock: object, prepared_app_home: Path, runner: object) -> RuntimePaths:
        del lock, runner
        if failure_stage == "runtime":
            raise install_macos.InstallerError("runtime preparation failed")
        return _fake_runtime_switching(prepared_app_home)

    monkeypatch.setattr(install_macos, "prepare_models", fake_prepare_models)
    monkeypatch.setattr(install_macos, "prepare_runtime", fake_prepare_runtime)
    monkeypatch.setattr(
        install_macos,
        "run_preflight",
        lambda *args, **kwargs: PreflightResult(
            ok=failure_stage != "preflight", checks=()
        ),
    )
    if failure_stage == "profile":
        monkeypatch.setattr(install_macos, "recover_selection", lambda _: None)

        class FailingProfileStore:
            def __init__(self, app_home: Path) -> None:
                del app_home

            def initialize(self, selection: object) -> None:
                del selection
                raise install_macos.InstallerError("profile initialization failed")

        monkeypatch.setattr(install_macos, "ProfileStore", FailingProfileStore)

    def runner(command: tuple[str, ...]) -> subprocess.CompletedProcess[str]:
        calls.append(command)
        if command[:2] == ("uv", "venv"):
            venv = Path(command[-1])
            venv.joinpath("bin").mkdir(parents=True)
            venv.joinpath("bin", "python").touch()
        if failure_stage == "service" and "service" in command and "install" in command:
            return subprocess.CompletedProcess(command, 1, stdout="", stderr="failed")
        return subprocess.CompletedProcess(command, 0, stdout="", stderr="")

    with pytest.raises(install_macos.InstallerError):
        install_macos.install_managed(
            wheel,
            app_home=app_home,
            preset_id="quality",
            downloader=object(),
            runtime_runner=lambda command: subprocess.CompletedProcess(
                command, 0, stdout="", stderr=""
            ),
            runner=runner,
        )

    assert layout.current_runtime.resolve() == old_release.resolve()
    assert vendor_current.resolve() == old_vendor.resolve()
    assert layout.config_file.read_bytes() == original_config
    assert selection_path.read_bytes() == original_selection
    assert not any("enable" in command for command in calls)


def test_managed_rollback_error_does_not_skip_app_cleanup(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    wheel, app_home = _inputs(tmp_path)
    layout = ServiceLayout.for_app_home(app_home)
    layout.ensure_directories()
    old_release = layout.runtime_root / "releases" / "old"
    old_release.mkdir(parents=True)
    layout.current_runtime.symlink_to(old_release, target_is_directory=True)
    old_vendor = layout.vendor_root / "runtime-old"
    old_vendor.mkdir(parents=True)
    layout.vendor_current.symlink_to(old_vendor, target_is_directory=True)

    async def fake_prepare_models(preset_id: str, **kwargs: object) -> str:
        del preset_id, kwargs
        return "prepared-quality"

    monkeypatch.setattr(install_macos, "prepare_models", fake_prepare_models)
    monkeypatch.setattr(
        install_macos,
        "prepare_runtime",
        lambda lock, prepared_app_home, runner: _fake_runtime_switching(prepared_app_home),
    )
    monkeypatch.setattr(
        install_macos,
        "run_preflight",
        lambda *args, **kwargs: PreflightResult(ok=False, checks=()),
    )

    def broken_restore(snapshot: object) -> None:
        del snapshot
        raise RuntimeError("restore failed")

    monkeypatch.setattr(install_macos, "restore_runtime_current", broken_restore)
    with pytest.raises(install_macos.InstallerError, match="rollback failed") as caught:
        install_macos.install_managed(
            wheel,
            app_home=app_home,
            preset_id="quality",
            downloader=object(),
            runtime_runner=lambda command: subprocess.CompletedProcess(
                command, 0, stdout="", stderr=""
            ),
            runner=_runner_that_creates_python([]),
        )

    assert isinstance(caught.value.__cause__, install_macos.InstallerError)
    assert layout.current_runtime.resolve() == old_release.resolve()
    assert not layout.config_file.exists()
    release = layout.runtime_root / "releases" / install_macos._release_id(wheel)
    assert not release.exists()


def test_managed_first_install_failure_removes_vendor_current_but_keeps_release(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    wheel, app_home = _inputs(tmp_path)
    layout = ServiceLayout.for_app_home(app_home)
    calls: list[tuple[str, ...]] = []

    async def fake_prepare_models(preset_id: str, **kwargs: object) -> str:
        del preset_id, kwargs
        return "prepared-quality"

    monkeypatch.setattr(install_macos, "prepare_models", fake_prepare_models)
    monkeypatch.setattr(
        install_macos,
        "prepare_runtime",
        lambda lock, prepared_app_home, runner: _fake_runtime_switching(prepared_app_home),
    )
    monkeypatch.setattr(
        install_macos,
        "run_preflight",
        lambda *args, **kwargs: PreflightResult(ok=False, checks=()),
    )

    with pytest.raises(install_macos.InstallerError, match="preflight failed"):
        install_macos.install_managed(
            wheel,
            app_home=app_home,
            preset_id="quality",
            downloader=object(),
            runtime_runner=lambda command: subprocess.CompletedProcess(
                command, 0, stdout="", stderr=""
            ),
            runner=_runner_that_creates_python(calls),
        )

    assert not layout.current_runtime.exists()
    assert not layout.current_runtime.is_symlink()
    assert not layout.vendor_current.exists()
    assert not layout.vendor_current.is_symlink()
    assert (layout.vendor_root / "runtime-next").is_dir()
    assert not (layout.runtime_releases / install_macos._release_id(wheel)).exists()


def test_managed_install_preserves_existing_config_bytes(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    wheel, app_home = _inputs(tmp_path)
    layout = ServiceLayout.for_app_home(app_home)
    layout.ensure_directories()
    original = b"SPEECHRAIL_HOST=127.0.0.1\r\nSPEECHRAIL_API_KEY=provided\r\n"
    layout.config_file.write_bytes(original)
    layout.config_file.chmod(0o600)
    runtime = _fake_runtime(tmp_path)

    async def fake_prepare_models(preset_id: str, **kwargs: object) -> str:
        del preset_id, kwargs
        return "prepared-quality"

    monkeypatch.setattr(install_macos, "prepare_models", fake_prepare_models)
    monkeypatch.setattr(install_macos, "prepare_runtime", lambda *args, **kwargs: runtime)
    monkeypatch.setattr(
        install_macos,
        "run_preflight",
        lambda *args, **kwargs: PreflightResult(ok=True, checks=()),
    )

    install_macos.install_managed(
        wheel,
        app_home=app_home,
        preset_id="quality",
        downloader=object(),
        runtime_runner=lambda command: subprocess.CompletedProcess(
            command, 0, stdout="", stderr=""
        ),
        runner=_runner_that_creates_python([]),
    )

    assert layout.config_file.read_bytes() == original


def test_managed_config_creation_refuses_racing_replacement(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    destination = tmp_path / "config" / ".env"
    destination.parent.mkdir(parents=True)
    competitor = b"SPEECHRAIL_HOST=127.0.0.1\nSPEECHRAIL_PORT=9999\n"

    def racing_link(source: Path, target: Path) -> None:
        del source
        Path(target).write_bytes(competitor)
        raise FileExistsError(target)

    monkeypatch.setattr(install_macos.os, "link", racing_link)
    with pytest.raises(install_macos.InstallerError, match="concurrently"):
        install_macos._write_private_config(destination, "SPEECHRAIL_HOST=127.0.0.1\n")

    assert destination.read_bytes() == competitor


def test_managed_env_file_copy_refuses_racing_replacement(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source = tmp_path / "source.env"
    source.write_bytes(b"SPEECHRAIL_HOST=127.0.0.1\r\n")
    destination = tmp_path / "config" / ".env"
    destination.parent.mkdir(parents=True)
    competitor = b"SPEECHRAIL_PORT=9999\n"

    def racing_link(source_path: Path, target: Path) -> None:
        del source_path
        Path(target).write_bytes(competitor)
        raise FileExistsError(target)

    monkeypatch.setattr(install_macos.os, "link", racing_link)
    with pytest.raises(install_macos.InstallerError, match="concurrently"):
        install_macos._copy_config_exclusive(source, destination)

    assert destination.read_bytes() == competitor


def test_private_config_cleans_its_file_when_directory_fsync_fails(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    destination = tmp_path / "config" / ".env"
    fsync_calls = 0
    real_fsync = install_macos.os.fsync

    def fail_directory_fsync(descriptor: int) -> None:
        nonlocal fsync_calls
        fsync_calls += 1
        if fsync_calls == 2:
            raise OSError("directory fsync failed")
        real_fsync(descriptor)

    monkeypatch.setattr(install_macos.os, "fsync", fail_directory_fsync)
    with pytest.raises(OSError, match="directory fsync failed"):
        install_macos._write_private_config(destination, "SPEECHRAIL_HOST=127.0.0.1\n")

    assert not destination.exists()


def test_managed_install_only_enables_when_requested(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    wheel, app_home = _inputs(tmp_path)
    calls: list[tuple[str, ...]] = []
    runtime = _fake_runtime(tmp_path)

    async def fake_prepare_models(preset_id: str, **kwargs: object) -> str:
        del preset_id, kwargs
        return "prepared-quality"

    monkeypatch.setattr(install_macos, "prepare_models", fake_prepare_models)
    monkeypatch.setattr(install_macos, "prepare_runtime", lambda *args, **kwargs: runtime)
    monkeypatch.setattr(
        install_macos,
        "run_preflight",
        lambda *args, **kwargs: PreflightResult(ok=True, checks=()),
    )

    result = install_macos.install_managed(
        wheel,
        app_home=app_home,
        preset_id="quality",
        downloader=object(),
        runtime_runner=lambda command: subprocess.CompletedProcess(
            command, 0, stdout="", stderr=""
        ),
        enable=True,
        runner=_runner_that_creates_python(calls),
    )

    assert result.enabled is True
    assert any("service" in command and "enable" in command for command in calls)


def test_managed_first_install_enable_failure_removes_selection(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    wheel, app_home = _inputs(tmp_path)
    layout = ServiceLayout.for_app_home(app_home)
    calls: list[tuple[str, ...]] = []

    async def fake_prepare_models(preset_id: str, **kwargs: object) -> str:
        del preset_id, kwargs
        return "prepared-quality"

    monkeypatch.setattr(install_macos, "prepare_models", fake_prepare_models)
    monkeypatch.setattr(
        install_macos,
        "prepare_runtime",
        lambda lock, prepared_app_home, runner: _fake_runtime_switching(prepared_app_home),
    )
    monkeypatch.setattr(
        install_macos,
        "run_preflight",
        lambda *args, **kwargs: PreflightResult(ok=True, checks=()),
    )

    def runner(command: tuple[str, ...]) -> subprocess.CompletedProcess[str]:
        calls.append(command)
        if command[:2] == ("uv", "venv"):
            venv = Path(command[-1])
            venv.joinpath("bin").mkdir(parents=True)
            venv.joinpath("bin", "python").touch()
        if "service" in command and "enable" in command:
            return subprocess.CompletedProcess(command, 1, stdout="", stderr="failed")
        return subprocess.CompletedProcess(command, 0, stdout="", stderr="")

    with pytest.raises(install_macos.InstallerError):
        install_macos.install_managed(
            wheel,
            app_home=app_home,
            preset_id="quality",
            downloader=object(),
            runtime_runner=lambda command: subprocess.CompletedProcess(
                command, 0, stdout="", stderr=""
            ),
            enable=True,
            runner=runner,
        )

    assert not (app_home / "config" / "selection.json").exists()
    assert not layout.current_runtime.exists()
    assert not (layout.runtime_releases / install_macos._release_id(wheel)).exists()
    assert any("service" in command and "enable" in command for command in calls)
    assert any("service" in command and "stop" in command for command in calls)


def test_managed_post_enable_verifier_failure_rolls_back(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    wheel, app_home = _inputs(tmp_path)
    layout = ServiceLayout.for_app_home(app_home)
    calls: list[tuple[str, ...]] = []

    async def fake_prepare_models(preset_id: str, **kwargs: object) -> str:
        del preset_id, kwargs
        return "prepared-quality"

    monkeypatch.setattr(install_macos, "prepare_models", fake_prepare_models)
    monkeypatch.setattr(
        install_macos,
        "prepare_runtime",
        lambda lock, prepared_app_home, runner: _fake_runtime_switching(prepared_app_home),
    )
    monkeypatch.setattr(
        install_macos,
        "run_preflight",
        lambda *args, **kwargs: PreflightResult(ok=True, checks=()),
    )

    def runner(command: tuple[str, ...]) -> subprocess.CompletedProcess[str]:
        calls.append(command)
        if command[:2] == ("uv", "venv"):
            venv = Path(command[-1])
            venv.joinpath("bin").mkdir(parents=True)
            venv.joinpath("bin", "python").touch()
        return subprocess.CompletedProcess(command, 0, stdout="", stderr="")

    def failed_smoke(app_home_arg: Path, prepared_id: str) -> None:
        del app_home_arg, prepared_id
        raise install_macos.InstallerError("smoke failed")

    with pytest.raises(install_macos.InstallerError, match="smoke failed"):
        install_macos.install_managed(
            wheel,
            app_home=app_home,
            preset_id="quality",
            downloader=object(),
            runtime_runner=lambda command: subprocess.CompletedProcess(
                command, 0, stdout="", stderr=""
            ),
            enable=True,
            post_enable=failed_smoke,
            runner=runner,
        )

    assert not (app_home / "config" / "selection.json").exists()
    assert not layout.current_runtime.exists()
    assert not (layout.runtime_releases / install_macos._release_id(wheel)).exists()
    assert any("service" in command and "enable" in command for command in calls)
    assert any("service" in command and "stop" in command for command in calls)


def test_managed_preparation_failure_keeps_previous_current_runtime(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    wheel, app_home = _inputs(tmp_path)
    layout = ServiceLayout.for_app_home(app_home)
    layout.ensure_directories()
    old_release = layout.runtime_root / "releases" / "old"
    old_release.mkdir(parents=True)
    layout.current_runtime.symlink_to(old_release, target_is_directory=True)

    async def failing_prepare_models(preset_id: str, **kwargs: object) -> str:
        del preset_id, kwargs
        raise RuntimeError("fake downloader failed")

    monkeypatch.setattr(install_macos, "prepare_models", failing_prepare_models)
    with pytest.raises(install_macos.InstallerError, match="model preparation failed"):
        install_macos.install_managed(
            wheel,
            app_home=app_home,
            preset_id="quality",
            downloader=object(),
            runtime_runner=lambda command: subprocess.CompletedProcess(
                command, 0, stdout="", stderr=""
            ),
            runner=_runner_that_creates_python([]),
        )

    assert layout.current_runtime.resolve() == old_release.resolve()


def test_explicit_env_installer_surface_is_removed() -> None:
    assert not hasattr(install_macos, "install_wheel")
    assert not hasattr(install_macos, "InstallLayout")
    assert not hasattr(install_macos, "main")


def test_preflight_runs_from_the_newly_installed_wheel(tmp_path: Path) -> None:
    layout = ServiceLayout.for_app_home(tmp_path / "SpeechRail")
    calls: list[tuple[str, ...]] = []

    result = install_macos.run_preflight(
        tmp_path / "runtime" / "bin" / "python",
        layout,
        require_tts=False,
        runner=_runner_that_creates_python(calls),
    )

    assert result.ok is True
    assert calls == [
        (
            str(tmp_path / "runtime" / "bin" / "python"),
            "-m",
            "speechrail",
            "service",
            "preflight",
            "--app-home",
            str(layout.app_home),
            "--host-python",
            str(tmp_path / "runtime" / "bin" / "python"),
            "--asr-only",
        )
    ]


_B2_REVISION = "a" * 40
_B2_REPOSITORY = "fixture/model"
_B2_ALIGNER_PAYLOADS = {
    "config.json": b"aligner-config",
    "model.safetensors": b"aligner-weights",
    "tokenizer.json": b"aligner-tokenizer",
}
_B2_COREML_PATH = "coremldata.bin"
_B2_COREML_BYTES = b"coreml-bundle"
_B2_BUNDLE_NAME = "SortformerNvidiaLow_v2.1.mlmodelc"


def _b2_file(path: str, payload: bytes) -> dict[str, object]:
    return {
        "path": path,
        "size": len(payload),
        "sha256": hashlib.sha256(payload).hexdigest(),
    }


def _b2_files(payloads: dict[str, bytes]) -> list[dict[str, object]]:
    return [_b2_file(path, payload) for path, payload in payloads.items()]


def _b2_artifact(
    key: str, family: str, variant: str, bits: int | None, files: list[dict[str, object]]
) -> dict[str, object]:
    return {
        "key": key,
        "model_id": _B2_REPOSITORY,
        "revision": _B2_REVISION,
        "family": family,
        "variant": variant,
        "quantization": {
            "bits": bits,
            "group_size": 64 if bits is not None else None,
            "format": "mlx" if bits is not None else "none",
        },
        "files": files,
        "sources": [
            {
                "provider": "modelscope",
                "repository": _B2_REPOSITORY,
                "revision": _B2_REVISION,
            }
        ],
    }


def _b2_asr_variant(prefix: bytes) -> list[dict[str, object]]:
    return _b2_files(
        {
            "config.json": prefix + b"cfg",
            "model.safetensors": prefix + b"weights",
            "tokenizer.json": prefix + b"tok",
        }
    )


def _b2_tts_variant(prefix: bytes) -> list[dict[str, object]]:
    return _b2_files(
        {
            "config.json": prefix + b"cfg",
            "model.safetensors": prefix + b"weights",
            "tokenizer.json": prefix + b"tok",
            "speech_tokenizer/config.json": prefix + b"codec",
            "speech_tokenizer/weights.safetensors": prefix + b"codecw",
        }
    )


def _b2_catalog() -> ModelCatalog:
    aligner_files = _b2_files(_B2_ALIGNER_PAYLOADS)
    return ModelCatalog.model_validate(
        {
            "schema_version": 2,
            "artifacts": [
                _b2_artifact("asr-17b-q8", "qwen3_asr", "asr", 8, _b2_asr_variant(b"a17")),
                _b2_artifact("asr-06b-q4", "qwen3_asr", "asr", 4, _b2_asr_variant(b"a06")),
                _b2_artifact(
                    "tts-17b-design-q8",
                    "qwen3_tts",
                    "voice_design",
                    8,
                    _b2_tts_variant(b"d17"),
                ),
                _b2_artifact(
                    "tts-06b-custom-q8",
                    "qwen3_tts",
                    "custom_voice",
                    8,
                    _b2_tts_variant(b"c06"),
                ),
                _b2_artifact(
                    "tts-06b-custom-q4",
                    "qwen3_tts",
                    "custom_voice",
                    4,
                    _b2_tts_variant(b"c04"),
                ),
                _b2_artifact("aligner-q8", "qwen3_forced_aligner", "aligner", 8, aligner_files),
                _b2_artifact(
                    "aligner-bf16", "qwen3_forced_aligner", "aligner", None, aligner_files
                ),
            ],
            "presets": [
                {
                    "id": "light",
                    "asr": "asr-06b-q4",
                    "tts": "tts-06b-custom-q4",
                    "aligner": None,
                    "diarization": False,
                },
                {
                    "id": "balanced",
                    "asr": "asr-17b-q8",
                    "tts": "tts-06b-custom-q8",
                    "aligner": "aligner-q8",
                    "diarization": True,
                },
                {
                    "id": "quality",
                    "asr": "asr-17b-q8",
                    "tts": "tts-17b-design-q8",
                    "aligner": "aligner-bf16",
                    "diarization": True,
                },
            ],
            "precision_policy": {
                "light": {"asr": 4, "tts": 4, "aligner": None},
                "balanced": {"asr": 8, "tts": 8, "aligner": 8},
                "quality": {"asr": 8, "tts": 8, "aligner": "bf16"},
            },
        }
    )


@final
class _B2StreamResponse:
    def __init__(self, payload: bytes) -> None:
        self._payload = payload

    def __enter__(self) -> _B2StreamResponse:
        return self

    def __exit__(self, *exc: object) -> bool:
        return False

    def raise_for_status(self) -> None:
        return None

    def iter_bytes(self, chunk_size: int = 0) -> Iterator[bytes]:
        del chunk_size
        yield self._payload


@final
class _B2HttpClient:
    def __init__(self, payload: bytes) -> None:
        self._payload = payload
        self.urls: list[str] = []

    def stream(
        self, method: str, url: str, *, follow_redirects: bool = False
    ) -> _B2StreamResponse:
        del method, follow_redirects
        self.urls.append(url)
        return _B2StreamResponse(self._payload)


@final
class _B2Downloader(ModelScopeDownloader):
    def __init__(self, payloads: dict[str, bytes], coreml_payload: bytes) -> None:
        self.payloads = payloads
        self.http = _B2HttpClient(coreml_payload)
        self.download_calls: list[str] = []
        super().__init__(client=cast(httpx.Client, cast(object, self.http)))

    @override
    def download(self, source: SourceLocation, relative_path: str) -> Iterator[bytes]:
        del source
        self.download_calls.append(relative_path)
        return iter([self.payloads[relative_path]])


def _b2_setup(monkeypatch: pytest.MonkeyPatch) -> _B2Downloader:
    monkeypatch.setattr(diarization_assets, "load_catalog", _b2_catalog)
    monkeypatch.setattr(
        diarization_assets,
        "MODEL_FILE_SHA256",
        {_B2_COREML_PATH: hashlib.sha256(_B2_COREML_BYTES).hexdigest()},
    )
    monkeypatch.setattr(diarization_assets, "_COREML_FILE_SIZES", (len(_B2_COREML_BYTES),))
    return _B2Downloader(dict(_B2_ALIGNER_PAYLOADS), _B2_COREML_BYTES)


def test_prepare_diarization_assets_light_provisions_nothing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    downloader = _b2_setup(monkeypatch)
    app_home = tmp_path / "app"

    result = diarization_assets.prepare_diarization_assets(
        app_home, preset_id="light", downloader=downloader
    )

    assert result is None
    assert not (app_home / "diarization").exists()
    assert downloader.download_calls == []
    assert downloader.http.urls == []


def test_prepare_diarization_assets_balanced_provisions_aligner_q8(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    downloader = _b2_setup(monkeypatch)
    app_home = tmp_path / "app"

    result = diarization_assets.prepare_diarization_assets(
        app_home, preset_id="balanced", downloader=downloader
    )

    assert result is not None
    assert result.coreml_model_path == app_home / "diarization" / _B2_BUNDLE_NAME
    assert result.aligner_model_dir.name == "aligner-q8"
    aligner_dir = app_home / "diarization" / "aligner-q8"
    for relative, payload in _B2_ALIGNER_PAYLOADS.items():
        artifact = aligner_dir / relative
        assert artifact.read_bytes() == payload
        assert artifact.stat().st_size == len(payload)
        assert hashlib.sha256(artifact.read_bytes()).hexdigest() == (
            hashlib.sha256(payload).hexdigest()
        )
    assert sorted(downloader.download_calls) == sorted(_B2_ALIGNER_PAYLOADS)
    assert downloader.http.urls and downloader.http.urls[0].startswith(
        "https://huggingface.co/"
    )


def test_prepare_diarization_assets_quality_provisions_aligner_bf16(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    downloader = _b2_setup(monkeypatch)
    app_home = tmp_path / "app"

    result = diarization_assets.prepare_diarization_assets(
        app_home, preset_id="quality", downloader=downloader
    )

    assert result is not None
    assert result.aligner_model_dir.name == "aligner-bf16"
    assert (app_home / "diarization" / "aligner-bf16" / "config.json").is_file()


def test_prepare_diarization_assets_reuses_verified_directory(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    downloader = _b2_setup(monkeypatch)
    app_home = tmp_path / "app"

    first = diarization_assets.prepare_diarization_assets(
        app_home, preset_id="balanced", downloader=downloader
    )
    downloads_after_first = list(downloader.download_calls)
    urls_after_first = list(downloader.http.urls)

    second = diarization_assets.prepare_diarization_assets(
        app_home, preset_id="balanced", downloader=downloader
    )

    assert second == first
    assert downloader.download_calls == downloads_after_first
    assert downloader.http.urls == urls_after_first


def test_prepare_diarization_assets_rejects_corrupt_existing_directory(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    downloader = _b2_setup(monkeypatch)
    app_home = tmp_path / "app"
    corrupt = app_home / "diarization" / "aligner-q8"
    corrupt.mkdir(parents=True)
    (corrupt / "config.json").write_bytes(b"tampered")

    with pytest.raises(DiarizationAssetError):
        diarization_assets.prepare_diarization_assets(
            app_home, preset_id="balanced", downloader=downloader
        )


def test_prepare_diarization_assets_unknown_preset_raises(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    downloader = _b2_setup(monkeypatch)

    with pytest.raises(DiarizationAssetError):
        diarization_assets.prepare_diarization_assets(
            tmp_path / "app", preset_id="turbo", downloader=downloader
        )


def _preflight_selection_exit_code(app_home: Path) -> int:
    """Emulate the installed wheel preflight's selection resolution, which fail-closes."""

    layout = ServiceLayout.for_app_home(app_home)
    try:
        settings = Settings.from_env_file(layout.config_file)
        selection = recover_selection(app_home)
        if selection is not None:
            resolve_selection(settings, selection, load_catalog(), app_home)
    except Exception:
        return 1
    return 0


def test_managed_upgrade_provisions_tier_aligner_before_preflight(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(
        install_macos,
        "_provision_managed_diarization_assets",
        _REAL_MANAGED_DIARIZATION_PROVISIONING,
    )
    downloader = _b2_setup(monkeypatch)
    wheel, app_home = _inputs(tmp_path)
    layout = ServiceLayout.for_app_home(app_home)
    layout.ensure_directories()
    selected = load_catalog().preset("quality")
    for key in (selected.asr, selected.tts):
        (app_home / "models" / key).mkdir(parents=True, exist_ok=True)
    # Simulate the 2.2.2 layout: the selection is already committed, but only
    # the legacy aligner directory exists, not the per-tier aligner-bf16.
    legacy_aligner = app_home / "diarization" / "Qwen3-ForcedAligner-0.6B"
    legacy_aligner.mkdir(parents=True, exist_ok=True)
    selection_path = app_home / "config" / "selection.json"
    selection_path.write_bytes(_selection_payload())
    selection_path.chmod(0o600)
    calls: list[tuple[str, ...]] = []

    async def fake_prepare_models(preset_id: str, **kwargs: object) -> str:
        del preset_id, kwargs
        return "prepared-quality"

    monkeypatch.setattr(install_macos, "prepare_models", fake_prepare_models)
    monkeypatch.setattr(
        install_macos,
        "prepare_runtime",
        lambda lock, prepared_app_home, runner: _fake_runtime_switching(prepared_app_home),
    )

    def runner(command: tuple[str, ...]) -> subprocess.CompletedProcess[str]:
        calls.append(command)
        if command[:2] == ("uv", "venv"):
            venv = Path(command[-1])
            venv.joinpath("bin").mkdir(parents=True)
            venv.joinpath("bin", "python").touch()
        if "preflight" in command:
            code = _preflight_selection_exit_code(app_home)
            return subprocess.CompletedProcess(command, code, stdout="", stderr="")
        return subprocess.CompletedProcess(command, 0, stdout="", stderr="")

    result = install_macos.install_managed(
        wheel,
        app_home=app_home,
        preset_id="quality",
        downloader=downloader,
        runtime_runner=lambda command: subprocess.CompletedProcess(
            command, 0, stdout="", stderr=""
        ),
        runner=runner,
    )

    aligner_dir = app_home / "diarization" / "aligner-bf16"
    assert result.enabled is False
    assert result.prepared_id == "prepared-quality"
    assert aligner_dir.is_dir()
    assert (aligner_dir / "config.json").is_file()
    assert _preflight_selection_exit_code(app_home) == 0
    resolved = resolve_selection(
        Settings.from_env_file(layout.config_file),
        recover_selection(app_home),
        load_catalog(),
        app_home,
    )
    assert resolved.qwen3_aligner_model_dir == aligner_dir


def test_managed_diarization_provisioning_failure_rolls_back(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(
        install_macos,
        "_provision_managed_diarization_assets",
        _REAL_MANAGED_DIARIZATION_PROVISIONING,
    )
    downloader = _b2_setup(monkeypatch)
    wheel, app_home = _inputs(tmp_path)
    layout = ServiceLayout.for_app_home(app_home)
    layout.ensure_directories()
    old_release = layout.runtime_root / "releases" / "old"
    old_release.mkdir(parents=True)
    layout.current_runtime.symlink_to(old_release, target_is_directory=True)
    old_vendor = layout.vendor_root / "runtime-old"
    old_vendor.mkdir(parents=True)
    layout.vendor_current.symlink_to(old_vendor, target_is_directory=True)
    original_config = b"SPEECHRAIL_HOST=127.0.0.1\r\n"
    layout.config_file.write_bytes(original_config)
    layout.config_file.chmod(0o600)
    selection_path = app_home / "config" / "selection.json"
    original_selection = _selection_payload()
    selection_path.write_bytes(original_selection)
    selection_path.chmod(0o600)
    corrupt = app_home / "diarization" / "aligner-bf16"
    corrupt.mkdir(parents=True)
    (corrupt / "config.json").write_bytes(b"tampered")

    with pytest.raises(
        install_macos.InstallerError, match="diarization asset preparation failed"
    ):
        install_macos.install_managed(
            wheel,
            app_home=app_home,
            preset_id="quality",
            downloader=downloader,
            runtime_runner=lambda command: subprocess.CompletedProcess(
                command, 0, stdout="", stderr=""
            ),
            runner=_runner_that_creates_python([]),
        )

    assert layout.current_runtime.resolve() == old_release.resolve()
    assert layout.vendor_current.resolve() == old_vendor.resolve()
    assert layout.config_file.read_bytes() == original_config
    assert selection_path.read_bytes() == original_selection
