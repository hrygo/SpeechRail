import pytest
from pydantic import ValidationError

from speechrail.config.profiles import Capability, RuntimeProfile
from speechrail.domain.contracts import TranscriptSegment, TranscriptWindow
from speechrail.runtime.registry import ModelRegistry


def test_segment_rejects_invalid_timestamps_and_blank_text() -> None:
    with pytest.raises(ValidationError):
        TranscriptSegment(id=0, start_ms=-1, end_ms=0, text="hello")
    with pytest.raises(ValidationError):
        TranscriptSegment(id=0, start_ms=2, end_ms=1, text="hello")
    with pytest.raises(ValidationError):
        TranscriptSegment(id=0, start_ms=0, end_ms=1, text="   ")


def test_partial_window_is_not_final_and_sequences_are_monotonic() -> None:
    partial = TranscriptWindow(source_epoch=3, sequence=1, partial="draft")
    assert partial.is_final is False

    final = TranscriptWindow(source_epoch=3, sequence=2)
    assert final.is_final is True

    with pytest.raises(ValidationError):
        TranscriptWindow(source_epoch=3, sequence=2, partial="draft", final=True)


def test_registry_canonicalizes_aliases_and_reports_unsupported_capabilities() -> None:
    profile = RuntimeProfile(
        name="qwen3-batch",
        capabilities=frozenset({Capability.BATCH, Capability.SEGMENT_TIMESTAMPS}),
    )
    registry = ModelRegistry(
        canonical_model_id="speechrail/qwen3-asr-1.7b",
        aliases=("Qwen3-ASR-1.7B", "whisper-1"),
        profiles=(profile,),
    )

    assert registry.resolve("Qwen3-ASR-1.7B") == "speechrail/qwen3-asr-1.7b"
    assert registry.require_capability("speechrail/qwen3-asr-1.7b", Capability.BATCH) == profile

    with pytest.raises(ValueError, match="model_not_found"):
        registry.resolve("not-a-model")
    with pytest.raises(ValueError, match="capability_not_supported"):
        registry.require_capability("whisper-1", Capability.WORD_TIMESTAMPS)
