"""Host-service adapters for the local SpeechRail runtime."""

from speechrail.service.launchd import (
    SERVICE_LABEL,
    LaunchAgentDefinition,
    LaunchAgentManager,
    LaunchAgentPaths,
    ServiceError,
    UnsupportedPlatformError,
    create_launch_agent_manager,
)
from speechrail.service.paths import ServiceLayout
from speechrail.service.preflight import (
    FFMPEG_FALLBACKS,
    CommandRunner,
    PreflightCheck,
    PreflightResult,
    run_preflight,
)

__all__ = [
    "FFMPEG_FALLBACKS",
    "SERVICE_LABEL",
    "CommandRunner",
    "LaunchAgentDefinition",
    "LaunchAgentManager",
    "LaunchAgentPaths",
    "PreflightCheck",
    "PreflightResult",
    "ServiceError",
    "ServiceLayout",
    "UnsupportedPlatformError",
    "create_launch_agent_manager",
    "run_preflight",
]
