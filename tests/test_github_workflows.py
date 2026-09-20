from __future__ import annotations

import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def _workflow(name: str) -> dict[str, object]:
    path = ROOT / ".github" / "workflows" / name
    with path.open(encoding="utf-8") as handle:
        parsed = yaml.load(handle, Loader=yaml.BaseLoader)
    assert isinstance(parsed, dict)
    return parsed


def _jobs(workflow: dict[str, object]) -> dict[str, dict[str, object]]:
    jobs = workflow["jobs"]
    assert isinstance(jobs, dict)
    return jobs


def test_ci_is_reusable_and_keeps_service_and_app_runner_boundaries() -> None:
    workflow = _workflow("ci.yml")
    ci_text = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
    triggers = workflow["on"]
    assert isinstance(triggers, dict)
    assert "workflow_call" in triggers
    assert "pull_request" in triggers
    workflow_call = triggers["workflow_call"]
    assert isinstance(workflow_call, dict)
    assert workflow_call["inputs"]["package-runner"]["default"] == "macos-26"

    jobs = _jobs(workflow)
    assert jobs["test"]["runs-on"] == "${{ matrix.os }}"
    assert jobs["test"]["strategy"]["matrix"]["os"] == ["macos-26"]
    assert jobs["macos-app"]["runs-on"] == "macos-26"
    assert jobs["package"]["needs"] == ["quality", "test"]
    assert "speechrail-${version}-*.whl" in ci_text
    assert "tests/test_diarization_extensions.py" in ci_text
    assert "tests/test_diarization_sdk.py" in ci_text
    assert "tests/test_diarization_contracts.py" not in ci_text
    for relative_path in (
        "tests/test_diarization_extensions.py",
        "tests/test_diarization_sdk.py",
    ):
        assert (ROOT / relative_path).is_file()


def test_release_blocks_publish_until_tag_ci_and_unsigned_dmg_are_verified() -> None:
    workflow = _workflow("release.yml")
    release_text = (ROOT / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
    triggers = workflow["on"]
    assert isinstance(triggers, dict)
    assert "push" in triggers
    assert list(triggers) == ["push"]

    jobs = _jobs(workflow)
    assert jobs["ci"]["uses"] == "./.github/workflows/ci.yml"
    assert jobs["ci"]["with"] == {"package-runner": "macos-26"}
    assert jobs["publish"]["needs"] == ["verify-tag", "ci", "build-app"]
    assert jobs["publish"]["permissions"] == {"contents": "write"}
    assert jobs["build-app"]["runs-on"] == "macos-26"

    build_steps = jobs["build-app"]["steps"]
    build_text = "\n".join(
        step.get("run", "")
        for step in build_steps
        if isinstance(step, dict) and isinstance(step.get("run", ""), str)
    )
    assert "CODE_SIGNING_ALLOWED=NO" in build_text
    assert "scripts/macos_app_create_dmg.sh" in build_text
    assert "speechrail-${version}-*.whl" in release_text


def test_release_does_not_use_unpinned_or_third_party_release_actions() -> None:
    for path in (ROOT / ".github" / "workflows").glob("*.yml"):
        text = path.read_text(encoding="utf-8")
        assert "softprops/action-gh-release" not in text
        for line in text.splitlines():
            if " uses: " in line:
                reference = line.split("uses:", 1)[1].strip().split()[0]
                if reference.startswith("./"):
                    continue
                assert "@" in reference
                pinned_sha = reference.rsplit("@", 1)[1]
                assert re.fullmatch(r"[0-9a-f]{40}", pinned_sha)
