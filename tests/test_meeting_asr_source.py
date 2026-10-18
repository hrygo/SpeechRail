"""Only synthetic source manifests, WAV and frozen primary references."""

import asyncio
import hashlib
import json

import pytest
from meeting_evaluation_identity import candidate_digest, canonical_digest

from test_meeting_development_fixture import inputs
from test_meeting_quality_metrics import policy


@pytest.fixture
def source(tmp_path):
    manifest, split = inputs(tmp_path)
    fixture = manifest["fixtures"][0]
    reference = {
        "schema_version": 1,
        "fixture_id": "M0",
        "manifest_sha256": canonical_digest(manifest),
        "pcm_sha256": fixture["artifacts"]["pcm"]["sha256"],
        "overlap_order": "unambiguous",
        "main_reference": "frozen primary",
    }
    path = tmp_path / "primary.json"
    path.write_text(json.dumps(reference))
    descriptor = {"path": "primary.json", "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    return manifest, split, reference, descriptor


def load(tmp_path, source):
    from meeting_asr_source import load_locked_asr_case

    manifest, split, _, descriptor = source
    return load_locked_asr_case(
        manifest,
        split,
        artifact_root=tmp_path,
        scorer_policy=policy(),
        fixture_id="M0",
        candidate_sha256="a" * 64,
        primary_reference=descriptor,
    )


def test_loads_identical_kernel_pcm_and_explicit_primary_not_speaker_reference(tmp_path, source):
    locked = load(tmp_path, source)
    assert locked.case.pcm16 == bytes(320)
    assert locked.case.main_reference == "frozen primary"
    assert locked.case.source_group_id == source[0]["fixtures"][0]["source_group_id"]
    assert locked.case.manifest_sha256 == canonical_digest(source[0])
    locked.verify()
    locked.verify_stamps()


@pytest.mark.parametrize(
    "field,value",
    [
        ("manifest_sha256", "f" * 64),
        ("pcm_sha256", "f" * 64),
        ("fixture_id", "other"),
        ("schema_version", True),
    ],
)
def test_primary_reference_must_bind_selected_development_source(tmp_path, source, field, value):
    source[2][field] = value
    path = tmp_path / "primary.json"
    path.write_text(json.dumps(source[2]))
    source[3]["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    with pytest.raises(ValueError):
        load(tmp_path, source)


def test_ambiguous_or_missing_primary_is_preserved_not_ordered_by_timestamps(tmp_path, source):
    source[2]["overlap_order"] = "ambiguous"
    source[2]["main_reference"] = None
    path = tmp_path / "primary.json"
    path.write_text(json.dumps(source[2]))
    source[3]["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    locked = load(tmp_path, source)
    assert locked.case.overlap_order == "ambiguous"
    assert locked.case.main_reference is None


@pytest.mark.parametrize("kind", ["primary", "pcm", "text_reference", "asr_sidecar"])
def test_input_change_after_loading_rejected_including_restored_bytes(tmp_path, source, kind):
    locked = load(tmp_path, source)
    path = (
        tmp_path / "primary.json"
        if kind == "primary"
        else tmp_path / source[0]["fixtures"][0]["artifacts"][kind]["path"]
    )
    original = path.read_bytes()
    path.write_bytes(original + b"changed")
    path.write_bytes(original)
    with pytest.raises(ValueError):
        locked.verify_stamps()
    with pytest.raises(ValueError):
        locked.verify()


def test_locked_execution_verifies_identity_and_final_files_without_text_in_report(
    tmp_path, source
):
    from meeting_asr_source import evaluate_locked_asr_case

    locked = load(tmp_path, source)

    async def runner(data):
        return {
            **data.identity(),
            "candidate_sha256": "a" * 64,
            "runtime_identity_verified": False,
            "certification_eligible": False,
        }

    report = asyncio.run(evaluate_locked_asr_case(locked, runner))
    assert report["source_validation"]["bytes_verified"] is True
    assert report["source_validation"]["human_reference_provenance_verified"] is False
    assert "frozen primary" not in json.dumps(report)
    assert str(tmp_path) not in json.dumps(report)


def test_mutation_during_replay_or_wrong_candidate_cannot_return_verified_report(tmp_path, source):
    from meeting_asr_source import evaluate_locked_asr_case

    locked = load(tmp_path, source)

    async def runner(data):
        (tmp_path / "primary.json").write_text("changed during replay")
        return {**data.identity(), "candidate_sha256": "a" * 64}

    with pytest.raises(ValueError):
        asyncio.run(evaluate_locked_asr_case(locked, runner))


def test_wrong_candidate_or_case_report_cannot_receive_source_proof(tmp_path, source):
    from meeting_asr_source import evaluate_locked_asr_case

    locked = load(tmp_path, source)

    async def runner(data):
        return {**data.identity(), "candidate_sha256": "b" * 64}

    with pytest.raises(ValueError, match="source or candidate"):
        asyncio.run(evaluate_locked_asr_case(locked, runner))


@pytest.mark.parametrize("change", ["extra", "symlink", "digest", "holdout"])
def test_reference_schema_symlink_digest_and_holdout_rejected(tmp_path, source, change):
    if change == "extra":
        source[2]["speaker_order"] = ["R1"]
        path = tmp_path / "primary.json"
        path.write_text(json.dumps(source[2]))
        source[3]["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    elif change == "symlink":
        path = tmp_path / "primary.json"
        target = tmp_path / "same-primary.json"
        target.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(target)
    elif change == "digest":
        source[3]["sha256"] = "f" * 64
    else:
        source[0]["split"] = "frozen_holdout"
        source[1]["development_manifest_sha256"] = canonical_digest(source[0])
    with pytest.raises(ValueError):
        load(tmp_path, source)


def test_cancelled_replay_closes_runner_then_joins_source_revalidation(
    tmp_path, source, monkeypatch
):
    from meeting_asr_source import LockedAsrCase, evaluate_locked_asr_case

    locked = load(tmp_path, source)
    original = LockedAsrCase.verify
    checks = []

    def verify(self):
        checks.append(True)
        original(self)

    monkeypatch.setattr(LockedAsrCase, "verify", verify)

    async def exercise():
        entered = asyncio.Event()
        closed = []

        async def runner(data):
            try:
                entered.set()
                await asyncio.Event().wait()
            finally:
                closed.append(True)

        task = asyncio.create_task(evaluate_locked_asr_case(locked, runner))
        await entered.wait()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert closed == [True]
        assert len(checks) == 2

    asyncio.run(exercise())


def test_callback_and_missing_input_errors_are_sanitized(tmp_path, source):
    from meeting_asr_source import evaluate_locked_asr_case

    locked = load(tmp_path, source)

    async def runner(data):
        raise RuntimeError("private transcript /private/model")

    with pytest.raises(RuntimeError) as caught:
        asyncio.run(evaluate_locked_asr_case(locked, runner))
    assert str(caught.value) == "locked ASR replay failed"
    (tmp_path / "primary.json").unlink()
    with pytest.raises(ValueError) as caught:
        locked.verify()
    assert str(tmp_path) not in str(caught.value)


@pytest.mark.parametrize("mutate_after_replay", [False, True])
def test_locked_source_drives_formal_session_and_revalidates_after_close(
    tmp_path, source, mutate_after_replay
):
    import wave

    from meeting_asr_source import evaluate_locked_asr_case, load_locked_asr_case
    from meeting_realtime_asr_replay import replay_realtime_session

    from test_meeting_asr_sidecar import fixture as sidecar_fixture
    from test_meeting_realtime_asr_replay import case, observe, setup

    services, factory, _, candidate = setup()
    manifest, split, reference, descriptor = source
    artifacts = manifest["fixtures"][0]["artifacts"]
    pcm = case().pcm16
    path = tmp_path / artifacts["pcm"]["path"]
    with wave.open(str(path), "wb") as handle:
        handle.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        handle.writeframes(pcm)
    artifacts["pcm"]["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    for kind in ("activity_reference", "text_reference"):
        target = tmp_path / artifacts[kind]["path"]
        data = json.loads(target.read_text())
        data["total_samples"] = len(pcm) // 2
        target.write_text(json.dumps(data))
        artifacts[kind]["sha256"] = hashlib.sha256(target.read_bytes()).hexdigest()
    _, artifacts["asr_sidecar"] = sidecar_fixture(tmp_path, pcm_sha256=artifacts["pcm"]["sha256"])
    split["development_manifest_sha256"] = canonical_digest(manifest)
    reference.update(
        manifest_sha256=canonical_digest(manifest),
        pcm_sha256=artifacts["pcm"]["sha256"],
        main_reference="甲乙",
    )
    primary_path = tmp_path / descriptor["path"]
    primary_path.write_text(json.dumps(reference))
    descriptor["sha256"] = hashlib.sha256(primary_path.read_bytes()).hexdigest()
    locked = load_locked_asr_case(
        manifest,
        split,
        artifact_root=tmp_path,
        scorer_policy=policy(),
        fixture_id="M0",
        candidate_sha256=candidate_digest(candidate),
        primary_reference=descriptor,
    )

    async def replay(data):
        result = await replay_realtime_session(
            data, candidate, services, observe=observe(candidate)
        )
        assert factory.sessions[0].closed
        if mutate_after_replay:
            primary_path.write_text("changed after session close")
        return result

    if mutate_after_replay:
        with pytest.raises(ValueError, match="locked ASR source"):
            asyncio.run(evaluate_locked_asr_case(locked, replay))
    else:
        result = asyncio.run(evaluate_locked_asr_case(locked, replay))
        assert result["source_validation"]["bytes_verified"]
        assert result["quality_evidence_valid"]
        assert result["metrics"]["normalized"]["cer"] == 0
        assert result["coverage_samples"] == len(pcm) // 2
        assert result["runtime_identity_verified"] is False
        assert result["certification_eligible"] is False
        encoded = json.dumps(result, ensure_ascii=False)
        assert "甲乙" not in encoded and str(tmp_path) not in encoded


@pytest.fixture
def diagnostic_source(tmp_path, source):
    from prepare_meeting_evaluation_manifest import build_manifests

    manifest, _, reference, descriptor = source
    fixture = dict(manifest["fixtures"][0])
    fixture.pop("source_group_id")
    fixture["split"] = "diagnostic"
    fixture["sample_kind"] = "derived_mix"
    fixture["artifacts"] = {k: v for k, v in fixture["artifacts"].items() if k != "asr_sidecar"}
    catalog = {
        "schema_version": 2,
        "independence_level": "meeting-disjoint",
        "sources": {
            "M0": {
                "dataset": "synthetic",
                "partition": "train",
                "recording_sha256": "d" * 64,
                "derived_from": [],
                "global_speaker_ids": [],
            }
        },
        "fixtures": [fixture],
    }
    result = build_manifests(catalog, artifact_root=tmp_path, scorer_policy=policy())
    reference["manifest_sha256"] = canonical_digest(result["diagnostic"])
    reference["main_reference"] = None
    reference["overlap_order"] = "ambiguous"
    path = tmp_path / "primary.json"
    path.write_text(json.dumps(reference))
    descriptor["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    return catalog, result, descriptor


def load_diagnostic(tmp_path, diagnostic_source):
    from meeting_asr_source import load_locked_asr_diagnostic_case

    catalog, result, descriptor = diagnostic_source
    return load_locked_asr_diagnostic_case(
        catalog,
        result["split_lock"],
        artifact_root=tmp_path,
        scorer_policy=policy(),
        fixture_id="M0",
        candidate_sha256="a" * 64,
        primary_reference=descriptor,
    )


def test_diagnostic_asr_loads_derived_pcm_without_sidecar_or_fabricating_primary(
    tmp_path,
    diagnostic_source,
):
    locked = load_diagnostic(tmp_path, diagnostic_source)
    assert locked.case.pcm16 == bytes(320)
    assert locked.case.main_reference is None
    assert locked.case.overlap_order == "ambiguous"
    assert locked.proof()["source_scope"] == "diagnostic"
    assert locked.proof()["natural_development_eligible"] is False
    locked.verify()


def test_diagnostic_replay_cannot_claim_development_or_certification(tmp_path, diagnostic_source):
    from meeting_asr_source import evaluate_locked_asr_case

    locked = load_diagnostic(tmp_path, diagnostic_source)

    async def misleading_runner(data):
        return {
            **data.identity(),
            "candidate_sha256": "a" * 64,
            "split_role": "development",
            "certification_eligible": True,
            "certified_max_speakers": 8,
            "asr_quality_improvement_gate": "pass",
        }

    report = asyncio.run(evaluate_locked_asr_case(locked, misleading_runner))
    assert report["split_role"] == "diagnostic"
    assert report["certification_eligible"] is False
    assert report["certified_max_speakers"] is None
    assert report["asr_quality_improvement_gate"] == "not_observed"
    assert report["natural_development_eligible"] is False


@pytest.mark.parametrize("change", ["reserved", "development", "lock", "reference", "timebase"])
def test_diagnostic_source_scope_and_references_fail_closed(tmp_path, diagnostic_source, change):
    catalog, result, _ = diagnostic_source
    if change == "reserved":
        catalog["sources"]["M0"]["partition"] = "Eval_Ali"
    elif change == "development":
        catalog["fixtures"][0]["split"] = "development"
    elif change == "lock":
        result["split_lock"]["diagnostic_manifest_sha256"] = "f" * 64
    else:
        kind = "text_reference"
        path = tmp_path / catalog["fixtures"][0]["artifacts"][kind]["path"]
        value = json.loads(path.read_text())
        if change == "reference":
            value["segments"][0]["speaker"] = "real-name"
        else:
            value["total_samples"] += 1
        path.write_text(json.dumps(value))
        catalog["fixtures"][0]["artifacts"][kind]["sha256"] = hashlib.sha256(
            path.read_bytes()
        ).hexdigest()
        from prepare_meeting_evaluation_manifest import build_manifests

        result.update(build_manifests(catalog, artifact_root=tmp_path, scorer_policy=policy()))
        primary = tmp_path / "primary.json"
        reference = json.loads(primary.read_text())
        reference["manifest_sha256"] = canonical_digest(result["diagnostic"])
        primary.write_text(json.dumps(reference))
        diagnostic_source[2]["sha256"] = hashlib.sha256(primary.read_bytes()).hexdigest()
    with pytest.raises(ValueError):
        load_diagnostic(tmp_path, diagnostic_source)


def test_diagnostic_input_never_enters_existing_development_loader(tmp_path, diagnostic_source):
    from meeting_asr_source import load_locked_asr_case

    _, result, descriptor = diagnostic_source
    with pytest.raises(ValueError):
        load_locked_asr_case(
            result["diagnostic"],
            result["split_lock"],
            artifact_root=tmp_path,
            scorer_policy=policy(),
            fixture_id="M0",
            candidate_sha256="a" * 64,
            primary_reference=descriptor,
        )


def test_diagnostic_candidate_digest_is_validated(tmp_path, diagnostic_source):
    from meeting_asr_source import load_locked_asr_diagnostic_case

    catalog, result, descriptor = diagnostic_source
    with pytest.raises(ValueError):
        load_locked_asr_diagnostic_case(
            catalog,
            result["split_lock"],
            artifact_root=tmp_path,
            scorer_policy=policy(),
            fixture_id="M0",
            candidate_sha256="private invalid identity",
            primary_reference=descriptor,
        )


def test_diagnostic_callback_cannot_promote_text_evidence(tmp_path, diagnostic_source):
    from meeting_asr_source import evaluate_locked_asr_case

    locked = load_diagnostic(tmp_path, diagnostic_source)

    async def runner(data):
        return {**data.identity(), "candidate_sha256": "a" * 64, "quality_evidence_valid": True}

    result = asyncio.run(evaluate_locked_asr_case(locked, runner))
    assert result["quality_evidence_valid"] is False
