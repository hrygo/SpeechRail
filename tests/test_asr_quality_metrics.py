"""Quality evidence must expose scores, never raw reference or ASR text."""

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from examples.perf.asr_quality import character_error_metrics
from examples.perf.benchmark_http import HttpResponse, _fixture_request
from examples.perf.benchmark_manifest import Fixture


@pytest.mark.parametrize(
    ("reference", "hypothesis", "errors"),
    [("甲乙丙", "甲丁丙", 1), ("甲乙丙", "甲丙", 1), ("甲乙丙", "甲乙乙丙", 1),
     ("A，１２！", "a12", 0), ("甲乙", "", 2)],
)
def test_cer_counts_substitution_deletion_insertion_and_empty(reference, hypothesis, errors):
    result = character_error_metrics(reference, hypothesis)
    assert result["character_errors"] == errors
    assert "reference_text" not in result and "text" not in result


def test_reference_is_scored_locally_and_never_injected_into_request(tmp_path: Path):
    path = tmp_path / "audio.wav"
    path.write_bytes(b"test audio container")
    reference = "distinctive reference"
    fixture = Fixture("sample", path, "asr", "en", "default", None, reference)
    requests = []

    def runner(method, url, body, headers):
        requests.append(body)
        return HttpResponse(200, json.dumps({"text": reference}).encode())

    result = _fixture_request(
        fixture, base_url="http://127.0.0.1:8201", runner=runner,
        clock=lambda: 1.0, duration=1.0, auth_headers={},
    )
    assert reference.encode() not in requests[0]
    assert reference not in json.dumps(result)
    assert result["quality_metrics"]["cer"] == 0
