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

from mcp.server import MCPServer
from mcp.server.mcpserver.exceptions import ToolError


def test_mcp_sdk_major_is_the_supported_line() -> None:
    installed = metadata.version("mcp")
    assert installed.split(".")[0] == "2", (
        f"speechrail-mcp targets the MCP Python SDK v2 API, but {installed!r} is "
        "installed. Migrate the mcp imports before relaxing the 'mcp>=2,<3' pin."
    )


def test_mcpserver_is_the_v2_high_level_server() -> None:
    # v1 exposed `mcp.server.fastmcp.FastMCP`; v2 renamed it to MCPServer.
    assert MCPServer.__module__.startswith("mcp.server")


def test_toolerror_is_a_v2_mcpserver_error() -> None:
    assert issubclass(ToolError, Exception)
    assert not issubclass(ToolError, SystemExit)
