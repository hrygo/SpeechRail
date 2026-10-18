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
