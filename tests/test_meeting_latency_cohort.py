"""Frozen synthetic registrations and host metadata; no audio or model runs."""

import copy
import hashlib
import json
from pathlib import Path

import pytest
from meeting_evaluation_identity import canonical_digest
from meeting_latency_cohort import finish_configuration
from meeting_latency_policy import latency_policy


def sha(value):
    return hashlib.sha256(str(value).encode()).hexdigest()


def report(fixture, repetition=0, finish=2.0):
    pcm = sha(f"pcm-{fixture}")
    feed = {
        "clock_source": "injected",
        "sample_rate": 16000,
        "chunk_samples": 320,
        "queue_chunks": 8,
        "max_lateness_seconds": 1.0,
        "source_pcm_sha256": pcm,
        "source_samples": 16000,
    }
    policy = {
        "mode": "serial",
        "latency": latency_policy(),
        "pcm_feed_policy_sha256": canonical_digest(feed),
        "source_digests": {"fake": sha(0)},
    }
    origin = 100.0 + fixture * 100 + repetition * 10
    end = origin + 1 + finish
    return {
        "mode": "serial",
        "schedule_completed": True,
        "asr_complete": True,
        "live_attribution_complete": True,
        "asr_preserved_as_unknown": False,
        "diarization_failure": None,
        "joint_verdict": "diagnostic_not_certified",
        "runtime_identity_verified": False,
        "certification_eligible": False,
        "joint_latency_observed": False,
        "worker_reaping_verified": False,
        "deadline_enforcement": {"status": "not_expired", "kind": None},
        "pipeline_policy": policy,
        "pipeline_policy_sha256": canonical_digest(policy),
        "pcm_feed": {
            **feed,
            "policy_sha256": canonical_digest(feed),
            "source_origin_at": origin,
            "source_end_target_at": origin + 1,
        },
        "timing_observations": {
            "schema_version": 2,
            "scope": "diagnostic_host_sink_acknowledgements",
            "clock_source": "injected",
            "source_origin_at": origin,
            "source_samples_observed": 16000,
            "asr_sealed_through": 16000,
            "dia_stable_through": 16000,
            "text_delivery_verified": True,
            "stable_delivery_verified": True,
            "expected_text_units": 1,
            "open_sink_deliveries": 0,
            "failed_sink_deliveries": {},
            "record_fields": [
                "kind",
                "start_sample",
                "end_sample",
                "sequence",
                "known",
                "text_sha256",
                "entered_at",
                "completed_at",
            ],
            "records": [["stable_text", 0, 16000, 0, True, sha("text"), origin + 1, end]],
            "milestones_at": {
                "asr_callback_complete": end,
                "dia_input_eof": origin + 1,
                "dia_scope_closed": end,
            },
            "latency_diagnostics": {
                "scope": "single_meeting_host_sink_only",
                "stable_gate": "diagnostic_pass",
                "finish_seconds": finish,
                "finish_unresolved": False,
                "finish_hard_failed": finish > 15,
                "finish_target_exceeded": finish > 5,
            },
        },
    }


def controls(groups=6, repetitions=1, extra_fixtures=0):
    policy = json.loads(
        (
            Path(__file__).resolve().parents[1] / "examples/perf/meeting-evaluation-policy.json"
        ).read_text()
    )
    group_ids = [sha(f"group-{i}") for i in range(groups)]
    fixtures, executions, reports = [], [], {}
    for i in range(groups + extra_fixtures):
        fixture = {
            "id": f"f{i}",
            "source_group_id": group_ids[i if i < groups else 0],
            "split": "development",
            "speakers_count": 1,
            "scene": "near",
            "sample_kind": "natural_single",
            "artifacts": {"pcm": {"path": f"f{i}.wav", "sha256": sha(f"wav-{i}")}},
        }
        fixtures.append(fixture)
        for repetition in range(repetitions):
            value = report(i, repetition)
            reports[(fixture["id"], repetition)] = value
            executions.append(
                {
                    "fixture_id": fixture["id"],
                    "repetition": repetition,
                    "pcm_sha256": value["pcm_feed"]["source_pcm_sha256"],
                    "expected_samples": 16000,
                    "pipeline_policy_sha256": value["pipeline_policy_sha256"],
                }
            )
    manifest = {
        "schema_version": 2,
        "split": "development",
        "fixtures": fixtures,
        "group_order": {"1": group_ids},
        "source_catalog_sha256": sha("catalog"),
        "scorer_policy_sha256": canonical_digest(policy),
    }
    lock = {
        "schema_version": 2,
        "development_manifest_sha256": canonical_digest(manifest),
        "scorer_policy_sha256": canonical_digest(policy),
        "source_catalog_sha256": manifest["source_catalog_sha256"],
    }
    return {
        "manifest": manifest,
        "split_lock": lock,
        "scorer_policy": policy,
        "speakers_count": 1,
        "checkpoint": groups,
        "repetitions": repetitions,
        "asr_candidate_sha256": sha("asr"),
        "diarization_candidate_sha256": sha("dia"),
        "mode": "serial",
        "executions": executions,
        "pipeline_configuration_sha256": canonical_digest(
            finish_configuration(report(0)["pipeline_policy"], report(0)["pcm_feed"])
        ),
    }, reports


def cohort_observations(cohort, reports):
    return [
        cohort.observe(row["execution_sha256"], reports[(row["fixture_id"], row["repetition"])])
        for row in cohort.registration()["executions"]
    ]


def test_every_registered_execution_is_bound_and_only_sources_receive_equal_weight():
    from meeting_latency_cohort import FinishCohort

    args, reports = controls(extra_fixtures=30)
    # Thirty fast derivatives of group0 must not dilute one slow group among six.
    reports[("f5", 0)] = report(5, finish=6.0)
    cohort = FinishCohort(**args)
    result = cohort.aggregate(cohort_observations(cohort, reports))
    assert result["expected_executions"] == 36
    assert result["source_groups"] == 6
    assert result["finish_p95_seconds"] == result["worst_finish_seconds"] == 6.0
    assert result["finish_gate"] == "no-go"
    assert result["certification_eligible"] is False
    assert result["runtime_identity_verified"] is False


@pytest.mark.parametrize("missing", [1, 2])
def test_missing_executions_keep_source_weight_even_when_p95_itself_is_finite(missing):
    from meeting_latency_cohort import FinishCohort

    args, reports = controls(groups=24)
    cohort = FinishCohort(**args)
    result = cohort.aggregate(cohort_observations(cohort, reports)[:-missing])
    assert result["finish_p95_seconds"] == (2.0 if missing == 1 else None)
    assert result["missing_executions"] == missing
    assert result["failed_source_groups"] == missing
    assert result["worst_finish_seconds"] is None
    assert result["finish_gate"] == "no-go"


def test_repetitions_use_the_slowest_execution_and_never_allow_report_reuse():
    from meeting_latency_cohort import FinishCohort

    args, reports = controls(repetitions=2)
    reports[("f0", 1)] = report(0, 1, 5.0)
    cohort = FinishCohort(**args)
    observations = cohort_observations(cohort, reports)
    result = cohort.aggregate(observations)
    assert result["finish_p95_seconds"] == 5.0
    assert result["finish_gate"] == "diagnostic_pass"
    rows = cohort.registration()["executions"]
    duplicate = cohort.observe(rows[1]["execution_sha256"], reports[("f0", 0)])
    with pytest.raises(ValueError, match="reused"):
        cohort.aggregate([observations[0], duplicate, *observations[2:]])


@pytest.mark.parametrize("fault", ["missing_registration", "duplicate", "checkpoint", "holdout"])
def test_registration_requires_all_selected_fixtures_and_frozen_development_prefix(fault):
    from meeting_latency_cohort import FinishCohort

    args, _ = controls()
    if fault == "missing_registration":
        args["executions"].pop()
    elif fault == "duplicate":
        args["executions"].append(copy.deepcopy(args["executions"][0]))
    elif fault == "checkpoint":
        args["checkpoint"] = 5
    else:
        args["manifest"]["split"] = "holdout"
    with pytest.raises(ValueError):
        FinishCohort(**args)


@pytest.mark.parametrize("fault", ["pcm", "policy", "mode", "finish", "boolean", "upgrade"])
def test_inconsistent_or_upgraded_report_cannot_be_used_as_a_finish_observation(fault):
    from meeting_latency_cohort import FinishCohort

    args, reports = controls()
    cohort = FinishCohort(**args)
    value = reports[("f0", 0)]
    if fault == "pcm":
        value["pcm_feed"]["source_pcm_sha256"] = sha("other")
    elif fault == "policy":
        value["pipeline_policy"]["latency"]["finish_p95_seconds"] = 10
    elif fault == "mode":
        value["mode"] = "overlap"
    elif fault == "finish":
        value["timing_observations"]["latency_diagnostics"]["finish_seconds"] = 0.1
    elif fault == "boolean":
        value["timing_observations"]["latency_diagnostics"]["finish_seconds"] = True
    else:
        value["runtime_identity_verified"] = True
    with pytest.raises(ValueError):
        cohort.observe(cohort.registration()["executions"][0]["execution_sha256"], value)


def test_failed_execution_is_infinite_source_weight_and_control_snapshots_are_immutable():
    from meeting_latency_cohort import FinishCohort

    args, reports = controls()
    cohort = FinishCohort(**args)
    registered = cohort.registration()
    args["executions"][0]["pcm_sha256"] = sha("changed")
    args["manifest"]["fixtures"].clear()
    assert cohort.registration() == registered
    value = reports[("f0", 0)]
    value["joint_verdict"] = "no-go"
    value["timing_observations"]["latency_diagnostics"].update(
        finish_seconds=None,
        finish_unresolved=True,
    )
    observations = cohort_observations(cohort, reports)
    assert observations[0]["status"] == "failed"
    result = cohort.aggregate(observations)
    assert result["missing_executions"] == 0
    assert result["failed_source_groups"] == 1
    assert result["finish_gate"] == "no-go"
    observations[1]["finish_seconds"] = 0
    with pytest.raises(ValueError, match="identity"):
        cohort.aggregate(observations)


def test_configuration_is_mandatory_and_candidate_context_cannot_be_mixed():
    from meeting_latency_cohort import FinishCohort

    args, reports = controls()
    invalid = {**args, "pipeline_configuration_sha256": None}
    with pytest.raises(ValueError):
        FinishCohort(**invalid)
    first = FinishCohort(**args)
    second = FinishCohort(**{**args, "asr_candidate_sha256": sha("other-asr")})
    with pytest.raises(ValueError, match="identity"):
        second.aggregate(cohort_observations(first, reports))


def test_missing_or_unknown_stable_trace_cannot_be_accepted_by_summary_booleans():
    from meeting_latency_cohort import FinishCohort

    args, reports = controls()
    cohort = FinishCohort(**args)
    value = reports[("f0", 0)]
    value["timing_observations"]["records"][0][4] = False
    observation = cohort.observe(cohort.registration()["executions"][0]["execution_sha256"], value)
    assert observation["status"] == "failed"
    value["timing_observations"]["records"].clear()
    observation = cohort.observe(cohort.registration()["executions"][0]["execution_sha256"], value)
    assert observation["status"] == "failed"


def test_pipeline_report_matches_policy_frozen_before_any_synthetic_workload_output():
    import asyncio

    import meeting_live_pipeline as pipeline
    from meeting_activity_workload import run_shared_activity_stream
    from meeting_candidate_evidence import CompletedText
    from meeting_latency_cohort import FinishCohort
    from meeting_pcm_feed import CommonPcmFeed

    from speechrail.domain.audio_timeline import SampleSpan
    from speechrail.domain.resource_limits import GovernorLimits
    from speechrail.runtime.resource_governor import ResourceGovernor
    from test_meeting_candidate_runner import Activity
    from test_meeting_pcm_feed import Clock

    args, _ = controls()
    clock, pcm = Clock(), bytes(32000)
    pcm_hash = hashlib.sha256(pcm).hexdigest()
    feed = CommonPcmFeed(
        pcm,
        expected_pcm_sha256=pcm_hash,
        lanes=("asr", "diarization"),
        chunk_samples=16000,
        queue_chunks=8,
        max_lateness_seconds=1,
        clock=clock,
        sleep=clock.sleep,
    )
    base_policy = feed.policy()
    feed.close()
    sources = pipeline._source_digests()
    for i, row in enumerate(args["executions"]):
        if i == 0:
            row["pcm_sha256"] = pcm_hash
        source_policy = {**base_policy, "source_pcm_sha256": row["pcm_sha256"]}
        policy = pipeline.live_pipeline_policy(
            pcm_feed_policy_sha256=canonical_digest(source_policy),
            sources=sources,
        )
        row["pipeline_policy_sha256"] = canonical_digest(policy)
    args["pipeline_configuration_sha256"] = canonical_digest(
        finish_configuration(policy, base_policy)
    )
    cohort = FinishCohort(**args)
    execution = cohort.registration()["executions"][0]
    output = []

    async def run():
        async def asr(shared, frames, channel, body):
            async for frame in frames:
                item = CompletedText(0, "甲", SampleSpan(frame.start_sample, frame.end_sample))
                body.append(item)
                body.record_terminal(frame.start_sample, frame.end_sample)
                channel.publish(item)
            body.finish()
            channel.finish()
            return {"complete": True}

        async def dia(shared, frames, channel, sink):
            return await run_shared_activity_stream(
                pcm,
                frames,
                activity_factory=Activity,
                epoch="session",
                sink=sink,
                text_channel=channel,
            )

        async def sink(row):
            output.append(row)

        return await pipeline.run_live_meeting_pipeline(
            pcm=pcm,
            expected_pcm_sha256=pcm_hash,
            governor=ResourceGovernor(GovernorLimits(3, 1, 4), allow_heavy_overlap=False),
            asr=asr,
            diarization=dia,
            sink=sink,
            max_lateness_seconds=1,
            chunk_samples=16000,
            clock=clock,
            sleep=clock.sleep,
        )

    assert not output
    value = asyncio.run(run())
    observation = cohort.observe(execution["execution_sha256"], value)
    assert observation["status"] == "completed"
    assert observation["clock_source"] == "injected"
    result = cohort.aggregate([observation])
    assert result["missing_executions"] == 5
    assert result["finish_gate"] == "no-go"
    assert result["certification_eligible"] is False
    assert "甲" not in str(result) + str(observation) + str(cohort.registration())


def test_per_source_policy_cannot_hide_a_different_feed_configuration():
    from meeting_latency_cohort import FinishCohort

    args, reports = controls()
    value = reports[("f0", 0)]
    feed = value["pcm_feed"]
    feed["chunk_samples"] = 160
    keys = (
        "clock_source",
        "sample_rate",
        "chunk_samples",
        "queue_chunks",
        "max_lateness_seconds",
        "source_pcm_sha256",
        "source_samples",
    )
    feed["policy_sha256"] = canonical_digest({k: feed[k] for k in keys})
    value["pipeline_policy"]["pcm_feed_policy_sha256"] = feed["policy_sha256"]
    value["pipeline_policy_sha256"] = canonical_digest(value["pipeline_policy"])
    args["executions"][0]["pipeline_policy_sha256"] = value["pipeline_policy_sha256"]
    cohort = FinishCohort(**args)
    with pytest.raises(ValueError, match="configuration"):
        cohort.observe(cohort.registration()["executions"][0]["execution_sha256"], value)
