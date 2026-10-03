from __future__ import annotations

import asyncio
import importlib.util
import json
import sys
from importlib import resources
from pathlib import Path

_CONTRACT_SCRIPT = (
    Path(__file__).resolve().parents[1] / "scripts" / "check_mcp_tool_contract.py"
)
_SPEC = importlib.util.spec_from_file_location(
    "speechrail_test_mcp_tool_contract", _CONTRACT_SCRIPT
)
assert _SPEC is not None and _SPEC.loader is not None
_contract = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = _contract
_SPEC.loader.exec_module(_contract)


def _registered_tool_names() -> set[str]:
    """Return the tool names the shipped MCP server actually registers."""

    from speechrail.mcp import server as mcp_server

    async def collect() -> set[str]:
        registered = await mcp_server.create_server().list_tools()
        return {tool.name for tool in registered}

    return asyncio.run(collect())


def test_packaged_speechrail_skill_covers_the_published_mcp_surface() -> None:
    root = resources.files("speechrail").joinpath("assets", "skills", "speechrail")
    skill = root.joinpath("SKILL.md").read_text(encoding="utf-8")
    manifest = json.loads(root.joinpath("skill-manifest.json").read_text(encoding="utf-8"))

    assert skill.startswith("---\nname: speechrail\n")
    assert "describe" in skill
    assert manifest["skill"] == "speechrail"
    tools = manifest["tools"]
    assert len(tools) == len(set(tools)), "manifest must not repeat a tool"
    # The manifest is the coverage contract for the registered surface, so a new
    # public MCP tool that never reaches the installed skill fails here instead
    # of silently shipping an under-documented artifact.
    assert set(tools) == _registered_tool_names()
    for name in tools:
        assert name in skill, f"SKILL.md must advertise the {name!r} tool"
    assert "references/realtime.md" in manifest["references"]
    realtime = root.joinpath("references", "realtime.md").read_text(encoding="utf-8")
    # The installed artifact must teach the current wire: one revisioned mutable
    # hypothesis event, never the removed ``partial_mode`` snapshot event.
    assert "speechrail.transcription.hypothesis" in realtime
    assert "speechrail.transcription.snapshot" not in realtime
    assert set(manifest["resources"]) == {
        "speechrail://capabilities",
        "speechrail://voices",
        "speechrail://models",
    }
    for reference in manifest["references"]:
        assert root.joinpath(reference).is_file()


def test_packaged_skill_teaches_the_current_voice_admission_policy() -> None:
    """The installed artifact must survive the 3.5.5 admission and error policy.

    This skill is copied to paths outside the repository, where the user guide
    and the OpenAPI contract are not necessarily available. Anything that
    changes the caller's next action therefore has to be stated here, not only
    in ``docs/``.
    """

    root = resources.files("speechrail").joinpath("assets", "skills", "speechrail")
    voices = root.joinpath("references", "voices.md").read_text(encoding="utf-8")

    # An agent must be able to answer "why is this voice not production-ready,
    # and what fixes it?" from the installed files alone. The remediation is a
    # real quality run; there is no flag to set.
    assert "synthesis_validation_not_run" in voices
    assert "validate_voice" in voices
    assert "require_output_pass" in voices

    # The text-fidelity gate: similarity alone misses a misread digit, the
    # policy is versioned, and a human verdict sharpens a machine result but
    # never substitutes for one.
    for token in (
        "transcript_numbers_match",
        "validation_policy_revision",
        "voice_design_machine_validation_required",
    ):
        assert token in voices, f"voices.md must teach {token}"


def test_packaged_skill_documents_every_action_changing_error_code() -> None:
    root = resources.files("speechrail").joinpath("assets", "skills", "speechrail")
    errors = root.joinpath("references", "errors.md").read_text(encoding="utf-8")

    assert _contract.REQUIRED_SKILL_ERROR_CODES, "the required-code set must not be empty"
    for code in _contract.REQUIRED_SKILL_ERROR_CODES:
        assert code in errors, f"errors.md must teach the {code!r} code"
