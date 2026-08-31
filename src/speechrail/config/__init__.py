"""SpeechRail runtime configuration."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Literal

from pydantic import Field, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Validated, environment-backed service configuration."""

    model_config = SettingsConfigDict(env_prefix="SPEECHRAIL_", env_file=".env", extra="ignore")

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
    allowed_origins: tuple[str, ...] = ()
    backend_ready: bool = False
    qwen3_model_dir: Path | None = None
    qwen3_python: Path | None = None
    allow_model_downloads: bool = False
    device: Literal["mps", "cpu"] = "mps"
    dtype: Literal["float16", "float32"] = "float16"
    max_queue_size: int = Field(default=8, ge=1, le=1024)
    max_upload_bytes: int = Field(default=536_870_912, ge=1)
    max_audio_seconds: int = Field(default=3600, ge=1)
    max_realtime_frame_bytes: int = Field(default=160_000, ge=2, le=4_000_000)
    max_realtime_buffer_bytes: int = Field(default=8_388_608, ge=2, le=64_000_000)
    request_timeout_seconds: float = Field(default=120, gt=0, le=3600)
    legacy_wlk_enabled: bool = True
    legacy_query_token_enabled: bool = False

    @field_validator("api_key", mode="before")
    @classmethod
    def blank_api_key_is_unset(cls, value: Any) -> Any:
        return None if value == "" else value

    @model_validator(mode="after")
    def validate_exposure(self) -> Settings:
        if self.host not in {"127.0.0.1", "::1", "localhost"} and not self.api_key:
            raise ValueError("api_key is required when binding outside loopback")
        if self.device == "mps" and self.dtype != "float16":
            raise ValueError("MPS profile requires float16")
        if self.device == "cpu" and self.dtype != "float32":
            raise ValueError("CPU profile requires float32")
        return self


__all__ = ["Settings"]
