"""Frozen offline ASR comparisons use synthetic reports; no model/audio I/O."""

import asyncio
import json
from copy import deepcopy
from pathlib import Path

import pytest
from meeting_evaluation_identity import canonical_digest

from test_probe_meeting_asr_quality import case, policy, run


def controls(tmp_path):
    def document(name, value):
        path = tmp_path / f"{name}.json"
        path.write_text(json.dumps(value))
        return {"path": str(path), "sha256": canonical_digest(value)}

    old, new = [], []
    cases = []
    for index in range(2):
        data = case(f"source-{index}")
        baseline = run(data)[0]
        candidate = run(data, text="甲乙丙丁")[0]
        old.append(document(f"old-{index}", baseline))
        new.append(document(f"new-{index}", candidate))
        cases.append({**data.identity(), "expected_samples": len(data.pcm16) // 2})
    lock = {
        "schema_version": 1,
        "cases": cases,
        "scorer_policy": document("policy", policy()),
        "baseline": {
            "candidate_sha256": baseline["candidate_sha256"],
            "replay_policy_sha256": baseline["replay_policy_sha256"],
            "mode": baseline["mode"],
            "reports": old,
        },
        "candidate": {
            "candidate_sha256": candidate["candidate_sha256"],
            "replay_policy_sha256": candidate["replay_policy_sha256"],
            "mode": candidate["mode"],
            "reports": new,
        },
        "key_facts_review": "not_observed",
    }
    path = tmp_path / "comparison-lock.json"
    path.write_text(json.dumps(lock))
    return path, lock


def execute(path, tmp_path):
    from meeting_asr_comparison import execute_asr_comparison

    return asyncio.run(
        execute_asr_comparison(comparison_lock=path, output_directory=tmp_path / "output")
    )


def test_offline_comparison_writes_only_anonymous_private_diagnostic(tmp_path):
    path, _ = controls(tmp_path)
    result = execute(path, tmp_path)
    assert result == json.loads((tmp_path / "output" / "comparison.json").read_text())
    assert result["development_text_gate"] == "pass"
    assert result["relative_cer_improvement"] == 1
    assert result["quality_gate"] == "fail"
    assert result["certification_eligible"] is False
    assert result["runtime_identity_verified"] is False
    assert result["verdict"] == "diagnostic"
    assert result["paired_cer"]["groups"] == 2
    assert str(tmp_path) not in json.dumps(result)
    assert (tmp_path / "output").stat().st_mode & 0o777 == 0o700
    assert (tmp_path / "output" / "comparison.json").stat().st_mode & 0o777 == 0o600


@pytest.mark.parametrize(
    "mutation",
    [
        "schema",
        "extra",
        "missing_case",
        "duplicate_case",
        "case_digest",
        "samples",
        "report_digest",
        "arm_identity",
        "mode",
        "relative",
        "symlink",
        "holdout",
        "duplicate_report",
        "self_certified",
        "coverage_bool",
        "manual_review",
    ],
)
def test_frozen_inputs_reject_mismatch_without_completed_report(tmp_path, mutation):
    path, lock = controls(tmp_path)
    if mutation == "schema":
        lock["schema_version"] = True
    elif mutation == "extra":
        lock["trust"] = True
    elif mutation == "missing_case":
        lock["candidate"]["reports"].pop()
    elif mutation == "duplicate_case":
        lock["cases"].append(deepcopy(lock["cases"][0]))
    elif mutation == "case_digest":
        lock["cases"][0]["case_sha256"] = "a" * 64
    elif mutation == "samples":
        lock["cases"][0]["expected_samples"] = True
    elif mutation == "report_digest":
        lock["candidate"]["reports"][0]["sha256"] = "b" * 64
    elif mutation == "arm_identity":
        lock["candidate"]["candidate_sha256"] = "b" * 64
    elif mutation == "mode":
        lock["candidate"]["mode"] = "holdout"
    elif mutation == "relative":
        lock["candidate"]["reports"][0]["path"] = "new-0.json"
    elif mutation == "symlink":
        descriptor = lock["candidate"]["reports"][0]
        link = tmp_path / "linked.json"
        link.symlink_to(descriptor["path"])
        descriptor["path"] = str(link)
    elif mutation in {"holdout", "self_certified", "coverage_bool"}:
        descriptor = lock["candidate"]["reports"][0]
        target = Path(descriptor["path"])
        report = json.loads(target.read_text())
        field = {
            "holdout": "split_role",
            "self_certified": "certification_eligible",
            "coverage_bool": "coverage_samples",
        }[mutation]
        report[field] = "holdout" if mutation == "holdout" else True
        target.write_text(json.dumps(report))
        descriptor["sha256"] = canonical_digest(report)
    elif mutation == "duplicate_report":
        lock["candidate"]["reports"][1] = lock["candidate"]["reports"][0]
    elif mutation == "manual_review":
        lock["key_facts_review"] = "approved"
    path.write_text(json.dumps(lock))
    with pytest.raises(ValueError, match="locked ASR comparison failed"):
        execute(path, tmp_path)
    assert not (tmp_path / "output" / "comparison.json").exists()


def test_input_changed_during_scoring_is_rejected(tmp_path, monkeypatch):
    import meeting_asr_comparison as module

    path, _ = controls(tmp_path)
    original = module.compare_asr_runs

    def changed(*args, **kwargs):
        result = original(*args, **kwargs)
        target = tmp_path / "old-0.json"
        before = target.read_bytes()
        target.write_bytes(before + b" ")
        target.write_bytes(before)
        return result

    monkeypatch.setattr(module, "compare_asr_runs", changed)
    with pytest.raises(ValueError):
        execute(path, tmp_path)
    assert not (tmp_path / "output" / "comparison.json").exists()


def test_partial_changed_after_write_cannot_commit(tmp_path, monkeypatch):
    import meeting_asr_comparison as module

    path, _ = controls(tmp_path)
    original = module._write_json

    def changed(target, report):
        original(target, report)
        if target.name == "comparison.partial.json":
            target.write_text("{}")

    monkeypatch.setattr(module, "_write_json", changed)
    with pytest.raises(ValueError):
        execute(path, tmp_path)
    assert not (tmp_path / "output" / "comparison.json").exists()


def test_cancelled_comparison_joins_scoring_thread_before_return(tmp_path, monkeypatch):
    import threading

    import meeting_asr_comparison as module

    path, _ = controls(tmp_path)
    entered, release, finished = threading.Event(), threading.Event(), threading.Event()
    original = module.compare_asr_runs

    def blocked(*args, **kwargs):
        entered.set()
        assert release.wait(5)
        try:
            return original(*args, **kwargs)
        finally:
            finished.set()

    monkeypatch.setattr(module, "compare_asr_runs", blocked)

    async def exercise():
        task = asyncio.create_task(
            module.execute_asr_comparison(
                comparison_lock=path, output_directory=tmp_path / "output"
            )
        )
        assert await asyncio.to_thread(entered.wait, 5)
        task.cancel()
        await asyncio.sleep(0)
        assert not finished.is_set() and not task.done()
        release.set()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert finished.is_set()

    asyncio.run(exercise())
    assert not (tmp_path / "output" / "comparison.json").exists()
    assert json.loads((tmp_path / "output" / "failure.json").read_text())["status"] == "cancelled"


def test_partial_changed_during_final_verification_is_rejected(tmp_path, monkeypatch):
    import meeting_asr_comparison as module

    path, _ = controls(tmp_path)
    original = module._Controls.verify

    def changed(self):
        original(self)
        partial = tmp_path / "output" / "comparison.partial.json"
        if partial.exists():
            partial.write_text("{}")

    monkeypatch.setattr(module._Controls, "verify", changed)
    with pytest.raises(ValueError):
        execute(path, tmp_path)
    assert not (tmp_path / "output" / "comparison.json").exists()


def test_output_directory_replacement_is_not_used_for_commit_or_failure(tmp_path, monkeypatch):
    import meeting_asr_comparison as module

    path, _ = controls(tmp_path)
    original = module._write_json

    def replaced(target, report):
        original(target, report)
        if target.name == "comparison.partial.json":
            target.parent.rename(tmp_path / "original-output")
            target.parent.mkdir(mode=0o700)
            target.write_text(json.dumps(report))

    monkeypatch.setattr(module, "_write_json", replaced)
    with pytest.raises(ValueError):
        execute(path, tmp_path)
    assert not (tmp_path / "output" / "comparison.json").exists()
    assert not (tmp_path / "output" / "failure.json").exists()
    assert (tmp_path / "original-output" / "comparison.partial.json").exists()


def test_existing_output_is_preserved_and_total_input_budget_is_enforced(tmp_path, monkeypatch):
    import meeting_asr_comparison as module

    path, _ = controls(tmp_path)
    output = tmp_path / "output"
    output.mkdir()
    sentinel = output / "user-data.txt"
    sentinel.write_text("keep")
    with pytest.raises(ValueError):
        execute(path, tmp_path)
    assert sentinel.read_text() == "keep"
    monkeypatch.setattr(module, "_MAX_BYTES", 1)
    with pytest.raises(ValueError):
        execute(path, tmp_path)
    assert sentinel.read_text() == "keep"


def test_offline_comparison_never_opens_audio_or_starts_process(tmp_path, monkeypatch):
    import wave

    path, _ = controls(tmp_path)

    def forbidden(*args, **kwargs):
        pytest.fail("offline comparison must not open audio or launch a process")

    monkeypatch.setattr(wave, "open", forbidden)
    monkeypatch.setattr(asyncio, "create_subprocess_exec", forbidden)
    assert execute(path, tmp_path)["case_count"] == 2


def test_actual_formal_session_diagnostic_report_is_comparable_without_rewriting(tmp_path):
    from meeting_realtime_asr_replay import replay_realtime_session

    from test_meeting_realtime_asr_replay import case as formal_case
    from test_meeting_realtime_asr_replay import observe, setup

    services, _, _, candidate = setup()
    data = formal_case()
    report = asyncio.run(
        replay_realtime_session(data, candidate, services, observe=observe(candidate))
    )
    path, lock = controls(tmp_path)
    report_path = tmp_path / "formal-result.json"
    report_path.write_text(json.dumps(report))
    arm = {
        "candidate_sha256": report["candidate_sha256"],
        "replay_policy_sha256": report["replay_policy_sha256"],
        "mode": report["mode"],
        "reports": [{"path": str(report_path), "sha256": canonical_digest(report)}],
    }
    lock.update(
        cases=[{**data.identity(), "expected_samples": len(data.pcm16) // 2}],
        baseline=arm,
        candidate=deepcopy(arm),
    )
    path.write_text(json.dumps(lock))
    result = execute(path, tmp_path)
    assert result["baseline_macro_cer"] == 0
    assert result["relative_cer_improvement"] is None
    assert result["certification_eligible"] is False
