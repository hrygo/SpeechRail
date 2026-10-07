from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci_quality_gate.sh"


@pytest.mark.parametrize("failure", ["none", "sync", "ruff", "parity", "pytest", "diff"])
def test_quality_gate_stops_on_failure_and_uses_locked_dependencies(
    tmp_path: Path, failure: str
) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    calls_file = tmp_path / "calls.jsonl"
    shim = """#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
tool = pathlib.Path(sys.argv[0]).name
phase = ('sync' if args[0] == 'sync' else
         'ruff' if 'ruff' in args else
         'parity' if 'scripts/check_macos_test_target_coverage.py' in args else
         'pytest' if 'pytest' in args else
         'diff' if tool == 'git' and 'diff' in args else 'other')
with open(os.environ['QUALITY_CALL_LOG'], 'a') as stream:
    stream.write(json.dumps({'tool': tool, 'args': args, 'phase': phase,
                            'skip_native': os.getenv('SPEECHRAIL_SKIP_NATIVE_WORKER_BUILD')})
                 + '\\n')
if phase == os.environ['FAIL_PHASE']:
    sys.exit(17)
"""
    for tool in ("uv", "npx", "git"):
        executable = bin_dir / tool
        executable.write_text(shim, encoding="utf-8")
        executable.chmod(0o755)
    result = subprocess.run(
        ["bash", str(SCRIPT), "--base-ref", "origin/main"],
        cwd=ROOT,
        env={
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "QUALITY_CALL_LOG": str(calls_file),
            "FAIL_PHASE": failure,
        },
        text=True,
        capture_output=True,
        timeout=10,
    )
    calls = [json.loads(line) for line in calls_file.read_text().splitlines()]
    assert result.returncode == (0 if failure == "none" else 17), result.stderr
    sync = next(call for call in calls if call["phase"] == "sync")
    assert "--locked" in sync["args"]
    assert sync["args"].count("--extra") == 2
    assert sync["skip_native"] == "1"
    if failure != "none":
        assert calls[-1]["phase"] == failure
        assert "All quality gates passed" not in result.stdout
    else:
        assert any(call["phase"] == "parity" for call in calls)
        assert any(call["phase"] == "pytest" for call in calls)
        assert any("origin/main...HEAD" in call["args"] for call in calls)
        assert all("--no-sync" in call["args"] for call in calls if call["args"][0] == "run")
        assert "All quality gates passed" in result.stdout


def test_workflow_runs_the_same_quality_entrypoint() -> None:
    workflow = (ROOT / ".github/workflows/ci.yml").read_text()
    quality_job = workflow.split("\n  quality:", 1)[1].split("\n  test:", 1)[0]
    assert "bash scripts/ci_quality_gate.sh" in quality_job
    assert "uv run ruff" not in quality_job
