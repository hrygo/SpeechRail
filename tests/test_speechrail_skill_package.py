from __future__ import annotations

import asyncio
import json
from importlib import resources


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
