from __future__ import annotations

import json
from importlib import resources


def test_packaged_speechrail_skill_covers_the_published_mcp_surface() -> None:
    root = resources.files("speechrail").joinpath("assets", "skills", "speechrail")
    skill = root.joinpath("SKILL.md").read_text(encoding="utf-8")
    manifest = json.loads(root.joinpath("skill-manifest.json").read_text(encoding="utf-8"))

    assert skill.startswith("---\nname: speechrail\n")
    assert "describe" in skill
    assert manifest["skill"] == "speechrail"
    assert len(manifest["tools"]) == 15
    assert set(manifest["resources"]) == {
        "speechrail://capabilities",
        "speechrail://voices",
        "speechrail://models",
    }
    for reference in manifest["references"]:
        assert root.joinpath(reference).is_file()
