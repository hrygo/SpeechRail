from __future__ import annotations

from collections import Counter

import pytest
from pydantic import ValidationError

from speechrail.application.tts_timings import TtsTimingRegistry
from speechrail.backends.qwen3_tts_worker import MlxQwenTtsEngine
from speechrail.domain.tts_timing import TtsTimingChunk, TtsTimingSidecar


def _sidecar() -> TtsTimingSidecar:
    return TtsTimingSidecar(
        sample_rate=24_000,
        text_length=5,
        total_samples=240,
        chunks=(
            TtsTimingChunk(
                planner_chunk=0,
                text_start=0,
                text_end=3,
                audio_start_sample=0,
                audio_end_sample=120,
            ),
            TtsTimingChunk(
                planner_chunk=1,
                text_start=3,
                text_end=5,
                audio_start_sample=120,
                audio_end_sample=240,
            ),
        ),
    )


def test_timing_sidecar_requires_contiguous_text_and_audio_ranges() -> None:
    with pytest.raises(ValidationError, match="audio timing chunks must be contiguous"):
        TtsTimingSidecar(
            sample_rate=24_000,
            text_length=5,
            total_samples=241,
            chunks=(
                TtsTimingChunk(
                    planner_chunk=0,
                    text_start=0,
                    text_end=3,
                    audio_start_sample=0,
                    audio_end_sample=120,
                ),
                TtsTimingChunk(
                    planner_chunk=1,
                    text_start=3,
                    text_end=5,
                    audio_start_sample=121,
                    audio_end_sample=241,
                ),
            ),
        )


def test_timing_registry_enriches_only_metadata_display_spans() -> None:
    registry = TtsTimingRegistry()
    timing_id = registry.begin(
        request_id="req-1",
        sample_rate=24_000,
        display_mapping_status="mapped",
        expected_text_spans=((0, 3), (3, 5)),
        display_spans=((0, 2), (2, 4)),
    )
    registry.complete(timing_id, _sidecar())

    payload = registry.get(timing_id)
    assert payload["status"] == "completed"
    assert payload["timing_quality"] == "chunk"
    chunks = payload["chunks"]
    assert isinstance(chunks, list)
    assert chunks[0]["audio_start_sample"] == 0
    assert chunks[1]["audio_end_sample"] == 240
    assert chunks[0]["display_start"] == 0
    assert chunks[1]["display_end"] == 4
    assert "text" not in str(payload).lower()


def test_timing_registry_fails_closed_on_planner_contract_mismatch() -> None:
    registry = TtsTimingRegistry()
    timing_id = registry.begin(
        request_id="req-1",
        sample_rate=24_000,
        display_mapping_status="unavailable",
        expected_text_spans=((0, 5),),
        display_mapping_reason="normalization_changed_display_coordinates",
    )
    registry.complete(timing_id, _sidecar())

    payload = registry.get(timing_id)
    assert payload["status"] == "unavailable"
    assert payload["reason"] == "planner_contract_mismatch"
    assert payload["chunks"] == []


class _CountingTimingEngine(MlxQwenTtsEngine):
    def __init__(self) -> None:
        self._sample_rate = 24_000
        self._chunk_ms = 100
        self._delivery_stats = Counter()
        self._last_timing_sidecar = None

    def _generate(self, text: str, **kwargs):
        del kwargs
        yield b"\x00\x00" * len(text)


def test_engine_timing_uses_actual_generated_sample_counts_across_planner_chunks() -> None:
    engine = _CountingTimingEngine()
    text = "a" * 250 + "."
    audio = b"".join(
        engine.synthesize(
            text,
            voice="serena",
            speed=1.0,
            language="auto",
            profile=object(),  # type: ignore[arg-type]
        )
    )
    sidecar = engine.consume_timing_sidecar()

    assert sidecar is not None
    assert sidecar["total_samples"] == len(audio) // 2
    chunks = sidecar["chunks"]
    assert isinstance(chunks, list)
    assert len(chunks) == 2
    assert chunks[0]["audio_start_sample"] == 0
    assert chunks[0]["audio_end_sample"] == chunks[0]["text_end"]
    assert chunks[1]["audio_start_sample"] == chunks[0]["audio_end_sample"]
    assert chunks[1]["audio_end_sample"] == len(audio) // 2


def test_timing_registry_does_not_overflow_when_all_entries_are_pending() -> None:
    registry = TtsTimingRegistry(max_entries=1)
    first = registry.begin(
        request_id="req-1",
        sample_rate=24_000,
        display_mapping_status="identity",
        expected_text_spans=((0, 1),),
        display_spans=((0, 1),),
    )

    with pytest.raises(RuntimeError, match="full of pending"):
        registry.begin(
            request_id="req-2",
            sample_rate=24_000,
            display_mapping_status="identity",
            expected_text_spans=((0, 1),),
            display_spans=((0, 1),),
        )

    assert registry.get(first)["status"] == "pending"
