from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

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
    wheel = tmp_path / "speechrail-1.3.1-py3-none-any.whl"
    wheel.touch()
    env_file = tmp_path / "source.env"
    env_file.write_text("SPEECHRAIL_HOST=127.0.0.1\n", encoding="utf-8")
    app_home = tmp_path / "Application Support" / "SpeechRail"
    return wheel, env_file, app_home


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
