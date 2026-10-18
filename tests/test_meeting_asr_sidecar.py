"""Synthetic sidecars bind actual bytes and timing without claiming provenance."""

from __future__ import annotations

import asyncio
import hashlib
import json
import threading

import pytest
from meeting_asr_sidecar import open_asr_sidecar, timing_digest
from meeting_candidate_runner import FixedTextReplay


def row(sequence=0):
    return {
        "sequence": sequence,
        "text": "hello",
        "start_sample": 0,
        "end_sample": 160,
        "ready_after_sample": 160,
        "finish_only": False,
        "units": [],
    }


def fixture(tmp_path, rows=None, **header_changes):
    rows = [row()] if rows is None else rows
    timing = timing_digest(iter(rows))
    header = {
        "schema_version": 1,
        "kind": "fixed_asr_sidecar",
        "sample_rate": 16000,
        "pcm_sha256": "a" * 64,
        "producer_identity_sha256": "b" * 64,
        "timing_evidence_sha256": timing,
        "timing_algorithm": "sha256_timing_row_digests_v1",
    }
    header.update(header_changes)
    path = tmp_path / "asr.jsonl"
    path.write_text("".join(json.dumps(r) + "\n" for r in [header, *rows]))
    descriptor = {
        "path": path.name,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "producer_identity_sha256": "b" * 64,
        "timing_evidence_sha256": timing,
    }
    return path, descriptor


def opened(tmp_path, descriptor):
    return open_asr_sidecar(tmp_path, descriptor, pcm_sha256="a" * 64, total_samples=160)


def test_lossless_text_and_real_word_timing_reach_fixed_replay(tmp_path):
    value = row()
    value.update(
        text=" hello, world! ",
        units=[
            {"text_start": 1, "text_end": 6, "start_sample": 0, "end_sample": 80},
            {"text_start": 8, "text_end": 13, "start_sample": 80, "end_sample": 160},
        ],
    )
    _, descriptor = fixture(tmp_path, [value])
    with opened(tmp_path, descriptor) as source:
        replay = FixedTextReplay(source)
        assert replay.ready(159) == ()
        (item,) = replay.ready(160)
        assert item.text == value["text"]
        assert item.units[1].audio_span.start == 80
        replay.finish(160)
        assert source.proof()["bytes_and_timing_verified"] is True
        assert source.proof()["producer_provenance_verified"] is False
        replay.close()


@pytest.mark.parametrize(
    "field", ["pcm_sha256", "producer_identity_sha256", "timing_evidence_sha256", "sample_rate"]
)
def test_header_mismatch_fails_before_yield(tmp_path, field):
    _, descriptor = fixture(tmp_path, **{field: 8000 if field == "sample_rate" else "c" * 64})
    with pytest.raises(ValueError, match="sidecar"), opened(tmp_path, descriptor):
        pytest.fail("must reject before caller can create a worker")


@pytest.mark.parametrize(
    "changes",
    [
        {"sequence": 1},
        {"start_sample": True},
        {"end_sample": 161},
        {"ready_after_sample": 159},
        {"text": ""},
        {"speaker": "S1"},
        {"finish_only": 1},
    ],
)
def test_invalid_or_reference_bearing_rows_fail_before_yield(tmp_path, changes):
    value = {**row(), **changes}
    _, descriptor = fixture(tmp_path, [value])
    with pytest.raises(ValueError, match="sidecar"), opened(tmp_path, descriptor):
        pytest.fail("invalid record escaped preflight")


def test_changed_timing_cannot_be_hidden_by_only_refreshing_content_hash(tmp_path):
    path, descriptor = fixture(tmp_path, [{**row(), "end_sample": 80}])
    # Still causally valid: the independent timing digest must catch this.
    contents = path.read_text().replace('"ready_after_sample": 160', '"ready_after_sample": 159')
    path.write_text(contents)
    descriptor["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    with pytest.raises(ValueError, match="sidecar"), opened(tmp_path, descriptor):
        pass


def test_same_descriptor_detects_in_place_mutation_during_replay(tmp_path):
    path, descriptor = fixture(tmp_path)
    with pytest.raises(ValueError, match="sidecar"), opened(tmp_path, descriptor) as source:
        path.write_text(path.read_text().replace("hello", "other"))
        list(source)


def test_partial_consumption_never_gets_verified_proof(tmp_path):
    _, descriptor = fixture(tmp_path)
    with pytest.raises(ValueError, match="sidecar"), opened(tmp_path, descriptor) as source:
        with pytest.raises(ValueError, match="sidecar"):
            source.proof()
        next(source)


def test_no_symlinks_or_escaping_paths(tmp_path):
    path, descriptor = fixture(tmp_path)
    (tmp_path / "link").symlink_to(path)
    for name in ("link", "../asr.jsonl", str(path)):
        with (
            pytest.raises(ValueError, match="sidecar"),
            opened(tmp_path, {**descriptor, "path": name}),
        ):
            pass


def test_duplicate_json_keys_and_oversized_lines_are_rejected(tmp_path):
    path, descriptor = fixture(tmp_path)
    original = path.read_text()
    for contents in (
        original.replace('"sequence": 0', '"sequence": 0, "sequence": 0'),
        original + " " * 65537,
    ):
        path.write_text(contents)
        descriptor["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        with pytest.raises(ValueError, match="sidecar"), opened(tmp_path, descriptor):
            pass


def test_empty_observed_transcript_is_valid_not_missing(tmp_path):
    _, descriptor = fixture(tmp_path, [])
    with opened(tmp_path, descriptor) as source:
        assert list(source) == []
        assert source.proof()["records"] == 0


def test_disk_sidecar_integrates_with_supervised_runner(tmp_path):
    from test_meeting_candidate_runner import Activity, bounded_run, pcm

    _, descriptor = fixture(tmp_path)

    async def run():
        output = []

        async def sink(event):
            output.append(event)

        with opened(tmp_path, descriptor) as source:
            result = await bounded_run(
                pcm(1),
                activity_factory=Activity,
                text_replay=FixedTextReplay(source),
                epoch="session",
                sink=sink,
            )
            proof = source.proof()
        assert proof["bytes_and_timing_verified"] is True
        assert result["certification_eligible"] is False
        assert [e["text"] for e in output if e["kind"] == "text"] == ["hello"]

    asyncio.run(run())


@pytest.mark.parametrize("change", ["gap", "finish_order", "decreasing_ready", "grid", "omission"])
def test_invalid_later_records_or_word_evidence_fail_preflight(tmp_path, change):
    values = [row(), {**row(1), "start_sample": 80}]
    if change == "gap":
        values[1]["sequence"] = 2
    elif change == "finish_order":
        values[0]["finish_only"] = True
    elif change == "decreasing_ready":
        values[1].update(end_sample=100, ready_after_sample=100)
    else:
        values[1]["units"] = [
            {"text_start": 0, "text_end": 2, "start_sample": 80, "end_sample": 160},
            {"text_start": 2, "text_end": 5, "start_sample": 80, "end_sample": 160},
        ]
        if change == "omission":
            values[1]["units"].pop()
    _, descriptor = fixture(tmp_path, values)
    with pytest.raises(ValueError, match="sidecar"), opened(tmp_path, descriptor):
        pytest.fail("malformed later record must fail before any worker")


def test_path_replacement_and_descriptor_changes_cannot_refresh_open_identity(tmp_path):
    path, descriptor = fixture(tmp_path)
    with pytest.raises(ValueError, match="sidecar"), opened(tmp_path, descriptor) as source:
        replacement = tmp_path / "replacement"
        replacement.write_bytes(path.read_bytes())
        replacement.replace(path)
        descriptor["sha256"] = "f" * 64
        list(source)


def test_failed_caller_closes_file_without_masking_error(tmp_path):
    _, descriptor = fixture(tmp_path)
    with pytest.raises(RuntimeError, match="caller"), opened(tmp_path, descriptor) as source:
        raise RuntimeError("caller")
    assert source._handle.closed


def test_byte_and_row_budgets_are_enforced_before_yield(tmp_path, monkeypatch):
    import meeting_asr_sidecar

    path, descriptor = fixture(tmp_path)
    monkeypatch.setattr(meeting_asr_sidecar, "_MAX_BYTES", path.stat().st_size - 1)
    with pytest.raises(ValueError, match="sidecar"), opened(tmp_path, descriptor):
        pass
    monkeypatch.setattr(meeting_asr_sidecar, "_MAX_BYTES", path.stat().st_size)
    monkeypatch.setattr(meeting_asr_sidecar, "_MAX_ROWS", 0)
    with pytest.raises(ValueError, match="sidecar"), opened(tmp_path, descriptor):
        pass


def test_replay_disk_reads_run_outside_event_loop(tmp_path):
    from test_meeting_candidate_runner import Activity, bounded_run, pcm

    _, descriptor = fixture(tmp_path)

    class OffLoopReplay(FixedTextReplay):
        def ready(self, accepted):
            with pytest.raises(RuntimeError, match="no running event loop"):
                asyncio.get_running_loop()
            return super().ready(accepted)

        def finish(self, accepted):
            with pytest.raises(RuntimeError, match="no running event loop"):
                asyncio.get_running_loop()
            return super().finish(accepted)

    async def run():
        async def sink(_):
            pass

        with opened(tmp_path, descriptor) as source:
            await bounded_run(
                pcm(1),
                activity_factory=Activity,
                text_replay=OffLoopReplay(source),
                epoch="session",
                sink=sink,
            )

    asyncio.run(run())


def test_cancel_joins_inflight_sidecar_read_before_closing_source():
    from test_meeting_candidate_runner import Activity, bounded_run, pcm

    async def run():
        loop = asyncio.get_running_loop()
        entered = asyncio.Event()
        release = threading.Event()
        operations = []

        class SlowReplay(FixedTextReplay):
            def ready(self, accepted):
                loop.call_soon_threadsafe(entered.set)
                if not release.wait(1):
                    raise TimeoutError("test reader release missing")
                operations.append("read_done")
                return super().ready(accepted)

            def close(self):
                operations.append("closed")
                super().close()

        activity = Activity()

        async def sink(_):
            pass

        task = asyncio.create_task(
            bounded_run(
                pcm(1),
                activity_factory=lambda: activity,
                text_replay=SlowReplay(iter(())),
                epoch="session",
                sink=sink,
            )
        )
        try:
            await asyncio.wait_for(entered.wait(), 1)
            task.cancel()
            await asyncio.sleep(0)
            assert not task.done() and operations == []
        finally:
            release.set()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert operations == ["read_done", "closed"]
        assert activity.cancels == 1

    asyncio.run(run())
