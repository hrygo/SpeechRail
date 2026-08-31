from __future__ import annotations

import asyncio

from speechrail.backends.nemo_sortformer import NemoSortformerEngine
from speechrail.domain.contracts import TranscriptSegment
from speechrail.domain.diarization import DiarizationConfig


def test_nemo_sortformer_assigns_anonymous_label_by_maximum_time_overlap() -> None:
    engine = NemoSortformerEngine(
        model_path="/model/sortformer.nemo",
        max_buffer_bytes=32_000,
        diarize=lambda samples: [["[0.00, 0.45, 0]", "[0.45, 1.00, 1]"]],
    )

    async def scenario() -> None:
        session = engine.create(config=DiarizationConfig(enabled=True, speaker_count_hint=2))
        await session.append_audio(b"\x00\x00" * 16_000)
        update = await session.annotate(
            (
                TranscriptSegment(id="first", start_ms=0, end_ms=400, text="第一位"),
                TranscriptSegment(id="second", start_ms=500, end_ms=900, text="第二位"),
            )
        )

        assert [item.primary_speaker_id for item in update.assignments] == ["spk_01", "spk_02"]
        assert await session.finalize() == update.model_copy(update={"assignments": ()})

    asyncio.run(scenario())
