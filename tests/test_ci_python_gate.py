from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci_python_gate.sh"


@pytest.mark.parametrize("failure", ["none", "build", "suite", "wheel"])
def test_gate_builds_once_and_propagates_each_failure(tmp_path: Path, failure: str) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    uv = bin_dir / "uv"
    uv.write_text(
        """#!/usr/bin/env python3
import json, os, pathlib, sys, time
args = sys.argv[1:]
phase = 'build' if args[0] == 'build' else (
    'wheel' if 'tests/test_wheel_contents.py' in args else 'suite')
with open('calls.jsonl', 'a') as stream:
    stream.write(json.dumps({'phase': phase, 'args': args,
                            'wheel': os.getenv('SPEECHRAIL_WHEEL_PATH')}) + '\\n')
if phase == 'build':
    deadline = time.monotonic() + 5
    while not pathlib.Path('suite.started').exists():
        if time.monotonic() > deadline: sys.exit(99)
        time.sleep(0.01)
    if os.getenv('FAIL_PHASE') != 'build':
        pathlib.Path('dist/speechrail-test.whl').write_bytes(b'wheel')
elif phase == 'suite':
    pathlib.Path('suite.started').touch()
else:
    wheel = pathlib.Path(os.environ['SPEECHRAIL_WHEEL_PATH'])
    assert wheel.is_file() and wheel.read_bytes() == b'wheel'
sys.exit(1 if phase == os.getenv('FAIL_PHASE') else 0)
""",
        encoding="utf-8",
    )
    uv.chmod(0o755)
    output = tmp_path / "github.env"
    result = subprocess.run(
        ["bash", str(SCRIPT)],
        cwd=tmp_path,
        env={
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "RUNNER_TEMP": str(tmp_path),
            "GITHUB_ENV": str(output),
            "FAIL_PHASE": failure,
        },
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert (result.returncode == 0) == (failure == "none"), result.stderr
    calls = [json.loads(line) for line in (tmp_path / "calls.jsonl").read_text().splitlines()]
    assert sum(call["phase"] == "build" for call in calls) == 1
    suite = next(call for call in calls if call["phase"] == "suite")
    assert "--no-sync" in suite["args"]
    assert "--ignore=tests/test_wheel_contents.py" in suite["args"]
    assert "--cov-fail-under=0" in suite["args"]
    assert "--cov-report=" in suite["args"]
    if failure == "build":
        assert not any(call["phase"] == "wheel" for call in calls)
    else:
        wheel = next(call for call in calls if call["phase"] == "wheel")
        assert "--cov-append" in wheel["args"]
        assert "--cov-fail-under=80" in wheel["args"]
        assert calls.index(wheel) > calls.index(suite)
    assert output.exists() == (failure == "none")
