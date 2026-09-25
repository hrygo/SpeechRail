"""Machine-readable CLI output for the macOS control agent."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

import speechrail.cli as cli
from speechrail.service import ServiceError


def _profile_status() -> object:
    from speechrail.service import profile_commands

    return profile_commands.ProfileStatus("quality", "fast", "off", 7)


def _profile_summaries() -> tuple[object, ...]:
    from speechrail.service import profile_commands

    return (
        profile_commands.ProfileSummary(
            "fast",
            "asr-fast",
            "tts-fast",
            1 * 1024**3,
            tts_base="tts-base-fast",
            aligner="aligner-q8",
        ),
        profile_commands.ProfileSummary(
            "quality",
            "asr-quality",
            "tts-quality",
            3 * 1024**3,
            tts_base="tts-base-quality",
            aligner="aligner-bf16",
        ),
        profile_commands.ProfileSummary(
            "reference",
            "asr-reference",
            "tts-reference",
            4 * 1024**3,
            tts_base="tts-base-reference",
            voice_design="tts-design-reference",
            aligner="aligner-bf16",
        ),
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
        "current": "quality/fast",
        "schema_version": 1,
        "selection": {
            "asr_spec": "quality",
            "auto": "off",
            "generation": 7,
            "tts_spec": "fast",
        },
        "profiles": [
            {
                "aligner": "aligner-q8",
                "asr": "asr-fast",
                "download_bytes": 1 * 1024**3,
                "id": "fast",
                "tts": "tts-fast",
                "tts_base": "tts-base-fast",
                "voice_design": None,
            },
            {
                "aligner": "aligner-bf16",
                "asr": "asr-quality",
                "download_bytes": 3 * 1024**3,
                "id": "quality",
                "tts": "tts-quality",
                "tts_base": "tts-base-quality",
                "voice_design": None,
            },
            {
                "aligner": "aligner-bf16",
                "asr": "asr-reference",
                "download_bytes": 4 * 1024**3,
                "id": "reference",
                "tts": "tts-reference",
                "tts_base": "tts-base-reference",
                "voice_design": "tts-design-reference",
            },
        ],
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
        "asr_spec": "quality",
        "auto": "off",
        "command": "profile.status",
        "generation": 7,
        "schema_version": 1,
        "selection": "quality/fast",
        "status": "ok",
        "tts_spec": "fast",
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
        lambda asr_spec, tts_spec, *, app_home: ApplyResult("committed", "op_test", None),
    )

    assert (
        cli.main(
            [
                "profile",
                "apply",
                "--asr-spec",
                "fast",
                "--tts-spec",
                "fast",
                "--app-home",
                str(tmp_path),
                "--yes",
                "--json",
            ]
        )
        == 0
    )

    lines = capsys.readouterr().out.splitlines()
    assert len(lines) == 1
    assert json.loads(lines[0]) == {
        "command": "profile.apply",
        "error_code": None,
        "message": "profile applied and public API smoke passed",
        "operation_id": "op_test",
        "schema_version": 1,
        "status": "committed",
    }


def test_profile_apply_json_preserves_a_safe_failure_message(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    from speechrail.service import profile_commands
    from speechrail.service.profile_switch import ApplyResult

    monkeypatch.setattr(profile_commands, "list_profiles", _profile_summaries)
    monkeypatch.setattr(cli, "_confirm", lambda assume_yes: assume_yes)
    monkeypatch.setattr(
        profile_commands,
        "apply_profile",
        lambda asr_spec, tts_spec, *, app_home: ApplyResult(
            status="rolled_back",
            operation_id="op_test",
            error_code="profile_switch_failed",
            message="profile smoke failed; the previous profile was restored",
        ),
    )

    assert (
        cli.main(
            [
                "profile",
                "apply",
                "--asr-spec",
                "fast",
                "--tts-spec",
                "fast",
                "--app-home",
                str(tmp_path),
                "--yes",
                "--json",
            ]
        )
        == 1
    )

    payload = json.loads(capsys.readouterr().out)
    assert payload["error_code"] == "profile_switch_failed"
    assert payload["message"] == "profile smoke failed; the previous profile was restored"


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


def test_model_catalog_json_is_path_free(capsys: pytest.CaptureFixture[str]) -> None:
    assert cli.main(["model", "catalog", "--json"]) == 0

    payload = json.loads(capsys.readouterr().out)
    assert payload["command"] == "model.catalog"
    assert payload["status"] == "ok"
    assert {item["id"] for item in payload["profiles"]} == {
        "fast",
        "quality",
        "reference",
    }
    assert all("path" not in item and "url" not in item for item in payload["artifacts"])


def test_model_status_json_distinguishes_missing_without_paths(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert cli.main(["model", "status", "--app-home", str(tmp_path), "--json"]) == 0

    payload = json.loads(capsys.readouterr().out)
    assert payload["command"] == "model.status"
    assert all(item["state"] == "not_downloaded" for item in payload["artifacts"])
    assert str(tmp_path) not in json.dumps(payload)


def test_model_prepare_json_requires_confirmation(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert (
        cli.main(
            [
                "model",
                "prepare",
                "--asr-spec",
                "fast",
                "--tts-spec",
                "fast",
                "--app-home",
                str(tmp_path),
                "--json",
            ]
        )
        == 1
    )

    payload = json.loads(capsys.readouterr().out)
    assert payload["command"] == "model.prepare"
    assert payload["event"] == "result"
    assert payload["error_code"] == "confirmation_required"
    assert payload["status"] == "cancelled"


def test_model_errors_use_stable_machine_error_codes(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    from speechrail.service import model_commands

    monkeypatch.setattr(
        model_commands,
        "model_status_payload",
        lambda *args, **kwargs: (_ for _ in ()).throw(
            ValueError("insufficient disk space for missing model staging")
        ),
    )

    assert cli.main(["model", "status", "--app-home", str(tmp_path), "--json"]) == 1
    payload = json.loads(capsys.readouterr().out)
    assert payload["error_code"] == "insufficient_disk_space"
