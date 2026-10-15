"""External novels are optional local inputs, never a CI dependency."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).parents[1] / "scripts" / "check_audiobook_text_corpus.py"


def invoke(*args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        env=env or {},
        capture_output=True,
        text=True,
        check=False,
    )


def test_external_corpus_is_skipped_without_explicit_opt_in() -> None:
    result = invoke()
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == {"status": "skipped", "reason": "not_enabled"}


@pytest.mark.parametrize("env", [{"CI": "true"}, {"CI": "1"}, {"GITHUB_ACTIONS": "true"}])
def test_ci_skips_even_with_explicit_opt_in(tmp_path: Path, env: dict[str, str]) -> None:
    result = invoke("--run", "--corpus", str(tmp_path), env=env)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == {"status": "skipped", "reason": "ci"}
    assert not list(tmp_path.iterdir())


def test_enabled_but_missing_corpus_skips(tmp_path: Path) -> None:
    result = invoke("--run", "--corpus", str(tmp_path / "missing"))
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == {"status": "skipped", "reason": "corpus_unavailable"}


def test_enabled_but_incomplete_corpus_skips(tmp_path: Path) -> None:
    (tmp_path / "unrelated.txt").write_text("虚构内容。", encoding="utf-8")
    result = invoke("--run", "--corpus", str(tmp_path))
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["reason"] == "corpus_incomplete"


def test_corpus_inside_repository_is_rejected() -> None:
    result = invoke("--run", "--corpus", str(SCRIPT.parent.parent / "tests"))
    assert result.returncode == 2
    assert "outside the repository" in result.stderr


def test_environment_opt_in_uses_external_directory(tmp_path: Path) -> None:
    result = invoke(
        env={
            "SPEECHRAIL_RUN_AUDIOBOOK_CORPUS": "1",
            "SPEECHRAIL_AUDIOBOOK_CORPUS_DIR": str(tmp_path),
        }
    )
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["reason"] == "corpus_incomplete"


def test_complete_but_changed_corpus_is_rejected_before_build(tmp_path: Path) -> None:
    manifest = json.loads((SCRIPT.parent / "audiobook_text_corpus_manifest.json").read_text())
    for entry in manifest["files"]:
        (tmp_path / entry["name"]).write_text("用于验证指纹门禁的虚构文本。", encoding="utf-8")
    result = invoke("--run", "--corpus", str(tmp_path))
    assert result.returncode == 2
    assert "corpus fingerprint differs" in result.stderr
    assert not list(tmp_path.glob("*.log"))
