"""R1 regressions: continuous diarization stream state is bounded and isolated.

The harness below wraps the real ``DiarizationCoordinator`` with an injected
fake native streaming step; the coordinator behaviour under test is real, only
the native Sortformer step is scripted.
"""

from __future__ import annotations

import asyncio
from collections.abc import Callable, Sequence
from typing import Protocol

import pytest

from speechrail.application.diarization import DiarizationCoordinator
from speechrail.backends.nemo_sortformer import NemoSortformerStreamSession
from speechrail.domain.diarization import DiarizationError


class _FakeNative(Protocol):
    """Shape the adapter expects from a verified native streaming step."""

    frame_samples: int

    def step(self, frame: Sequence[float]) -> tuple[int, float]: ...

    def finish(self) -> None: ...

    def close(self) -> None: ...


class _ScriptedNative:
    """One 80 ms frame per step; the script decides the frame's speaker."""

    frame_samples = 1280

    def __init__(
        self,
        script: Callable[[int], tuple[int, float]],
        *,
        registry: list[_ScriptedNative] | None = None,
    ) -> None:
        self._script = script
        self.frame_index = 0
        self.closed = False
        # Opaque state identity: a correct adapter never replaces the native
        # mid-session, so this object outlives every commit.
        self.state_identity = object()
        if registry is not None:
            registry.append(self)

    def step(self, frame: Sequence[float]) -> tuple[int, float]:
        del frame
        result = self._script(self.frame_index)
        self.frame_index += 1
        return result

    def finish(self) -> None:
        return None

    def close(self) -> None:
        self.closed = True


def _one_speaker_script(frame_index: int) -> tuple[int, float]:
    del frame_index
    return (0, 0.9)


def _alternating_script(frame_index: int) -> tuple[int, float]:
    """Two frames per speaker so continuous speech creates many activities."""
    return (frame_index // 2, 0.9)


def _silence_script(frame_index: int) -> tuple[int, float]:
    """No speaker active in any frame (label -1)."""
    del frame_index
    return (-1, 0.0)


class _StreamHarness:
    """Real coordinator + injected fake native streaming step."""

    def __init__(self, *, script: Callable[[int], tuple[int, float]] | None = None) -> None:
        self.native: _ScriptedNative | None = None
        self.natives: list[_ScriptedNative] = []
        self._ranges: list[tuple[int, int]] = []

        def factory() -> _FakeNative:
            native = _ScriptedNative(script or _one_speaker_script, registry=self.natives)
            self.native = native
            return native

        self.session = NemoSortformerStreamSession(factory())
        self.coordinator = DiarizationCoordinator(continuous=self.session)

    @property
    def state_identity(self) -> object:
        assert self.native is not None
        return self.native.state_identity

    async def append_and_commit(self, sample_count: int) -> None:
        start = self.session.next_start_sample
        await self.coordinator.append_audio(b"\x00\x00" * sample_count)
        await self.coordinator.activities()
        self._ranges.append((start, self.session.next_start_sample))

    @property
    def accepted_ranges(self) -> list[tuple[int, int]]:
        return list(self._ranges)


def test_commit_does_not_reset_diarization() -> None:
    async def scenario() -> None:
        harness = _StreamHarness()
        before = harness.state_identity
        await harness.append_and_commit(16000)
        await harness.append_and_commit(16000)
        assert harness.state_identity == before
        assert harness.accepted_ranges == [(0, 16000), (16000, 32000)]
        assert harness.native is not None
        assert harness.native.closed is False

    asyncio.run(scenario())


def test_two_websocket_sessions_do_not_share_state() -> None:
    async def scenario() -> None:
        first = _StreamHarness()
        second = _StreamHarness()

        await first.append_and_commit(16000)
        await second.append_and_commit(16000)

        assert len(first.natives) == 1
        assert len(second.natives) == 1
        assert first.natives[0] is not second.natives[0]
        assert first.natives[0].state_identity != second.natives[0].state_identity
        assert first.accepted_ranges == [(0, 16000)]
        assert second.accepted_ranges == [(0, 16000)]

    asyncio.run(scenario())


def test_partial_first_frame_is_not_processed_until_full() -> None:
    async def scenario() -> None:
        harness = _StreamHarness()
        await harness.coordinator.append_audio(b"\x00\x00" * 1000)

        snapshot = await harness.coordinator.activities()

        assert snapshot is not None
        assert snapshot.processed_through_sample == 0
        assert snapshot.activities == ()

    asyncio.run(scenario())


def test_finish_flushes_trailing_half_frame() -> None:
    async def scenario() -> None:
        harness = _StreamHarness()
        await harness.coordinator.append_audio(b"\x00\x00" * (16000 + 600))

        snapshot = await harness.coordinator.finish_stream()

        assert snapshot is not None
        assert snapshot.processed_through_sample == 16600
        assert snapshot.stable_through_sample == 16600
        assert len(snapshot.activities) == 1
        assert snapshot.activities[0].start_sample == 0
        assert snapshot.activities[0].end_sample == 16600
        assert snapshot.activities[0].speaker == "spk_01"

    asyncio.run(scenario())


def test_activities_merge_consecutive_same_speaker_frames() -> None:
    async def scenario() -> None:
        harness = _StreamHarness()
        await harness.coordinator.append_audio(b"\x00\x00" * (1280 * 3))

        snapshot = await harness.coordinator.activities()

        assert snapshot is not None
        assert len(snapshot.activities) == 1
        assert snapshot.activities[0].end_sample == 1280 * 3

    asyncio.run(scenario())


def test_long_silence_keeps_state_bounded() -> None:
    """Two hours of silence: frames advance, no activity objects accumulate."""

    async def scenario() -> None:
        harness = _StreamHarness(script=_silence_script)
        chunk = b"\x00\x00" * 16000
        for _ in range(7200):
            await harness.coordinator.append_audio(chunk)

        snapshot = await harness.coordinator.activities()

        assert snapshot is not None
        assert snapshot.processed_through_sample == 7200 * 16000
        assert snapshot.activities == ()
        assert harness.session.retained_activity_count() == 0

    asyncio.run(scenario())


def test_activity_ring_is_bounded_under_two_hours_of_speech() -> None:
    """Two hours of alternating speech keeps the merged activity ring capped."""

    async def scenario() -> None:
        harness = _StreamHarness(script=_alternating_script)
        chunk = b"\x00\x00" * 16000
        for _ in range(7200):
            await harness.coordinator.append_audio(chunk)

        assert harness.session.retained_activity_count() <= harness.session.max_ring_activities
        snapshot = await harness.coordinator.activities()
        assert snapshot is not None
        assert snapshot.processed_through_sample == 7200 * 16000

    asyncio.run(scenario())


def test_close_releases_state_and_rejects_later_append() -> None:
    async def scenario() -> None:
        harness = _StreamHarness()
        await harness.coordinator.append_audio(b"\x00\x00" * 16000)
        await harness.coordinator.close()
        assert harness.native is not None
        assert harness.native.closed is True

        with pytest.raises(DiarizationError):
            await harness.coordinator.append_audio(b"\x00\x00" * 1600)

    asyncio.run(scenario())


def test_sample_clock_rejects_gap_and_overlap() -> None:
    async def scenario() -> None:
        harness = _StreamHarness()
        await harness.coordinator.append_audio(b"\x00\x00" * 1600)
        # Coordinator-owned timeline: an adapter that dropped or double-counted
        # samples would break the next append's continuity check.
        assert harness.session.next_start_sample == 1600
        with pytest.raises(DiarizationError):
            await harness.session.append(b"\x00\x00" * 1600, start_sample=800)
        with pytest.raises(DiarizationError):
            await harness.session.append(b"\x00\x00" * 1600, start_sample=3200)

    asyncio.run(scenario())


def test_coordinator_requires_exactly_one_session() -> None:
    with pytest.raises(ValueError):
        DiarizationCoordinator()

    session = NemoSortformerStreamSession(_ScriptedNative(_one_speaker_script))
    with pytest.raises(ValueError):
        DiarizationCoordinator(_FakeLegacySession(), continuous=session)  # type: ignore[arg-type]


class _FakeLegacySession:
    async def append_audio(self, audio: bytes) -> None:
        del audio

    async def annotate(self, segments):
        del segments

    async def finalize(self):
        raise AssertionError("legacy finalize not used here")

    async def close(self) -> None:
        return None
