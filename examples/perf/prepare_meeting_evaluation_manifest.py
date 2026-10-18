"""Lock declared local source ancestry and artifact bytes without model execution.

This verifies catalog consistency, not the truth of human source declarations.
All manifests stay outside the repository. No audio is decoded or transcribed.
"""

from __future__ import annotations

import argparse
import json
import random
import re
from collections import defaultdict
from collections.abc import Mapping, Sequence
from pathlib import Path, PurePosixPath
from typing import Any

from meeting_evaluation_identity import canonical_digest, file_digest

_REPOSITORY = Path(__file__).resolve().parents[2]
_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z")
_SHA = re.compile(r"[0-9a-f]{64}\Z")
_SPLITS = ("development", "holdout", "diagnostic")
_KINDS = {
    "natural_single",
    "natural_meeting",
    "continuous_excerpt",
    "derived_single_track",
    "derived_mix",
}


def _identifier(value: object) -> str:
    if not isinstance(value, str) or not _ID.fullmatch(value):
        raise ValueError("invalid anonymous catalog identifier")
    return value


def _digest(value: object) -> str:
    if not isinstance(value, str) or not _SHA.fullmatch(value):
        raise ValueError("invalid artifact or source digest")
    return value


def _external(path: Path) -> Path:
    path = path.expanduser().resolve()
    if path.is_relative_to(_REPOSITORY):
        raise ValueError("evaluation files must remain outside the repository")
    return path


def _artifact(value: Mapping[str, Any], root: Path, *, sidecar: bool) -> dict[str, Any]:
    expected = {"path", "sha256"}
    if sidecar:
        expected |= {"producer_identity_sha256", "timing_evidence_sha256"}
    if set(value) != expected:
        raise ValueError("artifact descriptor fields differ from schema")
    name = value["path"]
    if (
        not isinstance(name, str)
        or not name
        or "\\" in name
        or PurePosixPath(name).is_absolute()
        or ".." in PurePosixPath(name).parts
    ):
        raise ValueError("artifact path must be relative and confined")
    path = root / name
    if not path.resolve().is_relative_to(root) or any(
        p.is_symlink() for p in (path, *path.parents) if p != root
    ):
        raise ValueError("artifact path must not escape or use symlinks")
    if not path.is_file() or file_digest(path) != _digest(value["sha256"]):
        raise ValueError("artifact bytes differ from catalog")
    for key in expected - {"path"}:
        _digest(value[key])
    return dict(value)


def build_manifests(
    catalog: Mapping[str, Any],
    *,
    artifact_root: Path,
    scorer_policy: Mapping[str, Any],
    required_strata: Sequence[int] = (1, 2, 3, 4),
) -> dict[str, Any]:
    """Produce deterministic manifests; insufficient sources never imply readiness."""
    root = _external(artifact_root)
    if (
        set(catalog) != {"schema_version", "independence_level", "sources", "fixtures"}
        or type(catalog.get("schema_version")) is not int
        or catalog["schema_version"] != 2
        or catalog.get("independence_level") not in {"meeting-disjoint", "speaker-disjoint"}
    ):
        raise ValueError("catalog schema or independence level invalid")
    strata = list(required_strata)
    if (
        not strata
        or any(type(count) is not int for count in strata)
        or strata != list(range(1, len(strata) + 1))
        or len(strata) > 8
    ):
        raise ValueError("required strata must be a continuous range starting at one")
    sources, fixtures = catalog.get("sources"), catalog.get("fixtures")
    if (
        not isinstance(sources, dict)
        or not sources
        or len(sources) > 4096
        or not isinstance(fixtures, list)
        or len(fixtures) > 4096
    ):
        raise ValueError("catalog source or fixture bounds invalid")
    parents: dict[str, str] = {}
    for name, source in sources.items():
        _identifier(name)
        if not isinstance(source, dict) or set(source) != {
            "dataset",
            "partition",
            "recording_sha256",
            "derived_from",
            "global_speaker_ids",
        }:
            raise ValueError("source descriptor fields differ from schema")
        _identifier(source["dataset"])
        _identifier(source["partition"])
        _digest(source["recording_sha256"])
        declared_parents, people = source["derived_from"], source["global_speaker_ids"]
        if (
            not isinstance(declared_parents, list)
            or len(set(declared_parents)) != len(declared_parents)
            or any(a not in sources for a in declared_parents)
            or not isinstance(people, list)
            or len(set(people)) != len(people)
        ):
            raise ValueError("invalid source ancestry or global identity declarations")
        for person in people:
            _digest(person)
        parents[name] = name

    def find(name: str) -> str:
        while parents[name] != name:
            name = parents[name]
        return name

    def union(a: str, b: str) -> None:
        a, b = sorted((find(a), find(b)))
        parents[b] = a

    ancestry: dict[str, set[str]] = {}

    def ancestors(name: str, visiting: set[str]) -> set[str]:
        if name in visiting or len(visiting) >= 64:
            raise ValueError("source ancestry cycle or depth limit")
        if name not in ancestry:
            result: set[str] = set()
            for parent in sources[name]["derived_from"]:
                result.add(parent)
                result.update(ancestors(parent, visiting | {name}))
                union(name, parent)
            ancestry[name] = result
        return ancestry[name]

    recordings: dict[str, str] = {}
    person_sources: dict[str, str] = {}
    for name, source in sources.items():
        ancestors(name, set())
        for registry, keys in (
            (recordings, [source["recording_sha256"]]),
            (person_sources, source["global_speaker_ids"]),
        ):
            for key in keys:
                if key in registry:
                    union(name, registry[key])
                registry[key] = name
    components: defaultdict[str, list[str]] = defaultdict(list)
    for name in sources:
        components[find(name)].append(name)
    source_groups = {
        name: canonical_digest({"sources": sorted(components[find(name)])}) for name in sources
    }
    reserved_groups = {
        source_groups[name]
        for name, source in sources.items()
        if source["partition"].casefold() in {"test", "eval_ali", "r004", "holdout"}
        or source["dataset"].casefold().replace("-", "_") == "eval_ali"
        or "r004" in name.casefold()
    }
    policy_hash = canonical_digest(scorer_policy)
    source_hash = canonical_digest(sources)
    manifests = {
        split: {
            "schema_version": 2,
            "split": split,
            "fixtures": [],
            "independence_level": catalog["independence_level"],
            "source_catalog_sha256": source_hash,
            "scorer_policy_sha256": policy_hash,
        }
        for split in _SPLITS
    }
    seen_ids: set[str] = set()
    group_splits: dict[str, set[str]] = {}
    pcm_splits: dict[str, tuple[str, str]] = {}
    for fixture in fixtures:
        if not isinstance(fixture, dict) or set(fixture) != {
            "id",
            "source_meeting_id",
            "derived_from",
            "channel",
            "split",
            "sample_kind",
            "scene",
            "speakers_count",
            "transform",
            "reference_label_policy",
            "artifacts",
        }:
            raise ValueError("fixture fields differ from schema")
        identifier = _identifier(fixture["id"])
        source = fixture["source_meeting_id"]
        if identifier in seen_ids or source not in sources:
            raise ValueError("duplicate fixture or unknown source")
        seen_ids.add(identifier)
        if fixture["derived_from"] != sorted(ancestry[source]):
            raise ValueError("fixture ancestry must declare all source ancestors")
        split, kind, count = fixture["split"], fixture["sample_kind"], fixture["speakers_count"]
        if (
            split not in _SPLITS
            or kind not in _KINDS
            or fixture["scene"] not in {"near", "far"}
            or type(count) is not int
            or not 1 <= count <= 8
            or type(fixture["channel"]) is not int
            or fixture["channel"] < 0
        ):
            raise ValueError("invalid fixture stratum, channel or scene")
        if (kind == "natural_single" and count != 1) or (kind == "natural_meeting" and count == 1):
            raise ValueError("natural sample kind and speaker count differ")
        if (kind.startswith("derived_") or (kind == "continuous_excerpt" and count == 1)) and (
            split != "diagnostic"
        ):
            raise ValueError("derived samples must remain diagnostic")
        for key in ("transform", "reference_label_policy"):
            if not isinstance(fixture[key], dict) or not fixture[key]:
                raise ValueError("processing and reference policies must be explicit")
        group = source_groups[source]
        if split != "holdout" and group in reserved_groups:
            raise ValueError("reserved source cannot enter development or diagnostic")
        previous = group_splits.setdefault(group, set())
        if previous and (split == "holdout") != ("holdout" in previous):
            raise ValueError("source, ancestor or global person crosses split")
        previous.add(split)
        if catalog["independence_level"] == "speaker-disjoint" and any(
            not sources[s]["global_speaker_ids"] for s in components[find(source)]
        ):
            raise ValueError("global identity evidence is incomplete")
        artifacts = fixture["artifacts"]
        if (
            not isinstance(artifacts, dict)
            or not {"pcm", "activity_reference", "text_reference"} <= set(artifacts)
            or set(artifacts) - {"pcm", "activity_reference", "text_reference", "asr_sidecar"}
        ):
            raise ValueError("required artifact reference is missing")
        checked = {k: _artifact(v, root, sidecar=k == "asr_sidecar") for k, v in artifacts.items()}
        pcm = checked["pcm"]["sha256"]
        if pcm in pcm_splits:
            prior_split, prior_group = pcm_splits[pcm]
            if (prior_split == "holdout") != (split == "holdout"):
                raise ValueError("identical PCM crosses split")
            if prior_group != group:
                raise ValueError("identical PCM must share a declared source group")
        pcm_splits[pcm] = (split, group)
        manifests[split]["fixtures"].append(
            {**fixture, "source_group_id": group, "artifacts": checked}
        )
    coverage = {}
    for manifest in manifests.values():
        manifest["fixtures"].sort(key=lambda row: row["id"])
        manifest["group_order"] = {}
        for count in strata:
            groups = sorted(
                {r["source_group_id"] for r in manifest["fixtures"] if r["speakers_count"] == count}
            )
            random.Random(1717).shuffle(groups)
            manifest["group_order"][str(count)] = groups
    for count in strata:
        dev = len(manifests["development"]["group_order"][str(count)])
        holdout = len(manifests["holdout"]["group_order"][str(count)])
        coverage[str(count)] = {
            "development_groups": dev,
            "holdout_groups": holdout,
            "required_holdout_pool": max(12, 2 * (min(dev, 24) // 6 * 6)),
        }
    lock = {
        "schema_version": 2,
        "seed": 1717,
        "scorer_policy_sha256": policy_hash,
        "source_catalog_sha256": source_hash,
        "required_strata": strata,
        "coverage": coverage,
        **{
            f"{split}_manifest_sha256": canonical_digest(manifest)
            for split, manifest in manifests.items()
        },
        "readiness": "source_pool_locked"
        if all(
            c["development_groups"] >= 6 and c["holdout_groups"] >= c["required_holdout_pool"]
            for c in coverage.values()
        )
        else "insufficient_sources",
        "provenance": "declared_catalog_consistency_and_local_artifact_hashes",
        "certified_max_speakers": None,
    }
    # Validate every nested policy value before returning references to input.
    result_copy: dict[str, Any] = json.loads(
        json.dumps({**manifests, "split_lock": lock}, allow_nan=False)
    )
    return result_copy


def prepare(catalog_path: Path, output_directory: Path) -> dict[str, Any]:
    catalog_path, output = _external(catalog_path), _external(output_directory)
    if catalog_path.stat().st_size > 16 * 1024 * 1024:
        raise ValueError("catalog exceeds size bound")
    policy = json.loads((Path(__file__).with_name("meeting-evaluation-policy.json")).read_text())
    result = build_manifests(
        json.loads(catalog_path.read_text()),
        artifact_root=catalog_path.parent,
        scorer_policy=policy,
    )
    output.mkdir(parents=True, exist_ok=False)
    for name in (*_SPLITS, "split_lock"):
        filename = "split-lock.json" if name == "split_lock" else name + ".json"
        with (output / filename).open("x", encoding="utf-8") as handle:
            json.dump(result[name], handle, sort_keys=True, ensure_ascii=False, allow_nan=False)
            handle.write("\n")
    lock: dict[str, Any] = result["split_lock"]
    return lock


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = prepare(args.catalog, args.output_dir)
    except ValueError, OSError, TypeError, KeyError:
        parser.exit(2, "evaluation catalog validation or exclusive output creation failed\n")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
