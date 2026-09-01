from __future__ import annotations

from types import SimpleNamespace

import pytest

import speechrail.cli as cli
from speechrail.service import ServiceError


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


def test_serve_uses_settings_host_and_port(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, object] = {}
    monkeypatch.setattr(cli, "Settings", lambda: SimpleNamespace(host="127.0.0.1", port=8201))
    monkeypatch.setattr(cli.uvicorn, "run", lambda app, **kwargs: captured.update(kwargs))

    assert cli.main(["serve"]) == 0
    assert captured == {"host": "127.0.0.1", "port": 8201, "log_level": "info"}


def test_no_argument_remains_compatible_with_serve(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[object] = []
    monkeypatch.setattr(cli, "run_server", lambda: calls.append("serve"))

    assert cli.main([]) == 0
    assert calls == ["serve"]


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
