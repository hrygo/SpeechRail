from __future__ import annotations

import asyncio
import importlib.util
import sys
import threading
import time
import types
from collections.abc import Sequence

import numpy

from speechrail.backends.nemo_sortformer import (
    NemoSortformerEngine,
    _parse_activities,
    _speaker_index,
)
from speechrail.domain.contracts import TranscriptSegment
from speechrail.domain.diarization import DiarizationConfig, DiarizationError
from speechrail.runtime.speaker_centroids import SpeakerCentroidStore
from speechrail.runtime.worker_lease import WorkerIdleEvictor, WorkerLifecycleState


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


def test_parse_activities_accepts_space_separated_sortformer_tokens() -> None:
    raw = [["0.000 2.320 speaker_0", "4.240 8.070 speaker_0", "2.560 4.160 speaker_1"]]
    parsed = _parse_activities(raw, hint=2, offset_ms=0)
    assert parsed == ((0, 2320, 0), (4240, 8070, 0), (2560, 4160, 1))


def test_parse_activities_still_accepts_python_list_literals() -> None:
    raw = [["[0.0, 0.45, 0]", "(0.45, 1.00, 1)"]]
    parsed = _parse_activities(raw, hint=2, offset_ms=0)
    assert parsed == ((0, 450, 0), (450, 1000, 1))


def test_parse_activities_raises_on_invalid_token() -> None:
    raw = [["not a valid token"]]
    try:
        _parse_activities(raw, hint=2, offset_ms=0)
    except DiarizationError as exc:
        assert exc.code == "diarization_invalid_output"
    else:
        raise AssertionError("expected DiarizationError")


def test_speaker_index_normalizes_labels() -> None:
    assert _speaker_index("speaker_0") == 0
    assert _speaker_index("spk_1") == 1
    assert _speaker_index("0") == 0


def test_concurrent_first_load_restores_model_once(tmp_path, monkeypatch) -> None:
    """Two concurrent first diarization requests must not double-load the model."""

    model_file = tmp_path / "sortformer.nemo"
    model_file.write_bytes(b"stub")
    engine = NemoSortformerEngine(model_path=model_file, max_buffer_bytes=4096)

    restore_calls: list[str] = []
    release_load = threading.Event()

    class _FakeSortformer:
        @staticmethod
        def restore_from(path, map_location=None):
            restore_calls.append(str(path))
            release_load.wait(timeout=5.0)
            return type(
                "M", (), {"diarize": lambda self, *a, **k: [], "eval": lambda s: s}
            )()

    fake_module = types.ModuleType("nemo.collections.asr.models")
    fake_module.SortformerEncLabelModel = _FakeSortformer
    fake_module.__spec__ = importlib.util.spec_from_loader(
        "nemo.collections.asr.models", None
    )
    monkeypatch.setitem(sys.modules, "nemo.collections.asr.models", fake_module)

    threads = [
        threading.Thread(target=engine._load_local_model, args=([0.0, 0.0],))
        for _ in range(2)
    ]
    for thread in threads:
        thread.start()
    # Give an unlocked implementation time to enter restore twice, then release.
    deadline = time.monotonic() + 0.5
    while time.monotonic() < deadline and len(restore_calls) < 2:
        time.sleep(0.01)
    release_load.set()
    for thread in threads:
        thread.join(timeout=5.0)

    assert len(restore_calls) == 1, f"model restored {len(restore_calls)} times"
    assert engine._model is not None


def test_engine_updates_last_active_and_aliveness_on_use() -> None:
    """The engine must expose the evictor protocol: last_active stamps on use."""

    calls: list[Sequence[float]] = []

    def _diarize(samples: Sequence[float]) -> list[list[str]]:
        calls.append(samples)
        return []

    engine = NemoSortformerEngine(
        model_path="/unused/sortformer.nemo", max_buffer_bytes=4096, diarize=_diarize
    )
    assert engine.alive is False

    before = engine.last_active
    time.sleep(0.01)
    assert engine._diarize([0.0, 0.0]) == []
    assert engine.last_active > before
    assert calls == [[0.0, 0.0]]


def test_engine_close_unloads_model_and_next_use_reloads(tmp_path, monkeypatch) -> None:
    """Evictor cold unload drops the model; the next diarize restores it again."""

    model_file = tmp_path / "sortformer.nemo"
    model_file.write_bytes(b"stub")
    engine = NemoSortformerEngine(model_path=model_file, max_buffer_bytes=4096)

    restore_calls: list[str] = []

    class _FakeSortformer:
        @staticmethod
        def restore_from(path, map_location=None):
            restore_calls.append(str(path))
            return type(
                "M", (), {"diarize": lambda self, *a, **k: [], "eval": lambda s: s}
            )()

    fake_module = types.ModuleType("nemo.collections.asr.models")
    fake_module.SortformerEncLabelModel = _FakeSortformer
    fake_module.__spec__ = importlib.util.spec_from_loader(
        "nemo.collections.asr.models", None
    )
    monkeypatch.setitem(sys.modules, "nemo.collections.asr.models", fake_module)

    engine._load_local_model(numpy.zeros(4, dtype=numpy.float32))
    assert engine.alive is True and len(restore_calls) == 1

    asyncio.run(engine.close())
    assert engine.alive is False

    engine._load_local_model(numpy.zeros(4, dtype=numpy.float32))
    assert engine.alive is True and len(restore_calls) == 2


def test_evictor_cold_evicts_idle_diarization_engine(tmp_path, monkeypatch) -> None:
    """An idle diarization engine participates in two-phase eviction like workers."""

    model_file = tmp_path / "sortformer.nemo"
    model_file.write_bytes(b"stub")
    engine = NemoSortformerEngine(model_path=model_file, max_buffer_bytes=4096)

    class _FakeSortformer:
        @staticmethod
        def restore_from(path, map_location=None):
            return type(
                "M", (), {"diarize": lambda self, *a, **k: [], "eval": lambda s: s}
            )()

    fake_module = types.ModuleType("nemo.collections.asr.models")
    fake_module.SortformerEncLabelModel = _FakeSortformer
    fake_module.__spec__ = importlib.util.spec_from_loader(
        "nemo.collections.asr.models", None
    )
    monkeypatch.setitem(sys.modules, "nemo.collections.asr.models", fake_module)

    engine._load_local_model(numpy.zeros(4, dtype=numpy.float32))
    assert engine.alive is True

    evictor = WorkerIdleEvictor(
        [engine],
        idle_timeout_seconds=0.2,
        warm_standby_timeout_seconds=0.1,
        min_uptime_seconds=0.0,
        check_interval_seconds=0.05,
    )
    async def scenario() -> None:
        await evictor.start()
        for _ in range(100):
            if engine.alive is False:
                break
            await asyncio.sleep(0.05)
        await evictor.close()

    asyncio.run(scenario())

    assert engine.alive is False
    assert evictor.state_of(engine) is WorkerLifecycleState.COLD_EVICTED
