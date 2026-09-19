from __future__ import annotations

import json

import pytest

from speechrail.domain.idempotency import (
    DurableIdempotencyJournal,
    IdempotencyConflictError,
    IdempotencyStoreUnavailableError,
)


def test_pending_survives_restart_and_blocks_duplicate_side_effect(tmp_path):
    path = tmp_path / "journal.json"
    first = DurableIdempotencyJournal(path, max_entries=8)
    decision = first.begin(
        owner="local",
        operation="voice.clone",
        key="same-key",
        fingerprint="payload-a",
    )
    assert decision.state == "new"

    restarted = DurableIdempotencyJournal(path, max_entries=8)
    replay = restarted.begin(
        owner="local",
        operation="voice.clone",
        key="same-key",
        fingerprint="payload-a",
    )
    assert replay.state == "pending"
    assert replay.result_id is None


def test_completed_replay_returns_original_result_after_restart(tmp_path):
    path = tmp_path / "journal.json"
    journal = DurableIdempotencyJournal(path, max_entries=8)
    journal.begin(
        owner="local",
        operation="voice.clone",
        key="same-key",
        fingerprint="payload-a",
    )
    assert (
        journal.complete(
            owner="local",
            operation="voice.clone",
            key="same-key",
            fingerprint="payload-a",
            result_id="voice-123",
        )
        == "voice-123"
    )

    replay = DurableIdempotencyJournal(path, max_entries=8).begin(
        owner="local",
        operation="voice.clone",
        key="same-key",
        fingerprint="payload-a",
    )
    assert replay.state == "completed"
    assert replay.result_id == "voice-123"


def test_same_key_with_different_payload_is_rejected(tmp_path):
    journal = DurableIdempotencyJournal(tmp_path / "journal.json")
    journal.begin(
        owner="local",
        operation="voice.clone",
        key="same-key",
        fingerprint="payload-a",
    )
    with pytest.raises(IdempotencyConflictError):
        journal.begin(
            owner="local",
            operation="voice.clone",
            key="same-key",
            fingerprint="payload-b",
        )


def test_abort_removes_only_pending_record(tmp_path):
    path = tmp_path / "journal.json"
    journal = DurableIdempotencyJournal(path)
    journal.begin(
        owner="local",
        operation="voice.clone",
        key="same-key",
        fingerprint="payload-a",
    )
    journal.abort(
        owner="local",
        operation="voice.clone",
        key="same-key",
        fingerprint="payload-a",
    )
    assert journal.begin(
        owner="local",
        operation="voice.clone",
        key="same-key",
        fingerprint="payload-a",
    ).state == "new"


def test_journal_does_not_persist_raw_idempotency_key(tmp_path):
    path = tmp_path / "journal.json"
    journal = DurableIdempotencyJournal(path)
    journal.begin(
        owner="local",
        operation="voice.clone",
        key="SUPER-SECRET-KEY",
        fingerprint="payload-a",
    )
    raw = path.read_text(encoding="utf-8")
    assert "SUPER-SECRET-KEY" not in raw
    data = json.loads(raw)
    assert data[0]["state"] == "pending"


def test_pending_replay_preserves_provisional_result_id(tmp_path):
    path = tmp_path / "journal.json"
    first = DurableIdempotencyJournal(path, max_entries=8)
    created = first.begin(
        owner="local",
        operation="voice.clone",
        key="recoverable-key",
        fingerprint="payload-a",
        provisional_result_id="clone_idem_deadbeef",
    )
    assert created.state == "new"
    assert created.result_id == "clone_idem_deadbeef"

    replay = DurableIdempotencyJournal(path, max_entries=8).begin(
        owner="local",
        operation="voice.clone",
        key="recoverable-key",
        fingerprint="payload-a",
        provisional_result_id="ignored-on-replay",
    )
    assert replay.state == "pending"
    assert replay.result_id == "clone_idem_deadbeef"


def test_lookup_requires_key_possession_and_returns_terminal_state(tmp_path):
    journal = DurableIdempotencyJournal(tmp_path / "journal.json")
    journal.begin(
        owner="local",
        operation="voice.clone",
        key="known-key",
        fingerprint="payload-a",
        provisional_result_id="voice-1",
    )
    assert journal.lookup(
        owner="local",
        operation="voice.clone",
        key="missing-key",
    ) is None
    pending = journal.lookup(
        owner="local",
        operation="voice.clone",
        key="known-key",
    )
    assert pending is not None
    assert pending.state == "pending"
    assert pending.result_id == "voice-1"

    journal.complete(
        owner="local",
        operation="voice.clone",
        key="known-key",
        fingerprint="payload-a",
        result_id="voice-1",
    )
    completed = journal.lookup(
        owner="local",
        operation="voice.clone",
        key="known-key",
    )
    assert completed is not None
    assert completed.state == "completed"
    assert completed.result_id == "voice-1"


def test_bounded_journal_never_evicts_unresolved_pending_records(tmp_path):
    journal = DurableIdempotencyJournal(
        tmp_path / "journal.json",
        max_entries=2,
    )
    for index in range(2):
        journal.begin(
            owner="local",
            operation="voice.clone",
            key=f"pending-{index}",
            fingerprint=f"payload-{index}",
            provisional_result_id=f"voice-{index}",
        )

    with pytest.raises(IdempotencyStoreUnavailableError):
        journal.begin(
            owner="local",
            operation="voice.clone",
            key="pending-overflow",
            fingerprint="payload-overflow",
            provisional_result_id="voice-overflow",
        )
