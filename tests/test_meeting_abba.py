"""ABBA registration/host evidence only; fake reports, no audio or models."""

import copy
import hashlib
import json

import pytest
from meeting_evaluation_identity import canonical_digest


def sha(value):
    return hashlib.sha256(str(value).encode()).hexdigest()


def arguments(groups=8, conditions=("cold", "warm"), repeats=1):
    return {
        "controls": {
            k: sha(k)
            for k in (
                "attempt_sha256",
                "source_pool_sha256",
                "asr_candidate_sha256",
                "diarization_candidate_sha256",
                "scorer_policy_sha256",
                "workload_policy_sha256",
            )
        },
        "sources": [
            {
                "source_group_sha256": sha(f"g{i}"),
                "fixture_sha256": sha(f"f{i}"),
                "pcm_sha256": sha(f"pcm{i}"),
                "samples": 16000 * 300,
            }
            for i in range(groups)
        ],
        "conditions": conditions,
        "blocks_per_source": repeats,
        "feed_configuration": {
            "clock_source": "injected",
            "sample_rate": 16000,
            "chunk_samples": 320,
            "queue_chunks": 8,
            "max_lateness_seconds": 1.0,
        },
    }


def report(row):
    start = 100.0 + row["ordinal"] * 1000
    lanes = {
        "asr-only": ["asr"],
        "diarization-only": ["diarization"],
        "serial": ["asr", "diarization"],
        "overlap": ["asr", "diarization"],
    }[row["mode"]]
    feed = {
        "clock_source": "injected",
        "sample_rate": 16000,
        "chunk_samples": 320,
        "queue_chunks": 8,
        "max_lateness_seconds": 1.0,
        "source_pcm_sha256": row["pcm_sha256"],
        "source_samples": row["samples"],
    }
    return {
        "schema_version": 1,
        "mode": row["mode"],
        "schedule_completed": True,
        "runtime_identity_verified": False,
        "certification_eligible": False,
        "joint_latency_observed": False,
        "worker_reaping_verified": False,
        "clock_source": "injected",
        "workloads": {
            name: {
                "started_at_seconds": 0.0,
                "ended_at_seconds": 301.0,
                "elapsed_seconds": 301.0,
                "report_sha256": sha(f"{row['ordinal']}-{name}"),
            }
            for name in lanes
        },
        "pcm_feed": {
            **feed,
            "policy_sha256": canonical_digest(feed),
            "source_origin_at": start,
            "source_end_target_at": start + 300,
            "source_end_offered_at": start + 300,
            "delivered_samples": dict.fromkeys(lanes, row["samples"]),
        },
    }


def test_frozen_order_and_budget_include_separate_baselines_for_each_condition():
    from meeting_abba import AbbaLedger

    args = arguments()
    ledger = AbbaLedger(**args)
    plan = ledger.registration()
    assert len(plan["runs"]) == 96
    assert [r["mode"] for r in plan["runs"][:6]] == [
        "asr-only",
        "diarization-only",
        "serial",
        "overlap",
        "overlap",
        "serial",
    ]
    assert plan["minimum_pcm_feed_seconds"] == 28800
    assert plan["minimum_joint_pcm_feed_seconds"] == 19200
    assert plan["blocks_per_condition"] == 8
    args["sources"][0]["samples"] = 1
    assert ledger.registration() == plan
    assert ledger.summary()["status"] == "invalid"
    assert ledger.summary()["missing_runs"] == 96


@pytest.mark.parametrize(
    "fault",
    [
        "groups",
        "duplicate_group",
        "duplicate_pcm",
        "duplicate_fixture",
        "conditions",
        "empty_condition",
        "repeat",
        "identity",
        "feed_rate",
    ],
)
def test_incomplete_or_unpaired_design_is_rejected_before_observation(fault):
    from meeting_abba import AbbaLedger

    args = arguments()
    if fault == "groups":
        args["sources"].pop()
    elif fault == "duplicate_group":
        args["sources"][1]["source_group_sha256"] = args["sources"][0]["source_group_sha256"]
    elif fault == "duplicate_fixture":
        args["sources"][1]["fixture_sha256"] = args["sources"][0]["fixture_sha256"]
    elif fault == "duplicate_pcm":
        args["sources"][1]["pcm_sha256"] = args["sources"][0]["pcm_sha256"]
    elif fault == "conditions":
        args["conditions"] = ("cold", "cold")
    elif fault == "empty_condition":
        args["conditions"] = ()
    elif fault == "repeat":
        args["blocks_per_source"] = True
    elif fault == "identity":
        args["controls"].pop("asr_candidate_sha256")
    else:
        args["feed_configuration"]["sample_rate"] = 48000
    with pytest.raises(ValueError):
        AbbaLedger(**args)


def test_missing_baseline_and_failed_run_cannot_disappear_from_summary():
    from meeting_abba import AbbaLedger

    ledger = AbbaLedger(**arguments(conditions=("warm",)))
    rows = ledger.registration()["runs"]
    with pytest.raises(ValueError, match="order"):
        ledger.observe(rows[2]["run_sha256"], condition="warm", report=report(rows[2]))
    ledger.fail(rows[0]["run_sha256"])
    for row in rows[1:]:
        ledger.observe(row["run_sha256"], condition="warm", report=report(row))
    result = ledger.summary()
    assert result["status"] == "invalid"
    assert result["failed_runs"] == 1
    assert result["missing_runs"] == 0
    assert result["conditions"]["warm"]["complete_blocks"] == 7
    assert result["selected_schedule"] is None


@pytest.mark.parametrize(
    "fault",
    [
        "condition",
        "mode",
        "source",
        "samples",
        "policy",
        "lane",
        "clock",
        "upgrade",
        "undrained",
        "time",
    ],
)
def test_inconsistent_host_report_rejected_without_advancing_expected_run(fault):
    from meeting_abba import AbbaLedger

    ledger = AbbaLedger(**arguments(conditions=("cold",)))
    row = ledger.registration()["runs"][0]
    value, condition = report(row), "cold"
    if fault == "condition":
        condition = "warm"
    elif fault == "mode":
        value["mode"] = "serial"
    elif fault == "source":
        value["pcm_feed"]["source_pcm_sha256"] = sha("other")
    elif fault == "samples":
        value["pcm_feed"]["source_samples"] = True
    elif fault == "policy":
        value["pcm_feed"]["chunk_samples"] = 160
    elif fault == "lane":
        value["workloads"]["diarization"] = copy.deepcopy(value["workloads"]["asr"])
    elif fault == "clock":
        value["clock_source"] = "monotonic"
    elif fault == "upgrade":
        value["certification_eligible"] = True
    elif fault == "undrained":
        value["pcm_feed"]["delivered_samples"]["asr"] = 1
    else:
        value["workloads"]["asr"]["elapsed_seconds"] = 1
    with pytest.raises(ValueError):
        ledger.observe(row["run_sha256"], condition=condition, report=value)
    assert ledger.summary()["observed_runs"] == 0
    ledger.observe(row["run_sha256"], condition="cold", report=report(row))
    assert ledger.summary()["observed_runs"] == 1


def test_complete_metadata_does_not_invent_primary_benefit_quality_or_runtime_attestation():
    from meeting_abba import AbbaLedger

    ledger = AbbaLedger(**arguments(repeats=2))
    for row in ledger.registration()["runs"]:
        ledger.observe(row["run_sha256"], condition=row["condition"], report=report(row))
    result = ledger.summary()
    assert result["status"] == "complete_metadata"
    assert result["conditions"]["cold"]["complete_blocks"] == 16
    assert result["conditions"]["warm"]["complete_blocks"] == 16
    assert result["primary_benefit_interval_seconds"] is None
    assert result["selected_schedule"] is None
    assert result["quality_gate"] == "not_observed"
    assert result["certification_eligible"] is False
    assert result["runtime_identity_verified"] is False
    assert "private" not in json.dumps(result)


def test_actual_pcm_scheduler_reports_fill_registered_four_mode_blocks():
    import asyncio

    from bench_asr_diarization_overlap import run_pcm_workload_schedule
    from meeting_abba import AbbaLedger

    from test_meeting_pcm_feed import Clock, governor

    args = arguments(conditions=("warm",))
    inputs = {}
    for index, source in enumerate(args["sources"]):
        pcm = bytes([index, 0]) * 16
        source.update(pcm_sha256=hashlib.sha256(pcm).hexdigest(), samples=16)
        inputs[source["pcm_sha256"]] = pcm
    args["feed_configuration"]["chunk_samples"] = 16
    ledger = AbbaLedger(**args)  # Before any callback output.
    clock = Clock()

    async def scenario():
        for row in ledger.registration()["runs"]:
            seen = []

            async def consume(shared, frames, captured=seen):
                samples = 0
                async for frame in frames:
                    samples += len(frame.pcm) // 2
                captured.append(samples)
                return {"complete": True, "private": "private transcript /private/model"}

            mode = row["mode"]
            value = await run_pcm_workload_schedule(
                pcm=inputs[row["pcm_sha256"]],
                expected_pcm_sha256=row["pcm_sha256"],
                mode=mode,
                governor=governor(mode == "overlap"),
                overlap_enabled=mode == "overlap",
                max_lateness_seconds=1.0,
                chunk_samples=16,
                queue_chunks=8,
                clock=clock,
                sleep=clock.sleep,
                asr=consume if mode != "diarization-only" else None,
                diarization=consume if mode != "asr-only" else None,
            )
            assert seen == [16] * (2 if mode in {"serial", "overlap"} else 1)
            ledger.observe(row["run_sha256"], condition="warm", report=value)

    asyncio.run(scenario())
    result = ledger.summary()
    assert result["status"] == "complete_metadata"
    assert result["observed_runs"] == 48
    assert result["conditions"]["warm"]["complete_blocks"] == 8
    assert "private" not in json.dumps(result)
    assert result["primary_benefit_interval_seconds"] is None


def joint_arguments(conditions=("warm",), repeats=1):
    from meeting_latency_cohort import finish_configuration

    args = arguments(conditions=conditions, repeats=repeats)
    for source in args["sources"]:
        source["samples"] = 16000
    policies = {}
    for _index, source in enumerate(args["sources"]):
        policies[source["source_group_sha256"]] = {}
        for mode in ("serial", "overlap"):
            row = {**source, "ordinal": 0, "mode": mode}
            value = joint_report(row, 2.0)
            policies[source["source_group_sha256"]][mode] = {
                "pipeline_policy_sha256": value["pipeline_policy_sha256"],
                "pipeline_configuration_sha256": canonical_digest(
                    finish_configuration(value["pipeline_policy"], value["pcm_feed"])
                ),
            }
    args["joint_policies"] = policies
    from meeting_abba import joint_comparison_configuration

    args["joint_comparison_sha256"] = canonical_digest(
        joint_comparison_configuration(value["pipeline_policy"], value["pcm_feed"])
    )
    return args


def joint_report(row, finish):
    from test_meeting_latency_cohort import report as finish_report

    value = finish_report(0, repetition=row["ordinal"] * 100, finish=finish)
    value["mode"] = value["pipeline_policy"]["mode"] = row["mode"]
    feed = value["pcm_feed"]
    feed["source_pcm_sha256"] = row["pcm_sha256"]
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
    source_end = feed["source_end_target_at"]
    lanes = ("asr", "diarization")
    feed.update(source_end_offered_at=source_end, delivered_samples=dict.fromkeys(lanes, 16000))
    value["clock_source"] = "injected"
    value["schema_version"] = 1
    value["workloads"] = {
        k: {
            "started_at_seconds": 0.0,
            "ended_at_seconds": 1.0 + finish,
            "elapsed_seconds": 1.0 + finish,
            "report_sha256": sha(f"{row['ordinal']}-{k}"),
        }
        for k in lanes
    }
    return value


def fill_joint(ledger, finish, *, fault=None):
    for row in ledger.registration()["runs"]:
        if fault == (row["condition"], row["ordinal"]):
            ledger.fail(row["run_sha256"])
        elif row["mode"] in {"serial", "overlap"}:
            ledger.observe(
                row["run_sha256"], condition=row["condition"], report=joint_report(row, finish(row))
            )
        else:
            value = report(row)
            # This test uses one second sources; baseline helper is 300s by default.
            origin = value["pcm_feed"]["source_origin_at"]
            value["pcm_feed"].update(
                source_end_target_at=origin + 1, source_end_offered_at=origin + 1
            )
            ledger.observe(row["run_sha256"], condition=row["condition"], report=value)


def test_joint_primary_uses_paired_source_p95_not_callback_elapsed_or_independent_intervals():
    from meeting_abba import AbbaLedger

    ledger = AbbaLedger(**joint_arguments())

    def finish(row):
        source = int((row["ordinal"] % 48) // 6)
        return 1.0 + source * 0.25 + (0.5 if row["mode"] == "serial" else 0)

    fill_joint(ledger, finish)
    summary = ledger.summary()
    result = summary["conditions"]["warm"]["joint_finish"]
    assert result["source_groups"] == 8
    assert result["serial_p95_seconds"] == 3.25
    assert result["overlap_p95_seconds"] == 2.75
    assert result["primary_difference_seconds"] == 0.5
    # Pairing identical source indices preserves this constant shift exactly.
    assert result["paired_interval_seconds"] == [0.5, 0.5]
    assert result["benefit_supported"] is True
    assert result["absolute_finish_gate"] == {
        "serial": "diagnostic_pass",
        "overlap": "diagnostic_pass",
    }
    assert summary["selected_schedule"] is None
    assert summary["certification_eligible"] is False


def test_missing_single_baseline_suppresses_primary_interval_without_dropping_source():
    from meeting_abba import AbbaLedger

    ledger = AbbaLedger(**joint_arguments())
    fill_joint(ledger, lambda row: 4 if row["mode"] == "serial" else 2, fault=("warm", 0))
    result = ledger.summary()["conditions"]["warm"]["joint_finish"]
    assert result["source_groups"] == 8
    assert result["failed_source_groups"] == 1
    assert result["paired_interval_seconds"] is None
    assert result["benefit_supported"] is False


def test_repetitions_are_group_worst_and_cold_warm_cannot_be_pooled():
    from meeting_abba import AbbaLedger

    ledger = AbbaLedger(**joint_arguments(conditions=("cold", "warm"), repeats=2))

    def finish(row):
        if row["condition"] == "cold":
            return 4 if row["mode"] == "serial" else 2
        if row["repetition"] == 1:
            return 6 if row["mode"] == "overlap" else 4
        return 4 if row["mode"] == "serial" else 1

    fill_joint(ledger, finish)
    result = ledger.summary()
    cold = result["conditions"]["cold"]["joint_finish"]
    warm = result["conditions"]["warm"]["joint_finish"]
    assert cold["paired_interval_seconds"] == [2.0, 2.0]
    assert warm["source_groups"] == 8
    assert warm["paired_interval_seconds"] == [-2.0, -2.0]
    assert warm["benefit_supported"] is False
    assert warm["absolute_finish_gate"]["overlap"] == "no-go"
    assert result["primary_benefit_interval_seconds"] is None


@pytest.mark.parametrize(
    "fault", ["partial_policies", "different_common", "changed_policy", "bad_trace"]
)
def test_joint_binding_and_trace_must_match_frozen_registration(fault):
    from meeting_abba import AbbaLedger

    args = joint_arguments()
    group = args["sources"][0]["source_group_sha256"]
    if fault == "partial_policies":
        args["joint_policies"][group].pop("overlap")
        with pytest.raises(ValueError):
            AbbaLedger(**args)
        return
    if fault == "different_common":
        args["joint_policies"][group]["serial"]["pipeline_configuration_sha256"] = sha("other")
        with pytest.raises(ValueError):
            AbbaLedger(**args)
        return
    ledger = AbbaLedger(**args)
    rows = ledger.registration()["runs"]
    for row in rows[:2]:
        value = report(row)
        origin = value["pcm_feed"]["source_origin_at"]
        value["pcm_feed"].update(source_end_target_at=origin + 1, source_end_offered_at=origin + 1)
        ledger.observe(row["run_sha256"], condition="warm", report=value)
    row = rows[2]
    value = joint_report(row, 2.0)
    if fault == "changed_policy":
        value["pipeline_policy"]["latency"]["finish_p95_seconds"] = 100
        with pytest.raises(ValueError):
            ledger.observe(row["run_sha256"], condition="warm", report=value)
        assert ledger.summary()["observed_runs"] == 2
    else:
        value["timing_observations"]["records"].pop(2)
        ledger.observe(row["run_sha256"], condition="warm", report=value)
        assert ledger.summary()["failed_runs"] == 1


def test_joint_comparison_requires_one_frozen_configuration_across_modes():
    from meeting_abba import AbbaLedger

    args = joint_arguments()
    # Coherently register a different runtime policy for every overlap run.
    # It must still fail against the comparison-wide common configuration.
    for source in args["sources"]:
        row = {**source, "ordinal": 0, "mode": "overlap"}
        value = joint_report(row, 2.0)
        value["pipeline_policy"]["sink_timeout_seconds"] = 0.1
        value["pipeline_policy_sha256"] = canonical_digest(value["pipeline_policy"])
        from meeting_latency_cohort import finish_configuration

        args["joint_policies"][source["source_group_sha256"]]["overlap"] = {
            "pipeline_policy_sha256": value["pipeline_policy_sha256"],
            "pipeline_configuration_sha256": canonical_digest(
                finish_configuration(value["pipeline_policy"], value["pcm_feed"])
            ),
        }
    ledger = AbbaLedger(**args)
    rows = ledger.registration()["runs"]
    for row in rows[:3]:
        if row["mode"] == "serial":
            value = joint_report(row, 2.0)
        else:
            value = report(row)
            origin = value["pcm_feed"]["source_origin_at"]
            value["pcm_feed"].update(
                source_end_target_at=origin + 1, source_end_offered_at=origin + 1
            )
        ledger.observe(row["run_sha256"], condition="warm", report=value)
    row = rows[3]
    value = joint_report(row, 2.0)
    value["pipeline_policy"]["sink_timeout_seconds"] = 0.1
    value["pipeline_policy_sha256"] = canonical_digest(value["pipeline_policy"])
    with pytest.raises(ValueError, match="comparison"):
        ledger.observe(row["run_sha256"], condition="warm", report=value)
    assert ledger.summary()["observed_runs"] == 3


def test_live_joint_pipeline_reports_reach_paired_analysis_after_pre_output_freeze():
    import asyncio

    import meeting_live_pipeline as pipeline
    from bench_asr_diarization_overlap import run_pcm_workload_schedule
    from meeting_abba import AbbaLedger, joint_comparison_configuration
    from meeting_activity_workload import run_shared_activity_stream
    from meeting_candidate_evidence import CompletedText
    from meeting_latency_cohort import finish_configuration

    from speechrail.domain.audio_timeline import SampleSpan
    from test_meeting_candidate_runner import Activity
    from test_meeting_pcm_feed import Clock, governor

    args = arguments(conditions=("warm",))
    args["feed_configuration"]["chunk_samples"] = 16000
    inputs, policies = {}, {}
    sources = pipeline._source_digests()
    for index, source in enumerate(args["sources"]):
        pcm = bytes([index, 0]) * 16000
        source.update(pcm_sha256=hashlib.sha256(pcm).hexdigest(), samples=16000)
        inputs[source["pcm_sha256"]] = pcm
        feed = {
            **args["feed_configuration"],
            "source_pcm_sha256": source["pcm_sha256"],
            "source_samples": 16000,
        }
        modes = {}
        for mode in ("serial", "overlap"):
            policy = pipeline.live_pipeline_policy(
                pcm_feed_policy_sha256=canonical_digest(feed),
                sources=sources,
                mode=mode,
                overlap_enabled=mode == "overlap",
            )
            modes[mode] = {
                "pipeline_policy_sha256": canonical_digest(policy),
                "pipeline_configuration_sha256": canonical_digest(
                    finish_configuration(policy, feed)
                ),
            }
        policies[source["source_group_sha256"]] = modes
    args["joint_policies"] = policies
    args["joint_comparison_sha256"] = canonical_digest(joint_comparison_configuration(policy, feed))
    ledger = AbbaLedger(**args)
    clock, sink_calls = Clock(), []

    async def scenario():
        for row in ledger.registration()["runs"]:
            pcm, mode = inputs[row["pcm_sha256"]], row["mode"]

            async def consume(shared, frames):
                async for _ in frames:
                    pass
                return {"complete": True}

            async def asr(shared, frames, channel, body):
                async for frame in frames:
                    item = CompletedText(0, "甲", SampleSpan(frame.start_sample, frame.end_sample))
                    body.append(item)
                    body.record_terminal(frame.start_sample, frame.end_sample)
                    channel.publish(item)
                body.finish()
                channel.finish()
                return {"complete": True}

            async def dia(shared, frames, channel, sink, source_pcm=pcm):
                return await run_shared_activity_stream(
                    source_pcm,
                    frames,
                    activity_factory=Activity,
                    epoch="session",
                    sink=sink,
                    text_channel=channel,
                )

            async def sink(value):
                sink_calls.append(value["kind"])

            kwargs = {
                "pcm": pcm,
                "expected_pcm_sha256": row["pcm_sha256"],
                "mode": mode,
                "governor": governor(mode == "overlap"),
                "overlap_enabled": mode == "overlap",
                "max_lateness_seconds": 1.0,
                "chunk_samples": 16000,
                "queue_chunks": 8,
                "clock": clock,
                "sleep": clock.sleep,
            }
            if mode in {"serial", "overlap"}:
                value = await pipeline.run_live_meeting_pipeline(
                    **kwargs, asr=asr, diarization=dia, sink=sink
                )
            else:
                value = await run_pcm_workload_schedule(
                    **kwargs,
                    asr=consume if mode == "asr-only" else None,
                    diarization=consume if mode == "diarization-only" else None,
                )
            ledger.observe(row["run_sha256"], condition="warm", report=value)

    assert not sink_calls
    asyncio.run(scenario())
    summary = ledger.summary()
    result = summary["conditions"]["warm"]["joint_finish"]
    assert summary["status"] == "complete_metadata"
    assert result["failed_source_groups"] == 0
    assert result["paired_interval_seconds"] == [0.0, 0.0]
    assert result["benefit_supported"] is False
    assert summary["selected_schedule"] is None
    assert "甲" not in json.dumps(summary)
    assert "stable_text" in sink_calls


def test_one_failed_source_of_24_retains_denominator_even_with_finite_p95():
    from meeting_abba import AbbaLedger

    # Build the same frozen joint policy bindings for the larger source pool.
    args = joint_arguments()
    template = arguments(groups=24, conditions=("warm",))
    for source in template["sources"]:
        source["samples"] = 16000
    from meeting_latency_cohort import finish_configuration

    policies = {}
    for source in template["sources"]:
        policies[source["source_group_sha256"]] = {}
        for mode in ("serial", "overlap"):
            value = joint_report({**source, "ordinal": 0, "mode": mode}, 2.0)
            policies[source["source_group_sha256"]][mode] = {
                "pipeline_policy_sha256": value["pipeline_policy_sha256"],
                "pipeline_configuration_sha256": canonical_digest(
                    finish_configuration(value["pipeline_policy"], value["pcm_feed"])
                ),
            }
    template.update(
        joint_policies=policies, joint_comparison_sha256=args["joint_comparison_sha256"]
    )
    ledger = AbbaLedger(**template)
    fill_joint(ledger, lambda row: 4 if row["mode"] == "serial" else 2, fault=("warm", 0))
    result = ledger.summary()["conditions"]["warm"]["joint_finish"]
    assert result["source_groups"] == 24
    assert result["failed_source_groups"] == 1
    assert result["serial_p95_seconds"] == 4.0
    assert result["overlap_p95_seconds"] == 2.0
    assert result["paired_interval_seconds"] is None
    assert result["benefit_supported"] is False
    assert result["absolute_finish_gate"] == {"serial": "no-go", "overlap": "no-go"}
