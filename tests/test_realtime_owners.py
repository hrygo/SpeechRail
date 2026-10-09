"""Independent Realtime owners use narrow fakes and bounded connection state."""

from __future__ import annotations

import asyncio


def test_protocol_snapshots_cannot_change_published_nested_configuration() -> None:
    import pytest

    from speechrail.application.realtime_state import RealtimeConfiguration

    source = {"turn_detection": {"mode": "server_vad"}, "keywords": ["rail"]}
    config = RealtimeConfiguration(source)
    source["keywords"].append("changed")
    snapshot = config.snapshot()
    with pytest.raises(TypeError):
        snapshot["model"] = "other"
    snapshot["turn_detection"]["mode"] = "manual"
    snapshot["keywords"].clear()
    assert config.snapshot() == {
        "turn_detection": {"mode": "server_vad"}, "keywords": ["rail"],
    }


def _tts_owner(send):
    from speechrail.application.realtime_tts import RealtimeTtsOwner
    from speechrail.config.selection import ActiveModelCatalog
    from speechrail.domain.tts import SYSTEM_VOICE_PROFILES
    from speechrail.domain.tts_execution import EMPTY_TTS_EXECUTION

    class Voices:
        def get_profile(self, voice):
            return SYSTEM_VOICE_PROFILES[voice]

    return RealtimeTtsOwner(
        task_id="task",
        send=send,
        config=lambda: {"tts_enabled": True},
        catalog=ActiveModelCatalog(None, None, None, None, None, False),
        voices=Voices(),
        streams=None,
        execution=EMPTY_TTS_EXECUTION,
        ready=lambda: False,
        synthesizer_available=False,
        timeout_seconds=1,
        initial_model="fake",
    )


def test_old_tts_context_release_cannot_wake_or_clear_new_utterance() -> None:
    from speechrail.application.realtime_tts import TtsUtterance

    async def scenario() -> None:
        async def send(event):
            raise AssertionError("release must not emit a terminal")

        old = TtsUtterance(request_id="old", response_id="old-response")
        new = TtsUtterance(request_id="new", response_id="new-response")
        owner = _tts_owner(send)
        owner._current = new
        owner._release_stream_state(old)
        assert old.ready.is_set()
        assert owner._current is new
        assert not new.ready.is_set()

    asyncio.run(scenario())


def test_tts_terminal_projection_uses_captured_utterance_accounting() -> None:
    from speechrail.application.realtime_tts import TtsUtterance

    async def scenario() -> None:
        events = []

        async def send(event):
            events.append(event)
            return 1

        old = TtsUtterance(request_id="old", response_id="old-response")
        old.generated_samples = 37
        new = TtsUtterance(request_id="new", response_id="new-response")
        new.generated_samples = 2
        owner = _tts_owner(send)
        owner._current = new
        await owner._finalize_tts(old, status="completed")
        await owner._finalize_tts(old, status="cancelled")
        assert len(events) == 1
        assert events[0]["request_id"] == "old"
        assert events[0]["generated_samples"] == 37
        assert old.terminal_sent
        assert not new.terminal_sent

    asyncio.run(scenario())


def test_admission_waiters_wake_when_tts_is_cancelled_before_controller_exists() -> None:
    import pytest

    from realtime_wire import tts_append_text, tts_cancel
    from speechrail.application.realtime_tts import TtsUtterance
    from speechrail.compatibility.openai_realtime import RealtimeAdapterError

    async def scenario() -> None:
        events = []

        async def send(event):
            events.append(event)
            return 1

        owner = _tts_owner(send)
        context = TtsUtterance(request_id="admitting", response_id="response")
        context.task = asyncio.create_task(asyncio.Event().wait())
        owner._current = context
        append = asyncio.create_task(
            owner.append(tts_append_text(request_id="admitting", sequence=1, text="Hello."))
        )
        await asyncio.sleep(0)
        assert not append.done()
        await owner.cancel(tts_cancel(request_id="admitting"))
        with pytest.raises(RealtimeAdapterError) as error:
            await asyncio.wait_for(append, timeout=0.1)
        assert error.value.code == "tts_not_active"
        assert context.ready.is_set()
        assert context.task.cancelled()
        assert owner._current is None
        assert [event["type"] for event in events] == ["speechrail.tts.cancelled"]

    asyncio.run(scenario())


def test_asr_and_auxiliary_owners_construct_without_tts_or_app_services() -> None:
    from speechrail.application.realtime_asr import RealtimeAsrOwner, RealtimeAsrPorts
    from speechrail.application.realtime_auxiliary import (
        RealtimeAuxiliaryOwner,
        RealtimeAuxiliaryPorts,
    )
    from speechrail.application.realtime_state import FrozenTranscript, RealtimeConfiguration
    from speechrail.config import Settings
    from speechrail.domain.resource_limits import GovernorLimits
    from speechrail.observability.metrics import Metrics
    from speechrail.runtime.alignment_admission import AlignmentAdmission
    from speechrail.runtime.diarization_admission import DiarizationAdmission
    from speechrail.runtime.resource_governor import ResourceGovernor

    async def scenario() -> None:
        events = []

        async def send(event):
            events.append(event)
            return len(events)

        settings = Settings(qwen3_model_dir=None, qwen3_python=None)
        config = RealtimeConfiguration({})
        governor = ResourceGovernor(GovernorLimits(2, 1, 8))
        metrics = Metrics()
        asr = RealtimeAsrOwner(
            ports=RealtimeAsrPorts(None, governor, metrics),
            settings=settings,
            task_id="task",
            session_id="session",
            send=send,
            config=config.snapshot,
        )
        auxiliary = RealtimeAuxiliaryOwner(
            ports=RealtimeAuxiliaryPorts(
                None, None, AlignmentAdmission(), DiarizationAdmission(), metrics,
                lambda: False, lambda: "not enabled",
            ),
            settings=settings,
            task_id="task",
            session_id="session",
            send=send,
            config=config.snapshot,
            input_source=asr,
        )
        asr.bind_auxiliary(auxiliary)
        identity = asr.identity
        await asr.commit(commit_event_id="empty")
        assert events[-1]["transcript"] == ""
        assert events[-1]["commit_event_id"] == "empty"
        await asr.begin_close()
        auxiliary.start_alignment(FrozenTranscript(
            "task", identity.epoch, identity.generation, identity.item_id,
            "frozen text", 1, 0, 24, 0, 16, bytes(32), False, None,
        ))
        await auxiliary._wait_for_pending_alignment()
        assert events[-1]["error"]["code"] == "alignment_stale"
        assert asr.identity.generation != identity.generation
        await asr.close()
        await auxiliary.close()
        assert governor.snapshot().active_asr == 0
        assert auxiliary._alignment_tasks == set()

    asyncio.run(scenario())


def test_root_close_joins_all_owners_after_failure_and_repeated_cancellation() -> None:
    import pytest

    from speechrail.application.realtime_openai import OpenAIRealtimeSession

    async def scenario() -> None:
        calls = []
        entered = asyncio.Event()
        release = asyncio.Event()

        class Asr:
            async def begin_close(self):
                calls.append("asr begin")

            async def close(self):
                calls.append("asr close")

        class Auxiliary:
            async def cancel_alignment_tasks(self):
                calls.append("alignment cancel")

            async def close(self):
                calls.append("auxiliary close")

        class Tts:
            async def close(self):
                calls.append("tts close")
                entered.set()
                await release.wait()
                raise RuntimeError("reclamation failed")

        session = object.__new__(OpenAIRealtimeSession)
        session._asr_owner = Asr()
        session._tts_owner = Tts()
        session._auxiliary_owner = Auxiliary()
        session._close_task = None
        close = asyncio.create_task(session.close())
        await entered.wait()
        close.cancel()
        await asyncio.sleep(0)
        close.cancel()
        await asyncio.sleep(0)
        assert not close.done()
        release.set()
        with pytest.raises(ExceptionGroup, match="cleanup failed"):
            await close
        assert calls == [
            "asr begin", "alignment cancel", "tts close", "asr close", "auxiliary close",
        ]
        with pytest.raises(ExceptionGroup, match="cleanup failed"):
            await session.close()
        assert len(calls) == 5

    asyncio.run(scenario())


def test_tts_close_joins_retired_wire_tasks_without_a_current_utterance() -> None:
    async def scenario() -> None:
        entered = asyncio.Event()
        released = asyncio.Event()

        async def send(event):
            return 1

        owner = _tts_owner(send)

        async def retired_task():
            entered.set()
            try:
                await asyncio.Event().wait()
            finally:
                released.set()

        old_task = asyncio.create_task(retired_task())
        owner._tasks.add(old_task)
        old_task.add_done_callback(owner._task_done)
        await entered.wait()
        assert owner._current is None
        await owner.close()
        assert released.is_set()
        assert old_task.cancelled()
        assert owner._tasks == set()

    asyncio.run(scenario())


def test_root_rejects_new_events_during_and_after_close() -> None:
    import pytest

    from speechrail.application.realtime_openai import OpenAIRealtimeSession
    from speechrail.compatibility.openai_realtime import RealtimeAdapterError

    async def scenario() -> None:
        entered = asyncio.Event()
        release = asyncio.Event()
        session = object.__new__(OpenAIRealtimeSession)
        session._close_task = None

        async def close_owned():
            entered.set()
            await release.wait()

        session._close_owned = close_owned
        close = asyncio.create_task(session.close())
        await entered.wait()
        event = {"type": "session.update", "session": {"tts_enabled": True}}
        for completed in (False, True):
            if completed:
                release.set()
                await close
            with pytest.raises(RealtimeAdapterError) as error:
                await session.handle(event)
            assert error.value.code == "invalid_state"

    asyncio.run(scenario())


def test_unconfirmed_tts_cleanup_retains_context_and_visible_failure() -> None:
    import pytest

    from speechrail.application.realtime_tts import TtsUtterance
    from speechrail.compatibility.openai_realtime import RealtimeAdapterError

    async def scenario() -> None:
        async def send(event):
            raise AssertionError("failed cleanup must not invent a wire terminal")

        class Controller:
            closed = False

            async def aclose(self, *, reason):
                raise RuntimeError("reclamation failed")

        owner = _tts_owner(send)
        context = TtsUtterance(request_id="failed", response_id="response")
        context.controller = Controller()
        owner._current = context
        with pytest.raises(ExceptionGroup, match="cleanup failed"):
            await owner.close()
        assert owner._current is context
        assert owner.busy
        with pytest.raises(RealtimeAdapterError) as error:
            owner._claim_request("new")
        assert error.value.code == "tts_in_progress"
        assert not context.terminal_sent

    asyncio.run(scenario())
