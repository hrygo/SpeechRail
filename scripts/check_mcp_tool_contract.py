#!/usr/bin/env python3
"""Validate the published MCP tool/resource surface against its documentation.

The MCP proxy is documented in three places that used to drift independently:
the user integration guide, the proxy architecture contract, and the packaged
skill manifest.  This checker fails closed when the registered server surface
and those documents disagree, so a new or renamed tool cannot ship with a
stale ``tools/list`` story.

It also guards the error codes the packaged skill has to teach.  Name parity
cannot catch that drift: the skill is copied to paths outside this repository,
where the user guide and the OpenAPI contract are not necessarily readable, so
an error whose *correct handling* differs from the generic advice must be
stated in the artifact itself.
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
SKILL_ERRORS = (
    ROOT
    / "src"
    / "speechrail"
    / "assets"
    / "skills"
    / "speechrail"
    / "references"
    / "errors.md"
)

_USER_GUIDE_HEADING = re.compile(r"^### 1\.1 工具集（(\d+) 个）$")
_BACKTICKED_CALL = re.compile(r"`([A-Za-z_][A-Za-z0-9_]*)(?:\(\))?`")
_RESOURCE_URI = re.compile(r"`(speechrail://[a-z0-9\-]+)`")
_PROXY_TOOL_COUNT = re.compile(r"当前工具集为 (\d+) 个")

#: Error codes whose correct next action is not the generic "fix the request and
#: retry" advice.  Each entry is ``code -> why an agent must know it``.  Keep the
#: rationale: a future edit that drops a code should have to argue that the
#: behaviour it protects is no longer reachable.
REQUIRED_SKILL_ERROR_CODES: dict[str, str] = {
    "backend_reclamation_failed": (
        "backend ownership is unconfirmed and the lane stays isolated; queue "
        "backoff or refreshing discovery cannot replace operator runtime recovery"
    ),
    "transcript_mismatch": (
        "candidate confirmation now also rejects a misread number that still "
        "passes similarity, so a retry with the same reference never succeeds"
    ),
    "voice_design_machine_validation_required": (
        "a human verdict can sharpen a machine result but never replace one, "
        "so the only way forward is another validate_voice_design run"
    ),
    "voice_design_validation_limit_reached": (
        "the candidate keeps 32 results and never evicts an already-returned "
        "one; a same-ID idempotent retry still succeeds"
    ),
    "validation_audio_unavailable": (
        "the stored audition asset conflicts with its recorded identity; "
        "regenerating or overwriting it would destroy the evidence"
    ),
    "voice_design_revision_conflict": (
        "the candidate was published, cancelled, failed or revised while a "
        "validation was in flight; re-read it rather than restoring the old one"
    ),
    "stream_unsupported": (
        "streaming file transcription is understood but unimplemented, so 400 "
        "means 'change the request', not 'retry'"
    ),
    "chunking_strategy_unsupported": (
        "chunking is only accepted for diarization; 400 is a capability "
        "mismatch rather than malformed input"
    ),
    "unsupported_parameter": (
        "known-speaker parameters are refused on purpose; this service keeps no "
        "real-name or cross-session voiceprint identity"
    ),
    "stream_format_unsupported": (
        "/v1/audio/speech returns a complete audio body only, so a streaming "
        "format request must be rewritten, not retried"
    ),
}


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

    skill_errors = SKILL_ERRORS.read_text(encoding="utf-8")
    for code in sorted(REQUIRED_SKILL_ERROR_CODES):
        if code not in skill_errors:
            problems.append(f"packaged skill does not teach error code: {code}")

    return problems


def main() -> int:
    problems = find_drift()
    if problems:
        for problem in problems:
            print(f"mcp-tool-contract: {problem}")
        return 1
    tools, resources = server_surface()
    print(
        f"mcp-tool-contract: OK ({len(tools)} tools, {len(resources)} resources, "
        f"{len(REQUIRED_SKILL_ERROR_CODES)} required skill error codes)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
