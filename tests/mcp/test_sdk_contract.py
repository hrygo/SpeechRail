"""Contract tests pinning the MCP SDK major the ``speechrail-mcp`` proxy targets.

The proxy is written against the MCP Python SDK **v2** API
(``mcp.server.MCPServer`` / ``mcp.server.mcpserver.exceptions.ToolError``). A
future major bump relocates these symbols, so relaxing the dependency pin
without migrating the imports would crash the proxy at import time (the
``-32000 Connection closed`` failure this suite guards against). These tests
fail loudly on the next major upgrade instead of at MCP launch.
"""

from __future__ import annotations

import importlib.metadata as metadata
import tomllib
from pathlib import Path

from mcp.server import MCPServer
from mcp.server.mcpserver.exceptions import ToolError

_PYPROJECT = Path(__file__).resolve().parents[2] / "pyproject.toml"


def test_mcp_sdk_major_is_the_supported_line() -> None:
    installed = metadata.version("mcp")
    assert installed.split(".")[0] == "2", (
        f"speechrail-mcp targets the MCP Python SDK v2 API, but {installed!r} is "
        "installed. Migrate the mcp imports before relaxing the 'mcp>=2.1,<3' pin."
    )


def test_mcpserver_is_the_v2_high_level_server() -> None:
    # v1 exposed `mcp.server.fastmcp.FastMCP`; v2 renamed it to MCPServer.
    assert MCPServer.__module__.startswith("mcp.server")


def test_toolerror_is_a_v2_mcpserver_error() -> None:
    assert issubclass(ToolError, Exception)
    assert not issubclass(ToolError, SystemExit)


def _mcp_specs() -> list[str]:
    data = tomllib.loads(_PYPROJECT.read_text(encoding="utf-8"))
    extras = data["project"]["optional-dependencies"]
    return [d for d in extras["dev"] if d.startswith("mcp")] + [
        d for d in extras["mcp"] if d.startswith("mcp")
    ]


def test_pyproject_pins_mcp_floor_at_2_1() -> None:
    specs = _mcp_specs()
    assert specs, "no mcp dependency declared in pyproject extras"
    for spec in specs:
        assert ">=2.1" in spec, (
            f"mcp pin {spec!r} is too loose: cache hints on a server serving a pre-2026 "
            "session break list_tools() on mcp 2.0.x (fixed in 2.1.0). Pin >=2.1,<3."
        )


def test_installed_mcp_minor_supports_cache_hints() -> None:
    installed = metadata.version("mcp")
    parts = installed.split(".")
    assert int(parts[1]) >= 1, (
        f"mcp {installed} is too old: a server serving a pre-2026 session (e.g. "
        "opencode's 2025-11-25 handshake) rejects cache hints on list_tools() and "
        "the call crashes; fixed in 2.1.0. Install mcp>=2.1,<3."
    )


def test_cache_hints_api_is_importable_and_accepted() -> None:
    # v2.1 added cache hints; the proxy constructs MCPServer(cache_hints=...).
    from typing import get_args

    from mcp.server import MCPServer
    from mcp.server.caching import CacheableMethod, CacheHint
    from mcp.server.mcpserver.context import Context

    assert "tools/list" in get_args(CacheableMethod)
    assert isinstance(Context, type)
    app = MCPServer(
        name="sdk-guard",
        cache_hints={"tools/list": CacheHint(ttl_ms=300_000, scope="public")},
    )
    assert app._lowlevel_server.cache_hints["tools/list"].ttl_ms == 300_000
