"""CLI handlers for `speechrail media capabilities` and `speechrail media export`."""

from __future__ import annotations

import asyncio
import signal
from collections.abc import Callable
from pathlib import Path
from uuid import UUID

from speechrail.media.encoder import (
    MediaEncodeError,
    MediaProcessRunner,
    MediaToolchain,
    SubprocessMediaRunner,
    discover_media_toolchain,
    encode,
)
from speechrail.media.manifest import MediaManifestError, load_manifest


def run_media_capabilities(
    app_home: Path,
    *,
    toolchain: MediaToolchain | None = None,
) -> dict[str, object]:
    """Return machine-readable media encoding capabilities without starting any ASR/TTS models."""
    resolved_home = Path(app_home).resolve()
    tools = toolchain or discover_media_toolchain(resolved_home)
    return {
        "available": tools.available,
        "command": "media.capabilities",
        "encoders": sorted(tools.encoders),
        "media": {
            "available": tools.available,
            "encoders": sorted(tools.encoders),
            "kind": "capabilities",
            "supports_m4b": tools.supports_m4b,
            "supports_mp3": tools.supports_mp3,
        },
        "status": "ok" if tools.available else "unavailable",
        "supports_m4b": tools.supports_m4b,
        "supports_mp3": tools.supports_mp3,
    }


def run_media_export(
    app_home: Path,
    request_id: UUID,
    *,
    toolchain: MediaToolchain | None = None,
    runner: MediaProcessRunner | None = None,
    on_progress: Callable[[dict[str, object]], None] | None = None,
) -> dict[str, object]:
    """Execute one bounded media export operation from its owned manifest."""
    resolved_home = Path(app_home).resolve()
    manifest = load_manifest(resolved_home, request_id)
    tools = toolchain or discover_media_toolchain(resolved_home)
    proc_runner = runner or SubprocessMediaRunner()

    cancel_event = asyncio.Event()
    previous_sigterm = signal.getsignal(signal.SIGTERM)

    def _on_sigterm(_signum: int, _frame: object) -> None:
        cancel_event.set()

    signal.signal(signal.SIGTERM, _on_sigterm)
    try:
        result = asyncio.run(
            encode(
                manifest,
                tools,
                proc_runner,
                app_home=resolved_home,
                cancel_event=cancel_event,
                on_progress=on_progress,
            )
        )
    finally:
        signal.signal(signal.SIGTERM, previous_sigterm)

    result_dict = result.to_dict()
    return {
        "command": "media.export",
        "event": "result",
        "media": {
            "kind": "export_result",
            **result_dict,
        },
        "status": "committed",
        **result_dict,
    }


__all__ = ["MediaEncodeError", "MediaManifestError", "run_media_capabilities", "run_media_export"]
