"""Rendering use cases tested directly through speech ports and temporary stores."""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from pathlib import Path

import pytest

from speechrail.domain.ports import AudioChunk, SpeechRequest
from speechrail.domain.tts import SYSTEM_VOICE_PROFILES


def test_preparation_preserves_unobserved_recipe_facts_and_pins_revision() -> None:
    from speechrail.application.render_preparation import prepare_render

    profile = SYSTEM_VOICE_PROFILES["serena"]
    result = prepare_render(
        SpeechRequest(text="Hello.", voice=profile.id),
        profile=profile,
        artifact=None,
        output_format="wav",
        sample_rate=24_000,
        integrity=True,
    )
    assert result.request.text == "Hello."
    assert result.request.expected_voice_revision == profile.revision
    assert result.recipe is not None
    assert result.recipe.engine_revision is None
    assert result.recipe.seed_policy is None
    assert result.recipe.model_artifact is None
    assert result.timing is None


def test_preparation_marks_changed_display_coordinates_unavailable() -> None:
    from speechrail.application.render_preparation import prepare_render

    profile = SYSTEM_VOICE_PROFILES["serena"]
    result = prepare_render(
        SpeechRequest(text=" A   B ", voice=profile.id, timing_mode="chunk"),
        profile=profile,
        artifact=None,
        output_format="pcm",
        sample_rate=24_000,
    )
    assert result.timing is not None
    assert result.timing.display_mapping_status == "unavailable"
    assert result.timing.display_mapping_reason == "normalization_changed_display_coordinates"
    assert result.timing.display_spans == ()
    assert result.recipe is None


class RenderFake:
    def __init__(self, *, close_fails: bool = False) -> None:
        self.closed = False
        self.close_fails = close_fails
        self.requests: list[SpeechRequest] = []

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        self.requests.append(request)

        async def chunks() -> AsyncIterator[AudioChunk]:
            try:
                yield AudioChunk(response_id="test", chunk_index=0, audio=b"\x01\x00" * 2)
            finally:
                self.closed = True
                if self.close_fails:
                    raise RuntimeError("cleanup failed")

        return chunks()


def _operation(tmp_path: Path, fake: RenderFake):
    from speechrail.application.render_operation import RenderOperation
    from speechrail.application.render_receipts import RenderReceiptRegistry
    from speechrail.application.tts_timings import TtsTimingRegistry
    from speechrail.domain.resource_limits import GovernorLimits
    from speechrail.domain.tts_execution import EMPTY_TTS_EXECUTION
    from speechrail.infrastructure.voice_registry import FileVoiceRegistry
    from speechrail.observability.metrics import Metrics
    from speechrail.runtime.resource_governor import ResourceGovernor, WorkClass, WorkPurpose

    receipts = RenderReceiptRegistry()
    receipt_id = receipts.begin(
        request_id="test",
        voice_id="serena",
        voice_revision=None,
        model_artifact=None,
        model_source=None,
        model_variant=None,
        model_catalog_revision=None,
        model_runtime_revision=None,
        output_format="pcm",
        sample_rate=24_000,
    )
    timings = TtsTimingRegistry()
    timing_id = timings.begin(
        request_id="test",
        sample_rate=24_000,
        display_mapping_status="identity",
        expected_text_spans=((0, 6),),
        display_spans=((0, 6),),
    )
    return RenderOperation(
        request=SpeechRequest(text="Hello.", voice="serena"),
        synthesizer=fake,
        execution=EMPTY_TTS_EXECUTION,
        voices=FileVoiceRegistry.open(tmp_path / "voices.json", tmp_path / "audio"),
        governor=ResourceGovernor(GovernorLimits(2, 1, 8)),
        artifact=None,
        capability_key=None,
        expires_at=asyncio.get_running_loop().time() + 10,
        work_class=WorkClass.BATCH_TTS,
        work_purpose=WorkPurpose.DEFAULT,
        receipts=receipts,
        timings=timings,
        receipt_id=receipt_id,
        timing_id=timing_id,
        metrics=Metrics(),
        voice_class="system",
        raw_character_count=6,
        sample_rate=24_000,
    )


def test_operation_owns_prefetched_pcm_before_body_starts(tmp_path: Path) -> None:
    from speechrail.application.tts_delivery import PcmOutputCounter

    async def scenario() -> None:
        fake = RenderFake()
        operation = _operation(tmp_path, fake)
        counter = PcmOutputCounter(100)
        source = operation.pcm(counter=counter)
        first = await anext(source)
        assert operation.governor.snapshot().active_tts == 1
        operation.deliver(source, first, counter=counter)
        await operation.close_delivery()
        assert fake.closed
        assert operation.governor.snapshot().active_tts == 0
        assert operation.receipts.get(operation.receipt_id)["status"] == "cancelled"
        assert operation.timings.get(operation.timing_id)["status"] == "cancelled"
        await operation.close_delivery()
        assert operation.timings.get(operation.timing_id)["status"] == "cancelled"

    asyncio.run(scenario())


def test_operation_completes_receipt_only_after_validated_pcm_delivery(tmp_path: Path) -> None:
    from speechrail.application.tts_delivery import PcmOutputCounter

    async def scenario() -> None:
        fake = RenderFake()
        operation = _operation(tmp_path, fake)
        counter = PcmOutputCounter(100)
        source = operation.pcm(counter=counter)
        body = operation.deliver(source, await anext(source), counter=counter)
        assert b"".join([chunk async for chunk in body]) == b"\x01\x00" * 2
        await operation.close_delivery()
        assert fake.closed
        assert operation.receipts.get(operation.receipt_id)["status"] == "completed"
        assert operation.receipts.get(operation.receipt_id)["audio"]["sample_count"] == 2
        assert operation.governor.snapshot().active_tts == 0

    asyncio.run(scenario())


def test_operation_failed_cleanup_keeps_receipt_pending_and_lane_isolated(tmp_path: Path) -> None:
    from speechrail.application.tts_delivery import PcmOutputCounter

    async def scenario() -> None:
        fake = RenderFake(close_fails=True)
        operation = _operation(tmp_path, fake)
        counter = PcmOutputCounter(100)
        source = operation.pcm(counter=counter)
        operation.deliver(source, await anext(source), counter=counter)
        with pytest.raises(RuntimeError, match="cleanup failed"):
            await operation.close_delivery()
        assert operation.governor.tts_lane_isolated()
        assert operation.receipts.get(operation.receipt_id)["status"] == "pending"
        assert operation.timings.get(operation.timing_id)["status"] == "pending"

    asyncio.run(scenario())


def test_operation_has_one_execution_owner(tmp_path: Path) -> None:
    async def scenario() -> None:
        fake = RenderFake()
        operation = _operation(tmp_path, fake)
        source = operation.pcm()
        await anext(source)
        with pytest.raises(RuntimeError, match="already has an owner"):
            await anext(operation.pcm())
        await source.aclose()
        assert len(fake.requests) == 1

    asyncio.run(scenario())


def test_expired_operation_never_starts_backend(tmp_path: Path) -> None:
    async def scenario() -> None:
        fake = RenderFake()
        operation = _operation(tmp_path, fake)
        operation.expires_at = asyncio.get_running_loop().time() - 1
        with pytest.raises(TimeoutError):
            await anext(operation.pcm())
        assert fake.requests == []
        receipt = operation.receipts.get(operation.receipt_id)
        assert receipt["status"] == "error"
        assert receipt["error_code"] == "backend_timeout"
        assert operation.timings.get(operation.timing_id)["status"] == "error"
        assert operation.timings.get(operation.timing_id)["reason"] == "backend_timeout"
        assert operation.governor.snapshot().active_tts == 0

    asyncio.run(scenario())


def test_strict_preparation_uses_the_operation_deadline(tmp_path: Path) -> None:
    from speechrail.domain.tts_execution import TtsExecutionPorts

    class BlockingPreparer:
        cancelled = False

        async def prepare_voice(self, voice: str, *, expected_voice_revision=None):
            try:
                await asyncio.Event().wait()
            finally:
                self.cancelled = True

    async def scenario() -> None:
        fake = RenderFake()
        operation = _operation(tmp_path, fake)
        operation.voices.create_cloned_profile(
            name="Clone",
            voice_id="clone",
            ref_text="test reference",
            audio_bytes=b"fake audio",
            duration_seconds=1.0,
        )
        preparer = BlockingPreparer()
        operation.execution = TtsExecutionPorts(preparer=preparer)
        operation.request = SpeechRequest(
            text="Hello.",
            voice="clone",
            validation_policy="require_output_pass",
        )
        operation.expires_at = asyncio.get_running_loop().time() + 0.01
        task = asyncio.create_task(anext(operation.pcm()))
        try:
            done, _ = await asyncio.wait({task}, timeout=0.2)
            assert task in done, "strict preparation must not escape the render deadline"
            with pytest.raises(TimeoutError):
                await task
        finally:
            if not task.done():
                task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        assert preparer.cancelled
        assert fake.requests == []
        assert operation.receipts.get(operation.receipt_id)["error_code"] == "backend_timeout"
        assert operation.governor.snapshot().active_tts == 0

    asyncio.run(scenario())
