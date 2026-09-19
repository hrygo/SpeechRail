from __future__ import annotations

import json

import pytest

from speechrail.domain.idempotency import (
    DurableIdempotencyJournal,
    IdempotencyConflictError,
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
