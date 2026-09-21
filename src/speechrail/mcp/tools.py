"""Tool logic for the SpeechRail MCP proxy.

Each function is a plain typed async function that takes an explicit
:class:`~speechrail.mcp.client.SpeechRailClient`, so it can be unit-tested
against ``httpx.MockTransport`` without the MCP transport.  ``server.py``
wraps these functions into MCPServer tools whose arguments stay free of any
client/context plumbing.

Proxy policy implemented here (per docs/architecture/speechrail-mcp-proxy-draft.md):

- ``audio_ref`` is path/``file://`` only; inline base64 is rejected with a
  teaching error so audio never enters the agent context.
- ``synthesize`` hard-enforces the active tier: clone/instruction voices that
  require the ``quality`` (voice_design) engine are rejected up front on other
  tiers, mirroring the backend ``resolve_binding`` rejection.
- ``preview_voice`` is quality-only and rejected up front on other profiles.
- SpeechRail REST errors are surfaced as typed failures carrying the stable
  ``code``/``retryable`` pair plus a retry/action hint.
"""

from __future__ import annotations

import asyncio
import contextlib
import os
import re
import tempfile
from pathlib import Path
from typing import Any, cast
from urllib.parse import unquote, urlparse
from urllib.request import url2pathname

from speechrail.domain.job_request import (
    JobParamsValidationError,
    validate_job_params,
)
from speechrail.domain.tts_request import (
    TtsModelVariant,
    TtsParameterError,
    validate_tts_parameters,
)
from speechrail.mcp.client import SpeechRailClient

_MAX_TTS_TEXT = 4_096
_MAX_PREVIEW_TEXT = 4_096
_MAX_PREVIEW_INSTRUCTION = 10_000
_MAX_VOICE_NAME = 200
_MAX_VOICE_INSTRUCTION = 10_000
_MAX_VOICE_SEED = 2**32 - 1
_VOICE_ID_RE = re.compile(r"^[a-zA-Z0-9_-]{1,64}$")
_VOICE_REVISION_RE = re.compile(r"^vr_[0-9a-f]{32}$")
_MODEL_REVISION_RE = re.compile(r"^[0-9a-f]{40}$")
_MAX_JOB_REF = 1_000
_SPEED_RANGE = (0.25, 4.0)
_TTS_OUTPUT_FORMATS = frozenset({"mp3", "wav", "pcm"})
_JOB_KINDS = frozenset({"speech", "transcription"})
_PREVIEW_FORMAT = "wav"
_PREVIEW_SUFFIX = ".wav"
_DEFAULT_TTS_MODEL = "speechrail/qwen3-tts"

_TTS_CONTENT_TYPES = {
    "mp3": "audio/mpeg",
    "wav": "audio/wav",
    "pcm": "audio/x-pcm",
}
_TTS_OUTPUT_SUFFIXES = {
    "mp3": ".mp3",
    "wav": ".wav",
    "pcm": ".pcm",
}
_JOB_RESULT_SUFFIXES = {
    "audio/mpeg": ".mp3",
    "audio/wav": ".wav",
    "audio/x-pcm": ".pcm",
    "application/json": ".json",
}

_TIER_MESSAGES = {
    "clone": (
        "voice {voice} is a user clone that only exists on the quality tier "
        "(voice_design); the active profile is {profile}. Call describe() and "
        "pick a voice with available=true, or switch tiers."
    ),
    "instruction": (
        "voice {voice} is an instruction-driven voice that only runs on the "
        "quality tier (voice_design); the active profile is {profile}. Call "
        "describe() and pick a voice with available=true, or switch tiers."
    ),
}

_BASE64_CHARSET = re.compile(r"^[A-Za-z0-9+/]+={0,2}$")


class ToolCallError(Exception):
    """A tool-level rejection that should surface as an MCP tool error."""

    def __init__(
        self,
        *,
        code: str,
        message: str,
        retryable: bool = False,
        hint: str | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.retryable = retryable
        self.hint = hint


def _text(value: object) -> str | None:
    return value if isinstance(value, str) else None


def _bool_flag(value: object) -> bool:
    return value is True


def _first_tts_model(models: list[dict[str, Any]]) -> dict[str, Any] | None:
    """Locate the real TTS artifact entry (never a bare alias entry)."""
    for entry in models:
        if entry.get("family") == "qwen3_tts":
            return entry
    for entry in models:
        if (
            entry.get("variant") in {"voice_design", "custom_voice"}
            and entry.get("resolves_to") is None
        ):
            return entry
    return None


def _tts_variant(models: list[dict[str, Any]]) -> str | None:
    entry = _first_tts_model(models)
    if entry is None:
        return None
    return _text(entry.get("variant"))


def _derive_tier(*, profile: str | None, variant: str | None) -> str:
    if profile in {"quality", "balanced", "light"}:
        return profile
    if variant == "voice_design":
        return "quality"
    if variant == "custom_voice":
        return "balanced"
    return profile or "unknown"


def _find_voice(voices: list[dict[str, Any]], voice: str) -> dict[str, Any] | None:
    for entry in voices:
        if entry.get("id") == voice:
            return entry
        aliases = entry.get("aliases")
        if isinstance(aliases, list) and voice in aliases:
            return entry
    return None


def _effective_voice_projection(effective: dict[str, Any]) -> list[dict[str, Any]]:
    """Project the safe atomic voice snapshot for agent-facing discovery."""
    raw_voices = effective.get("voices")
    if not isinstance(raw_voices, list):
        return []
    allowed = {
        "id",
        "name",
        "aliases",
        "is_default",
        "is_system",
        "mode",
        "available",
        "availability_reason",
        "variant",
        "voice_revision",
        "voice_identity_assurance",
        "revoked",
        "model",
        "descriptors",
        "quality_summary",
        "validation_state",
        "validated_for",
        "production_ready",
        "production_ready_reason",
        "operations",
    }
    result: list[dict[str, Any]] = []
    for raw in raw_voices:
        if not isinstance(raw, dict):
            continue
        safe = {key: value for key, value in raw.items() if key in allowed}
        result.append(safe)
    return result


def _effective_tts_variant(effective: dict[str, Any]) -> str | None:
    models = effective.get("models")
    if not isinstance(models, dict):
        return None
    tts = models.get("tts")
    return _text(tts.get("variant")) if isinstance(tts, dict) else None


def _effective_model_revision(
    effective: dict[str, Any], entry: dict[str, Any]
) -> str | None:
    model = entry.get("model")
    if isinstance(model, dict):
        revision = _text(model.get("catalog_revision"))
        if revision is not None:
            return revision
    models = effective.get("models")
    if not isinstance(models, dict):
        return None
    model_key = "tts_clone" if entry.get("mode") == "clone" else "tts"
    model = models.get(model_key)
    if not isinstance(model, dict):
        return None
    return _text(model.get("catalog_revision"))


def _safe_voice_record(raw: object) -> dict[str, Any]:
    """Keep private voice recipes and reference text out of MCP output."""

    if not isinstance(raw, dict):
        raise ToolCallError(
            code="invalid_response", message="SpeechRail returned no voice record"
        )
    source = raw.get("voice")
    if not isinstance(source, dict):
        source = raw
    allowed = {
        "id",
        "name",
        "mode",
        "available",
        "availability_reason",
        "variant",
        "revision",
        "voice_revision",
        "capabilities",
        "validation_state",
        "production_ready",
        "production_ready_reason",
        "synthesis_validation",
    }
    safe = {key: value for key, value in source.items() if key in allowed}
    if isinstance(raw.get("synthesis_validation"), str):
        safe["synthesis_validation"] = raw["synthesis_validation"]
    if not isinstance(safe.get("id"), str):
        raise ToolCallError(
            code="invalid_response", message="SpeechRail returned no voice identifier"
        )
    return safe


def _validate_revision_pin(
    value: str | None,
    *,
    field: str,
    pattern: re.Pattern[str],
) -> None:
    if value is not None and pattern.fullmatch(value) is None:
        raise ToolCallError(
            code=f"invalid_{field}",
            message=f"{field} has an invalid format",
            hint="call describe() and copy the current revision exactly",
        )


async def describe(client: SpeechRailClient) -> dict[str, Any]:
    """Return current observations plus the required atomic capability snapshot."""
    models = await client.fetch_models()
    health = await client.fetch_health()
    effective = await client.fetch_capabilities()
    variant = _tts_variant(models)
    entry = _first_tts_model(models)
    model_profile = _text(entry.get("profile")) if entry is not None else None
    health_profile = _text(health.get("profile"))
    profile = model_profile or health_profile
    # 能力结论只读服务发布的 `capabilities`: `supports_preview` 曾经由这里按
    # `variant == "voice_design"` 重算, 等于把服务端的判定规则抄了第二份; 两份
    # 规则一旦分叉, agent 会拿到与服务不一致的答案。
    declared = entry.get("capabilities") if entry is not None else None
    capabilities = declared if isinstance(declared, dict) else {}
    return {
        "tier": _derive_tier(profile=profile, variant=variant),
        "profile": profile,
        "diarization_ready": _bool_flag(health.get("diarization_ready")),
        "readiness": {
            "asr": _bool_flag(health.get("asr_ready")),
            "tts": _bool_flag(health.get("tts_ready")),
            "diarization": _bool_flag(health.get("diarization_ready")),
        },
        "tts_lifecycle": health.get("tts_lifecycle")
        if isinstance(health.get("tts_lifecycle"), dict)
        else None,
        "realtime": {
            "vad": health.get("realtime_vad")
            if isinstance(health.get("realtime_vad"), dict)
            else None,
            "streaming_state": _text(health.get("streaming_state")),
            "asr_state": _text(health.get("asr_state")),
            "tts_state": _text(health.get("tts_state")),
            "orchestration": "caller",
            "server_llm": False,
            "conversation_state": False,
            "websocket_path": "/v1/realtime",
            "mcp_realtime": False,
        },
        "clone_supported": _bool_flag(capabilities.get("supports_clone")),
        "preview_supported": _bool_flag(capabilities.get("supports_preview")),
        "jobs": {
            "spool_ready": _bool_flag(health.get("job_spool_ready")),
            "runner_active": _bool_flag(health.get("job_runner_active")),
        },
        "models": models,
        "voices": _effective_voice_projection(effective),
        "effective_capabilities": effective,
    }


def _raise_for_inline_base64(audio_ref: str) -> None:
    """Reject inline base64/``data:`` audio before it reaches any request."""
    stripped = audio_ref.strip()
    if stripped.startswith("data:") or "base64," in stripped.lower():
        raise ToolCallError(
            code="base64_not_supported",
            message=(
                "base64 audio is not accepted; pass an audio_ref as a file "
                "path or file:// URI so the audio never enters your context"
            ),
            hint="provide a local path to the audio file instead",
        )
    if (
        len(stripped) >= 64
        and _BASE64_CHARSET.fullmatch(stripped) is not None
        and not Path(stripped).is_file()
    ):
        raise ToolCallError(
            code="base64_not_supported",
            message=(
                "the audio_ref looks like inline base64, which is not "
                "accepted; pass a file path or file:// URI instead"
            ),
            hint="provide a local path to the audio file instead",
        )


def _resolve_local_audio(audio_ref: str) -> tuple[Path, str]:
    """Resolve a bare path or ``file://`` URI to a readable local file.

    Raises :class:`ToolFailure` for remote schemes or missing files; the proxy
    never fetches remote URLs (privacy boundary of the draft spec).
    """
    stripped = audio_ref.strip()
    if not stripped:
        raise ToolCallError(code="audio_ref_missing", message="audio_ref must not be empty")
    scheme = urlparse(stripped).scheme.lower()
    if scheme == "file":
        path = Path(url2pathname(unquote(urlparse(stripped).path)))
    elif scheme == "":
        path = Path(stripped)
    elif scheme in {"http", "https", "ftp", "s3", "gs"}:
        raise ToolCallError(
            code="remote_audio_unsupported",
            message=(
                f"remote {scheme} URLs are not fetched by the proxy; download "
                "the audio locally first and pass its path"
            ),
            hint="download the file first, then pass a local path",
        )
    else:
        raise ToolCallError(
            code="audio_ref_unsupported",
            message=(
                f"unable to resolve audio_ref scheme {scheme!r}; pass a local "
                "file path or file:// URI"
            ),
            hint="use a local path (stdio/host-local) for audio_ref",
        )
    if not path.is_file():
        raise ToolCallError(
            code="audio_ref_not_found",
            message=f"audio file not found at {path}",
            hint="confirm the audio_ref path exists on the proxy host",
        )
    return path, path.name or "audio"


def _enforce_available_voice(
    entry: dict[str, Any],
    voice: str,
    *,
    variant: str | None,
    profile: str | None,
    validation_policy: str = "allow_unverified",
) -> None:
    """Hard-enforce tier/availability for a requested voice before TTS calls."""
    if entry.get("available") is not True:
        suffix = f" ({profile!r})" if profile else ""
        raise ToolCallError(
            code="voice_not_available",
            message=(
                f"voice {voice!r} is not available on the active profile{suffix}; "
                "call describe() and pick a voice with available=true"
            ),
            hint="call describe() and choose a voice with available=true",
        )
    if (
        validation_policy == "require_output_pass"
        and entry.get("mode") == "clone"
        and entry.get("production_ready") is False
    ):
        reason = _text(entry.get("production_ready_reason")) or "synthesis_validation_required"
        raise ToolCallError(
            code="voice_not_production_ready",
            message=(
                f"voice {voice!r} is available for routing but is not production-ready: "
                f"{reason}"
            ),
            hint="run validate_voice and require a persisted synthesis output pass",
        )
    if variant == "voice_design":
        return
    capabilities = entry.get("capabilities")
    caps = capabilities if isinstance(capabilities, dict) else {}
    supports_clone = _bool_flag(caps.get("supports_clone"))
    supports_instruction = _bool_flag(caps.get("supports_instruction"))
    mode = _text(entry.get("mode"))
    tier_label = profile or "non-quality"
    if mode == "clone" or supports_clone:
        raise ToolCallError(
            code="voice_not_available",
            message=_TIER_MESSAGES["clone"].format(voice=voice, profile=tier_label),
            hint=(
                "call describe() to see voices with available=true, "
                "or switch to the quality profile"
            ),
        )
    if mode == "instruction" or supports_instruction:
        raise ToolCallError(
            code="voice_not_available",
            message=_TIER_MESSAGES["instruction"].format(voice=voice, profile=tier_label),
            hint=(
                "call describe() to see voices with available=true, "
                "or switch to the quality profile"
            ),
        )


def _write_temp_audio(content: bytes, suffix: str) -> str:
    fd, path = tempfile.mkstemp(prefix="speechrail-", suffix=suffix)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(content)
    except Exception:
        with contextlib.suppress(OSError):
            Path(path).unlink()
        raise
    return path


async def transcribe(
    client: SpeechRailClient,
    *,
    audio_ref: str,
    language: str | None = None,
    diarize: bool = False,
    timestamps: bool = False,
) -> dict[str, Any]:
    """Transcribe an audio file referenced by ``audio_ref`` (path or file URI).

    Output shapes (mirroring SpeechRail REST ``response_format``):
      default    -> ``{"text": ...}`` plus usage
      timestamps -> ``verbose_json`` with ``text``/``segments``(/``words``)
      diarize    -> ``diarized_json`` with ``segments`` (anonymous speaker labels)
    """
    _raise_for_inline_base64(audio_ref)
    path, filename = _resolve_local_audio(audio_ref)
    if language is not None and not language.strip():
        raise ToolCallError(
            code="invalid_language", message="language must be a non-empty ISO 639-1 code"
        )
    if diarize and timestamps:
        # timestamps only apply to non-diarized shapes; diarize wins.
        timestamps = False
    if diarize:
        health = await client.fetch_health()
        if not _bool_flag(health.get("diarization_ready")):
            raise ToolCallError(
                code="diarization_not_available",
                message=(
                    "diarization is requested but the diarization engine is not "
                    "installed or not ready; install it (`uv sync --extra "
                    "diarization`) and check describe()"
                ),
                hint="call describe() and confirm diarization_ready is true",
            )
    try:
        content: bytes = await asyncio.to_thread(path.read_bytes)
    except OSError as exc:
        raise ToolCallError(
            code="audio_read_failed",
            message=f"failed to read audio file {path}: {exc}",
        ) from exc
    response_format = (
        "diarized_json" if diarize else ("verbose_json" if timestamps else "json")
    )
    return await client.transcribe(
        content=content,
        filename=filename,
        response_format=response_format,
        language=language,
    )


async def synthesize(
    client: SpeechRailClient,
    *,
    text: str,
    voice: str = "serena",
    output_format: str = "mp3",
    speed: float = 1.0,
    language: str = "auto",
    instruction: str | None = None,
    seed: int | None = None,
    validation_policy: str = "allow_unverified",
    expected_voice_revision: str | None = None,
    expected_model_revision: str | None = None,
) -> dict[str, Any]:
    """Synthesize ``text`` with ``voice`` into a local audio file.

    ``voice`` must come from ``describe().voices``; clone/instruction voices
    are rejected unless the active profile is the quality (voice_design) tier.
    The binary audio is written to a temporary file and returned as
    ``audio_path`` so it never enters the agent context.
    """
    stripped_text = text.strip()
    if not stripped_text:
        raise ToolCallError(code="invalid_text", message="text must not be blank")
    if len(stripped_text) > _MAX_TTS_TEXT:
        raise ToolCallError(
            code="invalid_text",
            message=f"text exceeds the {_MAX_TTS_TEXT} character limit",
        )
    if not voice.strip():
        raise ToolCallError(code="invalid_voice", message="voice must not be blank")
    if output_format not in _TTS_OUTPUT_FORMATS:
        raise ToolCallError(
            code="invalid_output_format",
            message="output_format must be one of " + ", ".join(sorted(_TTS_OUTPUT_FORMATS)),
        )
    if not _SPEED_RANGE[0] <= speed <= _SPEED_RANGE[1]:
        raise ToolCallError(
            code="invalid_speed",
            message=f"speed must be between {_SPEED_RANGE[0]} and {_SPEED_RANGE[1]}",
        )
    if validation_policy not in {"allow_unverified", "require_output_pass"}:
        raise ToolCallError(
            code="invalid_validation_policy",
            message="validation_policy must be allow_unverified or require_output_pass",
        )
    _validate_revision_pin(
        expected_voice_revision,
        field="voice_revision",
        pattern=_VOICE_REVISION_RE,
    )
    _validate_revision_pin(
        expected_model_revision,
        field="model_revision",
        pattern=_MODEL_REVISION_RE,
    )

    effective = await client.fetch_capabilities()
    raw_voices = effective.get("voices")
    effective_voices = (
        [entry for entry in raw_voices if isinstance(entry, dict)]
        if isinstance(raw_voices, list)
        else []
    )
    entry = _find_voice(effective_voices, voice)
    if entry is None:
        raise ToolCallError(
            code="voice_not_found",
            message=f"voice {voice!r} is not present in the effective capability snapshot",
            hint="call describe() and choose a voice from voices",
        )
    profile = _text(effective.get("profile"))
    variant = _effective_tts_variant(effective)
    _enforce_available_voice(
        entry,
        voice,
        variant=variant,
        profile=profile,
        validation_policy=validation_policy,
    )
    variant_value = _text(entry.get("variant")) or variant
    if variant_value not in {"voice_design", "custom_voice", "base"}:
        raise ToolCallError(
            code="tts_variant_unsupported",
            message="the effective capability snapshot does not publish a supported TTS variant",
            hint="call describe() and inspect the active TTS model",
        )
    voice_variant = cast(TtsModelVariant, variant_value)
    capabilities = entry.get("capabilities")
    capability_map = capabilities if isinstance(capabilities, dict) else {}
    is_clone = _text(entry.get("mode")) == "clone" or _bool_flag(
        capability_map.get("supports_clone")
    )
    try:
        validated = validate_tts_parameters(
            model_variant=voice_variant,
            is_clone=is_clone,
            speed=speed,
            language=language,
            instruction=instruction,
            seed=seed,
        )
    except TtsParameterError as exc:
        raise ToolCallError(
            code=exc.public_code,
            message=exc.message,
            hint="call describe() and align parameters with the selected voice capabilities",
        ) from None
    snapshot_voice_revision = _text(entry.get("voice_revision"))
    snapshot_model_revision = _effective_model_revision(effective, entry)
    if expected_voice_revision is None and _VOICE_REVISION_RE.fullmatch(
        snapshot_voice_revision or ""
    ):
        expected_voice_revision = snapshot_voice_revision
    if expected_model_revision is None and _MODEL_REVISION_RE.fullmatch(
        snapshot_model_revision or ""
    ):
        expected_model_revision = snapshot_model_revision
    model = _DEFAULT_TTS_MODEL
    content, request_id = await client.synthesize(
        model=model,
        text=stripped_text,
        voice=voice,
        response_format=output_format,
        speed=validated.speed,
        language=validated.language,
        instruction=instruction,
        seed=seed,
        validation_policy=validation_policy,
        expected_voice_revision=expected_voice_revision,
        expected_model_revision=expected_model_revision,
    )
    if not content:
        raise ToolCallError(
            code="empty_audio",
            message="SpeechRail returned an empty audio body for the request",
        )
    path = await asyncio.to_thread(
        _write_temp_audio, content, _TTS_OUTPUT_SUFFIXES[output_format]
    )
    return {
        "audio_path": path,
        "host": "mcp_host",
        "content_type": _TTS_CONTENT_TYPES[output_format],
        "output_format": output_format,
        "language": validated.language,
        "bytes": len(content),
        "request_id": request_id,
        "voice_revision": expected_voice_revision,
        "model_revision": expected_model_revision,
        "validation_policy": validation_policy,
        "validation_state": entry.get("validation_state"),
    }


async def preview_voice(
    client: SpeechRailClient,
    *,
    instruction: str,
    text: str,
) -> dict[str, Any]:
    """Generate an ephemeral VoiceDesign sample (quality tier only).

    Lets an agent audition a natural-language voice instruction before
    committing to it.  The binary audio is written to a temporary file and
    returned as ``audio_path``.  Nothing is persisted: call ``create_voice``
    to register the chosen instruction, then ``synthesize`` by its id.

    Instruction guidance (Qwen3-TTS VoiceDesign): write in Chinese or
    English only (30-200 words); be specific across gender/age/pitch/speed/
    emotion/characteristics/use-case; describe acoustic traits, never a real
    person; avoid contradictory dimensions (e.g. calm + frantic) and vague
    fillers (nice/normal).  Same instruction may yield slightly different
    voices per generation: audition again before rewording.
    """
    stripped_instruction = instruction.strip()
    if not stripped_instruction:
        raise ToolCallError(
            code="invalid_instruction", message="instruction must not be blank"
        )
    if len(stripped_instruction) > _MAX_PREVIEW_INSTRUCTION:
        raise ToolCallError(
            code="invalid_instruction",
            message=f"instruction exceeds the {_MAX_PREVIEW_INSTRUCTION} character limit",
        )
    stripped_text = text.strip()
    if not stripped_text:
        raise ToolCallError(code="invalid_text", message="text must not be blank")
    if len(stripped_text) > _MAX_PREVIEW_TEXT:
        raise ToolCallError(
            code="invalid_text",
            message=f"text exceeds the {_MAX_PREVIEW_TEXT} character limit",
        )
    effective = await client.fetch_capabilities()
    variant = _effective_tts_variant(effective)
    if variant != "voice_design":
        profile = _text(effective.get("profile")) or "not the quality profile"
        raise ToolCallError(
            code="voice_preview_unsupported",
            message=(
                "voice previews require the quality (voice_design) tier; the "
                f"active profile is {profile}. Call describe() to confirm "
                "current capabilities."
            ),
            hint="switch to the quality profile before using preview_voice",
        )
    content = await client.voice_preview(
        model=_DEFAULT_TTS_MODEL,
        text=stripped_text,
        instruction=stripped_instruction,
        response_format=_PREVIEW_FORMAT,
    )
    if not content:
        raise ToolCallError(
            code="empty_audio",
            message="SpeechRail returned an empty audio body for the preview",
        )
    path = await asyncio.to_thread(_write_temp_audio, content, _PREVIEW_SUFFIX)
    return {
        "audio_path": path,
        "content_type": _TTS_CONTENT_TYPES[_PREVIEW_FORMAT],
        "output_format": _PREVIEW_FORMAT,
        "bytes": len(content),
    }


async def create_voice(
    client: SpeechRailClient,
    *,
    name: str,
    instruction: str,
    voice_id: str | None = None,
    seed: int | None = None,
) -> dict[str, Any]:
    """Register a persistent instruction-driven voice (``POST /v1/voices``).

    Completes the preview → persist → synthesize loop: audition with
    ``preview_voice`` first, then persist the chosen instruction here and
    synthesize by the returned ``id``. The voice only synthesizes on the
    quality (voice_design) tier; on other tiers it is listed with
    ``available=false`` until the profile switches back.
    """
    stripped_name = name.strip()
    if not stripped_name:
        raise ToolCallError(code="invalid_name", message="name must not be blank")
    if len(stripped_name) > _MAX_VOICE_NAME:
        raise ToolCallError(
            code="invalid_name",
            message=f"name exceeds the {_MAX_VOICE_NAME} character limit",
        )
    stripped_instruction = instruction.strip()
    if not stripped_instruction:
        raise ToolCallError(
            code="invalid_instruction", message="instruction must not be blank"
        )
    if len(stripped_instruction) > _MAX_VOICE_INSTRUCTION:
        raise ToolCallError(
            code="invalid_instruction",
            message=(
                f"instruction exceeds the {_MAX_VOICE_INSTRUCTION} character limit"
            ),
        )
    normalized_id: str | None = None
    if voice_id is not None:
        normalized_id = voice_id.strip().lower()
        if not _VOICE_ID_RE.fullmatch(normalized_id):
            raise ToolCallError(
                code="invalid_voice_id",
                message="voice_id must match ^[a-zA-Z0-9_-]{1,64}$",
            )
    if seed is not None and (
        type(seed) is not int or not 0 <= seed <= _MAX_VOICE_SEED
    ):
        raise ToolCallError(
            code="invalid_seed",
            message=f"seed must be an integer between 0 and {_MAX_VOICE_SEED}",
        )
    return _safe_voice_record(
        await client.create_voice(
            name=stripped_name,
            instruction=stripped_instruction,
            voice_id=normalized_id,
            seed=seed,
        )
    )


async def get_voice(client: SpeechRailClient, *, voice_id: str) -> dict[str, Any]:
    """Read one safe voice detail without exposing its reference path."""
    stripped = voice_id.strip()
    if not stripped:
        raise ToolCallError(code="invalid_voice_id", message="voice_id must not be blank")
    return _safe_voice_record(await client.get_voice(voice_id=stripped))


async def design_voice(
    client: SpeechRailClient,
    *,
    voice_id: str,
    name: str,
    instruction: str,
    reference_text: str,
    seed: int = 42,
    language: str = "zh",
    idempotency_key: str | None = None,
) -> dict[str, Any]:
    """Generate a reference with VoiceDesign and register it for Base clone use."""
    normalized_id = voice_id.strip().lower()
    if not _VOICE_ID_RE.fullmatch(normalized_id):
        raise ToolCallError(
            code="invalid_voice_id",
            message="voice_id must match ^[a-zA-Z0-9_-]{1,64}$",
        )
    stripped_name = name.strip()
    stripped_instruction = instruction.strip()
    stripped_reference = reference_text.strip()
    if not stripped_name:
        raise ToolCallError(code="invalid_name", message="name must not be blank")
    if not stripped_instruction:
        raise ToolCallError(
            code="invalid_instruction", message="instruction must not be blank"
        )
    if not 20 <= len(stripped_reference) <= 240:
        raise ToolCallError(
            code="invalid_ref_text",
            message="reference_text must contain 20 to 240 characters",
        )
    if type(seed) is not int or not 0 <= seed <= _MAX_VOICE_SEED:
        raise ToolCallError(
            code="invalid_seed",
            message=f"seed must be an integer between 0 and {_MAX_VOICE_SEED}",
        )
    if language.strip().lower() != "zh":
        raise ToolCallError(
            code="unsupported_language",
            message="the current generated-reference registration gate accepts language=zh",
        )
    raw = await client.design_voice(
        voice_id=normalized_id,
        name=stripped_name,
        instruction=stripped_instruction,
        reference_text=stripped_reference,
        seed=seed,
        language="zh",
        idempotency_key=idempotency_key,
    )
    return _safe_voice_record(raw)


async def clone_voice(
    client: SpeechRailClient,
    *,
    audio_ref: str,
    name: str,
    ref_text: str,
    voice_id: str | None = None,
    idempotency_key: str | None = None,
) -> dict[str, Any]:
    """Register a local reference recording after the Base reference gate."""
    _raise_for_inline_base64(audio_ref)
    path, filename = _resolve_local_audio(audio_ref)
    stripped_name = name.strip()
    stripped_ref = ref_text.strip()
    if not stripped_name:
        raise ToolCallError(code="invalid_name", message="name must not be blank")
    if not stripped_ref:
        raise ToolCallError(code="invalid_ref_text", message="ref_text must not be blank")
    if voice_id is not None:
        normalized_id = voice_id.strip().lower()
        if not _VOICE_ID_RE.fullmatch(normalized_id):
            raise ToolCallError(
                code="invalid_voice_id",
                message="voice_id must match ^[a-zA-Z0-9_-]{1,64}$",
            )
    else:
        normalized_id = None
    try:
        content = await asyncio.to_thread(path.read_bytes)
    except OSError as exc:
        raise ToolCallError(
            code="audio_read_failed", message=f"failed to read audio file: {exc}"
        ) from exc
    return _safe_voice_record(
        await client.clone_voice(
            content=content,
            filename=filename,
            name=stripped_name,
            ref_text=stripped_ref,
            voice_id=normalized_id,
            idempotency_key=idempotency_key,
        )
    )


async def validate_voice(
    client: SpeechRailClient,
    *,
    voice_id: str,
    runs: int = 1,
) -> dict[str, Any]:
    """Run output validation for a registered clone voice and return its report."""
    stripped = voice_id.strip()
    if not stripped:
        raise ToolCallError(code="invalid_voice_id", message="voice_id must not be blank")
    if type(runs) is not int or not 1 <= runs <= 3:
        raise ToolCallError(code="invalid_runs", message="runs must be an integer between 1 and 3")
    result = await client.validate_voice(voice_id=stripped, runs=runs)
    return {"voice_id": stripped, **result}


async def delete_voice(client: SpeechRailClient, *, voice_id: str) -> dict[str, Any]:
    """Delete a persistent custom voice (``DELETE /v1/voices/{id}``)."""
    stripped = voice_id.strip()
    if not stripped:
        raise ToolCallError(
            code="invalid_voice_id", message="voice_id must not be blank"
        )
    return await client.delete_voice(voice_id=stripped)


async def create_job(
    client: SpeechRailClient,
    *,
    kind: str,
    input_ref: str,
    params: dict[str, Any] | None = None,
    idempotency_key: str | None = None,
) -> dict[str, Any]:
    """Create a durable job (``transcription`` or ``speech``).

    ``input_ref`` reuses the same path/URI convention as ``audio_ref``.
    ``params`` is a kind-specific caller-supplied JSON object that the server
    stores and echoes back on GET.  Speech jobs support the same validation
    policy names as synchronous TTS.
    """
    if kind not in _JOB_KINDS:
        raise ToolCallError(
            code="invalid_job_kind",
            message="kind must be one of " + ", ".join(sorted(_JOB_KINDS)),
        )
    stripped_ref = input_ref.strip()
    if not stripped_ref:
        raise ToolCallError(code="invalid_input_ref", message="input_ref must not be blank")
    if len(stripped_ref) > _MAX_JOB_REF:
        raise ToolCallError(
            code="invalid_input_ref",
            message=f"input_ref exceeds the {_MAX_JOB_REF} character limit",
        )
    if params is not None:
        try:
            validate_job_params(kind, params)
        except JobParamsValidationError as exc:
            raise ToolCallError(code="invalid_params", message=str(exc)) from None
    if idempotency_key is not None and not idempotency_key.strip():
        raise ToolCallError(
            code="invalid_idempotency_key", message="idempotency_key must not be blank"
        )
    return await client.create_job(
        kind=kind,
        input_ref=stripped_ref,
        params=params,
        idempotency_key=idempotency_key,
    )


async def get_job(client: SpeechRailClient, *, job_id: str) -> dict[str, Any]:
    """Fetch a durable job by ``job_id`` and return its current record."""
    stripped = job_id.strip()
    if not stripped:
        raise ToolCallError(code="invalid_job_id", message="job_id must not be blank")
    return await client.get_job(job_id=stripped)


async def list_jobs(
    client: SpeechRailClient,
    *,
    limit: int = 20,
    cursor: str | None = None,
) -> dict[str, Any]:
    """List owner-scoped jobs with bounded pagination."""
    if type(limit) is not int or not 1 <= limit <= 100:
        raise ToolCallError(
            code="invalid_limit", message="limit must be an integer between 1 and 100"
        )
    if cursor is not None and len(cursor) > 512:
        raise ToolCallError(code="invalid_cursor", message="cursor is too long")
    return await client.list_jobs(limit=limit, cursor=cursor)


async def get_job_result(
    client: SpeechRailClient,
    *,
    job_id: str,
) -> dict[str, Any]:
    """Materialize one completed job result into a local MCP-host file."""
    stripped = job_id.strip()
    if not stripped:
        raise ToolCallError(code="invalid_job_id", message="job_id must not be blank")
    content, content_type = await client.get_job_result(job_id=stripped)
    if not content:
        raise ToolCallError(
            code="empty_job_result", message="SpeechRail returned an empty job result"
        )
    suffix = _JOB_RESULT_SUFFIXES.get(content_type, ".bin")
    path = await asyncio.to_thread(_write_temp_audio, content, suffix)
    return {
        "result_path": path,
        "host": "mcp_host",
        "content_type": content_type,
        "bytes": len(content),
        "job_id": stripped,
    }


async def cancel_job(client: SpeechRailClient, *, job_id: str) -> dict[str, Any]:
    """Cancel a durable job by ``job_id`` and return its updated record."""
    stripped = job_id.strip()
    if not stripped:
        raise ToolCallError(code="invalid_job_id", message="job_id must not be blank")
    return await client.cancel_job(job_id=stripped)
