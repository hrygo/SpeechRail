from __future__ import annotations

import plistlib
import subprocess
from pathlib import Path

import pytest

from speechrail.service.launchd import (
    SERVICE_LABEL,
    LaunchAgentDefinition,
    LaunchAgentManager,
    LaunchAgentPaths,
    ServiceError,
    UnsupportedPlatformError,
    create_launch_agent_manager,
)


def _definition(tmp_path: Path) -> LaunchAgentDefinition:
    python = tmp_path / "venv" / "bin" / "python"
    python.parent.mkdir(parents=True)
    python.touch()
    return LaunchAgentDefinition(
        working_directory=tmp_path,
        python_executable=python,
        stdout_path=tmp_path / "logs" / "stdout.log",
        stderr_path=tmp_path / "logs" / "stderr.log",
    )


def _manager(tmp_path: Path, calls: list[tuple[str, ...]]) -> LaunchAgentManager:
    definition = _definition(tmp_path)

    def runner(command: tuple[str, ...]) -> subprocess.CompletedProcess[str]:
        calls.append(command)
        return subprocess.CompletedProcess(command, 0, stdout="ok", stderr="")

    return LaunchAgentManager(
        definition=definition,
        paths=LaunchAgentPaths(
            plist_path=tmp_path / "LaunchAgents" / f"{SERVICE_LABEL}.plist",
            log_directory=tmp_path / "logs",
        ),
        uid=501,
        runner=runner,
    )


def test_launch_agent_plist_uses_current_python_and_never_serializes_environment_secrets(
    tmp_path: Path,
) -> None:
    definition = _definition(tmp_path)

    plist = plistlib.loads(definition.to_plist())

    assert plist["Label"] == SERVICE_LABEL
    assert plist["ProgramArguments"] == [
        str((tmp_path / "venv" / "bin" / "python").resolve()),
        "-m",
        "speechrail",
        "serve",
    ]
    assert plist["WorkingDirectory"] == str(tmp_path.resolve())
    assert plist["RunAtLoad"] is True
    assert plist["KeepAlive"] == {"SuccessfulExit": False}
    assert plist["ThrottleInterval"] == 10
    assert plist["ProcessType"] == "Interactive"
    assert "EnvironmentVariables" not in plist


def test_definition_rejects_relative_or_missing_runtime_paths(tmp_path: Path) -> None:
    with pytest.raises(ServiceError, match="absolute"):
        LaunchAgentDefinition(
            working_directory=Path(),
            python_executable=tmp_path / "python",
            stdout_path=tmp_path / "stdout.log",
            stderr_path=tmp_path / "stderr.log",
        )

    with pytest.raises(ServiceError, match="python executable"):
        LaunchAgentDefinition(
            working_directory=tmp_path,
            python_executable=tmp_path / "missing-python",
            stdout_path=tmp_path / "stdout.log",
            stderr_path=tmp_path / "stderr.log",
        )


def test_launch_agent_preserves_python_venv_symlink_path(tmp_path: Path) -> None:
    python_target = tmp_path / "uv" / "python3.12"
    python_target.parent.mkdir(parents=True)
    python_target.touch()
    python_link = tmp_path / "venv" / "bin" / "python"
    python_link.parent.mkdir(parents=True)
    python_link.symlink_to(python_target)
    definition = LaunchAgentDefinition(
        working_directory=tmp_path,
        python_executable=python_link,
        stdout_path=tmp_path / "stdout.log",
        stderr_path=tmp_path / "stderr.log",
    )

    plist = plistlib.loads(definition.to_plist())

    assert plist["ProgramArguments"][0] == str(python_link.absolute())


def test_create_manager_preserves_current_python_symlink(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    python_target = tmp_path / "uv" / "python3.12"
    python_target.parent.mkdir(parents=True)
    python_target.touch()
    python_link = tmp_path / "venv" / "bin" / "python3"
    python_link.parent.mkdir(parents=True)
    python_link.symlink_to(python_target)
    monkeypatch.setattr("speechrail.service.launchd.sys.executable", str(python_link))

    manager = create_launch_agent_manager(working_directory=tmp_path)

    assert manager.definition.python_executable == python_link.absolute()


def test_create_manager_uses_explicit_app_home(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    python_link = tmp_path / "venv" / "bin" / "python3"
    python_link.parent.mkdir(parents=True)
    python_link.touch()
    installed = tmp_path / "installed"
    installed.mkdir()
    monkeypatch.setattr("speechrail.service.launchd.sys.executable", str(python_link))

    manager = create_launch_agent_manager(working_directory=installed)

    assert manager.definition.working_directory == installed.resolve()


def test_install_writes_a_private_log_directory_and_idempotent_plist(tmp_path: Path) -> None:
    calls: list[tuple[str, ...]] = []
    manager = _manager(tmp_path, calls)

    installed = manager.install()
    first = installed.read_bytes()
    manager.paths.log_directory.chmod(0o755)
    manager.install()

    assert installed == manager.paths.plist_path
    assert first == installed.read_bytes()
    assert manager.paths.log_directory.stat().st_mode & 0o777 == 0o700
    assert installed.stat().st_mode & 0o777 == 0o644
    assert calls == []


def test_lifecycle_commands_use_user_domain_and_do_not_delete_on_bootout_failure(
    tmp_path: Path,
) -> None:
    calls: list[tuple[str, ...]] = []
    manager = _manager(tmp_path, calls)
    manager.install()
    target = f"gui/501/{SERVICE_LABEL}"

    manager.enable()
    manager.restart()
    assert manager.status() == "ok"
    manager.disable()

    assert calls == [
        ("launchctl", "bootstrap", "gui/501", str(manager.paths.plist_path)),
        ("launchctl", "kickstart", "-k", target),
        ("launchctl", "kickstart", "-k", target),
        ("launchctl", "print", target),
        ("launchctl", "bootout", target),
    ]

    def failing_runner(command: tuple[str, ...]) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(command, 1, stdout="", stderr="still running")

    failing = LaunchAgentManager(
        definition=manager.definition,
        paths=manager.paths,
        uid=501,
        runner=failing_runner,
    )
    with pytest.raises(ServiceError, match="exit code 1"):
        failing.uninstall()
    assert manager.paths.plist_path.exists()


def test_create_manager_rejects_non_macos_before_touching_files(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr("speechrail.service.launchd.sys.platform", "linux")

    with pytest.raises(UnsupportedPlatformError, match="macOS"):
        create_launch_agent_manager(working_directory=tmp_path)


def test_checked_in_launchagent_template_matches_managed_safety_policy() -> None:
    root = Path(__file__).parents[1]
    with (root / "deploy" / "macos" / "com.speechrail.plist.example").open("rb") as handle:
        plist = plistlib.load(handle)

    assert plist["ProgramArguments"] == [
        "<absolute-path-to-python>",
        "-m",
        "speechrail",
        "serve",
    ]
    assert plist["ProcessType"] == "Interactive"
    assert plist["KeepAlive"] == {"SuccessfulExit": False}
    assert plist["ThrottleInterval"] == 10
    assert "EnvironmentVariables" not in plist
