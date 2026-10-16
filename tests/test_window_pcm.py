import pytest

from speechrail.domain.audio_timeline import SampleSpan
from speechrail.runtime.window_pcm import PcmBudgetExceededError, WindowPcmRing


def test_exact_samples_and_all_copy_reservations_are_accounted():
    ring = WindowPcmRing()
    pcm = b"\x01\x00" * 513
    ring.append(0, pcm)
    borrow = ring.borrow(SampleSpan(1, 512))
    assert borrow.pcm16 == pcm[2:1024]
    assert ring.charged_bytes == len(pcm) + 511 * 2 * 4
    with pytest.raises(PcmBudgetExceededError):
        ring.clear()
    borrow.release()
    borrow.release()
    ring.clear()
    assert ring.charged_bytes == 0


def test_pinned_pcm_cannot_be_overwritten_by_retention_or_budget():
    ring = WindowPcmRing(max_samples=10, budget_bytes=100)
    ring.append(0, bytes(20))
    borrow = ring.borrow(SampleSpan(0, 2))
    with pytest.raises(PcmBudgetExceededError):
        ring.append(10, bytes(2))
    assert ring.accepted_samples == 10
    borrow.release()
    ring.append(10, bytes(2))
    assert ring.retained_from_sample == 1


def test_budget_is_checked_before_copy_and_rejection_keeps_state():
    ring = WindowPcmRing(max_samples=10, budget_bytes=32)
    ring.append(0, bytes(20))
    with pytest.raises(PcmBudgetExceededError):
        ring.borrow(SampleSpan(0, 2))
    assert ring.charged_bytes == 20
    assert ring.active_borrows == 0


def test_gaps_odd_bytes_and_lost_audio_are_rejected():
    ring = WindowPcmRing(max_samples=2)
    ring.append(0, bytes(4))
    ring.append(2, bytes(2))
    for start, pcm in [(4, bytes(2)), (3, b"\x00"), (True, bytes(2))]:
        with pytest.raises(ValueError):
            ring.append(start, pcm)
    with pytest.raises(ValueError):
        ring.borrow(SampleSpan(0, 1))
    with pytest.raises(ValueError):
        ring.borrow(SampleSpan(1, 4))


def test_explicit_compaction_respects_pin_and_clear_invalidates_old_audio():
    ring = WindowPcmRing()
    ring.append(0, bytes(20))
    with ring.borrow(SampleSpan(2, 5)) as borrow:
        with pytest.raises(PcmBudgetExceededError):
            ring.discard_before(3)
        ring.discard_before(2)
        assert len(borrow.pcm16) == 6
    ring.discard_before(10)
    assert ring.charged_bytes == 0
    ring.clear()
    assert ring.accepted_samples == 0


def test_two_hour_input_keeps_retention_fixed_without_model_or_sleep():
    ring = WindowPcmRing(max_samples=60 * 16000)
    pcm = bytes(16000 * 2)
    for second in range(7200):
        ring.append(second * 16000, pcm)
    assert ring.charged_bytes == 60 * 16000 * 2
    assert ring.accepted_samples == 7200 * 16000
