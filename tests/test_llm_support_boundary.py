"""Architecture guards complement the independent Swift compiler check."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "macos" / "SpeechRailApp" / "SpeechRailApp"


def test_provider_has_no_feature_type_or_static_recorder_dependency():
    source = (APP / "LLMProvider.swift").read_text()
    assert not re.search(r"\bTeleprompter\w+", source)
    assert not re.search(r"\b(?:MinutesGenerator|InnerOSSession|MeetingSession)\b", source)
    assert "recorderBox" not in source


def test_production_has_one_strict_json_scanner():
    definitions = [
        path.name
        for path in APP.glob("*.swift")
        if re.search(r"\benum\s+\w*StrictJSON\s*\{", path.read_text())
    ]
    assert definitions == ["LLMProvider.swift"]
    for filename in [
        "TeleprompterPreparationPipeline.swift",
        "TeleprompterPreparationPrompts.swift",
        "TeleprompterAnalysis.swift",
    ]:
        assert "LLMStrictJSON.object" in (APP / filename).read_text()
