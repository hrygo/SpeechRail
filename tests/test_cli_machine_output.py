"""Machine-readable CLI output for the macOS control agent."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

import speechrail.cli as cli
from speechrail.service import ServiceError


def _profile_status() -> object:
    from speechrail.service import profile_commands

    return profile_commands.ProfileStatus("balanced", 7, "asr-balanced", "tts-balanced")


def _profile_summaries() -> tuple[object, ...]:
    from speechrail.service import profile_commands

    return (
        profile_commands.ProfileSummary("quality", "asr-quality", "tts-quality", 3 * 1024**3),
        profile_commands.ProfileSummary("balanced", "asr-balanced", "tts-balanced", 2 * 1024**3),
        profile_commands.ProfileSummary("light", "asr-light", "tts-light", 1 * 1024**3),
    )


def test_profile_list_json_is_stable_and_path_free(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    from speechrail.service import profile_commands

    monkeypatch.setattr(profile_commands, "profile_status", lambda app_home: _profile_status())
    monkeypatch.setattr(profile_commands, "list_profiles", _profile_summaries)

    assert cli.main(["profile", "list", "--app-home", str(tmp_path), "--json"]) == 0

    payload = json.loads(capsys.readouterr().out)
    assert payload == {
        "command": "profile.list",
        "current": "balanced",
        "profiles": [
            {
                "aligner": None,
                "asr": "asr-quality",
                "download_bytes": 3 * 1024**3,
                "id": "quality",
                "tts": "tts-quality",
            },
            {
                "aligner": None,
                "asr": "asr-balanced",
                "download_bytes": 2 * 1024**3,
                "id": "balanced",
                "tts": "tts-balanced",
            },
            {
                "aligner": None,
                "asr": "asr-light",
                "download_bytes": 1 * 1024**3,
                "id": "light",
                "tts": "tts-light",
            },
        ],
        "schema_version": 1,
        "status": "ok",
    }
    assert str(tmp_path) not in json.dumps(payload)


def test_profile_status_json_contains_only_public_fields(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    from speechrail.service import profile_commands

    monkeypatch.setattr(profile_commands, "profile_status", lambda app_home: _profile_status())

    assert cli.main(["profile", "status", "--app-home", str(tmp_path), "--json"]) == 0

    payload = json.loads(capsys.readouterr().out)
    assert payload == {
        "asr": "asr-balanced",
        "command": "profile.status",
        "generation": 7,
        "preset": "balanced",
        "schema_version": 1,
        "status": "ok",
        "tts": "tts-balanced",
    }


def test_profile_apply_json_has_no_human_prefix(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    from speechrail.service import profile_commands
    from speechrail.service.profile_switch import ApplyResult

    monkeypatch.setattr(profile_commands, "list_profiles", _profile_summaries)
    monkeypatch.setattr(cli, "_confirm", lambda assume_yes: assume_yes)
    monkeypatch.setattr(
        profile_commands,
        "apply_profile",
        lambda preset, app_home: ApplyResult("committed", "op_test", None),
    )

    assert (
        cli.main(
            ["profile", "apply", "light", "--app-home", str(tmp_path), "--yes", "--json"]
        )
        == 0
    )

    lines = capsys.readouterr().out.splitlines()
    assert len(lines) == 1
    assert json.loads(lines[0]) == {
        "command": "profile.apply",
        "error_code": None,
        "operation_id": "op_test",
        "schema_version": 1,
        "status": "committed",
    }


class _JsonFakeManager:
    def status(self) -> str:
        return "state = running\n"


def test_service_status_json_does_not_expose_launchctl_output(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(cli, "create_launch_agent_manager", lambda: _JsonFakeManager())

    assert cli.main(["service", "status", "--json"]) == 0

    payload = json.loads(capsys.readouterr().out)
    assert payload == {
        "command": "service.status",
        "schema_version": 1,
        "service_state": "running",
        "status": "ok",
    }


def test_service_lifecycle_json_is_a_single_line_envelope(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    class Manager:
        def start(self) -> None:
            return None

        def enable(self) -> None:
            return None

    monkeypatch.setattr(cli, "create_launch_agent_manager", lambda: Manager())
    monkeypatch.setattr(cli, "LaunchAgentServiceController", lambda manager, **kwargs: manager)

    assert cli.main(["service", "start", "--json"]) == 0

    assert json.loads(capsys.readouterr().out) == {
        "command": "service.start",
        "schema_version": 1,
        "status": "completed",
    }


def test_machine_error_is_json_and_does_not_leak_exception_details(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    def fail(self) -> str:
        raise ServiceError("managed runtime Python is missing at /private/secret/path")

    monkeypatch.setattr(
        cli, "create_launch_agent_manager", lambda: type("M", (), {"status": fail})()
    )

    assert cli.main(["service", "status", "--json"]) == 1

    payload = json.loads(capsys.readouterr().out)
    assert payload["command"] == "service.status"
    assert payload["schema_version"] == 1
    assert payload["status"] == "failed"
    assert payload["error_code"] == "managed_runtime_missing"
    assert "/private/secret/path" not in json.dumps(payload)
