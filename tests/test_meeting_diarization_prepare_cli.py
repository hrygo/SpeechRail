"""Explicit preparation never edits the active selection or enables inference."""

import json

from speechrail import cli
from speechrail.service import diarization_assets


def test_prepare_dynamic_is_explicit_and_does_not_write_configuration(
    tmp_path, monkeypatch, capsys
):
    calls = []
    monkeypatch.setattr(cli, "_managed_runtime_for_mutation", lambda _: None)
    monkeypatch.setattr(
        diarization_assets,
        "prepare_meeting_dynamic_assets",
        lambda base: calls.append(base) or base / "locked",
    )
    result = cli.main(
        [
            "model",
            "prepare-diarization",
            "--backend",
            "meeting_dynamic",
            "--app-home",
            str(tmp_path),
            "--yes",
            "--json",
        ]
    )
    assert result == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["status"] == "verified" and payload["enabled"] is False
    assert calls == [tmp_path / "diarization"]
    assert not (tmp_path / "config").exists()
    assert not (tmp_path / "selection.json").exists()


def test_prepare_dynamic_requires_explicit_confirmation(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(cli, "_confirm", lambda _: False)
    monkeypatch.setattr(
        diarization_assets,
        "prepare_meeting_dynamic_assets",
        lambda _: (_ for _ in ()).throw(AssertionError("unconfirmed download")),
    )
    assert (
        cli.main(
            [
                "model",
                "prepare-diarization",
                "--backend",
                "meeting_dynamic",
                "--app-home",
                str(tmp_path),
                "--json",
            ]
        )
        == 1
    )
    assert json.loads(capsys.readouterr().out)["error_code"] == "confirmation_required"
