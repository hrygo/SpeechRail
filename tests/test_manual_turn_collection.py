"""Deterministic consumer conformance for the current manual ASR barrier."""

from __future__ import annotations

import pytest

from speechrail.realtime.turn_collection import ManualTurnCollector

COMPLETED = "conversation.item.input_audio_transcription.completed"


def _event(sequence: int, kind: str, **fields: object) -> dict[str, object]:
    return {"sequence": sequence, "event_id": f"e{sequence}", "type": kind, **fields}


def test_declared_items_join_in_terminal_order() -> None:
    turn = ManualTurnCollector(epoch="connection-a")
    for _ in range(3):
        turn.expect_item()
    turn.begin_close()
    turn.accept(_event(1, COMPLETED, item_id="b", transcript="相同"), epoch="connection-a")
    turn.accept(_event(2, COMPLETED, item_id="a", transcript="相同"), epoch="connection-a")
    assert turn.result is None
    turn.accept(_event(3, COMPLETED, item_id="tail", transcript=""), epoch="connection-a")
    assert turn.result is not None
    assert turn.result.item_ids == ("b", "a", "tail")
    assert turn.result.text == "相同相同"


@pytest.mark.parametrize(
    ("failure", "expected_state"),
    [
        ("error", "failed"),
        ("disconnect", "failed"),
        # A declared item whose terminal never arrives leaves the barrier
        # unresolved: the current wire has no clear receipt to interpret as
        # success or failure, so the turn must never report a receipt.
        ("missing", "closing"),
        ("gap", "failed"),
        ("cancel", "cancelled"),
    ],
)
def test_partial_or_aborted_turn_is_not_a_success_receipt(
    failure: str, expected_state: str
) -> None:
    turn = ManualTurnCollector(epoch="a")
    turn.expect_item()
    turn.begin_close()
    if failure == "error":
        turn.accept(_event(1, "error", error={"code": "backend_timeout"}), epoch="a")
    elif failure == "disconnect":
        turn.disconnect()
    elif failure == "cancel":
        turn.cancel()
    elif failure == "gap":
        turn.accept(_event(3, COMPLETED, item_id="i", transcript="partial"), epoch="a")
    assert turn.result is None
    assert turn.state == expected_state


def test_duplicate_and_old_epoch_cannot_duplicate_text() -> None:
    turn = ManualTurnCollector(epoch="new")
    turn.accept(_event(1, COMPLETED, item_id="old", transcript="old"), epoch="old")
    turn.expect_item()
    event = _event(1, COMPLETED, item_id="i", transcript="hello")
    turn.accept(event, epoch="new")
    turn.accept(event, epoch="new")
    turn.begin_close()
    assert turn.result is not None and turn.result.text == "hello"


def test_empty_turn_is_empty_not_synthetic_text() -> None:
    turn = ManualTurnCollector(epoch="a")
    turn.expect_item()
    turn.begin_close()
    turn.accept(_event(1, COMPLETED, item_id="empty", transcript=""), epoch="a")
    assert turn.result is not None and turn.result.text == ""


def test_append_during_close_is_detectable_and_invalidates_turn() -> None:
    turn = ManualTurnCollector(epoch="a")
    turn.note_append()
    turn.begin_close()
    with pytest.raises(ValueError, match="turn_not_collecting"):
        turn.note_append()
    assert turn.result is None and turn.state == "failed"


@pytest.mark.parametrize("mutation", ["duplicate_conflict", "unexpected_item", "text_limit"])
def test_malformed_terminals_fail_closed(mutation: str) -> None:
    turn = ManualTurnCollector(epoch="a", max_text_chars=4)
    for _ in range(2 if mutation == "text_limit" else 1):
        turn.expect_item()
    turn.accept(_event(1, COMPLETED, item_id="i", transcript="ok"), epoch="a")
    if mutation == "duplicate_conflict":
        bad = _event(2, COMPLETED, item_id="i", transcript="no")
    elif mutation == "unexpected_item":
        bad = _event(2, COMPLETED, item_id="other", transcript="x")
    else:
        bad = _event(2, COMPLETED, item_id="j", transcript="too long")
    turn.accept(bad, epoch="a")
    assert turn.state == "failed"


@pytest.mark.parametrize("budget", ["event", "item", "text"])
def test_collection_resource_limits_fail_closed(budget: str) -> None:
    if budget == "event":
        turn = ManualTurnCollector(epoch="a", max_events=1)
        turn.expect_item()
        turn.accept(_event(1, COMPLETED, item_id="first", transcript=""), epoch="a")
        turn.accept(_event(2, COMPLETED, item_id="first", transcript=""), epoch="a")
        expected = "event_budget_exceeded"
    elif budget == "item":
        turn = ManualTurnCollector(epoch="a", max_items=1)
        turn.expect_item()
        with pytest.raises(ValueError, match="item_budget_exceeded"):
            turn.expect_item()
        expected = "item_budget_exceeded"
    else:
        turn = ManualTurnCollector(epoch="a", max_text_chars=1)
        turn.expect_item()
        turn.accept(_event(1, COMPLETED, item_id="first", transcript="xx"), epoch="a")
        expected = "text_budget_exceeded"
    assert turn.state == "failed"
    assert turn.failure_reason == expected
    assert turn.result is None


@pytest.mark.parametrize("kind", ["failed", "disconnect", "cancel"])
def test_late_completed_cannot_resurrect_an_aborted_turn(kind: str) -> None:
    turn = ManualTurnCollector(epoch="a")
    turn.expect_item()
    turn.begin_close()
    if kind == "failed":
        turn.accept(
            _event(
                1,
                "conversation.item.input_audio_transcription.failed",
                item_id="first",
            ),
            epoch="a",
        )
    elif kind == "disconnect":
        turn.disconnect()
    else:
        turn.cancel()
    turn.accept(_event(2, COMPLETED, item_id="first", transcript="late"), epoch="a")
    assert turn.result is None
    assert turn.state in {"failed", "cancelled"}
