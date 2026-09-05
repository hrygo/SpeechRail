"""PcmBlock and rolling-window behavior tests."""

from __future__ import annotations

import pytest

from speechrail.application.audio_stream import PcmBlock, PcmWindowBuffer, split_pcm


def _samples(count: int) -> bytes:
    return b"".join((sample % 65_536).to_bytes(2, "little") for sample in range(count))


def _core_bytes(block: PcmBlock) -> bytes:
    start_sample = block.start_sample
    core_start_sample = block.core_start_sample
    core_end_sample = block.core_end_sample
    offset = (core_start_sample - start_sample) * 2
    end = (core_end_sample - start_sample) * 2
    return block.pcm[offset:end]


def test_short_clip_is_one_window_and_core_covers_all_samples() -> None:
    pcm = _samples(5)

    blocks = split_pcm(pcm, window_samples=8, overlap_samples=2)

    assert len(blocks) == 1
    assert blocks[0].start_sample == 0
    assert blocks[0].core_start_sample == 0
    assert blocks[0].core_end_sample == 5
    assert blocks[0].pcm == pcm


def test_default_window_is_30_seconds_with_one_second_overlap() -> None:
    buffer = PcmWindowBuffer()

    assert buffer.window_samples == 16_000 * 30
    assert buffer.overlap_samples == 16_000


def test_split_pcm_assigns_overlap_to_the_following_window_core() -> None:
    blocks = split_pcm(_samples(20), window_samples=8, overlap_samples=2)

    assert [
        (block.start_sample, block.core_start_sample, block.core_end_sample)
        for block in blocks
    ] == [(0, 0, 8), (6, 8, 14), (12, 14, 20)]
    assert [len(block.pcm) // 2 for block in blocks] == [8, 8, 8]
    assert blocks[1].pcm[:4] == blocks[0].pcm[-4:]
    assert blocks[2].pcm[:4] == blocks[1].pcm[-4:]


def test_long_clip_has_bounded_windows_and_contiguous_core() -> None:
    sample_rate = 16_000
    window_samples = sample_rate * 30
    overlap_samples = sample_rate
    pcm = _samples(sample_rate * 61)

    blocks = split_pcm(
        pcm,
        window_samples=window_samples,
        overlap_samples=overlap_samples,
    )

    assert max(len(block.pcm) for block in blocks) <= window_samples * 2
    assert blocks[-1].core_end_sample == sample_rate * 61
    assert b"".join(_core_bytes(block) for block in blocks) == pcm
    assert all(
        block.core_start_sample <= block.core_end_sample
        for block in blocks
    )


def test_buffer_matches_split_for_arbitrary_even_feed_boundaries() -> None:
    pcm = _samples(97)
    window_samples = 16
    overlap_samples = 4
    expected = split_pcm(
        pcm,
        window_samples=window_samples,
        overlap_samples=overlap_samples,
    )
    buffer = PcmWindowBuffer(
        window_samples=window_samples,
        overlap_samples=overlap_samples,
    )
    emitted = []
    cursor = 0
    for sample_count in (1, 3, 7, 2, 11, 5, 19, 4, 45):
        next_cursor = min(len(pcm), cursor + sample_count * 2)
        emitted.extend(buffer.feed(pcm[cursor:next_cursor]))
        cursor = next_cursor
        assert buffer.buffered_samples <= window_samples + overlap_samples
    emitted.extend(buffer.finish())

    assert tuple(emitted) == expected


def test_buffer_empty_feed_and_finish_are_idempotent() -> None:
    buffer = PcmWindowBuffer(window_samples=8, overlap_samples=2)

    assert buffer.feed(b"") == ()
    first_finish = buffer.finish()
    second_finish = buffer.finish()

    assert first_finish == ()
    assert second_finish == first_finish
    with pytest.raises(ValueError, match="window_buffer_finished"):
        buffer.feed(b"\x00\x00")


def test_exact_window_does_not_create_an_overlap_only_tail() -> None:
    buffer = PcmWindowBuffer(window_samples=8, overlap_samples=2)

    emitted = buffer.feed(_samples(8))

    assert len(emitted) == 1
    assert buffer.finish() == ()


def test_odd_pcm_and_invalid_window_boundaries_are_rejected() -> None:
    with pytest.raises(ValueError, match="pcm_bytes_odd"):
        split_pcm(b"\x00", window_samples=8, overlap_samples=2)

    buffer = PcmWindowBuffer(window_samples=8, overlap_samples=2)
    with pytest.raises(ValueError, match="pcm_bytes_odd"):
        buffer.feed(b"\x00")

    with pytest.raises(ValueError, match="invalid_window"):
        PcmWindowBuffer(window_samples=0, overlap_samples=0)
    with pytest.raises(ValueError, match="invalid_window"):
        PcmWindowBuffer(window_samples=8, overlap_samples=8)
    with pytest.raises(ValueError, match="invalid_window"):
        PcmWindowBuffer(window_samples=8, overlap_samples=-1)


def test_buffered_samples_is_read_only_diagnostic() -> None:
    buffer = PcmWindowBuffer(window_samples=8, overlap_samples=2)
    buffer.feed(_samples(3))

    assert buffer.buffered_samples == 3
    with pytest.raises(AttributeError):
        buffer.buffered_samples = 0  # type: ignore[misc]
