"""SpeechRail configuration for the contract-first service shell."""

from __future__ import annotations

from typing import Any

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Runtime settings shared by HTTP and WebSocket entry points.

    Model files and inference engines are intentionally not loaded by this
    foundation shell. The production implementation will add a backend
    factory behind the same settings boundary.
    """

    model_config = SettingsConfigDict(
        env_prefix="SPEECHRAIL_",
        env_file=".env",
        extra="ignore",
    )

    service_name: str = "speechrail"
    version: str = "0.1.0"
    host: str = "127.0.0.1"
    port: int = Field(default=8201, ge=1, le=65535)
    model_id: str = "speechrail/qwen3-asr-1.7b"
    compatibility_model_ids: tuple[str, ...] = (
        "Qwen3-ASR-1.7B",
        "qwen3-asr-1.7b",
        "whisper-1",
    )
    api_key: str | None = None
    backend_ready: bool = False

    @field_validator("api_key", mode="before")
    @classmethod
    def blank_api_key_is_unset(cls, value: Any) -> Any:
        """Treat an empty dotenv value as no key for loopback development."""

        return None if value == "" else value
