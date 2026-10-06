from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

import pytest
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
    # The gate switches must default to "auto": `inputs` is null for
    # push/pull_request, so an empty value would be read as an explicit
    # override and silently skip every gate.
    assert workflow_call["inputs"]["run-python"]["default"] == "auto"
    assert workflow_call["inputs"]["run-swift"]["default"] == "auto"

    jobs = _jobs(workflow)
    assert jobs["test"]["runs-on"] == "${{ matrix.os }}"
    assert jobs["test"]["strategy"]["matrix"]["os"] == ["macos-26"]
    assert jobs["macos-app"]["runs-on"] == "macos-26"
    assert jobs["swift-tests"]["runs-on"] == "macos-26"
    # The heavy gates hang off change-scope; `package` follows `test` so a
    # skipped Python gate skips the wheel rather than publishing an untested one.
    assert jobs["test"]["needs"] == ["change-scope"]
    assert jobs["macos-app"]["needs"] == ["change-scope"]
    assert jobs["swift-tests"]["needs"] == ["change-scope"]
    assert jobs["test"]["if"] == "${{ needs.change-scope.outputs.run_python == 'true' }}"
    assert (
        jobs["macos-app"]["if"]
        == "${{ needs.change-scope.outputs.run_swift == 'true' }}"
    )
    assert jobs["package"]["needs"] == ["change-scope", "quality", "test"]
    assert "speechrail-*.whl" in ci_text
    assert "speechrail-wheel-candidate" in ci_text
    assert "tests/test_diarization_extensions.py" in ci_text
    assert "tests/test_diarization_sdk.py" in ci_text
    assert "tests/test_diarization_contracts.py" not in ci_text
    for relative_path in (
        "tests/test_diarization_extensions.py",
        "tests/test_diarization_sdk.py",
    ):
        assert (ROOT / relative_path).is_file()


def test_ci_reuses_the_tested_wheel_artifact_in_the_package_job() -> None:
    workflow = _workflow("ci.yml")
    ci_text = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
    jobs = _jobs(workflow)

    test_steps = jobs["test"]["steps"]
    package_steps = jobs["package"]["steps"]
    assert isinstance(test_steps, list)
    assert isinstance(package_steps, list)
    test_run_text = "\n".join(
        step.get("run", "")
        for step in test_steps
        if isinstance(step, dict) and isinstance(step.get("run", ""), str)
    )
    package_run_text = "\n".join(
        step.get("run", "")
        for step in package_steps
        if isinstance(step, dict) and isinstance(step.get("run", ""), str)
    )

    gate = (ROOT / "scripts/ci_python_gate.sh").read_text()
    assert "bash scripts/ci_python_gate.sh" in test_run_text
    assert "uv build --no-sources --wheel" in gate
    assert "SPEECHRAIL_WHEEL_PATH" in gate
    assert "speechrail-wheel-candidate" in ci_text
    assert any(
        isinstance(step, dict)
        and str(step.get("uses", "")).startswith("actions/upload-artifact@")
        and step.get("with", {}).get("name") == "speechrail-wheel-candidate"
        for step in test_steps
    )
    assert any(
        isinstance(step, dict)
        and str(step.get("uses", "")).startswith("actions/download-artifact@")
        and step.get("with", {}).get("name") == "speechrail-wheel-candidate"
        for step in package_steps
    )
    assert not any(
        isinstance(step, dict)
        and str(step.get("uses", "")).startswith("actions/checkout@")
        for step in package_steps
    )
    assert "uv sync --locked --extra dev --extra mcp" not in package_run_text
    assert "uv build --no-sources --wheel" not in package_run_text
    assert "tests/test_wheel_contents.py" not in package_run_text


def test_ci_overlaps_native_build_without_rebuilding_the_wheel_in_pytest() -> None:
    """Checkout tests overlap the build; wheel tests reuse its successful output."""

    workflow = _workflow("ci.yml")
    jobs = _jobs(workflow)
    test_steps = jobs["test"]["steps"]
    assert isinstance(test_steps, list)

    sync_steps = [
        step
        for step in test_steps
        if isinstance(step, dict) and "uv sync --locked" in str(step.get("run", ""))
    ]
    assert len(sync_steps) == 1
    assert sync_steps[0]["env"]["SPEECHRAIL_SKIP_NATIVE_WORKER_BUILD"] == "1"

    overlap = next(
        step
        for step in test_steps
        if isinstance(step, dict) and step.get("name") == "Build wheel and run test suite"
    )
    assert overlap["run"] == "bash scripts/ci_python_gate.sh"
    script = (ROOT / "scripts/ci_python_gate.sh").read_text()
    # The build is backgrounded and awaited by PID within the same step; each
    # `run:` is a fresh shell, so a PID from an earlier step cannot be waited on.
    assert "uv build --no-sources --wheel" in script
    assert "build_pid=$!" in script
    assert 'wait "$build_pid"' in script
    assert "uv run --no-sync pytest --cov=src" in script
    assert "uv run pytest" not in script
    # A failing suite must not be masked by a successful build, or vice versa.
    assert "suite_status=$?" in script
    assert 'exit "$suite_status"' in script
    assert "--ignore=tests/test_wheel_contents.py" in script
    assert "--cov-append" in script

    # The opt-out must never reach the release wheel, or the published artifact
    # would ship without the worker.
    assert "env -u SPEECHRAIL_SKIP_NATIVE_WORKER_BUILD" in script


@pytest.mark.parametrize(
    ("scope", "python", "swift", "failed_job", "result", "expected"),
    [
        ("full", "true", "true", None, "success", 0),
        ("swift", "false", "true", None, "success", 0),
        ("python", "true", "false", None, "success", 0),
        ("meta", "false", "false", None, "success", 0),
        ("explicit", "true", "false", None, "success", 0),
        ("full", "true", "true", "SWIFT_RESULT", "failure", 1),
        ("swift", "false", "true", "SWIFT_RESULT", "skipped", 1),
        ("swift", "false", "true", "MACOS_RESULT", "skipped", 1),
        ("python", "true", "false", "TEST_RESULT", "skipped", 1),
        ("explicit", "true", "false", "PACKAGE_RESULT", "skipped", 1),
        ("meta", "false", "false", "QUALITY_RESULT", "skipped", 1),
        ("full", "true", "true", "SWIFT_RESULT", "cancelled", 1),
        ("full", "true", "true", "SWIFT_RESULT", "", 1),
    ],
)
def test_summary_requires_every_selected_gate(
    tmp_path: Path,
    scope: str,
    python: str,
    swift: str,
    failed_job: str | None,
    result: str,
    expected: int,
) -> None:
    jobs = _jobs(_workflow("ci.yml"))
    assert "swift-tests" in jobs["gate-summary"]["needs"]
    script = jobs["gate-summary"]["steps"][0]["run"]
    values = {
        "SCOPE": scope,
        "RUN_PYTHON": python,
        "RUN_SWIFT": swift,
        "QUALITY_RESULT": "success",
        "TEST_RESULT": "success" if python == "true" else "skipped",
        "PACKAGE_RESULT": "success" if python == "true" else "skipped",
        "MACOS_RESULT": "success" if swift == "true" else "skipped",
        "SWIFT_RESULT": "success" if swift == "true" else "skipped",
        "GITHUB_STEP_SUMMARY": str(tmp_path / "summary.md"),
    }
    if failed_job:
        values[failed_job] = result
    completed = subprocess.run(
        ["bash", "-c", script],
        env={**os.environ, **values},
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert completed.returncode == expected, completed.stdout + completed.stderr


def test_release_blocks_publish_until_tag_ci_and_unsigned_dmg_are_verified() -> None:
    workflow = _workflow("release.yml")
    release_text = (ROOT / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
    triggers = workflow["on"]
    assert isinstance(triggers, dict)
    assert "push" in triggers
    assert list(triggers) == ["push"]

    jobs = _jobs(workflow)
    assert jobs["ci"]["uses"] == "./.github/workflows/ci.yml"
    # build-app already compiles the App from the tagged commit, so the release
    # must not repeat the Swift gate on a second runner.
    assert jobs["ci"]["with"] == {"package-runner": "macos-26", "run-swift": "false"}
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
