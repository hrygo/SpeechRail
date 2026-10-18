"""Only paired common prefixes may advance a finite development comparison."""

from __future__ import annotations

import copy
import hashlib

import pytest
from meeting_candidate_schedule import CommonPrefixSchedule


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def schedule(groups=24, speakers=2):
    candidates = {
        name: digest(name) for name in ("C0", "C1", "C2") if speakers <= 4 or name != "C0"
    }
    return CommonPrefixSchedule(
        speakers,
        candidates,
        [digest(str(i)) for i in range(groups)],
        manifest_sha256=digest("manifest"),
        scorer_policy_sha256=digest("policy"),
    )


def evidence(item, decisions=None):
    decisions = decisions or {}
    request = item.request()
    return {
        name: {
            "candidate_sha256": item.candidate_ids[name],
            "source_group_ids": request["source_group_ids"],
            "product_decision": decisions.get(name, "pass"),
            "nondegradation_decision": "pass"
            if item.speakers_count <= 4 and name != "C0"
            else None,
        }
        for name in request["candidates"]
    }


def test_initial_six_and_common_expansion_include_c0_and_all_survivors():
    item = schedule()
    assert item.request()["checkpoint"] == 6
    first = item.record(evidence(item, {"C1": "insufficient_evidence"}))
    assert item.request()["checkpoint"] == 6
    assert first.request()["checkpoint"] == 12
    assert first.request()["candidates"] == ["C0", "C1", "C2"]
    assert first.request()["source_group_ids"][:6] == item.request()["source_group_ids"]
    assert first.record(evidence(first)).request()["status"] == "passed"


def test_point_failure_is_eliminated_not_resurrected_by_another_expansion():
    item = schedule()
    next_item = item.record(evidence(item, {"C1": "point_failed", "C2": "insufficient_evidence"}))
    assert next_item.request()["candidates"] == ["C0", "C2"]
    assert next_item.request()["eliminated"] == ["C1"]
    wrong = evidence(next_item)
    wrong["C1"] = evidence(item)["C1"]
    with pytest.raises(ValueError, match="candidate"):
        next_item.record(wrong)
    done = next_item.record(evidence(next_item))
    assert done.request()["eligible_candidates"] == ["C2"]


def test_c0_absolute_failure_does_not_remove_control_or_disqualify_other_candidates():
    item = schedule()
    done = item.record(evidence(item, {"C0": "point_failed"}))
    assert done.request()["status"] == "passed"
    assert done.request()["eligible_candidates"] == ["C1", "C2"]


def test_nondegradation_point_and_interval_failures_have_distinct_actions():
    item = schedule()
    results = evidence(item)
    results["C1"]["nondegradation_decision"] = "point_failed"
    results["C2"]["nondegradation_decision"] = "insufficient_evidence"
    next_item = item.record(results)
    assert next_item.request()["checkpoint"] == 12
    assert next_item.request()["eliminated"] == ["C1"]


@pytest.mark.parametrize(
    "change", ["identity", "missing_group", "extra_group", "wrong_order", "missing_candidate"]
)
def test_mismatched_or_unpaired_evidence_is_rejected(change):
    item = schedule()
    results = evidence(item)
    if change == "identity":
        results["C1"]["candidate_sha256"] = digest("other")
    elif change == "missing_group":
        results["C1"]["source_group_ids"] = results["C1"]["source_group_ids"][:-1]
    elif change == "extra_group":
        results["C1"]["source_group_ids"] = [*results["C1"]["source_group_ids"], digest("extra")]
    elif change == "wrong_order":
        results["C1"]["source_group_ids"] = list(reversed(results["C1"]["source_group_ids"]))
    else:
        del results["C2"]
    with pytest.raises(ValueError):
        item.record(results)


def test_only_six_twelve_eighteen_twentyfour_are_allowed_and_stop_at_cap():
    item = schedule()
    for expected in (6, 12, 18, 24):
        assert item.request()["checkpoint"] == expected
        item = item.record(evidence(item, {"C1": "insufficient_evidence"}))
    assert item.request()["status"] == "evidence_exhausted"
    assert item.request()["eligible_candidates"] == ["C2"]
    with pytest.raises(ValueError, match="terminal"):
        item.record({})


def test_incomplete_execution_stops_instead_of_expanding_or_dropping_failed_groups():
    item = schedule()
    stopped = item.record(evidence(item, {"C1": "not_observed"}))
    assert stopped.request()["status"] == "incomplete"
    assert stopped.request()["eligible_candidates"] == []
    assert stopped.request()["checkpoint"] == 6
    with pytest.raises(ValueError, match="terminal"):
        stopped.record(evidence(item))


def test_lack_of_next_common_prefix_stops_without_using_a_partial_checkpoint():
    item = schedule(groups=7)
    stopped = item.record(evidence(item, {"C1": "insufficient_evidence"}))
    assert stopped.request()["status"] == "insufficient_sources"
    assert stopped.request()["checkpoint"] == 6
    assert schedule(groups=5).request()["status"] == "insufficient_sources"


def test_all_point_failures_stop_without_running_c0_alone():
    item = schedule()
    done = item.record(evidence(item, {"C1": "point_failed", "C2": "point_failed"}))
    assert done.request()["status"] == "no_candidate"
    assert done.request()["eligible_candidates"] == []


def test_more_than_four_speakers_does_not_use_four_slot_control_or_invent_nondegradation():
    item = schedule(speakers=5)
    assert item.request()["candidates"] == ["C1", "C2"]
    results = evidence(item)
    results["C1"]["nondegradation_decision"] = "pass"
    with pytest.raises(ValueError, match="nondegradation"):
        item.record(results)
    assert item.record(evidence(item)).request()["status"] == "passed"


def test_inputs_and_evidence_are_snapshotted_and_resume_replays_validation():
    item = schedule()
    results = evidence(item, {"C1": "insufficient_evidence"})
    next_item = item.record(results)
    results["C1"]["product_decision"] = "pass"
    saved = next_item.as_dict()
    assert CommonPrefixSchedule.restore(saved, expected=item).as_dict() == saved
    corrupt = copy.deepcopy(saved)
    corrupt["rounds"][0]["C1"]["source_group_ids"] = []
    with pytest.raises(ValueError):
        CommonPrefixSchedule.restore(corrupt, expected=item)
    assert next_item.request()["checkpoint"] == 12


def test_selection_requires_one_candidate_to_pass_every_continuous_stratum():
    from meeting_candidate_schedule import eligible_across_strata

    first, second = schedule(speakers=1), schedule(speakers=2)
    a = first.record(evidence(first, {"C1": "point_failed"}))
    b = second.record(evidence(second, {"C2": "point_failed"}))
    assert eligible_across_strata({1: a, 2: b}, required_max=2) == []
    assert eligible_across_strata({1: a, 2: second}, required_max=2) == []
    b = second.record(evidence(second))
    assert eligible_across_strata({1: a, 2: b}, required_max=2) == ["C2"]
    with pytest.raises(ValueError, match="stratum"):
        eligible_across_strata({1: a, 3: b}, required_max=3)


def test_restore_and_selection_reject_changed_lock_or_candidate_bytes():
    from meeting_candidate_schedule import eligible_across_strata

    item = schedule()
    saved = item.record(evidence(item)).as_dict()
    for field in ("manifest_sha256", "scorer_policy_sha256"):
        corrupt = copy.deepcopy(saved)
        corrupt[field] = digest("other")
        with pytest.raises(ValueError, match="lock"):
            CommonPrefixSchedule.restore(corrupt, expected=item)
    corrupt = copy.deepcopy(saved)
    corrupt["source_groups"].reverse()
    with pytest.raises(ValueError, match="lock"):
        CommonPrefixSchedule.restore(corrupt, expected=item)
    first = schedule(speakers=1)
    candidate_ids = item.candidate_ids
    candidate_ids["C1"] = digest("changed_worker")
    second = CommonPrefixSchedule(
        2,
        candidate_ids,
        [digest(str(i)) for i in range(24)],
        manifest_sha256=digest("manifest"),
        scorer_policy_sha256=digest("policy"),
    )
    with pytest.raises(ValueError, match="identities"):
        eligible_across_strata({1: first, 2: second}, required_max=2)
