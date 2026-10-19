"""Offline selection locks use synthetic checkpoint documents only."""

import asyncio
import json
import threading

import pytest
from meeting_evaluation_identity import canonical_digest

from test_meeting_candidate_selection import inputs


def controls(tmp_path):
    initial, checkpoints, manifest, policy = inputs(2)

    def document(name, value):
        path = tmp_path / f"{name}.json"
        path.write_text(json.dumps(value))
        return {"path": str(path), "sha256": canonical_digest(value)}

    lock = {
        "schema_version": 1,
        "required_max": 2,
        "manifest": document("manifest", manifest),
        "scorer_policy": document("policy", policy),
        "strata": {
            str(count): {
                "initial_schedule": document(f"initial-{count}", schedule.as_dict()),
                "checkpoint": document(f"checkpoint-{count}", checkpoints[count]),
            }
            for count, schedule in initial.items()
        },
    }
    path = tmp_path / "selection-lock.json"
    path.write_text(json.dumps(lock))
    return path, lock


def run(path, tmp_path):
    from meeting_selection_execution import execute_development_selection

    return asyncio.run(
        execute_development_selection(selection_lock=path, output_directory=tmp_path / "output")
    )


def test_locked_offline_selection_commits_private_anonymous_report_without_models(
    tmp_path, monkeypatch
):
    from speechrail.runtime.diarization_worker import CoreMLWorkerProcess

    async def no_worker(*args, **kwargs):
        pytest.fail("offline selection must not launch a worker")

    monkeypatch.setattr(CoreMLWorkerProcess, "start", no_worker)
    path, _ = controls(tmp_path)
    result = run(path, tmp_path)
    saved = json.loads((tmp_path / "output" / "selection.json").read_text())
    assert saved == result
    assert saved["selected_candidate"] == "C1"
    assert saved["input_files_verified"] is True
    assert len(saved["selection_control_sha256"]) == 64
    assert len(saved["selection_executor_sha256"]) == 64
    assert saved["runtime_identity_verified"] is False
    assert saved["certification_eligible"] is False
    assert saved["certified_max_speakers"] is None
    assert (tmp_path / "output").stat().st_mode & 0o777 == 0o700
    assert (tmp_path / "output" / "selection.json").stat().st_mode & 0o777 == 0o600
    assert str(tmp_path) not in json.dumps(saved)


@pytest.mark.parametrize(
    "change",
    [
        "extra",
        "schema",
        "maximum",
        "missing_layer",
        "relative",
        "digest",
        "symlink",
        "history",
        "holdout",
    ],
)
def test_invalid_independent_controls_rejected_without_final_result(tmp_path, change):
    path, lock = controls(tmp_path)
    if change == "extra":
        lock["approve"] = True
    elif change == "schema":
        lock["schema_version"] = True
    elif change == "maximum":
        lock["required_max"] = True
    elif change == "missing_layer":
        del lock["strata"]["2"]
    elif change == "relative":
        lock["manifest"]["path"] = "manifest.json"
    elif change == "digest":
        lock["manifest"]["sha256"] = "f" * 64
    elif change == "symlink":
        target = tmp_path / "manifest.json"
        replacement = tmp_path / "replacement.json"
        replacement.write_bytes(target.read_bytes())
        target.unlink()
        target.symlink_to(replacement)
    elif change == "history":
        descriptor = lock["strata"]["1"]["initial_schedule"]
        target = tmp_path / "initial-1.json"
        value = json.loads(target.read_text())
        value["rounds"] = [{}]
        target.write_text(json.dumps(value))
        descriptor["sha256"] = canonical_digest(value)
    else:
        target = tmp_path / "manifest.json"
        value = json.loads(target.read_text())
        value["split"] = "frozen_holdout"
        target.write_text(json.dumps(value))
        lock["manifest"]["sha256"] = canonical_digest(value)
    path.write_text(json.dumps(lock))
    with pytest.raises(ValueError):
        run(path, tmp_path)
    assert not (tmp_path / "output" / "selection.json").exists()


@pytest.mark.parametrize("restore", [False, True])
def test_input_change_during_selection_cannot_commit_even_if_bytes_restored(
    tmp_path, monkeypatch, restore
):
    import meeting_selection_execution as execution

    path, _ = controls(tmp_path)
    original = execution.select_development_candidate
    target = tmp_path / "checkpoint-1.json"

    def mutate(**kwargs):
        result = original(**kwargs)
        before = target.read_bytes()
        target.write_bytes(before + b" ")
        if restore:
            target.write_bytes(before)
        return result

    monkeypatch.setattr(execution, "select_development_candidate", mutate)
    with pytest.raises(ValueError):
        run(path, tmp_path)
    assert not (tmp_path / "output" / "selection.json").exists()
    assert str(tmp_path) not in (tmp_path / "output" / "failure.json").read_text()


def test_final_write_await_does_not_reopen_input_change_window(tmp_path, monkeypatch):
    import meeting_selection_execution as execution

    path, _ = controls(tmp_path)
    original = execution._write_json

    def mutate(target, value):
        original(target, value)
        if target.name == "selection.partial.json":
            (tmp_path / "policy.json").write_text("changed after write")

    monkeypatch.setattr(execution, "_write_json", mutate)
    with pytest.raises(ValueError):
        run(path, tmp_path)
    assert not (tmp_path / "output" / "selection.json").exists()


def test_cancellation_joins_selection_thread_and_never_commits(tmp_path, monkeypatch):
    import meeting_selection_execution as execution

    path, _ = controls(tmp_path)
    original = execution.select_development_candidate
    entered, release, finished = threading.Event(), threading.Event(), threading.Event()

    def slow(**kwargs):
        entered.set()
        assert release.wait(3)
        try:
            return original(**kwargs)
        finally:
            finished.set()

    monkeypatch.setattr(execution, "select_development_candidate", slow)

    async def scenario():
        task = asyncio.create_task(
            execution.execute_development_selection(
                selection_lock=path, output_directory=tmp_path / "output"
            )
        )
        try:
            assert await asyncio.to_thread(entered.wait, 3)
            task.cancel()
        finally:
            release.set()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert finished.is_set()
        assert not (tmp_path / "output" / "selection.json").exists()

    asyncio.run(scenario())


def test_duplicate_control_keys_and_preexisting_output_are_preserved(tmp_path):
    path, _ = controls(tmp_path)
    original = path.read_text()
    path.write_text('{"schema_version":1,' + original[1:])
    with pytest.raises(ValueError):
        run(path, tmp_path)
    path.write_text(original)
    output = tmp_path / "output"
    output.mkdir(exist_ok=True)
    marker = output / "keep.txt"
    marker.write_text("preserve")
    with pytest.raises(ValueError):
        run(path, tmp_path)
    assert marker.read_text() == "preserve"


def test_select_development_cli_is_offline_and_sanitizes_errors(tmp_path, capsys):
    from probe_meeting_candidate import main

    path, _ = controls(tmp_path)
    assert (
        main(
            [
                "select-development",
                "--selection-lock",
                str(path),
                "--output-directory",
                str(tmp_path / "output"),
            ]
        )
        == 0
    )
    result = json.loads(capsys.readouterr().out)
    assert result["selected_candidate"] == "C1"
    assert result["certification_eligible"] is False
    with pytest.raises(SystemExit) as caught:
        main(
            [
                "select-development",
                "--selection-lock",
                str(tmp_path / "private-missing"),
                "--output-directory",
                str(tmp_path / "other"),
            ]
        )
    assert caught.value.code == 2
    assert str(tmp_path) not in capsys.readouterr().err


@pytest.mark.parametrize("change", ["budget", "fifo"])
def test_input_budget_and_nonregular_control_fail_before_selection(tmp_path, monkeypatch, change):
    import os

    import meeting_selection_execution as execution

    path, _ = controls(tmp_path)
    if change == "budget":
        monkeypatch.setattr(execution, "_MAX_BYTES", 100)
    else:
        path.unlink()
        os.mkfifo(path)
    with pytest.raises(ValueError):
        run(path, tmp_path)
    assert not (tmp_path / "output").exists()
