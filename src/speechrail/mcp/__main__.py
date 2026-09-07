"""``speechrail-mcp`` console entry point.

Runs the MCP proxy over stdio (default) or the streamable HTTP transport.
"""

from __future__ import annotations

from speechrail.mcp.server import main

if __name__ == "__main__":
    raise SystemExit(main())
