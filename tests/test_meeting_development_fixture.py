"""Locked fixture execution connects only synthetic WAV, text and fake activity."""

from __future__ import annotations

import asyncio
import copy
import hashlib
import json
import wave

import pytest
from meeting_development_fixture import evaluate_development_fixture
from meeting_evaluation_identity import canonical_digest
from prepare_meeting_evaluation_manifest import build_manifests

from test_meeting_asr_sidecar import fixture as sidecar_fixture
from test_meeting_candidate_runner import Activity
from test_meeting_evaluation_manifest import catalog
from test_meeting_quality_metrics import policy


def inputs(tmp_path):
    value = catalog(tmp_path)
    fixture = value["fixtures"][0]
    pcm = tmp_path / fixture["artifacts"]["pcm"]["path"]
    with wave.open(str(pcm), "wb") as f:
        f.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        f.writeframes(bytes(320))
    pcm_hash = hashlib.sha256(pcm.read_bytes()).hexdigest()
    _, sidecar = sidecar_fixture(tmp_path, pcm_sha256=pcm_hash)
    fixture["artifacts"]["asr_sidecar"] = sidecar
    for kind in ("activity_reference", "text_reference"):
        segment = {"start_sample": 0, "end_sample": 160, "speaker": "R1"}
        if kind == "text_reference":
            segment["text"] = "hello"
        path = tmp_path / fixture["artifacts"][kind]["path"]
        path.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "sample_rate": 16000,
                    "total_samples": 160,
                    "segments": [segment],
                }
            )
        )
    for artifact in fixture["artifacts"].values():
        artifact["sha256"] = hashlib.sha256((tmp_path / artifact["path"]).read_bytes()).hexdigest()
    result = build_manifests(value, artifact_root=tmp_path, scorer_policy=policy())
    return result["development"], result["split_lock"]


def execute(tmp_path, manifest, lock, factory=Activity, **kwargs):
    return asyncio.run(
        asyncio.wait_for(
            evaluate_development_fixture(
                manifest,
                lock,
                artifact_root=tmp_path,
                scorer_policy=policy(),
                fixture_id="M0",
                candidate_sha256="c" * 64,
                activity_factory=factory,
                output_directory=tmp_path / "result",
                **kwargs,
            ),
            3,
        )
    )


def test_complete_replay_scores_independent_streams_and_writes_private_raw_sink(tmp_path):
    manifest, lock = inputs(tmp_path)
    activity = Activity()
    result = execute(tmp_path, manifest, lock, lambda: activity)
    assert result["quality"]["schema_version"] == 3
    assert result["quality"]["product_all_regions"]["recall"] == 1
    assert result["quality"]["standard_metrics"]["cp_cer"]["error_rate"] == 0
    assert result["source_meeting_id"] == manifest["fixtures"][0]["source_group_id"]
    assert result["manifest_sha256"] == lock["development_manifest_sha256"]
    assert result["input_files_verified"] is True
    assert result["sidecar"]["bytes_and_timing_verified"] is True
    assert result["runtime_identity_verified"] is False
    assert result["certification_eligible"] is False
    assert result["certified_max_speakers"] is None
    assert activity.cancels == 1
    saved = (tmp_path / "result" / "result.json").read_text()
    assert "hello" not in saved and str(tmp_path) not in saved
    raw = tmp_path / "result" / "events.jsonl"
    assert raw.stat().st_mode & 0o777 == 0o600
    assert "hello" in raw.read_text()


@pytest.mark.parametrize("change", ["manifest", "policy", "split", "missing_sidecar", "digest"])
def test_invalid_locks_or_artifacts_fail_before_factory(tmp_path, change):
    manifest, lock = inputs(tmp_path)
    if change == "manifest":
        manifest["fixtures"][0]["channel"] = 5
    elif change == "policy":
        lock["scorer_policy_sha256"] = "d" * 64
    elif change == "split":
        manifest["split"] = "holdout"
        lock["development_manifest_sha256"] = canonical_digest(manifest)
    elif change == "missing_sidecar":
        del manifest["fixtures"][0]["artifacts"]["asr_sidecar"]
        lock["development_manifest_sha256"] = canonical_digest(manifest)
    else:
        (tmp_path / manifest["fixtures"][0]["artifacts"]["pcm"]["path"]).write_bytes(b"changed")
    with pytest.raises(ValueError, match="development"):
        execute(tmp_path, manifest, lock, lambda: pytest.fail("worker created before validation"))
    assert not (tmp_path / "result" / "result.json").exists()


def test_existing_output_is_not_overwritten_and_worker_not_created(tmp_path):
    manifest, lock = inputs(tmp_path)
    execute(tmp_path, manifest, lock)
    before = (tmp_path / "result" / "result.json").read_bytes()
    with pytest.raises(FileExistsError):
        execute(tmp_path, manifest, lock, lambda: pytest.fail("overwrote result"))
    assert (tmp_path / "result" / "result.json").read_bytes() == before


def test_reference_mutation_during_run_cannot_produce_success(tmp_path):
    manifest, lock = inputs(tmp_path)
    path = tmp_path / manifest["fixtures"][0]["artifacts"]["text_reference"]["path"]

    def factory():
        path.write_text(path.read_text().replace("hello", "other"))
        return Activity()

    with pytest.raises(RuntimeError, match="development_fixture_failed"):
        execute(tmp_path, manifest, lock, factory)
    assert not (tmp_path / "result" / "result.json").exists()
    assert json.loads((tmp_path / "result" / "failure.json").read_text())["status"] == "failed"


def test_activity_and_text_reference_boundaries_are_not_interchanged(tmp_path):
    manifest, lock = inputs(tmp_path)
    artifact = manifest["fixtures"][0]["artifacts"]["text_reference"]
    path = tmp_path / artifact["path"]
    path.write_text(path.read_text().replace('"end_sample": 160', '"end_sample": 80'))
    artifact["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    lock["development_manifest_sha256"] = canonical_digest(manifest)
    result = execute(tmp_path, manifest, lock)
    assert result["quality"]["product_all_regions"]["reference_speaker_seconds"] == 0.01
    assert result["quality"]["standard_metrics"]["cp_cer"]["error_rate"] == 0


@pytest.mark.parametrize("change", ["speaker", "extra", "timing", "integer", "text_in_activity"])
def test_invalid_reference_schema_fails_before_factory(tmp_path, change):
    manifest, lock = inputs(tmp_path)
    artifact = manifest["fixtures"][0]["artifacts"]["activity_reference"]
    path = tmp_path / artifact["path"]
    data = json.loads(path.read_text())
    if change == "extra":
        data["other"] = "private"
    elif change == "speaker":
        data["segments"][0]["speaker"] = "real identity must not escape"
    elif change == "timing":
        data["segments"][0]["end_sample"] = 161
    elif change == "integer":
        data["segments"][0]["start_sample"] = False
    else:
        data["segments"][0]["text"] = "private"
    path.write_text(json.dumps(data))
    artifact["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    lock["development_manifest_sha256"] = canonical_digest(manifest)
    with pytest.raises(ValueError, match="development"):
        execute(tmp_path, manifest, lock, lambda: pytest.fail("invalid reference reached worker"))


def test_factory_failure_is_sanitized_and_inputs_are_not_mutated(tmp_path):
    manifest, lock = inputs(tmp_path)
    original = copy.deepcopy(manifest)

    def fail():
        raise RuntimeError("full private text hello")

    with pytest.raises(RuntimeError, match=r"^development_fixture_failed$") as exc:
        execute(tmp_path, manifest, lock, fail)
    assert str(exc.value) == "development_fixture_failed"
    assert "hello" not in (tmp_path / "result" / "failure.json").read_text()
    assert manifest == original


def test_truncated_second_pcm_packet_is_rejected_before_worker(tmp_path):
    manifest, lock = inputs(tmp_path)
    artifact = manifest["fixtures"][0]["artifacts"]["pcm"]
    path = tmp_path / artifact["path"]
    with wave.open(str(path), "wb") as f:
        f.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        f.writeframes(bytes(32002))
    path.write_bytes(path.read_bytes()[:-2])
    artifact["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    artifacts = manifest["fixtures"][0]["artifacts"]
    for kind in ("activity_reference", "text_reference"):
        target = tmp_path / artifacts[kind]["path"]
        data = json.loads(target.read_text())
        data["total_samples"] = 16001
        target.write_text(json.dumps(data))
        artifacts[kind]["sha256"] = hashlib.sha256(target.read_bytes()).hexdigest()
    _, artifacts["asr_sidecar"] = sidecar_fixture(tmp_path, pcm_sha256=artifact["sha256"])
    lock["development_manifest_sha256"] = canonical_digest(manifest)
    with pytest.raises(ValueError, match="development"):
        execute(tmp_path, manifest, lock, lambda: pytest.fail("truncated PCM reached worker"))


def test_cancel_during_final_report_write_leaves_no_completed_result(tmp_path, monkeypatch):
    import threading

    import meeting_development_fixture as probe

    manifest, lock = inputs(tmp_path)
    original = probe._write_json
    entered, release = threading.Event(), threading.Event()

    def write(path, value):
        original(path, value)
        if value.get("status") == "completed" or path.name == "result.json":
            entered.set()
            if not release.wait(2):
                raise TimeoutError("missing test release")

    monkeypatch.setattr(probe, "_write_json", write)

    async def run():
        task = asyncio.create_task(
            probe.evaluate_development_fixture(
                manifest,
                lock,
                artifact_root=tmp_path,
                scorer_policy=policy(),
                fixture_id="M0",
                candidate_sha256="c" * 64,
                activity_factory=Activity,
                output_directory=tmp_path / "result",
            )
        )
        try:
            assert await asyncio.to_thread(entered.wait, 2)
            task.cancel()
            await asyncio.sleep(0)
        finally:
            release.set()
        with pytest.raises(asyncio.CancelledError):
            await asyncio.wait_for(task, 2)
        assert not (tmp_path / "result" / "result.json").exists()
        assert (tmp_path / "result" / "failure.json").is_file()

    asyncio.run(run())


def checkpoint_inputs(tmp_path):
    fixtures, groups = [], []
    for i in range(6):
        part = tmp_path / f"part{i}"
        part.mkdir()
        manifest, lock = inputs(part)
        value = manifest["fixtures"][0]
        value["id"] = f"F{i}"
        value["source_group_id"] = hashlib.sha256(f"group-{i}".encode()).hexdigest()
        # Distinct artificial sample values avoid duplicating identical PCM.
        pcm = part / value["artifacts"]["pcm"]["path"]
        data = bytearray(pcm.read_bytes())
        data[-2:] = i.to_bytes(2, "little")
        pcm.write_bytes(data)
        pcm_hash = hashlib.sha256(data).hexdigest()
        value["artifacts"]["pcm"]["sha256"] = pcm_hash
        _, value["artifacts"]["asr_sidecar"] = sidecar_fixture(part, pcm_sha256=pcm_hash)
        for artifact in value["artifacts"].values():
            artifact["path"] = f"part{i}/" + artifact["path"]
        fixtures.append(value)
        groups.append(value["source_group_id"])
    manifest["fixtures"] = fixtures
    manifest["group_order"] = {"1": groups}
    lock["development_manifest_sha256"] = canonical_digest(manifest)
    return manifest, lock


def test_checkpoint_connects_paired_scores_to_common_prefix_schedule(tmp_path):
    from meeting_candidate_schedule import CommonPrefixSchedule
    from meeting_development_fixture import evaluate_development_checkpoint

    manifest, lock = checkpoint_inputs(tmp_path)
    candidates = {"C0": "a" * 64, "C1": "b" * 64, "C2": "c" * 64}
    schedule = CommonPrefixSchedule(
        1,
        candidates,
        manifest["group_order"]["1"],
        manifest_sha256=canonical_digest(manifest),
        scorer_policy_sha256=canonical_digest(policy()),
    )
    calls, activities = [], []

    def factory(name):
        def create():
            assert all(a.cancels == 1 for a in activities)
            calls.append(name)
            activity = Activity()
            activities.append(activity)
            return activity

        return create

    result = asyncio.run(
        asyncio.wait_for(
            evaluate_development_checkpoint(
                manifest,
                lock,
                schedule=schedule,
                candidate_ids=candidates,
                activity_factories={name: factory(name) for name in candidates},
                artifact_root=tmp_path,
                scorer_policy=policy(),
                output_directory=tmp_path / "checkpoint",
            ),
            10,
        )
    )
    assert calls == ["C0"] * 6 + ["C1"] * 6 + ["C2"] * 6
    assert result["request"]["status"] == "passed"
    assert result["request"]["eligible_candidates"] == ["C1", "C2"]
    assert result["certification_eligible"] is False
    assert result["certified_max_speakers"] is None
    assert schedule.request()["status"] == "pending"
    assert result["comparisons"]["C1"]["nondegradation"]["decision"] == "pass"
    assert result["comparisons"]["C1"]["scenes"]["near"]["independent_groups"] == 6
    assert result["comparisons"]["C1"]["scenes"]["far"]["decision"] == "not_observed"
    saved = (tmp_path / "checkpoint" / "checkpoint.json").read_text()
    assert "hello" not in saved and str(tmp_path) not in saved


def test_checkpoint_rejects_candidate_or_source_identity_before_factory(tmp_path):
    from meeting_candidate_schedule import CommonPrefixSchedule
    from meeting_development_fixture import evaluate_development_checkpoint

    manifest, lock = checkpoint_inputs(tmp_path)
    candidates = {"C0": "a" * 64, "C1": "b" * 64, "C2": "c" * 64}
    schedule = CommonPrefixSchedule(
        1,
        candidates,
        manifest["group_order"]["1"],
        manifest_sha256=canonical_digest(manifest),
        scorer_policy_sha256=canonical_digest(policy()),
    )
    changed = {**candidates, "C1": "d" * 64}
    with pytest.raises(ValueError, match="checkpoint"):
        asyncio.run(
            evaluate_development_checkpoint(
                manifest,
                lock,
                schedule=schedule,
                candidate_ids=changed,
                activity_factories={
                    n: lambda: pytest.fail("identity mismatch reached worker") for n in candidates
                },
                artifact_root=tmp_path,
                scorer_policy=policy(),
                output_directory=tmp_path / "checkpoint",
            )
        )
    assert not (tmp_path / "checkpoint").exists()


def test_partial_checkpoint_never_records_round_and_reaps_failed_candidate(tmp_path):
    from meeting_candidate_schedule import CommonPrefixSchedule
    from meeting_development_fixture import evaluate_development_checkpoint

    manifest, lock = checkpoint_inputs(tmp_path)
    candidates = {"C0": "a" * 64, "C1": "b" * 64, "C2": "c" * 64}
    schedule = CommonPrefixSchedule(
        1,
        candidates,
        manifest["group_order"]["1"],
        manifest_sha256=canonical_digest(manifest),
        scorer_policy_sha256=canonical_digest(policy()),
    )
    failed = Activity(broken=True)
    with pytest.raises(RuntimeError, match="development_checkpoint_failed"):
        asyncio.run(
            asyncio.wait_for(
                evaluate_development_checkpoint(
                    manifest,
                    lock,
                    schedule=schedule,
                    candidate_ids=candidates,
                    activity_factories={"C0": Activity, "C1": Activity, "C2": lambda: failed},
                    artifact_root=tmp_path,
                    scorer_policy=policy(),
                    output_directory=tmp_path / "checkpoint",
                ),
                10,
            )
        )
    assert failed.cancels == 1
    assert schedule.as_dict()["rounds"] == []
    assert not (tmp_path / "checkpoint" / "checkpoint.json").exists()
    assert (tmp_path / "checkpoint" / "failure.json").exists()


def test_checkpoint_does_not_retain_all_meetings_reference_texts(tmp_path, monkeypatch):
    import weakref

    import meeting_development_fixture as probe
    from meeting_candidate_schedule import CommonPrefixSchedule

    manifest, lock = checkpoint_inputs(tmp_path)
    candidates = {"C0": "a" * 64, "C1": "b" * 64, "C2": "c" * 64}
    schedule = CommonPrefixSchedule(
        1,
        candidates,
        manifest["group_order"]["1"],
        manifest_sha256=canonical_digest(manifest),
        scorer_policy_sha256=canonical_digest(policy()),
    )
    references = []
    original = probe._prepare

    class TrackedRows(list):
        pass

    def prepare(*args, **kwargs):
        value = original(*args, **kwargs)
        for kind, rows in value["references"].items():
            tracked = TrackedRows(rows)
            value["references"][kind] = tracked
            references.append(weakref.ref(tracked))
        return value

    def factory():
        assert sum(ref() is not None for ref in references) == 2
        return Activity()

    monkeypatch.setattr(probe, "_prepare", prepare)
    asyncio.run(
        asyncio.wait_for(
            probe.evaluate_development_checkpoint(
                manifest,
                lock,
                schedule=schedule,
                candidate_ids=candidates,
                activity_factories=dict.fromkeys(candidates, factory),
                artifact_root=tmp_path,
                scorer_policy=policy(),
                output_directory=tmp_path / "checkpoint",
            ),
            10,
        )
    )
    assert all(ref() is None for ref in references)


def test_event_artifact_budget_failure_closes_worker_and_never_completes(tmp_path, monkeypatch):
    import meeting_development_fixture as probe

    manifest, lock = inputs(tmp_path)
    activity = Activity()
    monkeypatch.setattr(probe, "_MAX_EVENTS_BYTES", 1)
    with pytest.raises(RuntimeError, match="development_fixture_failed"):
        execute(tmp_path, manifest, lock, lambda: activity)
    assert activity.cancels == 1
    assert not (tmp_path / "result" / "result.json").exists()
    assert (tmp_path / "result" / "failure.json").exists()


def test_unsafe_fixture_id_is_rejected_even_when_manifest_hash_is_consistent(tmp_path):
    manifest, lock = inputs(tmp_path)
    manifest["fixtures"][0]["id"] = "../escape"
    lock["development_manifest_sha256"] = canonical_digest(manifest)
    with pytest.raises(ValueError, match="development"):
        asyncio.run(
            evaluate_development_fixture(
                manifest,
                lock,
                artifact_root=tmp_path,
                scorer_policy=policy(),
                fixture_id="../escape",
                candidate_sha256="c" * 64,
                activity_factory=lambda: pytest.fail("unsafe identifier reached worker"),
                output_directory=tmp_path / "result",
            )
        )


def test_unapproved_scorer_policy_is_rejected_before_worker(tmp_path):
    manifest, lock = inputs(tmp_path)
    bad_policy = policy()
    bad_policy["speaker_time_recall_min"] = 1.5
    manifest["scorer_policy_sha256"] = lock["scorer_policy_sha256"] = canonical_digest(bad_policy)
    lock["development_manifest_sha256"] = canonical_digest(manifest)
    with pytest.raises(ValueError, match="development"):
        asyncio.run(
            evaluate_development_fixture(
                manifest,
                lock,
                artifact_root=tmp_path,
                scorer_policy=bad_policy,
                fixture_id="M0",
                candidate_sha256="c" * 64,
                activity_factory=lambda: pytest.fail("invalid scorer reached worker"),
                output_directory=tmp_path / "result",
            )
        )


@pytest.mark.parametrize("mode", ["missing", "wrong_version"])
def test_scorer_environment_is_checked_before_worker(tmp_path, monkeypatch, mode):
    import meeting_quality_metrics as metrics

    manifest, lock = inputs(tmp_path)
    original = metrics.importlib.metadata.version

    def version(name):
        if name == "pyannote.metrics":
            if mode == "missing":
                raise metrics.importlib.metadata.PackageNotFoundError(name)
            return "999"
        return original(name)

    monkeypatch.setattr(metrics.importlib.metadata, "version", version)
    with pytest.raises(ValueError, match="development"):
        execute(tmp_path, manifest, lock, lambda: pytest.fail("invalid environment reached worker"))


def test_cancel_during_sidecar_open_joins_and_closes_entered_context(tmp_path, monkeypatch):
    import contextlib
    import threading

    import meeting_development_fixture as probe

    manifest, lock = inputs(tmp_path)
    original = probe.open_asr_sidecar
    entered, release = threading.Event(), threading.Event()
    sources = []

    @contextlib.contextmanager
    def slow(*args, **kwargs):
        with original(*args, **kwargs) as source:
            sources.append(source)
            entered.set()
            if not release.wait(2):
                raise TimeoutError("test release missing")
            yield source

    monkeypatch.setattr(probe, "open_asr_sidecar", slow)

    async def run():
        task = asyncio.create_task(
            probe.evaluate_development_fixture(
                manifest,
                lock,
                artifact_root=tmp_path,
                scorer_policy=policy(),
                fixture_id="M0",
                candidate_sha256="c" * 64,
                activity_factory=lambda: pytest.fail("cancelled before worker construction"),
                output_directory=tmp_path / "result",
            )
        )
        try:
            assert await asyncio.to_thread(entered.wait, 2)
            task.cancel()
            await asyncio.sleep(0)
            assert not task.done()
        finally:
            release.set()
        with pytest.raises(asyncio.CancelledError):
            await asyncio.wait_for(task, 2)
        assert sources[0]._handle.closed
        assert not (tmp_path / "result" / "result.json").exists()

    asyncio.run(run())
