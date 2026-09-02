from __future__ import annotations

import asyncio

from speechrail.backends.nemo_sortformer import NemoSortformerEngine
from speechrail.domain.contracts import TranscriptSegment
from speechrail.domain.diarization import DiarizationConfig
from speechrail.runtime.speaker_centroids import SpeakerCentroidStore


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
                TranscriptSegment(id=0, start_ms=0, end_ms=400, text="第一位"),
                TranscriptSegment(id=1, start_ms=500, end_ms=900, text="第二位"),
            )
        )

        assert [item.primary_speaker_id for item in update.assignments] == ["spk_01", "spk_02"]
        assert await session.finalize() == update.model_copy(update={"assignments": ()})

    asyncio.run(scenario())


def test_nemo_sortformer_remaps_reconnected_raw_labels_within_a_group() -> None:
    store = SpeakerCentroidStore(max_groups=1, ttl_seconds=60, similarity_threshold=0.8)
    raw_indices = iter((0, 1))
    engine = NemoSortformerEngine(
        model_path="/model/sortformer.nemo",
        max_buffer_bytes=32_000,
        diarize=lambda samples: [[f"[0.00, 1.00, {next(raw_indices)}]"]],
        embedding=lambda audio: (1.0, 0.0),
        centroids=store,
    )

    async def annotate(segment_id: int) -> tuple[str, dict[str, str]]:
        session = engine.create(
            config=DiarizationConfig(enabled=True, group_id="a" * 64, speaker_count_hint=2)
        )
        await session.append_audio(b"\x00\x00" * 16_000)
        update = await session.annotate(
            (TranscriptSegment(id=segment_id, start_ms=0, end_ms=1000, text="讲话"),)
        )
        return update.assignments[0].primary_speaker_id, dict((await session.finalize()).mapping)

    first_label, first_mapping = asyncio.run(annotate(7))
    second_label, second_mapping = asyncio.run(annotate(8))

    assert first_label == "spk_01"
    assert first_mapping == {}
    assert second_label == "spk_02"
    assert second_mapping == {"spk_02": "spk_01"}


def test_nemo_sortformer_translates_local_model_offsets_to_stream_timeline() -> None:
    engine = NemoSortformerEngine(
        model_path="/model/sortformer.nemo",
        max_buffer_bytes=32_000,
        diarize=lambda samples: [["[0.00, 1.00, 0]"]],
    )

    async def scenario() -> None:
        session = engine.create(config=DiarizationConfig(enabled=True))
        await session.append_audio(b"\x00\x00" * 16_000)
        first = await session.annotate(
            (TranscriptSegment(id=0, start_ms=0, end_ms=1000, text="第一段"),)
        )
        await session.append_audio(b"\x00\x00" * 16_000)
        second = await session.annotate(
            (TranscriptSegment(id=1, start_ms=1000, end_ms=2000, text="第二段"),)
        )

        assert first.assignments[0].primary_speaker_id == "spk_01"
        assert second.assignments[0].primary_speaker_id == "spk_01"

    asyncio.run(scenario())
