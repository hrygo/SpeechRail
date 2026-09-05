from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

from speechrail.config.model_catalog import load_catalog, load_runtime_lock
from speechrail.service.bootstrap import RuntimePaths
from speechrail.service.paths import ServiceLayout
from speechrail.service.preflight import PreflightResult

_INSTALLER_PATH = Path(__file__).parents[1] / "tools" / "install_macos.py"
_SPEC = importlib.util.spec_from_file_location("speechrail_test_installer", _INSTALLER_PATH)
assert _SPEC is not None and _SPEC.loader is not None
install_macos = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = install_macos
_SPEC.loader.exec_module(install_macos)


def _runner_that_creates_python(calls: list[tuple[str, ...]]):
    def runner(command: tuple[str, ...]) -> subprocess.CompletedProcess[str]:
        calls.append(command)
        if command[:2] == ("uv", "venv"):
            venv = Path(command[-1])
            venv.joinpath("bin").mkdir(parents=True)
            venv.joinpath("bin", "python").touch()
        return subprocess.CompletedProcess(command, 0, stdout="", stderr="")

    return runner


def _inputs(tmp_path: Path) -> tuple[Path, Path, Path]:
    wheel = tmp_path / "speechrail-1.7.1-py3-none-any.whl"
    wheel.touch()
    env_file = tmp_path / "source.env"
    env_file.write_text("SPEECHRAIL_HOST=127.0.0.1\n", encoding="utf-8")
    app_home = tmp_path / "Application Support" / "SpeechRail"
    return wheel, env_file, app_home


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


def test_managed_state_remains_outside_release(tmp_path: Path) -> None:
    layout = ServiceLayout.for_app_home(tmp_path, user_home=tmp_path)

    assert layout.config_file == tmp_path / "config" / ".env"
    assert layout.current_runtime == tmp_path / "runtime" / "current"
    assert layout.models_root == tmp_path / "models"
    assert layout.vendor_root == tmp_path / "vendor"


def test_managed_install_prepares_preset_and_keeps_service_disabled(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    wheel, _, app_home = _inputs(tmp_path)
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


def test_managed_install_same_preset_reuses_wheel_release(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    wheel, _, app_home = _inputs(tmp_path)
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
    wheel, _, app_home = _inputs(tmp_path)
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
    wheel, _, app_home = _inputs(tmp_path)
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
    wheel, _, app_home = _inputs(tmp_path)
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
    wheel, _, app_home = _inputs(tmp_path)
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
    wheel, _, app_home = _inputs(tmp_path)
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


def test_managed_preparation_failure_keeps_previous_current_runtime(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    wheel, _, app_home = _inputs(tmp_path)
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


def test_install_wheel_stages_new_runtime_and_switches_current_atomically(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    wheel, env_file, app_home = _inputs(tmp_path)
    calls: list[tuple[str, ...]] = []
    monkeypatch.setattr(
        install_macos,
        "run_preflight",
        lambda *args, **kwargs: PreflightResult(ok=True, checks=()),
    )

    result = install_macos.install_wheel(
        wheel,
        app_home=app_home,
        env_file=env_file,
        runner=_runner_that_creates_python(calls),
    )

    layout = ServiceLayout.for_app_home(app_home)
    assert result.enabled is False
    assert result.runtime_python.is_file()
    assert layout.current_runtime.is_symlink()
    assert layout.current_runtime.resolve() == result.runtime_python.parents[2].resolve()
    assert layout.config_file.read_text(encoding="utf-8") == env_file.read_text(encoding="utf-8")
    launcher = app_home / "SpeechRail 设置.command"
    assert launcher.is_file()
    assert launcher.stat().st_mode & 0o777 == 0o700
    assert not any("launchctl" in part for command in calls for part in command)


def test_install_wheel_installs_diarization_extra_when_configured(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    wheel, env_file, app_home = _inputs(tmp_path)
    env_file.write_text(
        "SPEECHRAIL_HOST=127.0.0.1\n"
        "SPEECHRAIL_DIARIZATION_MODEL_PATH=/external/sortformer.nemo\n",
        encoding="utf-8",
    )
    calls: list[tuple[str, ...]] = []
    monkeypatch.setattr(
        install_macos,
        "run_preflight",
        lambda *args, **kwargs: PreflightResult(ok=True, checks=()),
    )

    install_macos.install_wheel(
        wheel,
        app_home=app_home,
        env_file=env_file,
        runner=_runner_that_creates_python(calls),
    )

    install_command = next(command for command in calls if command[:2] == ("uv", "pip"))
    assert install_command[-1] == f"{wheel}[diarization]"


def test_preflight_runs_from_the_newly_installed_wheel(tmp_path: Path) -> None:
    layout = ServiceLayout.for_app_home(tmp_path / "SpeechRail")
    calls: list[tuple[str, ...]] = []

    result = install_macos.run_preflight(
        tmp_path / "runtime" / "bin" / "python",
        install_macos.InstallLayout.for_app_home(layout.app_home),
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
            "--asr-only",
        )
    ]


def test_install_wheel_does_not_overwrite_existing_configuration(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    wheel, env_file, app_home = _inputs(tmp_path)
    layout = ServiceLayout.for_app_home(app_home)
    layout.ensure_directories()
    layout.config_file.write_text("SPEECHRAIL_PORT=9999\n", encoding="utf-8")
    layout.config_file.chmod(0o600)
    monkeypatch.setattr(
        install_macos,
        "run_preflight",
        lambda *args, **kwargs: PreflightResult(ok=True, checks=()),
    )

    with pytest.raises(install_macos.InstallerError, match="configuration already exists"):
        install_macos.install_wheel(
            wheel,
            app_home=app_home,
            env_file=env_file,
            runner=_runner_that_creates_python([]),
        )


def test_preflight_failure_does_not_switch_current_or_enable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    wheel, env_file, app_home = _inputs(tmp_path)
    layout = ServiceLayout.for_app_home(app_home)
    layout.ensure_directories()
    old_release = layout.runtime_root / "releases" / "old"
    old_release.mkdir(parents=True)
    layout.current_runtime.symlink_to(old_release, target_is_directory=True)
    calls: list[tuple[str, ...]] = []
    monkeypatch.setattr(
        install_macos,
        "run_preflight",
        lambda *args, **kwargs: PreflightResult(ok=False, checks=()),
    )

    with pytest.raises(install_macos.InstallerError, match="preflight failed"):
        install_macos.install_wheel(
            wheel,
            app_home=app_home,
            env_file=env_file,
            runner=_runner_that_creates_python(calls),
        )

    assert layout.current_runtime.resolve() == old_release.resolve()
    assert not layout.config_file.exists()
    assert not any("launchctl" in part for command in calls for part in command)


def test_wheel_install_failure_keeps_previous_current_runtime(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    wheel, env_file, app_home = _inputs(tmp_path)
    layout = ServiceLayout.for_app_home(app_home)
    layout.ensure_directories()
    old_release = layout.runtime_root / "releases" / "old"
    old_release.mkdir(parents=True)
    layout.current_runtime.symlink_to(old_release, target_is_directory=True)

    def failing_runner(command: tuple[str, ...]) -> subprocess.CompletedProcess[str]:
        if command[:2] == ("uv", "venv"):
            Path(command[-1]).mkdir(parents=True)
        if command[:2] == ("uv", "pip"):
            return subprocess.CompletedProcess(command, 1, stdout="", stderr="install failed")
        return subprocess.CompletedProcess(command, 0, stdout="", stderr="")

    with pytest.raises(install_macos.InstallerError, match="uv command failed"):
        install_macos.install_wheel(
            wheel,
            app_home=app_home,
            env_file=env_file,
            runner=failing_runner,
        )

    assert layout.current_runtime.resolve() == old_release.resolve()
