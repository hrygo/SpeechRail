"""Realtime ASR/TTS schema and shared cross-language fixtures.

The Python service and Swift clients consume the same fixture manifest.  The
schema is intentionally strict: removed events and unknown fields fail instead
of being translated or silently ignored.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest
from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[1]
SCHEMA_PATH = ROOT / "contracts" / "realtime-events.schema.json"
FIELD_MATRIX_PATH = ROOT / "contracts" / "realtime-field-matrix.json"
FIXTURE_ROOT = ROOT / "tests" / "fixtures" / "realtime-current"
MANIFEST_PATH = FIXTURE_ROOT / "manifest.json"


def _load(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        payload = json.load(handle)
    assert isinstance(payload, dict)
    return payload


def _manifest() -> dict[str, Any]:
    return _load(MANIFEST_PATH)


def test_schema_and_shared_fixture_manifest_are_closed() -> None:
    schema = _load(SCHEMA_PATH)
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema)
    manifest = _manifest()
    assert manifest["contract_version"] == 1
    assert manifest["schema"] == "contracts/realtime-events.schema.json"

    names: set[str] = set()
    for case in manifest["cases"]:
        assert case["name"] not in names
        case_name = str(case["name"])
        names.add(case["name"])
        fixture = _load(FIXTURE_ROOT / case["file"])
        errors = list(validator.iter_errors(fixture))
        if case["valid"]:
            assert not errors, f"{case_name}: {[error.message for error in errors]}"
        else:
            assert errors, f"{case_name} unexpectedly matched the current schema"
            assert case.get("rejection"), f"{case_name} has no explicit rejection reason"


def test_legacy_wire_is_not_accepted_by_schema() -> None:
    schema = _load(SCHEMA_PATH)
    validator = Draft202012Validator(schema)
    manifest = _manifest()
    invalid_names = {case["name"] for case in manifest["cases"] if not case["valid"]}
    required_rejections = {
        "legacy_transcription_session_update",
        "legacy_flat_session_audio",
        "legacy_tts_response_delta",
        "legacy_tts_response_done",
        "legacy_session_tts_revision",
        "unsupported_turn_detection",
        "unsupported_audio_format",
        "unsupported_model_precision",
        "design_runtime_voice",
        "invalid_asr_policy_bool",
    }
    assert required_rejections <= invalid_names
    for case in manifest["cases"]:
        if case["name"] not in required_rejections:
            continue
        fixture = _load(FIXTURE_ROOT / case["file"])
        assert list(validator.iter_errors(fixture)), case["name"]


def test_field_matrix_covers_positive_fixtures_and_rejections() -> None:
    manifest = _manifest()
    matrix = _load(FIELD_MATRIX_PATH)
    assert matrix["contract_version"] == 1
    case_by_name = {case["name"]: case for case in manifest["cases"]}
    paths: set[str] = set()
    for row in matrix["fields"]:
        path = row["path"]
        assert path not in paths
        paths.add(path)
        assert row["validator"]
        assert row["task_request"]
        assert row["adapter"]
        positive_name = str(row["positive_case"])
        assert row["positive_case"] in case_by_name
        assert case_by_name[row["positive_case"]]["valid"] is True
        fixture = _load(FIXTURE_ROOT / case_by_name[row["positive_case"]]["file"])
        assert _path_exists(fixture, path), f"{path} missing from {positive_name}"
        rejection = row.get("reject_case")
        if rejection is not None:
            assert rejection in case_by_name
            assert case_by_name[rejection]["valid"] is False


def test_asr_policy_and_segment_boundary_fields_are_in_the_public_matrix() -> None:
    matrix = _load(FIELD_MATRIX_PATH)
    paths = {row["path"] for row in matrix["fields"]}

    assert {
        "session.speechrail.asr.preview_interval_ms",
        "session.speechrail.asr.max_segment_ms",
        "session.speechrail.asr.finalization",
        "session.speechrail.asr.final_deadline_ms",
        "session.speechrail.asr.effective_max_segment_ms",
        "item_id",
        "reason",
    } <= paths


def test_segment_closed_schema_rejects_commit_id_for_non_client_close() -> None:
    validator = Draft202012Validator(_load(SCHEMA_PATH))
    fixture = _load(
        FIXTURE_ROOT / "server" / "transcription-segment-closed.json"
    )
    fixture["reason"] = "vad"

    assert list(validator.iter_errors(fixture))


def test_asr_policy_schema_rejects_non_integer_and_unknown_wire_values() -> None:
    validator = Draft202012Validator(_load(SCHEMA_PATH))
    fixture = _load(
        FIXTURE_ROOT / "client" / "session-update-asr-policy.json"
    )
    for field, value in (
        ("preview_interval_ms", 800.5),
        ("finalization", "vendor_default"),
        ("unknown", 1),
    ):
        invalid = json.loads(json.dumps(fixture))
        invalid["session"]["speechrail"]["asr"][field] = value
        assert list(validator.iter_errors(invalid)), field


def test_server_session_responses_require_effective_asr_policy_echo() -> None:
    validator = Draft202012Validator(_load(SCHEMA_PATH))
    for filename in ("session-created.json", "session-updated.json"):
        fixture = _load(FIXTURE_ROOT / "server" / filename)
        assert not list(validator.iter_errors(fixture)), filename
        del fixture["session"]["speechrail"]["asr"]
        assert list(validator.iter_errors(fixture)), filename


def _path_exists(value: object, dotted: str) -> bool:
    current = value
    for component in dotted.split("."):
        if not isinstance(current, dict) or component not in current:
            return False
        current = current[component]
    return True


@pytest.mark.parametrize(
    "removed_event",
    [
        "transcription_session.update",
        "response.output_audio.delta",
        "response.done",
        "speechrail.tts.create",
    ],
)
def test_removed_event_types_are_absent_from_schema(removed_event: str) -> None:
    schema = _load(SCHEMA_PATH)
    encoded = json.dumps(schema, sort_keys=True)
    needle = '"const": "{removed_event}"'
    assert needle not in encoded


def test_optional_commit_receipt_wire_schema() -> None:
    validator = Draft202012Validator(_load(SCHEMA_PATH))
    for requested in (True, False):
        validator.validate({"type": "input_audio_buffer.commit", "event_id": "barrier",
                            "speechrail": {"request_receipt": requested}})
    receipt = {
        "type": "speechrail.input_audio_buffer.committed", "event_id": "evt_1",
        "session_id": "sess_1", "sequence": 1,
        "commit_event_id": "barrier", "accepted_samples": 24000,
    }
    validator.validate(receipt)
    for invalid in (-1, True, "24000", 1.5):
        assert list(validator.iter_errors({**receipt, "accepted_samples": invalid}))
