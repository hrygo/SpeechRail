"""CLI dispatch only; no models, real audio, or service discovery."""

import json
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest


def test_explicit_locked_cli_dispatches_without_overriding_registration(monkeypatch, capsys):
    from probe_meeting_asr_development import main

    calls = []

    async def execute(**kwargs):
        calls.append(kwargs)
        return {"runtime_identity_verified": False, "certification_eligible": False}

    monkeypatch.setitem(
        sys.modules, "meeting_asr_execution", SimpleNamespace(execute_asr_development=execute)
    )
    assert (
        main(
            [
                "evaluate-development",
                "--asr-lock",
                "/external/control.json",
                "--output-directory",
                "/external/new-output",
            ]
        )
        == 0
    )
    assert calls == [
        {
            "evaluation_lock": Path("/external/control.json"),
            "output_directory": Path("/external/new-output"),
        }
    ]
    assert json.loads(capsys.readouterr().out)["certification_eligible"] is False


@pytest.mark.parametrize("error", [ValueError, OSError, RuntimeError])
def test_execution_error_does_not_reveal_paths_or_content(monkeypatch, capsys, error):
    from probe_meeting_asr_development import main

    async def execute(**kwargs):
        raise error("/private/model-file private reference body")

    monkeypatch.setitem(
        sys.modules, "meeting_asr_execution", SimpleNamespace(execute_asr_development=execute)
    )
    with pytest.raises(SystemExit) as caught:
        main(
            [
                "evaluate-development",
                "--asr-lock",
                "/external/control.json",
                "--output-directory",
                "/external/new-output",
            ]
        )
    assert caught.value.code == 2
    output = capsys.readouterr()
    assert not output.out
    assert "private" not in output.err and "/external" not in output.err
    assert "locked ASR development execution failed" in output.err


def test_help_and_missing_controls_cannot_start_runtime(monkeypatch, capsys):
    from probe_meeting_asr_development import main

    async def execute(**kwargs):
        pytest.fail("argument parsing must complete before any execution")

    monkeypatch.setitem(
        sys.modules, "meeting_asr_execution", SimpleNamespace(execute_asr_development=execute)
    )
    with pytest.raises(SystemExit) as caught:
        main(["evaluate-development", "--help"])
    assert caught.value.code == 0
    assert "--asr-lock" in capsys.readouterr().out
    with pytest.raises(SystemExit) as caught:
        main(["evaluate-development"])
    assert caught.value.code == 2
