"""SpeechRail MCP proxy package.

Exposes the local SpeechRail OpenAI-compatible REST service to MCP agents
through a small set of stateless tools (``describe``, ``transcribe``,
``synthesize``, ``preview_voice`` and the durable-job trio).  The proxy runs
as its own process and never imports the FastAPI application or any model
worker: it talks plain ``Authorization: Bearer`` REST to the shared daemon.
"""

from __future__ import annotations

from speechrail.mcp.server import create_server

__version__ = "0.2.0"

__all__ = ["__version__", "create_server"]
