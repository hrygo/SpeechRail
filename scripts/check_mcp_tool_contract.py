#!/usr/bin/env python3
"""Validate the published MCP tool/resource surface against its documentation.

The MCP proxy is documented in three places that used to drift independently:
the user integration guide, the proxy architecture contract, and the packaged
skill manifest.  This checker fails closed when the registered server surface
and those documents disagree, so a new or renamed tool cannot ship with a
stale ``tools/list`` story.
"""

from __future__ import annotations

import asyncio
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
USER_GUIDE = ROOT / "docs" / "users" / "mcp-agent-integration.md"
PROXY_CONTRACT = ROOT / "docs" / "architecture" / "speechrail-mcp-proxy.md"
SKILL_MANIFEST = (
    ROOT / "src" / "speechrail" / "assets" / "skills" / "speechrail" / "skill-manifest.json"
)

_USER_GUIDE_HEADING = re.compile(r"^### 1\.1 工具集（(\d+) 个）$")
_BACKTICKED_CALL = re.compile(r"`([A-Za-z_][A-Za-z0-9_]*)(?:\(\))?`")
_RESOURCE_URI = re.compile(r"`(speechrail://[a-z0-9\-]+)`")
_PROXY_TOOL_COUNT = re.compile(r"当前工具集为 (\d+) 个")


def _user_guide_tool_section() -> tuple[int | None, list[str]]:
    """Return the declared tool count and every tool name in the §1.1 table."""

    declared: int | None = None
    names: list[str] = []
    in_table = False
    for line in USER_GUIDE.read_text(encoding="utf-8").splitlines():
        heading = _USER_GUIDE_HEADING.match(line)
        if heading is not None:
            declared = int(heading.group(1))
            in_table = False
            continue
        if declared is None:
            continue
        if line.startswith("|"):
            in_table = True
            first_cell = line.split("|")[1] if line.count("|") >= 2 else ""
            names.extend(_BACKTICKED_CALL.findall(first_cell))
        elif in_table:
            break
    return declared, names


def _proxy_contract_tools() -> tuple[int | None, list[str]]:
    """Return the declared tool count and the proxy contract tool table names."""

    declared: int | None = None
    names: list[str] = []
    collecting = False
    for line in PROXY_CONTRACT.read_text(encoding="utf-8").splitlines():
        if declared is None:
            match = _PROXY_TOOL_COUNT.search(line)
            if match is not None:
                declared = int(match.group(1))
            continue
        if line.startswith("|"):
            collecting = True
            first_cell = line.split("|")[1] if line.count("|") >= 2 else ""
            names.extend(_BACKTICKED_CALL.findall(first_cell))
        elif collecting:
            break
    return declared, names


def _documented_resources() -> list[str]:
    return _RESOURCE_URI.findall(USER_GUIDE.read_text(encoding="utf-8"))


def _skill_manifest() -> dict[str, object]:
    payload = json.loads(SKILL_MANIFEST.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("skill manifest must be a JSON object")
    return payload


def server_surface() -> tuple[set[str], set[str]]:
    """Return the live ``tools/list`` and ``resources/list`` surface."""

    from speechrail.mcp import server as mcp_server

    app = mcp_server.create_server()
    tools = asyncio.run(app.list_tools())
    resources = asyncio.run(app.list_resources())
    return (
        {tool.name for tool in tools},
        {str(resource.uri) for resource in resources},
    )


def find_drift() -> list[str]:
    """Return a list of human-readable drift findings (empty means aligned)."""

    problems: list[str] = []
    tool_names, resource_uris = server_surface()

    declared, guide_names = _user_guide_tool_section()
    guide_set = set(guide_names)
    if declared is None:
        problems.append("user guide is missing the §1.1 tool table heading")
    elif declared != len(tool_names):
        problems.append(
            f"user guide declares {declared} tools but the server registers {len(tool_names)}"
        )
    if len(guide_names) != len(guide_set):
        duplicates = sorted({name for name in guide_names if guide_names.count(name) > 1})
        problems.append(f"user guide tool table repeats: {', '.join(duplicates)}")
    for missing in sorted(tool_names - guide_set):
        problems.append(f"user guide does not document tool: {missing}")
    for extra in sorted(guide_set - tool_names):
        problems.append(f"user guide documents unknown tool: {extra}")

    proxy_declared, proxy_names_raw = _proxy_contract_tools()
    proxy_names = set(proxy_names_raw)
    if proxy_declared is None:
        problems.append("proxy contract does not declare the current tool count")
    elif proxy_declared != len(tool_names):
        problems.append(
            f"proxy contract declares {proxy_declared} tools but the server registers "
            f"{len(tool_names)}"
        )
    for missing in sorted(tool_names - proxy_names):
        problems.append(f"proxy contract does not document tool: {missing}")
    for extra in sorted(proxy_names - tool_names):
        problems.append(f"proxy contract documents unknown tool: {extra}")

    manifest = _skill_manifest()
    manifest_tools = manifest.get("tools")
    if not isinstance(manifest_tools, list) or not all(
        isinstance(name, str) for name in manifest_tools
    ):
        problems.append("skill manifest tools must be a list of strings")
    else:
        manifest_set = set(manifest_tools)
        for missing in sorted(tool_names - manifest_set):
            problems.append(f"skill manifest is missing tool: {missing}")
        for extra in sorted(manifest_set - tool_names):
            problems.append(f"skill manifest lists unknown tool: {extra}")

    manifest_resources = manifest.get("resources")
    if not isinstance(manifest_resources, list) or not all(
        isinstance(uri, str) for uri in manifest_resources
    ):
        problems.append("skill manifest resources must be a list of strings")
    else:
        for missing in sorted(resource_uris - set(manifest_resources)):
            problems.append(f"skill manifest is missing resource: {missing}")
        for extra in sorted(set(manifest_resources) - resource_uris):
            problems.append(f"skill manifest lists unknown resource: {extra}")

    for missing in sorted(resource_uris - set(_documented_resources())):
        problems.append(f"user guide does not document resource: {missing}")

    return problems


def main() -> int:
    problems = find_drift()
    if problems:
        for problem in problems:
            print(f"mcp-tool-contract: {problem}")
        return 1
    tools, resources = server_surface()
    print(f"mcp-tool-contract: OK ({len(tools)} tools, {len(resources)} resources)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
