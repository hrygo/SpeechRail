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

__all__ = [
    "SERVICE_LABEL",
    "LaunchAgentDefinition",
    "LaunchAgentManager",
    "LaunchAgentPaths",
    "ServiceError",
    "UnsupportedPlatformError",
    "create_launch_agent_manager",
    "ServiceLayout",
]
