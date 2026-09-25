from __future__ import annotations

from dataclasses import FrozenInstanceError

import pytest

from speechrail.backends.qwen3_voice_binding import VoiceBinding, resolve_binding
from speechrail.domain.tts import VOICE_ALIASES, VOICE_PROFILES, VoiceCapabilities


def test_custom_voice_is_explicitly_bound() -> None:
    binding = resolve_binding("custom_voice", "serena")

    assert binding.speaker == "Serena"
    assert binding.voice == "serena"
    assert binding.instruction is None


@pytest.mark.parametrize(
    ("voice", "speaker"),
    [
        ("serena", "Serena"),
        ("vivian", "Vivian"),
        ("uncle_fu", "Uncle_Fu"),
        ("dylan", "Dylan"),
        ("eric", "Eric"),
        ("ryan", "Ryan"),
        ("aiden", "Aiden"),
        ("ono_anna", "Ono_Anna"),
        ("sohee", "Sohee"),
    ],
)
def test_custom_voice_uses_shared_vendor_speaker_mapping(voice: str, speaker: str) -> None:
    binding = resolve_binding("custom_voice", voice)

    assert binding.speaker == speaker
    assert binding.instruction is None


@pytest.mark.parametrize("voice", tuple(VOICE_PROFILES))
def test_voice_design_preserves_each_existing_instruction(voice: str) -> None:
    binding = resolve_binding("voice_design", voice)

    assert binding.speaker is None
    assert binding.instruction == VOICE_PROFILES[voice].instruction


@pytest.mark.parametrize(("alias", "preset"), tuple(VOICE_ALIASES.items()))
def test_aliases_are_resolved_before_profile_lookup(alias: str, preset: str) -> None:
    binding = resolve_binding("custom_voice", alias)

    assert binding.voice == preset


def test_voice_lookup_keeps_existing_case_sensitive_behavior() -> None:
    with pytest.raises(ValueError, match="unknown preset voice"):
        resolve_binding("custom_voice", "DEFAULT")


def test_unknown_voice_and_variant_fail_closed() -> None:
    with pytest.raises(ValueError, match="unknown preset voice"):
        resolve_binding("custom_voice", "not-registered")
    with pytest.raises(ValueError, match="unsupported voice role"):
        resolve_binding("unknown", "serena")


def test_binding_and_public_capabilities_are_frozen_and_path_free() -> None:
    binding = resolve_binding("custom_voice", "serena")
    capabilities = VoiceCapabilities(
        variant="custom_voice", supports_speaker=True, supports_instruction=False
    )

    with pytest.raises(FrozenInstanceError):
        binding.speaker = "Vivian"  # type: ignore[misc]
    with pytest.raises(FrozenInstanceError):
        capabilities.variant = "voice_design"  # type: ignore[misc]

    assert not hasattr(capabilities, "model_path")
    assert capabilities.supports_speaker is True
    assert capabilities.supports_instruction is False
    assert VoiceBinding.__dataclass_params__.frozen is True


def test_custom_profile_without_vendor_speaker_fails_closed(monkeypatch) -> None:
    import speechrail.backends.qwen3_voice_binding as binding_module
    from speechrail.domain.tts import VoiceProfile

    monkeypatch.setattr(
        binding_module,
        "get_voice_profile",
        lambda _voice: VoiceProfile(id="user_voice", instruction="温柔的声音"),
    )

    with pytest.raises(ValueError, match="no custom_voice speaker binding"):
        resolve_binding("custom_voice", "user_voice")


def test_clone_binding_error_describes_missing_base_capability_without_tier_name(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import speechrail.backends.qwen3_voice_binding as binding_module
    from speechrail.domain.tts import VoiceProfile

    monkeypatch.setattr(
        binding_module,
        "get_voice_profile",
        lambda _voice: VoiceProfile(id="user_voice", mode="clone"),
    )

    with pytest.raises(
        ValueError, match="requires an active Base clone capability"
    ) as excinfo:
        resolve_binding("voice_design", "user_voice")

    assert "quality" not in str(excinfo.value).lower()


def test_incremental_capability_is_limited_to_speaker_and_clone_bindings() -> None:
    assert resolve_binding("custom_voice", "serena").supports_incremental_stream is True
    assert (
        VoiceBinding(
            variant="custom_voice", voice="serena", speaker=None, instruction=None
        ).supports_incremental_stream
        is False
    )
    assert (
        VoiceBinding(
            variant="base",
            voice="serena",
            speaker=None,
            instruction=None,
            is_clone=True,
            ref_audio_path="/tmp/ref.wav",
            ref_text="参考文本",
        ).supports_incremental_stream
        is True
    )
    assert (
        VoiceBinding(
            variant="base", voice="serena", speaker=None, instruction=None, is_clone=False
        ).supports_incremental_stream
        is False
    )


@pytest.mark.parametrize("voice", ("serena", "vivian"))
def test_voice_design_never_declares_incremental_stream(voice: str) -> None:
    binding = resolve_binding("voice_design", voice)

    assert binding.instruction
    assert binding.supports_incremental_stream is False


@pytest.mark.parametrize("role", ("tts_custom_voice", "custom_voice"))
def test_plan_role_and_engine_variant_resolve_the_same_route(role: str) -> None:
    binding = resolve_binding(role, "serena")

    assert binding.variant == "custom_voice"
    assert binding.speaker == "Serena"


def test_base_role_never_accepts_a_builtin_speaker() -> None:
    with pytest.raises(ValueError, match="not a clone voice"):
        resolve_binding("tts_base", "serena")


def test_custom_voice_role_never_accepts_a_clone_revision(monkeypatch) -> None:
    import speechrail.backends.qwen3_voice_binding as binding_module
    from speechrail.domain.tts import VoiceProfile

    monkeypatch.setattr(
        binding_module,
        "get_voice_profile",
        lambda _voice: VoiceProfile(id="user_voice", mode="clone", ref_text="参考文本"),
    )

    with pytest.raises(ValueError, match="requires an active Base clone capability"):
        resolve_binding("tts_custom_voice", "user_voice")


def test_instruction_voices_are_design_candidates_not_runtime_voices(monkeypatch) -> None:
    import speechrail.backends.qwen3_voice_binding as binding_module
    from speechrail.domain.tts import VoiceProfile

    monkeypatch.setattr(
        binding_module,
        "get_voice_profile",
        lambda _voice: VoiceProfile(id="user_voice", mode="instruction", instruction="温柔"),
    )

    with pytest.raises(ValueError, match="voice_design task"):
        resolve_binding("tts_custom_voice", "user_voice")
