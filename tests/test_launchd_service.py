from __future__ import annotations

import plistlib
import subprocess
from pathlib import Path

import pytest

from speechrail.service.constants import SERVICE_ENTRY_NAME
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
    service_entry = tmp_path / "venv" / "bin" / SERVICE_ENTRY_NAME
    service_entry.parent.mkdir(parents=True)
    service_entry.touch()
    return LaunchAgentDefinition(
        working_directory=tmp_path,
        service_executable=service_entry,
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


def test_launch_agent_plist_uses_self_describing_executable_and_never_serializes_secrets(
    tmp_path: Path,
) -> None:
    definition = _definition(tmp_path)

    plist = plistlib.loads(definition.to_plist())

    assert plist["Label"] == SERVICE_LABEL
    assert plist["ProgramArguments"] == [
        str((tmp_path / "venv" / "bin" / SERVICE_ENTRY_NAME).absolute()),
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
            service_executable=tmp_path / "speechrail",
            stdout_path=tmp_path / "stdout.log",
            stderr_path=tmp_path / "stderr.log",
        )

    with pytest.raises(ServiceError, match="service executable"):
        LaunchAgentDefinition(
            working_directory=tmp_path,
            service_executable=tmp_path / "missing-entry",
            stdout_path=tmp_path / "stdout.log",
            stderr_path=tmp_path / "stderr.log",
        )


def test_launch_agent_preserves_service_executable_symlink_path(tmp_path: Path) -> None:
    interpreter_target = tmp_path / "uv" / "python3.12"
    interpreter_target.parent.mkdir(parents=True)
    interpreter_target.touch()
    service_entry = tmp_path / "venv" / "bin" / SERVICE_ENTRY_NAME
    service_entry.parent.mkdir(parents=True)
    service_entry.symlink_to(interpreter_target)
    definition = LaunchAgentDefinition(
        working_directory=tmp_path,
        service_executable=service_entry,
        stdout_path=tmp_path / "stdout.log",
        stderr_path=tmp_path / "stderr.log",
    )

    plist = plistlib.loads(definition.to_plist())

    assert plist["ProgramArguments"][0] == str(service_entry.absolute())


def test_create_manager_prefers_service_entry_over_bare_interpreter(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr("speechrail.service.launchd.sys.platform", "darwin")
    bin_directory = tmp_path / "venv" / "bin"
    bin_directory.mkdir(parents=True)
    interpreter_link = bin_directory / "python3"
    interpreter_link.touch()
    service_entry = bin_directory / SERVICE_ENTRY_NAME
    service_entry.symlink_to("python3")
    monkeypatch.setattr("speechrail.service.launchd.sys.executable", str(interpreter_link))

    manager = create_launch_agent_manager(working_directory=tmp_path)

    assert manager.definition.service_executable == service_entry.absolute()
    assert plistlib.loads(manager.definition.to_plist())["ProgramArguments"] == [
        str(service_entry.absolute()),
        "-m",
        "speechrail",
        "serve",
    ]


def test_create_manager_never_launches_the_cli_shim_wrapper(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """The ``speechrail`` console script resolves its app home from the environment.

    The plist carries no environment, so pointing at it would start the default app
    home's runtime instead of this one.
    """
    monkeypatch.setattr("speechrail.service.launchd.sys.platform", "darwin")
    bin_directory = tmp_path / "venv" / "bin"
    bin_directory.mkdir(parents=True)
    interpreter_link = bin_directory / "python3"
    interpreter_link.touch()
    (bin_directory / "speechrail").write_text("#!/bin/sh\nexec python -m speechrail \"$@\"\n")
    monkeypatch.setattr("speechrail.service.launchd.sys.executable", str(interpreter_link))

    manager = create_launch_agent_manager(working_directory=tmp_path)

    assert manager.definition.service_executable == interpreter_link.absolute()


def test_create_manager_falls_back_to_interpreter_without_service_entry(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr("speechrail.service.launchd.sys.platform", "darwin")
    interpreter_link = tmp_path / "venv" / "bin" / "python3"
    interpreter_link.parent.mkdir(parents=True)
    interpreter_link.touch()
    monkeypatch.setattr("speechrail.service.launchd.sys.executable", str(interpreter_link))

    manager = create_launch_agent_manager(working_directory=tmp_path)

    assert manager.definition.service_executable == interpreter_link.absolute()


def test_create_manager_uses_explicit_app_home(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr("speechrail.service.launchd.sys.platform", "darwin")
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


def test_launchctl_timeout_is_reported_as_a_bounded_service_error(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    definition = _definition(tmp_path)
    manager = LaunchAgentManager(
        definition=definition,
        paths=LaunchAgentPaths(
            plist_path=tmp_path / "LaunchAgents" / f"{SERVICE_LABEL}.plist",
            log_directory=tmp_path / "logs",
        ),
        uid=501,
    )

    def timeout(*_args: object, **_kwargs: object) -> None:
        raise subprocess.TimeoutExpired(cmd="launchctl", timeout=15.0)

    monkeypatch.setattr("speechrail.service.launchd.subprocess.run", timeout)

    with pytest.raises(ServiceError, match="timed out"):
        manager.status()


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
        "<absolute-path-to-speechrail-service>",
        "-m",
        "speechrail",
        "serve",
    ]
    assert plist["ProcessType"] == "Interactive"
    assert plist["KeepAlive"] == {"SuccessfulExit": False}
    assert plist["ThrottleInterval"] == 10
    assert "EnvironmentVariables" not in plist
