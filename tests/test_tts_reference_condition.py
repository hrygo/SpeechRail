from __future__ import annotations

import pytest

from speechrail.domain.tts_reference_condition import (
    MLX_AUDIO_0_4_8_QWEN3_TTS_SUPPORT,
    PreparedReferenceUnsupportedError,
    UnsupportedPreparedReferenceProvider,
)


def test_pinned_mlx_audio_prepared_reference_support_is_explicitly_unsupported() -> None:
    support = MLX_AUDIO_0_4_8_QWEN3_TTS_SUPPORT

    assert support.vendor_package == "mlx-audio"
    assert support.vendor_version == "0.4.8"
    assert support.public_contract == "generate(ref_audio, ref_text)"
    assert support.private_cache_observed is True
    assert support.supported is False
    assert support.reason == "public_api_has_no_reusable_prepared_reference_condition"


def test_unsupported_provider_fails_closed_without_retaining_reference_material() -> None:
    provider = UnsupportedPreparedReferenceProvider()

    with pytest.raises(PreparedReferenceUnsupportedError) as caught:
        provider.prepare(
            reference_audio=b"private-pcm",
            reference_text="private reference text",
            voice_revision="vr_" + "1" * 32,
            model_revision=None,
        )

    assert str(caught.value) == provider.support.reason
    assert not vars(provider)
