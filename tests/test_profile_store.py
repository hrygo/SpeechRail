from __future__ import annotations

import json
import stat
from pathlib import Path

import pytest

from speechrail.service.profile_store import (
    ProfileStore,
    allowed_transition,
    claim_startup_selection,
    recover_selection,
)


def selection(preset: str = "quality", generation: int = 1) -> dict[str, object]:
    return {
        "schema_version": 1, "preset": preset, "generation": generation,
        "asr": "large-q8", "tts": "design-q8", "runtime_lock_id": "runtime-v1",
    }


def test_uncommitted_candidate_never_becomes_active(tmp_path: Path) -> None:
    store = ProfileStore(tmp_path)
    old, new = selection(), selection("light", 2)
    store.initialize(old)
    operation = store.begin(old, new)
    for stage in ("VERIFIED", "STOPPING", "SWITCHING"):
        store.mark(operation, stage)
        assert ProfileStore(tmp_path).recover() == old
    store.stage_candidate(operation)
    assert ProfileStore(tmp_path).recover() == old
    assert claim_startup_selection(tmp_path) == new
    store.mark(operation, "SMOKING")
    store.commit(operation)
    assert recover_selection(tmp_path) == new
    assert json.loads((tmp_path / "config/selection.previous.json").read_text()) == old


def test_commit_requires_successful_smoke_and_matching_operation(tmp_path: Path) -> None:
    store = ProfileStore(tmp_path)
    store.initialize(selection())
    operation = store.begin(selection(), selection("light", 2))
    with pytest.raises(ValueError, match="transition"):
        store.commit(operation)
    with pytest.raises(ValueError, match="operation"):
        store.mark("op_unknown", "VERIFIED")
    assert allowed_transition("SMOKING", "COMMITTED")
    assert not allowed_transition("STARTING", "COMMITTED")


def test_parallel_switch_is_rejected_and_rollback_is_idempotent(tmp_path: Path) -> None:
    first, second = ProfileStore(tmp_path), ProfileStore(tmp_path)
    first.initialize(selection())
    operation = first.begin(selection(), selection("balanced", 2))
    with pytest.raises(RuntimeError, match="busy"):
        second.begin(selection(), selection("light", 2))
    first.rollback(operation)
    first.rollback(operation)
    assert first.recover() == selection()
    assert second.begin(selection(), selection("light", 2)) != operation


def test_new_install_failure_stays_unconfigured(tmp_path: Path) -> None:
    store = ProfileStore(tmp_path)
    assert recover_selection(tmp_path) is None
    assert not (tmp_path / "config").exists()
    operation = store.begin(None, selection("light"))
    store.rollback(operation)
    assert store.recover() is None


def test_selection_and_transaction_files_are_private(tmp_path: Path) -> None:
    store = ProfileStore(tmp_path)
    store.initialize(selection())
    store.begin(selection(), selection("light", 2))
    for relative in ("config/selection.json", "state/profile-transaction.json"):
        assert stat.S_IMODE((tmp_path / relative).stat().st_mode) == 0o600
    for relative in ("config", "state"):
        assert stat.S_IMODE((tmp_path / relative).stat().st_mode) == 0o700


def test_invalid_selection_and_stale_generation_are_rejected(tmp_path: Path) -> None:
    store = ProfileStore(tmp_path)
    store.initialize(selection())
    for candidate in (selection("light", 1), selection("other", 2), {**selection(), "host": "x"}):
        with pytest.raises(ValueError):
            store.begin(selection(), candidate)
    with pytest.raises(ValueError, match="current"):
        store.begin(selection("balanced"), selection("light", 2))


def test_selection_symlink_never_overwrites_external_file(tmp_path: Path) -> None:
    target = tmp_path / "external.json"
    target.write_text("untouched")
    (tmp_path / "config").mkdir()
    (tmp_path / "config/selection.json").symlink_to(target)
    with pytest.raises(ValueError, match="symlink"):
        ProfileStore(tmp_path).initialize(selection())
    assert target.read_text() == "untouched"


def test_corrupt_candidate_does_not_hide_last_known_good(tmp_path: Path) -> None:
    store = ProfileStore(tmp_path)
    store.initialize(selection())
    store.begin(selection(), selection("light", 2))
    path = tmp_path / "state/profile-transaction.json"
    record = json.loads(path.read_text())
    record["candidate"] = {"broken": True}
    path.write_text(json.dumps(record))
    assert store.recover() == selection()


def test_crash_after_selection_write_before_commit_uses_previous(tmp_path: Path) -> None:
    store = ProfileStore(tmp_path)
    store.initialize(selection())
    store.begin(selection(), selection("light", 2))
    (tmp_path / "config/selection.json").write_text(json.dumps(selection("light", 2)))
    assert store.recover() == selection()


@pytest.mark.parametrize("failing_write", [1, 2, 3])
def test_commit_crash_at_each_atomic_write_recovers_old_selection(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, failing_write: int
) -> None:
    store = ProfileStore(tmp_path)
    store.initialize(selection())
    operation = store.begin(selection(), selection("light", 2))
    for stage in ("VERIFIED", "STOPPING", "SWITCHING"):
        store.mark(operation, stage)
    store.stage_candidate(operation)
    store.mark(operation, "SMOKING")
    original_write = store._write
    count = 0

    def fail_write(path: Path, value: object) -> None:
        nonlocal count
        count += 1
        if count == failing_write:
            raise OSError("simulated crash")
        original_write(path, value)

    monkeypatch.setattr(store, "_write", fail_write)
    with pytest.raises(OSError, match="simulated crash"):
        store.commit(operation)
    assert ProfileStore(tmp_path).recover() == selection()


def test_cross_instance_file_lock_is_nonblocking(tmp_path: Path) -> None:
    store = ProfileStore(tmp_path)
    with store._locked(), pytest.raises(RuntimeError, match="busy"):
        ProfileStore(tmp_path).initialize(selection())


def test_unknown_journal_schema_fails_closed(tmp_path: Path) -> None:
    store = ProfileStore(tmp_path)
    store.begin(None, selection())
    path = tmp_path / "state/profile-transaction.json"
    raw = json.loads(path.read_text())
    raw["schema_version"] = 2
    path.write_text(json.dumps(raw))
    with pytest.raises(ValueError, match="schema"):
        store.recover()


def test_stage_candidate_writes_one_shot_permit_and_claim_returns_lkg_afterward(
    tmp_path: Path,
) -> None:
    store = ProfileStore(tmp_path)
    old, candidate = selection(), selection("light", 2)
    store.initialize(old)
    operation = store.begin(old, candidate)
    for stage in ("VERIFIED", "STOPPING", "SWITCHING"):
        store.mark(operation, stage)

    store.stage_candidate(operation)

    permit_path = tmp_path / "state/profile-startup-permit.json"
    assert permit_path.is_file()
    assert stat.S_IMODE(permit_path.stat().st_mode) == 0o600
    assert claim_startup_selection(tmp_path) == candidate
    assert not permit_path.exists()
    assert claim_startup_selection(tmp_path) == old


def test_candidate_claim_requires_matching_operation_and_selection(tmp_path: Path) -> None:
    store = ProfileStore(tmp_path)
    old, candidate = selection(), selection("light", 2)
    store.initialize(old)
    operation = store.begin(old, candidate)
    for stage in ("VERIFIED", "STOPPING", "SWITCHING"):
        store.mark(operation, stage)
    store.stage_candidate(operation)

    permit_path = tmp_path / "state/profile-startup-permit.json"
    permit = json.loads(permit_path.read_text())
    permit["operation_id"] = "op_" + "0" * 32
    permit_path.write_text(json.dumps(permit))
    assert claim_startup_selection(tmp_path) == old


@pytest.mark.parametrize("tampered_file", ["journal", "selection"])
def test_candidate_claim_rejects_tampered_candidate_or_selection(
    tmp_path: Path, tampered_file: str
) -> None:
    store = ProfileStore(tmp_path)
    old, candidate = selection(), selection("light", 2)
    store.initialize(old)
    operation = store.begin(old, candidate)
    for stage in ("VERIFIED", "STOPPING", "SWITCHING"):
        store.mark(operation, stage)
    store.stage_candidate(operation)

    if tampered_file == "journal":
        journal_path = tmp_path / "state/profile-transaction.json"
        journal = json.loads(journal_path.read_text())
        journal["candidate"] = selection("balanced", 2)
        journal_path.write_text(json.dumps(journal))
    else:
        (tmp_path / "config/selection.json").write_text(json.dumps(old))

    assert claim_startup_selection(tmp_path) == old


def test_atomic_permit_consume_failure_falls_back_to_lkg(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    store = ProfileStore(tmp_path)
    old, candidate = selection(), selection("light", 2)
    store.initialize(old)
    operation = store.begin(old, candidate)
    for stage in ("VERIFIED", "STOPPING", "SWITCHING"):
        store.mark(operation, stage)
    store.stage_candidate(operation)
    monkeypatch.setattr(
        store, "_remove_startup_permit", lambda: (_ for _ in ()).throw(OSError("busy"))
    )

    assert store.claim_startup_selection() == old
    assert store.startup_permit_path.exists()


def test_rollback_removes_residual_startup_permit(tmp_path: Path) -> None:
    store = ProfileStore(tmp_path)
    old, candidate = selection(), selection("light", 2)
    store.initialize(old)
    operation = store.begin(old, candidate)
    for stage in ("VERIFIED", "STOPPING", "SWITCHING"):
        store.mark(operation, stage)
    store.stage_candidate(operation)

    store.rollback(operation)

    assert not store.startup_permit_path.exists()
    assert store.recover() == old


def test_first_install_candidate_is_not_restarted_after_consumed_permit(tmp_path: Path) -> None:
    store = ProfileStore(tmp_path)
    candidate = selection("light")
    operation = store.begin(None, candidate)
    for stage in ("VERIFIED", "STOPPING", "SWITCHING"):
        store.mark(operation, stage)
    store.stage_candidate(operation)

    assert claim_startup_selection(tmp_path) == candidate
    assert claim_startup_selection(tmp_path) is None
    assert recover_selection(tmp_path) is None


@pytest.mark.parametrize("mutation", ["corrupt", "oversized", "symlink"])
def test_invalid_startup_permit_falls_back_without_following_external_target(
    tmp_path: Path, mutation: str
) -> None:
    store = ProfileStore(tmp_path)
    old, candidate = selection(), selection("light", 2)
    store.initialize(old)
    operation = store.begin(old, candidate)
    for stage in ("VERIFIED", "STOPPING", "SWITCHING"):
        store.mark(operation, stage)
    store.stage_candidate(operation)
    permit_path = tmp_path / "state/profile-startup-permit.json"

    if mutation == "corrupt":
        permit_path.write_text("not-json")
    elif mutation == "oversized":
        permit_path.write_bytes(b"x" * 65_537)
    else:
        external = tmp_path / "external.json"
        external.write_text("untouched")
        permit_path.unlink()
        permit_path.symlink_to(external)

    assert claim_startup_selection(tmp_path) == old
    if mutation == "symlink":
        assert (tmp_path / "external.json").read_text() == "untouched"
