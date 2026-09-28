from __future__ import annotations

import importlib.util
import io
import sys
from pathlib import Path

import pytest

_SCRIPT_PATH = Path(__file__).resolve().parents[1] / "scripts" / "ci_changed_scope.py"
_SPEC = importlib.util.spec_from_file_location("speechrail_test_ci_scope", _SCRIPT_PATH)
assert _SPEC is not None and _SPEC.loader is not None
_module = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = _module
_SPEC.loader.exec_module(_module)


@pytest.mark.parametrize(
    ("paths", "expected"),
    [
        (["docs/architecture/architecture.md"], ("meta", False, False)),
        (["README.md", "README.zh-CN.md"], ("meta", False, False)),
        ([".agents/skills/speechrail-release/SKILL.md"], ("meta", False, False)),
        (["CHANGELOG.md"], ("meta", False, False)),
        (["src/speechrail/http/routes/jobs.py"], ("python", True, False)),
        (["tests/test_jobs.py"], ("python", True, False)),
        (["configs/speechrail.example.yaml"], ("python", True, False)),
        (["pyproject.toml"], ("python", True, False)),
        (["uv.lock"], ("python", True, False)),
        (["macos/SpeechRailApp/SpeechRailApp/RuntimeMonitoringView.swift"], ("swift", False, True)),
        (["contracts/openapi.yaml"], ("full", True, True)),
        (["contracts/realtime-events.schema.json"], ("full", True, True)),
        (["src/speechrail/__init__.py", "macos/SpeechRailApp/Package.swift"], ("full", True, True)),
        (["scripts/build_release_notes.py"], ("full", True, True)),
        ([".github/workflows/ci.yml"], ("full", True, True)),
        (["deploy/macos/com.speechrail.plist.example"], ("full", True, True)),
        ([], ("full", True, True)),
    ],
)
def test_classification(paths: list[str], expected: tuple[str, bool, bool]) -> None:
    decision = _module.classify_paths(paths)

    assert (decision.scope, decision.run_python, decision.run_swift) == expected


def test_unknown_path_fails_closed_to_full() -> None:
    """An unrecognised path must never silently drop a gate."""

    decision = _module.classify_paths(["brand-new-top-level/thing.bin"])

    assert decision.scope == "full"
    assert decision.run_python and decision.run_swift


def test_leading_dot_slash_is_normalized() -> None:
    assert _module.classify_paths(["./src/speechrail/__init__.py"]).scope == "python"


def test_docs_change_alongside_python_still_runs_python() -> None:
    decision = _module.classify_paths(["README.md", "src/speechrail/config/__init__.py"])

    assert decision.scope == "python"
    assert decision.run_python and not decision.run_swift


def test_nul_delimited_stream_round_trips() -> None:
    raw = b"docs/a.md\x00src/speechrail/__init__.py\x00"

    decision = _module.decision_from_nul_bytes(raw)

    assert decision.scope == "python"
    assert decision.file_count == 2


def test_invalid_utf8_fails_closed_to_full() -> None:
    decision = _module.decision_from_nul_bytes(b"src/\xff\xfe.py\x00")

    assert decision.scope == "full"
    assert decision.run_python and decision.run_swift


def test_github_output_is_lowercase_and_newline_free() -> None:
    stream = io.StringIO()

    _module.write_github_output(_module.classify_paths(["src/speechrail/x.py"]), stream)

    assert stream.getvalue() == "run_python=true\nrun_swift=false\nscope=python\n"


def test_summary_escapes_html_in_the_reason() -> None:
    """A path carrying markup must not inject HTML into the step summary."""

    decision = _module.classify_paths(["<img src=x onerror=alert(1)>"])
    stream = io.StringIO()

    _module.write_summary(decision, stream)

    assert "<img" not in stream.getvalue()
    assert "&lt;img" in stream.getvalue()


def test_summary_strips_newlines_from_the_reason() -> None:
    """A path with a newline must not break the summary's one-line reason."""

    decision = _module.classify_paths(["a\nb"])
    stream = io.StringIO()

    _module.write_summary(decision, stream)

    reason_lines = [
        line for line in stream.getvalue().splitlines() if line.startswith("- Reason:")
    ]
    assert len(reason_lines) == 1
    assert "a b" in reason_lines[0]


def test_force_full_selects_both_gates(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(sys, "stdin", io.TextIOWrapper(io.BytesIO(b"docs/a.md\x00")))
    out = tmp_path / "out.txt"

    exit_code = _module.main(["--force-full", "--github-output", str(out)])

    assert exit_code == 0
    assert _outputs_text(out) == "run_python=true\nrun_swift=true\nscope=full\n"


def _outputs_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")
