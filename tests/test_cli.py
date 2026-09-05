from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import pytest

import speechrail.cli as cli
from speechrail.service import PreflightCheck, PreflightResult, ServiceError


class _FakeManager:
    def __init__(self) -> None:
        self.calls: list[str] = []

    def install(self) -> object:
        self.calls.append("install")
        return "/tmp/com.speechrail.plist"

    def enable(self) -> None:
        self.calls.append("enable")

    def disable(self) -> None:
        self.calls.append("disable")

    def restart(self) -> None:
        self.calls.append("restart")

    def status(self) -> str:
        self.calls.append("status")
        return "running\n"

    def uninstall(self) -> None:
        self.calls.append("uninstall")


@pytest.mark.parametrize(
    ("command", "expected_call"),
    [
        ("install", "install"),
        ("enable", "enable"),
        ("disable", "disable"),
        ("restart", "restart"),
        ("status", "status"),
        ("uninstall", "uninstall"),
    ],
)
def test_service_commands_delegate_to_one_manager_operation(
    monkeypatch: pytest.MonkeyPatch, command: str, expected_call: str
) -> None:
    manager = _FakeManager()
    monkeypatch.setattr(cli, "create_launch_agent_manager", lambda: manager)

    assert cli.main(["service", command]) == 0
    assert manager.calls == [expected_call]


def test_serve_uses_settings_host_and_port(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    captured: dict[str, object] = {}

    monkeypatch.chdir(tmp_path)

    class FakeSettings:
        @classmethod
        def from_env_file(cls, env_file: Path | None) -> SimpleNamespace:
            assert env_file is None
            return SimpleNamespace(host="127.0.0.1", port=8201)

    monkeypatch.setattr(cli, "Settings", FakeSettings)
    monkeypatch.setattr("speechrail.app.create_app", lambda settings: settings)
    monkeypatch.setattr(cli.uvicorn, "run", lambda app, **kwargs: captured.update(kwargs))

    assert cli.main(["serve"]) == 0
    assert captured == {"host": "127.0.0.1", "port": 8201, "log_level": "info"}
    assert not (tmp_path / "state").exists()
    assert not (tmp_path / "config").exists()


def test_serve_discovers_private_app_home_configuration(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    env_file = tmp_path / "config" / ".env"
    env_file.parent.mkdir()
    env_file.write_text("SPEECHRAIL_PORT=8317\n", encoding="utf-8")
    captured: dict[str, object] = {}

    class FakeSettings:
        @classmethod
        def from_env_file(cls, actual_env_file: Path | None) -> SimpleNamespace:
            captured["env_file"] = actual_env_file
            return SimpleNamespace(host="127.0.0.1", port=8317)

    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(cli, "Settings", FakeSettings)
    monkeypatch.setattr("speechrail.app.create_app", lambda settings: settings)
    monkeypatch.setattr(cli.uvicorn, "run", lambda app, **kwargs: captured.update(kwargs))

    assert cli.main(["serve"]) == 0
    assert captured["env_file"] == env_file
    assert captured["port"] == 8317


def test_serve_uses_one_shot_startup_claim(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    env_file = tmp_path / "config" / ".env"
    env_file.parent.mkdir()
    env_file.write_text("SPEECHRAIL_PORT=8317\n", encoding="utf-8")
    candidate = {
        "schema_version": 1,
        "preset": "quality",
        "generation": 2,
        "asr": "large-q8",
        "tts": "design-q8",
        "runtime_lock_id": "runtime-v1",
    }
    captured: dict[str, object] = {}

    class FakeSettings:
        @classmethod
        def from_env_file(cls, actual_env_file: Path | None) -> SimpleNamespace:
            assert actual_env_file == env_file
            return SimpleNamespace(host="127.0.0.1", port=8317)

    def claim(app_home: Path) -> dict[str, object]:
        captured["app_home"] = app_home
        return candidate

    monkeypatch.setattr(cli, "Settings", FakeSettings)
    monkeypatch.setattr("speechrail.service.profile_store.claim_startup_selection", claim)
    monkeypatch.setattr("speechrail.config.model_catalog.load_catalog", lambda: object())
    monkeypatch.setattr(
        "speechrail.config.selection.resolve_selection",
        lambda settings, selection, catalog, app_home: captured.update(
            {"selection": selection, "selection_app_home": app_home}
        ) or settings,
    )
    monkeypatch.setattr("speechrail.app.create_app", lambda settings: settings)
    monkeypatch.setattr(cli.uvicorn, "run", lambda app, **kwargs: captured.update(kwargs))

    assert cli.run_server(env_file) is None
    assert captured["app_home"] == tmp_path.resolve()
    assert captured["selection"] == candidate
    assert captured["selection_app_home"] == tmp_path.resolve()


def test_no_argument_remains_compatible_with_serve(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[object] = []
    monkeypatch.setattr(cli, "run_server", lambda: calls.append("serve"))

    assert cli.main([]) == 0
    assert calls == ["serve"]


def test_profile_list_and_status_are_read_only(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    from speechrail.service import profile_commands

    monkeypatch.setattr(
        profile_commands,
        "profile_status",
        lambda app_home: profile_commands.ProfileStatus("balanced", 3, "asr", "tts"),
    )

    assert cli.main(["profile", "list", "--app-home", str(tmp_path)]) == 0
    output = capsys.readouterr().out
    assert "quality" in output and "balanced" in output and "light" in output
    assert "balanced *" in output

    assert cli.main(["profile", "status", "--app-home", str(tmp_path)]) == 0
    assert "balanced" in capsys.readouterr().out


def test_setup_yes_uses_memory_recommendation_without_machine_model_detection(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    from speechrail.service import profile_commands
    from speechrail.service.profile_switch import ApplyResult

    calls: list[str] = []
    monkeypatch.setattr(cli, "_physical_memory_bytes", lambda: 8 * 1024**3)
    monkeypatch.setattr(
        profile_commands,
        "profile_status",
        lambda app_home: profile_commands.ProfileStatus(None, None, None, None),
    )
    monkeypatch.setattr(
        profile_commands,
        "apply_profile",
        lambda preset, app_home: calls.append(preset)
        or ApplyResult("committed", "op_test", None),
    )

    assert cli.main(["setup", "--yes", "--app-home", str(tmp_path)]) == 0
    assert calls == ["light"]


def test_profile_apply_cancel_does_not_prepare_or_stop(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    from speechrail.service import profile_commands

    monkeypatch.setattr("builtins.input", lambda prompt: "n")
    monkeypatch.setattr(
        profile_commands,
        "apply_profile",
        lambda preset, app_home: pytest.fail("apply must not run"),
    )

    assert cli.main(["profile", "apply", "light", "--app-home", str(tmp_path)]) == 1


def test_service_error_is_redacted_and_returns_nonzero(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    class FailingManager(_FakeManager):
        def enable(self) -> None:
            raise ServiceError("launchctl operation failed with exit code 1")

    monkeypatch.setattr(cli, "create_launch_agent_manager", FailingManager)

    assert cli.main(["service", "enable"]) == 1
    assert capsys.readouterr().err == (
        "SpeechRail service: launchctl operation failed with exit code 1\n"
    )


def test_service_accepts_an_explicit_app_home(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    manager = _FakeManager()
    captured: dict[str, Path] = {}

    def create_manager(*, working_directory: Path) -> _FakeManager:
        captured["working_directory"] = working_directory
        return manager

    monkeypatch.setattr(cli, "create_launch_agent_manager", create_manager)

    assert cli.main(["service", "install", "--app-home", str(tmp_path)]) == 0
    assert captured == {"working_directory": tmp_path}
    assert manager.calls == ["install"]


def test_service_preflight_reports_failure_without_enabling(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    result = PreflightResult(
        ok=False,
        checks=(PreflightCheck(name="tts_config", ok=False, message="TTS is missing"),),
    )
    monkeypatch.setattr(cli, "run_preflight", lambda *args, **kwargs: result)

    assert cli.main(["service", "preflight", "--app-home", str(tmp_path)]) == 1
    assert "FAIL tts_config: TTS is missing" in capsys.readouterr().out
