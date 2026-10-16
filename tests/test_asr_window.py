from dataclasses import replace

import pytest

from speechrail.domain.asr_window import (
    WindowDecodeRequest,
    WindowDecodeResult,
    WindowIdentity,
    WindowLedger,
    WindowPolicy,
    WindowUnit,
)
from speechrail.domain.audio_timeline import SampleSpan


def ledger():
    return WindowLedger(WindowIdentity("session", 0, "window"))


def reviewed(unit, text=None):
    return replace(unit, state="reviewed", text=unit.text if text is None else text)


def test_atomic_review_replaces_preview_and_final_is_immutable():
    state = ledger()
    state.append(SampleSpan(0, 64000))
    initial = state.preview(SampleSpan(0, 64000), "错字🙂")
    state.close_block(64000, "budget_rollover")
    state.accept(
        [reviewed(initial, "正确🙂")],
        {initial.unit_id: initial.text_revision},
        identity=state.identity,
    )
    final = state.seal(64000)
    assert final.closed_span == SampleSpan(0, 64000)
    assert final.final_units[0].text == "正确🙂"
    assert final.final_units[0].review_scope == "contextual"
    assert state.snapshot().units == ()
    assert state.seal(64000) is None
    with pytest.raises(ValueError):
        state.preview(SampleSpan(0, 64000), "不能改终稿")


def test_stale_parent_and_epoch_do_not_mutate_snapshot():
    state = ledger()
    state.append(SampleSpan(0, 10))
    old = state.preview(SampleSpan(0, 10), "旧")
    new = state.preview(SampleSpan(0, 10), "新")
    state.close_block(10, "vad")
    before = state.snapshot()
    with pytest.raises(ValueError):
        state.accept([reviewed(old)], {old.unit_id: old.text_revision}, identity=state.identity)
    with pytest.raises(ValueError):
        state.accept(
            [reviewed(new)],
            {new.unit_id: new.text_revision},
            identity=WindowIdentity("session", 1, "window"),
        )
    assert state.snapshot() == before


def test_review_can_merge_closed_blocks_but_cannot_overlap_or_lose_coverage():
    state = ledger()
    state.append(SampleSpan(0, 20))
    first = state.preview(SampleSpan(0, 10), "重复")
    state.close_block(10, "budget_rollover")
    second = state.preview(SampleSpan(10, 20), "重复")
    state.close_block(20, "vad")
    parents = {u.unit_id: u.text_revision for u in (first, second)}
    merged = WindowUnit("merged", "重复一次", 1, SampleSpan(0, 20), "reviewed")
    with pytest.raises(ValueError):
        state.accept(
            [replace(merged, owned_span=SampleSpan(1, 20))], parents, identity=state.identity
        )
    state.accept([merged], parents, identity=state.identity)
    assert [u.unit_id for u in state.snapshot().units] == ["merged"]
    assert state.seal(20).final_units[0].text == "重复一次"


def test_empty_review_is_success_and_missing_review_is_not():
    state = ledger()
    state.append(SampleSpan(0, 1))
    u = state.preview(SampleSpan(0, 1), "")
    state.close_block(1, "vad")
    with pytest.raises(ValueError):
        state.seal(1)
    state.accept([reviewed(u)], {u.unit_id: u.text_revision}, identity=state.identity)
    final = state.seal(1)
    assert final.final_units[0].text == ""
    assert final.coverage[0].outcome == "speech"


def test_failure_preserves_preview_and_contiguous_failure_coverage():
    state = ledger()
    state.append(SampleSpan(0, 12))
    state.preview(SampleSpan(0, 12), "恢复🙂")
    final = state.fail(12, "decode_failed")
    assert final.failed_items[0].recovery_text == "恢复🙂"
    assert final.coverage[0].span == SampleSpan(0, 12)
    assert state.snapshot().sealed_through_sample == 12


@pytest.mark.parametrize("n", [511, 512, 513])
def test_wire_mapping_is_at_integer_boundaries_and_decode_rejects_truncation(n):
    identity = WindowIdentity("s", 0, "w")
    request = WindowDecodeRequest(identity, "attempt", "review", SampleSpan(0, n), bytes(n * 2))
    assert request.input_span.length == n
    with pytest.raises(ValueError):
        replace(request, pcm16=bytes(n * 2 - 1))
    result = WindowDecodeResult(identity, "attempt", SampleSpan(0, n), "", None, False)
    assert result.complete is False


def test_policy_context_sum_and_strict_integer_limits():
    p = WindowPolicy.for_scene("caption")
    assert p.owned_ms + p.review_grace_ms + p.left_context_ms == p.max_decode_ms == 14000
    with pytest.raises(ValueError):
        WindowIdentity("s", True, "w")
    with pytest.raises(ValueError):
        replace(p, owned_ms=True)
    with pytest.raises(ValueError):
        replace(p, max_decode_ms=12000)
    state = ledger()
    with pytest.raises(ValueError):
        state.append(SampleSpan(True, 2))


def test_snapshot_rejects_codepoint_and_unit_overflow_without_truncating():
    state = ledger()
    state.append(SampleSpan(0, 2))
    with pytest.raises(ValueError):
        state.preview(SampleSpan(0, 2), "🙂" * 8193)
    assert state.snapshot().units == ()


def test_silence_must_be_explicitly_authorized_by_admission_frontier():
    state = ledger()
    state.append(SampleSpan(0, 12))
    with pytest.raises(ValueError):
        state.seal(12)
    final = state.seal(12, allow_silence=True)
    assert not final.final_units
    assert final.coverage[0].outcome == "silence"
    assert final.coverage[0].reason == "vad_not_admitted"


def test_asr_and_dynamic_rings_share_one_physical_copy_budget():
    from speechrail.runtime.window_pcm import PcmBudget, PcmBudgetExceededError, WindowPcmRing

    pool = PcmBudget(limit_bytes=10000)
    asr = WindowPcmRing(budget_account=pool)
    activity = WindowPcmRing(budget_account=pool)
    asr.append(0, bytes(2000))
    activity.append(0, bytes(2000))
    with asr.borrow(SampleSpan(0, 500), copy_factor=4):
        assert pool.used_bytes == 8000
        with pytest.raises(PcmBudgetExceededError):
            activity.borrow(SampleSpan(0, 1000), copy_factor=4)
    assert pool.used_bytes == 4000
    asr.clear()
    activity.clear()
    assert pool.used_bytes == 0
