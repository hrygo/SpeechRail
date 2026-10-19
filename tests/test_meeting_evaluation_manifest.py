"""Declared source ancestry is locked before any candidate produces output."""

from __future__ import annotations

import copy
import hashlib
import json

import pytest
from prepare_meeting_evaluation_manifest import build_manifests, prepare


def catalog(tmp_path):
    sources, fixtures = {}, []
    for i, split in enumerate(("development", "holdout")):
        identifier = f"M{i}"
        sources[identifier] = {
            "dataset": "fixture",
            "partition": "train",
            "recording_sha256": hashlib.sha256(identifier.encode()).hexdigest(),
            "derived_from": [],
            "global_speaker_ids": [],
        }
        artifacts = {}
        for kind in ("pcm", "activity_reference", "text_reference"):
            path = tmp_path / f"{identifier}.{kind}"
            path.write_bytes(f"synthetic-{identifier}-{kind}".encode())
            artifacts[kind] = {
                "path": path.name,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            }
        fixtures.append(
            {
                "id": identifier,
                "source_meeting_id": identifier,
                "derived_from": [],
                "channel": 0,
                "split": split,
                "sample_kind": "natural_single",
                "scene": "near",
                "speakers_count": 1,
                "transform": {"kind": "identity"},
                "reference_label_policy": {"version": "human-v1", "timing": "utterance"},
                "artifacts": artifacts,
            }
        )
    return {
        "schema_version": 2,
        "independence_level": "meeting-disjoint",
        "sources": sources,
        "fixtures": fixtures,
    }


def build(value, tmp_path):
    return build_manifests(
        value,
        artifact_root=tmp_path,
        scorer_policy={"version": "fake-v1"},
        required_strata=(1, 2, 3, 4),
    )


def test_missing_strata_and_small_source_pool_never_certify(tmp_path):
    result = build(catalog(tmp_path), tmp_path)
    assert result["split_lock"]["readiness"] == "insufficient_sources"
    assert result["split_lock"]["certified_max_speakers"] is None
    assert result["split_lock"]["coverage"]["2"]["development_groups"] == 0
    assert result["development"]["independence_level"] == "meeting-disjoint"


@pytest.mark.parametrize("change", ["channel", "window", "ancestor", "content"])
def test_aliases_and_derived_recordings_cannot_cross_splits(tmp_path, change):
    value = catalog(tmp_path)
    if change in ("channel", "window"):
        value["fixtures"][1]["source_meeting_id"] = "M0"
        value["fixtures"][1]["channel"] = 1 if change == "channel" else 0
    elif change == "ancestor":
        value["sources"]["M1"]["derived_from"] = ["M0"]
        value["fixtures"][1]["derived_from"] = ["M0"]
    else:
        value["sources"]["M1"]["recording_sha256"] = value["sources"]["M0"]["recording_sha256"]
    with pytest.raises(ValueError, match=r"cross.*split"):
        build(value, tmp_path)


@pytest.mark.parametrize("partition", ["test", "Eval_Ali", "R004"])
def test_reserved_sources_and_their_derivatives_cannot_enter_development(tmp_path, partition):
    value = catalog(tmp_path)
    value["sources"]["M0"]["partition"] = partition
    with pytest.raises(ValueError, match="reserved"):
        build(value, tmp_path)


def test_known_global_person_overlap_is_rejected_without_claiming_full_person_disjointness(
    tmp_path,
):
    value = catalog(tmp_path)
    for source in value["sources"].values():
        source["global_speaker_ids"] = ["a" * 64]
    with pytest.raises(ValueError, match=r"cross.*split"):
        build(value, tmp_path)
    value = catalog(tmp_path)
    value["independence_level"] = "speaker-disjoint"
    with pytest.raises(ValueError, match="global"):
        build(value, tmp_path)


def test_derived_single_track_is_diagnostic_and_not_natural_single_evidence(tmp_path):
    value = catalog(tmp_path)
    value["fixtures"][0]["sample_kind"] = "derived_single_track"
    with pytest.raises(ValueError, match="diagnostic"):
        build(value, tmp_path)
    value["fixtures"][0]["split"] = "diagnostic"
    result = build(value, tmp_path)
    assert result["development"]["fixtures"] == []
    assert result["diagnostic"]["fixtures"][0]["sample_kind"] == "derived_single_track"
    assert result["split_lock"]["coverage"]["1"]["development_groups"] == 0


@pytest.mark.parametrize("change", ["reference_policy", "scorer_policy", "channel", "transform"])
def test_effective_reference_and_processing_changes_change_lock(tmp_path, change):
    value = catalog(tmp_path)
    before = build(value, tmp_path)["split_lock"]
    if change == "reference_policy":
        value["fixtures"][0]["reference_label_policy"]["version"] = "human-v2"
    elif change == "channel":
        value["fixtures"][0]["channel"] = 1
    elif change == "transform":
        value["fixtures"][0]["transform"] = {"kind": "excerpt", "start_sample": 160}
    else:
        after = build_manifests(value, artifact_root=tmp_path, scorer_policy={"version": "fake-v2"})
        assert after["split_lock"]["scorer_policy_sha256"] != before["scorer_policy_sha256"]
        return
    assert (
        build(value, tmp_path)["split_lock"]["development_manifest_sha256"]
        != before["development_manifest_sha256"]
    )


def test_changed_artifact_and_escaping_path_fail_before_lock(tmp_path):
    value = catalog(tmp_path)
    value["fixtures"][0]["artifacts"]["pcm"]["sha256"] = "0" * 64
    with pytest.raises(ValueError, match="artifact"):
        build(value, tmp_path)
    value = catalog(tmp_path)
    value["fixtures"][0]["artifacts"]["pcm"]["path"] = "../outside"
    with pytest.raises(ValueError, match="path"):
        build(value, tmp_path)


def test_source_cycles_and_incomplete_ancestry_are_rejected(tmp_path):
    value = catalog(tmp_path)
    value["sources"]["M0"]["derived_from"] = ["M1"]
    with pytest.raises(ValueError, match="ancestry"):
        build(value, tmp_path)
    value["sources"]["M1"]["derived_from"] = ["M0"]
    with pytest.raises(ValueError, match="cycle"):
        build(value, tmp_path)


def test_fixture_reordering_does_not_change_identity_or_group_order(tmp_path):
    value = catalog(tmp_path)
    first = build(value, tmp_path)
    value["fixtures"].reverse()
    assert build(value, tmp_path) == first


def test_output_is_external_exclusive_and_contains_no_absolute_paths(tmp_path):
    value = catalog(tmp_path)
    source = tmp_path / "catalog.json"
    source.write_text(json.dumps(value))
    output = tmp_path / "locked"
    result = prepare(source, output)
    assert result["certified_max_speakers"] is None
    assert str(tmp_path) not in (output / "development.json").read_text()
    with pytest.raises(FileExistsError):
        prepare(source, output)


def test_identical_pcm_cannot_inflate_independent_groups_with_new_source_ids(tmp_path):
    value = catalog(tmp_path)
    second = copy.deepcopy(value["fixtures"][0])
    second.update(id="alias", source_meeting_id="alias")
    value["sources"]["alias"] = copy.deepcopy(value["sources"]["M1"])
    value["fixtures"] = [value["fixtures"][0], second]
    with pytest.raises(ValueError, match="PCM"):
        build(value, tmp_path)


def test_reserved_dataset_and_recording_marker_propagate_to_descendants(tmp_path):
    value = catalog(tmp_path)
    value["sources"]["M0"]["dataset"] = "Eval_Ali"
    with pytest.raises(ValueError, match="reserved"):
        build(value, tmp_path)
    value = catalog(tmp_path)
    value["sources"]["20200622_M_R004S01C01"] = value["sources"].pop("M0")
    value["fixtures"][0]["source_meeting_id"] = "20200622_M_R004S01C01"
    with pytest.raises(ValueError, match="reserved"):
        build(value, tmp_path)


def test_diagnostic_view_of_development_source_is_not_a_holdout_leak(tmp_path):
    value = catalog(tmp_path)
    derived = copy.deepcopy(value["fixtures"][0])
    derived.update(id="diagnostic", split="diagnostic", sample_kind="derived_single_track")
    value["fixtures"].append(derived)
    result = build(value, tmp_path)
    assert result["split_lock"]["coverage"]["1"]["development_groups"] == 1
    assert len(result["diagnostic"]["fixtures"]) == 1
    value["fixtures"][0]["split"] = "holdout"
    with pytest.raises(ValueError, match=r"cross.*split"):
        build(value, tmp_path)


@pytest.mark.parametrize("development_count", [6, 7])
def test_locked_pool_has_required_independent_groups_but_never_certifies(
    tmp_path, development_count
):
    value = catalog(tmp_path)
    template = copy.deepcopy(value["fixtures"][0])
    source_template = copy.deepcopy(value["sources"]["M0"])
    value["sources"], value["fixtures"] = {}, []
    for split, count in (("development", development_count), ("holdout", 12)):
        for i in range(count):
            name = f"{split}{i}"
            source = copy.deepcopy(source_template)
            source["recording_sha256"] = hashlib.sha256(name.encode()).hexdigest()
            value["sources"][name] = source
            fixture = copy.deepcopy(template)
            fixture.update(id=name, source_meeting_id=name, split=split)
            path = tmp_path / f"{name}.pcm"
            path.write_bytes(name.encode())
            fixture["artifacts"]["pcm"] = {
                "path": path.name,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            }
            value["fixtures"].append(fixture)
    result = build_manifests(
        value, artifact_root=tmp_path, scorer_policy={"version": "fake-v1"}, required_strata=(1,)
    )
    assert result["split_lock"]["readiness"] == "source_pool_locked"
    assert result["split_lock"]["certified_max_speakers"] is None
    assert result["split_lock"]["coverage"]["1"] == {
        "development_groups": development_count,
        "holdout_groups": 12,
        "required_holdout_pool": 12,
    }
    value["fixtures"].reverse()
    assert (
        build_manifests(
            value,
            artifact_root=tmp_path,
            scorer_policy={"version": "fake-v1"},
            required_strata=(1,),
        )
        == result
    )


def test_artifact_symlinks_and_repository_artifacts_are_rejected(tmp_path):
    value = catalog(tmp_path)
    descriptor = value["fixtures"][0]["artifacts"]["pcm"]
    link = tmp_path / "alias.pcm"
    link.symlink_to(tmp_path / descriptor["path"])
    descriptor["path"] = link.name
    with pytest.raises(ValueError, match="path"):
        build(value, tmp_path)
    from pathlib import Path

    with pytest.raises(ValueError, match="outside"):
        build_manifests(value, artifact_root=Path(__file__).resolve().parents[1], scorer_policy={})


def test_cli_validation_error_does_not_print_private_catalog_paths(tmp_path):
    import subprocess
    import sys
    from pathlib import Path

    script = (
        Path(__file__).resolve().parents[1] / "examples/perf/prepare_meeting_evaluation_manifest.py"
    )
    result = subprocess.run(
        [
            sys.executable,
            str(script),
            "--catalog",
            str(tmp_path / "missing.json"),
            "--output-dir",
            str(tmp_path / "output"),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 2
    assert str(tmp_path) not in result.stderr
    assert "failed" in result.stderr
