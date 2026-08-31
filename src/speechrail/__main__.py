"""SpeechRail command-line entry point."""

from __future__ import annotations

import uvicorn

from speechrail.app import app
from speechrail.config import Settings


def main() -> None:
    """Start the ASGI service with environment-backed settings."""

    settings = Settings()
    uvicorn.run(app, host=settings.host, port=settings.port, log_level="info")


if __name__ == "__main__":
    main()
