"""Regression coverage for item-scoped streaming diarization delivery."""

from __future__ import annotations

import asyncio

import pytest

from speechrail.application.realtime_auxiliary import (
    RealtimeAuxiliaryOwner,
    RealtimeAuxiliaryPorts,
)
from speechrail.application.realtime_state import (
    AsrIdentity,
    FrozenTranscript,
    RealtimeConfiguration,
)
from speechrail.compatibility.openai_realtime import RealtimeAdapterError
from speechrail.config import Settings
from speechrail.domain.alignment import AlignmentRequest, AlignmentResult, AlignmentUnit
from speechrail.domain.audio_timeline import SampleSpan
from speechrail.domain.diarization.timeline import AttributionUnit
from speechrail.domain.diarization.types import ActivityFrame, ActivityUpdate, Attribution
from speechrail.observability.metrics import Metrics
from speechrail.runtime.alignment_admission import AlignmentAdmission
from speechrail.runtime.diarization_admission import DiarizationAdmission
from speechrail.runtime.resource_governor import GovernorLaneIsolatedError, GovernorQueueFullError


class _Input:
    def __init__(self) -> None:
        self.identity = AsrIdentity(
            generation=1,
            epoch=7,
            item_id="item-1",
            transcript_revision=2,
        )

    async def wait_finals(self) -> None:
        return


class _ActivitySession:
    def __init__(self, epoch: str) -> None:
        self.epoch = epoch
        self.accepted_samples = 0
        self.step_id = 0
        self.queue: asyncio.Queue[ActivityUpdate | None] = asyncio.Queue()
        self.finish_called = asyncio.Event()

    async def append(self, *, start_sample: int, pcm16: bytes) -> None:
        end = start_sample + len(pcm16) // 2
        self.accepted_samples = end
        await self.queue.put(
            ActivityUpdate(
                epoch=self.epoch,
                step_id=self.step_id,
                replace_span=SampleSpan(start_sample, end),
                frames=(
                    ActivityFrame(
                        span=SampleSpan(start_sample, end),
                        scores=(0.95, 0.0, 0.0, 0.0),
                        active_slots=frozenset({0}),
                    ),
                ),
                processed_through=end,
                stable_through=end,
            )
        )
        self.step_id += 1

    async def updates(self):
        while True:
            update = await self.queue.get()
            if update is None:
                return
            yield update

    async def finish(self, *, through_sample: int) -> None:
        assert through_sample == self.accepted_samples
        self.finish_called.set()
        await self.queue.put(None)

    async def cancel(self) -> None:
        await self.queue.put(None)


class _Engine:
    def __init__(self) -> None:
        self.sessions: list[_ActivitySession] = []

    def open(self, *, epoch: str) -> _ActivitySession:
        session = _ActivitySession(epoch)
        self.sessions.append(session)
        return session


class _LateFirstAligner:
    def __init__(self) -> None:
        self.first_entered = asyncio.Event()
        self.release_first = asyncio.Event()

    async def align(self, request: AlignmentRequest) -> AlignmentResult:
        if request.utterance_id == "item-1":
            self.first_entered.set()
            await self.release_first.wait()
        return AlignmentResult(
            task_id=request.task_id,
            epoch=request.epoch,
            utterance_id=request.utterance_id,
            transcript_revision=request.transcript_revision,
            units=(
                AlignmentUnit(
                    unit_id=request.utterance_id,
                    text_start=0,
                    text_end=len(request.text),
                    audio_span=request.span,
                    granularity="segment",
                ),
            ),
        )


class _Harness:
    def __init__(self, aligner: _LateFirstAligner) -> None:
        self.input = _Input()
        self.engine = _Engine()
        self.aligner = aligner
        self.events: list[dict[str, object]] = []
        self.hold_updates = True
        self.update_entered = asyncio.Event()
        self.release_updates = asyncio.Event()
        self.owner = RealtimeAuxiliaryOwner(
            ports=RealtimeAuxiliaryPorts(
                aligner=aligner,
                engine=self.engine,
                alignment_admission=AlignmentAdmission(),
                diarization_admission=DiarizationAdmission(),
                metrics=Metrics(),
                ready=lambda: True,
                status_message=lambda: "ready",
            ),
            settings=Settings(qwen3_model_dir=None, qwen3_python=None),
            session_id="session",
            task_id="task",
            send=self.send,
            config=RealtimeConfiguration({}).snapshot,
            input_source=self.input,
        )

    async def send(self, event: dict[str, object]) -> int:
        if self.hold_updates and event.get("type") == "speechrail.diarization.updated":
            self.update_entered.set()
            await self.release_updates.wait()
        self.events.append(dict(event))
        return len(self.events)


@pytest.mark.parametrize(
    "error,code", [(GovernorQueueFullError, "backend_busy"),
                   (GovernorLaneIsolatedError, "backend_reclamation_failed")],
)
def test_model_owner_rejection_releases_realtime_presence_and_uses_stable_error(error, code):
    async def scenario():
        harness = _Harness(_LateFirstAligner())

        def reject(*, epoch):
            raise error("private worker detail")

        harness.engine.open = reject
        with pytest.raises(RealtimeAdapterError) as failure:
            await harness.owner.configure(alignment=False, diarization=True)
        assert failure.value.code == code
        assert "private" not in str(failure.value)
        assert harness.owner._ports.diarization_admission.active == 0
        await harness.owner.close()

    asyncio.run(scenario())


def test_failed_close_retains_owner_and_admission_until_runtime_recovery():
    async def scenario():
        harness = _Harness(_LateFirstAligner())
        await harness.owner.configure(alignment=False, diarization=True)

        async def failed_cancel():
            raise RuntimeError("injected child reap failure")

        harness.engine.sessions[0].cancel = failed_cancel
        await harness.owner.close()
        admission = harness.owner._ports.diarization_admission
        assert admission.active == 1 and admission.quarantined

    asyncio.run(scenario())


def _frozen(
    *,
    epoch: int,
    generation: int,
    item_id: str,
    revision: int,
    wire_start: int,
    kernel_start: int,
    text: str,
) -> FrozenTranscript:
    kernel_end = kernel_start + 800
    return FrozenTranscript(
        task_id="task",
        epoch=epoch,
        generation=generation,
        item_id=item_id,
        transcript=text,
        transcript_revision=revision,
        item_start_wire=wire_start,
        item_end_wire=wire_start + 1_200,
        item_start_kernel=kernel_start,
        item_end_kernel=kernel_end,
        pcm16=b"\x00\x00" * 800,
        overflow=False,
        degraded_reason=None,
    )


def _events_of_type(events: list[dict[str, object]], event_type: str) -> list[dict[str, object]]:
    return [event for event in events if event.get("type") == event_type]


def test_late_attributions_keep_frozen_identity_and_finish_waits_for_updates() -> None:
    async def scenario() -> None:
        aligner = _LateFirstAligner()
        harness = _Harness(aligner)
        owner = harness.owner
        await owner.configure(alignment=True, diarization=True)

        await owner.append(b"\x00\x00" * 800)
        owner.start_alignment(
            _frozen(
                epoch=7,
                generation=1,
                item_id="item-1",
                revision=2,
                wire_start=0,
                kernel_start=0,
                text="first",
            )
        )
        await aligner.first_entered.wait()

        # A new ASR owner starts at revision zero after item-1 has frozen.
        harness.input.identity = AsrIdentity(
            generation=1,
            epoch=7,
            item_id="item-2",
            transcript_revision=0,
        )
        await owner.append(b"\x00\x00" * 800)
        owner.start_alignment(
            _frozen(
                epoch=7,
                generation=1,
                item_id="item-2",
                revision=1,
                wire_start=1_200,
                kernel_start=800,
                text="second",
            )
        )
        await asyncio.sleep(0)
        aligner.release_first.set()
        await owner._wait_for_pending_alignment()

        # Hold the active event consumer while finish queues the final update.
        await harness.update_entered.wait()
        finish_task = asyncio.create_task(owner.finish({"event_id": "finish-1"}))
        await harness.engine.sessions[0].finish_called.wait()
        await asyncio.sleep(0)
        assert not finish_task.done(), "done must wait until queued attribution events are consumed"

        harness.release_updates.set()
        await finish_task

        updates = _events_of_type(harness.events, "speechrail.diarization.updated")
        done = _events_of_type(harness.events, "speechrail.diarization.done")
        assert len(done) == 1
        done_index = harness.events.index(done[0])
        assert all(harness.events.index(update) < done_index for update in updates)

        units_by_item = {
            "item-1": (2, {"start": 0, "end": 1_200}),
            "item-2": (1, {"start": 1_200, "end": 2_400}),
        }
        assert {str(event["utterance_id"]) for event in updates} == set(units_by_item)
        for event in updates:
            expected_revision, expected_span = units_by_item[str(event["utterance_id"])]
            assert event["transcript_revision"] == expected_revision
            assert len(event["units"]) == 1
            assert event["units"][0]["sample_span"] == expected_span  # type: ignore[index]

        terminal = done[0]
        assert terminal["utterance_id"] == "item-2"
        assert terminal["transcript_revision"] == 1
        assert len(terminal["units"]) == 1  # type: ignore[arg-type]
        assert terminal["units"][0]["sample_span"] == {"start": 1_200, "end": 2_400}  # type: ignore[index]

        update_count = len(updates)
        await owner.finish({"event_id": "finish-1"})
        assert (
            len(_events_of_type(harness.events, "speechrail.diarization.updated"))
            == update_count
        )
        replayed_done = _events_of_type(harness.events, "speechrail.diarization.done")[-1]
        assert replayed_done == terminal

        await owner.reset()
        assert owner.phase == "active"
        assert owner._finalization_id is None
        assert owner._finalized_payload is None
        assert owner._diarization_units_payload() == []

        harness.input.identity = AsrIdentity(
            generation=2,
            epoch=8,
            item_id="item-3",
            transcript_revision=0,
        )
        await owner.configure(alignment=True, diarization=True)
        await owner.append(b"\x00\x00" * 800)
        owner.start_alignment(
            _frozen(
                epoch=8,
                generation=2,
                item_id="item-3",
                revision=1,
                wire_start=0,
                kernel_start=0,
                text="new",
            )
        )
        await owner._wait_for_pending_alignment()
        await owner.finish({"event_id": "finish-2"})

        new_done = _events_of_type(harness.events, "speechrail.diarization.done")[-1]
        assert new_done["utterance_id"] == "item-3"
        assert new_done["transcript_revision"] == 1
        assert len(new_done["units"]) == 1  # type: ignore[arg-type]
        assert new_done["units"][0]["sample_span"] == {"start": 0, "end": 1_200}  # type: ignore[index]

        await owner.close()

    asyncio.run(scenario())


def test_internal_pause_keeps_public_word_speaker_and_frozen_text_offsets() -> None:
    class PauseSession(_ActivitySession):
        async def append(self, *, start_sample: int, pcm16: bytes) -> None:
            assert start_sample == 0 and len(pcm16) == 1600
            self.accepted_samples = 800
            await self.queue.put(ActivityUpdate(
                epoch=self.epoch, step_id=0, replace_span=SampleSpan(0, 800),
                frames=(
                    ActivityFrame(SampleSpan(0, 200), (0.9,), frozenset({0})),
                    ActivityFrame(SampleSpan(200, 600), (0.05,), frozenset()),
                    ActivityFrame(SampleSpan(600, 800), (0.9,), frozenset({0})),
                ),
                processed_through=800, stable_through=800,
            ))

    async def scenario() -> None:
        aligner = _LateFirstAligner()
        aligner.release_first.set()
        harness = _Harness(aligner)
        harness.hold_updates = False

        def open_session(*, epoch: str) -> PauseSession:
            session = PauseSession(epoch)
            harness.engine.sessions.append(session)
            return session

        harness.engine.open = open_session
        await harness.owner.configure(alignment=True, diarization=True)
        await harness.owner.append(b"\x00\x00" * 800)
        frozen = _frozen(epoch=7, generation=1, item_id="item-1", revision=2,
                         wire_start=0, kernel_start=0, text="word")
        harness.owner.start_alignment(frozen)
        await harness.owner._wait_for_pending_alignment()
        await harness.owner.finish({"event_id": "pause-finish"})

        (done,) = _events_of_type(harness.events, "speechrail.diarization.done")
        (unit,) = done["units"]
        assert unit["speaker"] == "A"
        assert unit["sample_span"] == {"start": 0, "end": 1200}
        assert done["utterance_id"] == "item-1" and done["transcript_revision"] == 2
        (alignment,) = _events_of_type(harness.events, "speechrail.alignment.done")
        (aligned_word,) = alignment["units"]
        assert aligned_word["text_start"] == 0 and aligned_word["text_end"] == 4
        await harness.owner.close()
        assert harness.owner._ports.diarization_admission.active == 0

    asyncio.run(scenario())


def test_empty_diarization_finish_is_valid() -> None:
    async def scenario() -> None:
        harness = _Harness(_LateFirstAligner())
        await harness.owner.configure(alignment=False, diarization=True)
        await harness.owner.finish({"event_id": "empty-finish"})

        done = _events_of_type(harness.events, "speechrail.diarization.done")
        assert len(done) == 1
        assert done[0]["units"] == []
        await harness.owner.close()

    asyncio.run(scenario())


def test_public_units_fill_a_same_item_bracketed_unknown() -> None:
    owner = _Harness(_LateFirstAligner()).owner
    units = tuple(
        AttributionUnit(
            segment_uid=f"seg-{index}",
            text_start=index,
            text_end=index + 1,
            start_sample=index * 100,
            end_sample=(index + 1) * 100,
            timing_quality="aligned",
        )
        for index in range(3)
    )
    owner._units_by_id = {unit.segment_uid: unit for unit in units}
    owner._wire_span_by_unit = {
        unit.segment_uid: SampleSpan(
            unit.start_sample * 3 // 2, unit.end_sample * 3 // 2
        )
        for unit in units
    }
    owner._attribution_by_unit = {
        "seg-0": Attribution("seg-0", "A", ("A",), "final", None, 1),
        "seg-1": Attribution(
            "seg-1", None, (), "final", "insufficient_evidence", 1
        ),
        "seg-2": Attribution("seg-2", "A", ("A",), "final", None, 1),
    }
    assert [unit["speaker"] for unit in owner._diarization_units_payload()] == [
        "A",
        "A",
        "A",
    ]

    owner._attribution_by_unit["seg-1"] = Attribution(
        "seg-1", None, (), "final", "activity_gap", 1
    )
    assert [unit["speaker"] for unit in owner._diarization_units_payload()] == [
        "A",
        None,
        "A",
    ]
