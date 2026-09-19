"""Deterministic consumer conformance for the existing manual ASR barrier."""
from __future__ import annotations

import pytest

from speechrail.realtime.turn_collection import ManualTurnCollector

COMMITTED = "input_audio_buffer.committed"
COMPLETED = "conversation.item.input_audio_transcription.completed"
CLEARED = "input_audio_buffer.cleared"


def _event(sequence: int, kind: str, **fields: object) -> dict[str, object]:
    return {"sequence": sequence, "event_id": f"e{sequence}", "type": kind, **fields}


def test_rollovers_finish_in_commit_order_not_completion_order() -> None:
    turn = ManualTurnCollector(epoch="connection-a")
    turn.accept(_event(1, COMMITTED, item_id="a"), epoch="connection-a")
    turn.accept(_event(2, COMMITTED, item_id="b"), epoch="connection-a")
    turn.begin_close()
    turn.accept(_event(3, COMPLETED, item_id="b", transcript="相同"), epoch="connection-a")
    turn.accept(_event(4, COMPLETED, item_id="a", transcript="相同"), epoch="connection-a")
    assert turn.result is None
    turn.accept(_event(5, COMMITTED, item_id="tail"), epoch="connection-a")
    turn.accept(_event(6, COMPLETED, item_id="tail", transcript=""), epoch="connection-a")
    turn.accept(_event(7, CLEARED), epoch="connection-a")
    assert turn.result is not None
    assert turn.result.text == "相同相同"
    assert turn.result.item_ids == ("a", "b", "tail")


@pytest.mark.parametrize("failure", ["error", "disconnect", "missing", "gap", "cancel"])
def test_clear_is_not_a_success_receipt(failure: str) -> None:
    turn = ManualTurnCollector(epoch="a")
    turn.accept(_event(1, COMMITTED, item_id="i"), epoch="a")
    turn.begin_close()
    if failure == "error":
        turn.accept(_event(2, "error", error={"code": "backend_timeout"}), epoch="a")
    elif failure == "disconnect":
        turn.disconnect()
    elif failure == "cancel":
        turn.cancel()
    elif failure == "gap":
        turn.accept(_event(3, COMPLETED, item_id="i", transcript="partial"), epoch="a")
    turn.accept(_event(3 if failure == "error" else 2, CLEARED), epoch="a")
    assert turn.result is None
    assert turn.state in {"failed", "cancelled"}


def test_duplicate_and_old_epoch_cannot_duplicate_text() -> None:
    turn = ManualTurnCollector(epoch="new")
    turn.accept(_event(1, COMMITTED, item_id="old"), epoch="old")
    turn.accept(_event(1, COMMITTED, item_id="i"), epoch="new")
    event = _event(2, COMPLETED, item_id="i", transcript="hello")
    turn.accept(event, epoch="new")
    turn.accept(event, epoch="new")
    turn.begin_close()
    turn.accept(_event(3, CLEARED), epoch="new")
    assert turn.result is not None and turn.result.text == "hello"


def test_empty_turn_is_empty_not_synthetic_text() -> None:
    turn = ManualTurnCollector(epoch="a")
    turn.begin_close()
    turn.accept(_event(1, COMMITTED, item_id="empty"), epoch="a")
    turn.accept(_event(2, COMPLETED, item_id="empty", transcript=""), epoch="a")
    turn.accept(_event(3, CLEARED), epoch="a")
    assert turn.result is not None and turn.result.text == ""


def test_append_during_close_is_detectable_and_invalidates_turn() -> None:
    turn = ManualTurnCollector(epoch="a")
    turn.note_append()
    turn.begin_close()
    with pytest.raises(ValueError, match="turn_not_collecting"):
        turn.note_append()
    assert turn.result is None and turn.state == "failed"


@pytest.mark.parametrize("mutation", ["duplicate_conflict", "unknown_item", "text_limit"])
def test_malformed_terminals_fail_closed(mutation: str) -> None:
    turn = ManualTurnCollector(epoch="a", max_text_chars=4)
    turn.accept(_event(1, COMMITTED, item_id="i"), epoch="a")
    turn.accept(_event(2, COMPLETED, item_id="i", transcript="ok"), epoch="a")
    if mutation == "duplicate_conflict":
        bad = _event(2, COMPLETED, item_id="i", transcript="no")
    elif mutation == "unknown_item":
        bad = _event(3, COMPLETED, item_id="other", transcript="x")
    else:
        bad = _event(3, COMPLETED, item_id="i", transcript="too long")
    turn.accept(bad, epoch="a")
    assert turn.state == "failed"
