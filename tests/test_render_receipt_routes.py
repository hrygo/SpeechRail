from __future__ import annotations

import hashlib
import json
import re
from collections.abc import AsyncIterator
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from speechrail.app import create_app
from speechrail.config import Settings
from speechrail.domain.model_spec import required_spec_artifact
from speechrail.domain.ports import AudioChunk, SpeechRequest
from speechrail.domain.render_recipe import PRONUNCIATION_UNUSED
from speechrail.domain.tts import VoiceRegistry
from speechrail.domain.tts_pronunciation import PronunciationRegistry
from speechrail.domain.tts_sampling import TtsSamplingObservation

_PCM = b"\x01\x00\x02\x00\x03\x00"


class ReceiptSynthesizer:
    def __init__(
        self,
        *,
        fail: bool = False,
        fail_after_first_chunk: bool = False,
        runtime_revision: str | None = None,
        sampling: TtsSamplingObservation | None = None,
    ) -> None:
        self.requests: list[SpeechRequest] = []
        self.fail = fail
        self.fail_after_first_chunk = fail_after_first_chunk
        self.runtime_revision = runtime_revision
        self.sampling = sampling

    def runtime_revision_for_voice(self, voice: str) -> str | None:
        del voice
        return self.runtime_revision

    def take_sampling_observation(
        self,
        response_id: str,
    ) -> TtsSamplingObservation | None:
        assert response_id == "backend-response"
        return self.sampling

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        self.requests.append(request)

        async def chunks() -> AsyncIterator[AudioChunk]:
            if self.fail:
                raise RuntimeError("synthetic receipt failure")
            yield AudioChunk(
                response_id="backend-response",
                chunk_index=0,
                audio=_PCM,
            )
            if self.fail_after_first_chunk:
                # The boundary plan C1-3 asks for: produce and book a chunk
                # first, then fail halfway. A different path from `fail`,
                # which raises before producing anything at all.
                raise RuntimeError("synthetic receipt failure after first chunk")

        return chunks()


def _client(
    tmp_path: Path,
    monkeypatch,
    *,
    fail: bool = False,
    fail_after_first_chunk: bool = False,
    runtime_revision: str | None = None,
    sampling: TtsSamplingObservation | None = None,
    with_pronunciation: bool = False,
) -> tuple[TestClient, ReceiptSynthesizer, str, PronunciationRegistry | None]:
    asr_key = required_spec_artifact("quality", "asr")
    tts_key = required_spec_artifact("quality", "tts_custom_voice")
    base_key = required_spec_artifact("quality", "tts_base")
    assert asr_key is not None and tts_key is not None and base_key is not None
    registry = VoiceRegistry(
        storage_path=tmp_path / "custom_voices.json",
        voices_dir=tmp_path / "voices",
    )
    profile = registry.create_cloned_profile(
        name="Narrator",
        ref_text="参考文本。",
        audio_bytes=b"RIFF-test-reference",
        voice_id="narrator",
        duration_seconds=3.0,
    )
    assert profile.revision is not None
    monkeypatch.setattr(
        "speechrail.domain.tts._GLOBAL_VOICE_REGISTRY",
        registry,
    )
    synth = ReceiptSynthesizer(
        fail=fail,
        fail_after_first_chunk=fail_after_first_chunk,
        runtime_revision=runtime_revision,
        sampling=sampling,
    )
    pronunciation: PronunciationRegistry | None = None
    if with_pronunciation:
        pronunciation = PronunciationRegistry(tmp_path / "pronunciation.json")
        monkeypatch.setattr(
            "speechrail.http.routes.system.get_pronunciation_registry",
            lambda: pronunciation,
        )
        monkeypatch.setattr(
            "speechrail.http.routes.audio.get_pronunciation_registry",
            lambda: pronunciation,
        )
    app = create_app(
        Settings(
            qwen3_model_dir=tmp_path / asr_key,
            asr_resident_bytes=1 * 1024**3,
            qwen3_python=None,
            qwen3_tts_model_dir=tmp_path / tts_key,
            tts_resident_bytes=1 * 1024**3,
            qwen3_tts_clone_model_dir=tmp_path / base_key,
            qwen3_tts_python=None,
            selection_schema_version=2,
            selection_asr_spec="quality",
            selection_tts_spec="quality",
            asr_artifact_key=asr_key,
            tts_artifact_key=tts_key,
            tts_base_artifact_key=base_key,
        ),
        tts_synthesizer=synth,
    )
    return TestClient(app), synth, profile.revision, pronunciation


def _payload() -> dict[str, object]:
    return {
        "model": "speechrail/qwen3-tts",
        "input": "测试渲染回执。",
        "voice": "narrator",
        "response_format": "wav",
    }


def _quality_tts_revision() -> str:
    from speechrail.config.model_catalog import load_catalog

    artifact_key = required_spec_artifact("quality", "tts_base")
    assert artifact_key is not None
    artifact = next(item for item in load_catalog().artifacts if item.key == artifact_key)
    return artifact.revision


def test_v1_speech_returns_negotiated_receipt_bound_to_revision(
    tmp_path: Path,
    monkeypatch,
) -> None:
    client, synth, revision, _pronunciation = _client(tmp_path, monkeypatch)

    response = client.post(
        "/v1/audio/speech",
        json=_payload(),
        headers={"SpeechRail-Receipt-Mode": "integrity"},
    )
    assert response.status_code == 200
    receipt_id = response.headers["SpeechRail-Receipt-Id"]
    assert receipt_id.startswith("rr_")
    assert len(synth.requests) == 1
    assert synth.requests[0].expected_voice_revision == revision

    receipt_response = client.get(f"/v1/speechrail/audio/receipts/{receipt_id}")
    assert receipt_response.status_code == 200
    receipt = receipt_response.json()
    assert receipt["status"] == "completed"
    assert receipt["voice"] == {
        "id": "narrator",
        "revision": revision,
    }
    assert receipt["audio"]["sample_count"] == len(_PCM) // 2
    assert receipt["audio"]["pcm_sha256"] == hashlib.sha256(_PCM).hexdigest()
    assert receipt["audio"]["integrity_boundary"] == "pcm16_pre_transport"
    assert receipt["model"]["runtime_revision"] is None
    assert "测试渲染回执" not in receipt_response.text


def test_v1_receipt_binds_observed_runtime_revision(
    tmp_path: Path,
    monkeypatch,
) -> None:
    runtime_revision = "rt_" + ("d" * 64)
    client, _synth, _revision, _pronunciation = _client(
        tmp_path,
        monkeypatch,
        runtime_revision=runtime_revision,
    )

    response = client.post(
        "/v1/audio/speech",
        json=_payload(),
        headers={"SpeechRail-Receipt-Mode": "integrity"},
    )
    receipt_id = response.headers["SpeechRail-Receipt-Id"]

    receipt = client.get(f"/v1/speechrail/audio/receipts/{receipt_id}").json()
    assert receipt["model"]["runtime_revision"] == runtime_revision


def test_v1_receipt_reports_a_real_plan_identity_and_recipe(
    tmp_path: Path,
    monkeypatch,
) -> None:
    client, _synth, _revision, _pronunciation = _client(tmp_path, monkeypatch)

    response = client.post(
        "/v1/audio/speech",
        json=_payload(),
        headers={"SpeechRail-Receipt-Mode": "integrity"},
    )
    receipt = client.get(
        f"/v1/speechrail/audio/receipts/{response.headers['SpeechRail-Receipt-Id']}"
    ).json()

    plan = receipt["plan"]
    assert plan["plan_id"] is not None
    assert re.fullmatch(r"plan_[0-9a-f]{32}", plan["plan_id"])
    # The App stores the full digest next to the short id; a receipt that only
    # carried `plan_id` would leave every saved work without it, silently.
    assert re.fullmatch(r"[0-9a-f]{64}", str(plan["plan_sha256"]))
    assert plan["plan_id"] == "plan_" + str(plan["plan_sha256"])[:32]
    recipe = receipt["recipe"]
    assert recipe["schema_version"] == "render_recipe_v1"
    assert recipe["voice"]["id"] == "narrator"
    assert recipe["model"]["role"] == "tts"
    assert recipe["model"]["artifact"] is not None
    assert recipe["content"]["raw_text_sha256"] == hashlib.sha256(
        "测试渲染回执。".encode()
    ).hexdigest()
    assert recipe["parameters"]["output_format"] == "wav"
    assert recipe["parameters"]["sample_rate"] == 24_000
    # This fake worker never reports an engine identity, so the recipe stays
    # partial instead of borrowing the artifact revision as the runtime.
    assert "model.engine_revision" in recipe["missing_fields"]
    assert recipe["state"] == "partial"
    assert recipe["digest"] is None
    assert "测试渲染回执" not in json.dumps(recipe, ensure_ascii=False)


def test_v1_recipe_completes_once_the_worker_identity_is_observed(
    tmp_path: Path,
    monkeypatch,
) -> None:
    runtime_revision = "rt_" + ("d" * 64)
    client, _synth, _revision, _pronunciation = _client(
        tmp_path,
        monkeypatch,
        runtime_revision=runtime_revision,
    )

    response = client.post(
        "/v1/audio/speech",
        json=_payload(),
        headers={"SpeechRail-Receipt-Mode": "integrity"},
    )
    receipt = client.get(
        f"/v1/speechrail/audio/receipts/{response.headers['SpeechRail-Receipt-Id']}"
    ).json()

    recipe = receipt["recipe"]
    assert recipe["model"]["engine_revision"] == runtime_revision
    # Seed policy stays unknown until the adapter reports what it used.
    assert "parameters.seed_policy" in recipe["missing_fields"]
    assert recipe["state"] == "partial"


def test_two_renders_of_the_same_request_share_one_plan_but_not_one_recipe(
    tmp_path: Path,
    monkeypatch,
) -> None:
    client, _synth, _revision, _pronunciation = _client(tmp_path, monkeypatch)

    def _plan_id_for(text: str) -> str:
        payload = _payload()
        payload["input"] = text
        response = client.post(
            "/v1/audio/speech",
            json=payload,
            headers={"SpeechRail-Receipt-Mode": "integrity"},
        )
        receipt = client.get(
            f"/v1/speechrail/audio/receipts/"
            f"{response.headers['SpeechRail-Receipt-Id']}"
        ).json()
        return str(receipt["plan"]["plan_id"])

    assert _plan_id_for("第一段口播文稿。") == _plan_id_for("完全不同的第二段文稿。")


def test_recipe_separates_the_caller_text_from_what_the_pronunciation_set_produced(
    tmp_path: Path,
    monkeypatch,
) -> None:
    """A substitution is a different acoustic fact, not a different request.

    The recipe has to report both: `raw_text_sha256` is what the caller sent,
    `acoustic_text_sha256` is what reached the model. Collapsing them — or
    reporting "no pronunciation set" for a render that used one — produces a
    complete recipe with a digest that describes a render that never ran.
    """
    client, synth, _revision, pronunciation = _client(
        tmp_path,
        monkeypatch,
        runtime_revision="rt_" + ("9" * 64),
        sampling=TtsSamplingObservation(
            seed_policy="caller_fixed",
            seed=7,
            temperature=0.8,
            top_p=0.95,
            repetition_penalty=1.05,
        ),
        with_pronunciation=True,
    )
    assert pronunciation is not None
    created = client.put(
        "/v1/speechrail/pronunciation-sets/story",
        json={
            "expected_revision": None,
            "entries": [
                {
                    "id": "place",
                    "surface": "长安",
                    "spoken": "常安",
                    "language": "zh",
                    "case_sensitive": True,
                    "word_boundary": False,
                    "source": "user",
                }
            ],
        },
    )
    assert created.status_code == 200
    set_revision = created.json()["revision"]

    payload = _payload()
    payload["input"] = "去长安"
    response = client.post(
        "/v1/audio/speech",
        json=payload,
        headers={
            "SpeechRail-Receipt-Mode": "integrity",
            "SpeechRail-Pronunciation-Set": f"story@{set_revision}",
            "SpeechRail-Language": "zh",
        },
    )
    assert response.status_code == 200

    recipe = client.get(
        f"/v1/speechrail/audio/receipts/{response.headers['SpeechRail-Receipt-Id']}"
    ).json()["recipe"]

    spoken = synth.requests[-1].text
    assert spoken != payload["input"], "this test needs a substitution to differ"
    assert recipe["content"]["raw_text_sha256"] == hashlib.sha256(
        str(payload["input"]).encode()
    ).hexdigest()
    assert recipe["content"]["acoustic_text_sha256"] == hashlib.sha256(
        spoken.encode()
    ).hexdigest()
    assert recipe["content"]["pronunciation_set_id"] == "story"
    assert recipe["content"]["pronunciation_revision"] == set_revision
    # Every fact was observed, so the recipe may claim completeness — and then
    # the digest really is a digest of *this* render.
    assert recipe["missing_fields"] == []
    assert recipe["state"] == "complete"


def test_a_render_without_a_pronunciation_set_says_so_explicitly(
    tmp_path: Path,
    monkeypatch,
) -> None:
    """`unused` is an observed fact; a missing field is a different statement."""
    client, _synth, _revision, _pronunciation = _client(tmp_path, monkeypatch)

    response = client.post(
        "/v1/audio/speech",
        json=_payload(),
        headers={"SpeechRail-Receipt-Mode": "integrity"},
    )
    recipe = client.get(
        f"/v1/speechrail/audio/receipts/{response.headers['SpeechRail-Receipt-Id']}"
    ).json()["recipe"]

    assert recipe["content"]["pronunciation_revision"] == PRONUNCIATION_UNUSED
    assert "content.pronunciation_revision" not in recipe["missing_fields"]


def test_v1_recipe_completes_once_the_worker_reports_its_sampler(
    tmp_path: Path,
    monkeypatch,
) -> None:
    """Worker-reported sampling facts are the last missing recipe field."""
    client, _synth, _revision, _pronunciation = _client(
        tmp_path,
        monkeypatch,
        runtime_revision="rt_" + ("e" * 64),
        sampling=TtsSamplingObservation(
            seed_policy="clone_reference_derived",
            seed=4242,
            temperature=0.1,
            top_p=0.95,
            repetition_penalty=1.5,
        ),
    )

    response = client.post(
        "/v1/audio/speech",
        json=_payload(),
        headers={"SpeechRail-Receipt-Mode": "integrity"},
    )
    receipt = client.get(
        f"/v1/speechrail/audio/receipts/{response.headers['SpeechRail-Receipt-Id']}"
    ).json()

    recipe = receipt["recipe"]
    assert recipe["parameters"]["seed_policy"] == "clone_reference_derived"
    assert recipe["parameters"]["observed_sampling_parameters"] == {
        "seed_policy": "clone_reference_derived",
        "seed": 4242,
        "temperature": 0.1,
        "top_p": 0.95,
        "repetition_penalty": 1.5,
    }
    assert recipe["missing_fields"] == []
    assert recipe["state"] == "complete"
    assert re.fullmatch(r"[0-9a-f]{64}", str(recipe["digest"]))


def test_an_unseeded_sampler_completes_the_recipe_without_claiming_reproducibility(
    tmp_path: Path,
    monkeypatch,
) -> None:
    """`unseeded_sampler` is a fact: the recipe is complete, not reproducible."""
    client, _synth, _revision, _pronunciation = _client(
        tmp_path,
        monkeypatch,
        runtime_revision="rt_" + ("f" * 64),
        sampling=TtsSamplingObservation(
            seed_policy="unseeded_sampler",
            seed=None,
            temperature=0.7,
            top_p=0.95,
            repetition_penalty=1.05,
        ),
    )

    response = client.post(
        "/v1/audio/speech",
        json=_payload(),
        headers={"SpeechRail-Receipt-Mode": "integrity"},
    )
    receipt = client.get(
        f"/v1/speechrail/audio/receipts/{response.headers['SpeechRail-Receipt-Id']}"
    ).json()

    recipe = receipt["recipe"]
    assert recipe["state"] == "complete"
    assert recipe["parameters"]["seed_policy"] == "unseeded_sampler"
    assert recipe["parameters"]["observed_sampling_parameters"]["seed"] is None


def test_v1_accepts_namespaced_revision_pin_header(
    tmp_path: Path,
    monkeypatch,
) -> None:
    client, synth, revision, _pronunciation = _client(tmp_path, monkeypatch)
    response = client.post(
        "/v1/audio/speech",
        json=_payload(),
        headers={"SpeechRail-Expected-Voice-Revision": revision},
    )
    assert response.status_code == 200
    assert len(synth.requests) == 1
    assert synth.requests[0].expected_voice_revision == revision
    assert "SpeechRail-Receipt-Id" not in response.headers


def test_v1_accepts_namespaced_model_revision_pin(
    tmp_path: Path,
    monkeypatch,
) -> None:
    client, synth, _revision, _pronunciation = _client(tmp_path, monkeypatch)
    model_revision = _quality_tts_revision()
    response = client.post(
        "/v1/audio/speech",
        json=_payload(),
        headers={"SpeechRail-Expected-Model-Revision": model_revision},
    )
    assert response.status_code == 200
    assert len(synth.requests) == 1
    assert synth.requests[0].expected_model_revision == model_revision


def test_v1_rejects_stale_model_revision_before_synthesis(
    tmp_path: Path,
    monkeypatch,
) -> None:
    client, synth, _revision, _pronunciation = _client(tmp_path, monkeypatch)
    response = client.post(
        "/v1/audio/speech",
        json=_payload(),
        headers={"SpeechRail-Expected-Model-Revision": "0" * 40},
    )
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "model_revision_conflict"
    assert synth.requests == []


def test_failed_negotiated_speech_keeps_error_receipt_queryable_by_request(
    tmp_path: Path,
    monkeypatch,
) -> None:
    client, _synth, _revision, _pronunciation = _client(tmp_path, monkeypatch, fail=True)
    response = client.post(
        "/v1/audio/speech",
        json=_payload(),
        headers={"SpeechRail-Receipt-Mode": "integrity"},
    )
    assert response.status_code == 502
    request_id = response.json()["error"]["request_id"]

    receipt_response = client.get(
        f"/v1/speechrail/audio/receipts/by-request/{request_id}"
    )
    assert receipt_response.status_code == 200
    receipt = receipt_response.json()
    assert receipt["status"] == "error"
    assert receipt["error_code"] == "backend_error"
    assert receipt["audio"]["sample_count"] == 0


def test_a_vendor_error_after_real_pcm_never_marks_the_receipt_completed(
    tmp_path: Path,
    monkeypatch,
) -> None:
    """The first boundary named by plan C1-3: a vendor error after real PCM.

    This is a different path from
    `test_failed_negotiated_speech_keeps_error_receipt_queryable_by_request`,
    which asserts `sample_count == 0` and therefore covers "failed before
    producing anything". Here a chunk is produced and booked by `accept_pcm`
    first, so the `sample_count == 0` guard inside `complete()` no longer
    applies: if the control flow ever routed this path into `complete()`, the
    receipt would claim `completed` while carrying truncated audio.

    So this test guards the wiring, not the store's internal state machine.
    """

    client, _synth, _revision, _pronunciation = _client(
        tmp_path, monkeypatch, fail_after_first_chunk=True
    )
    response = client.post(
        "/v1/audio/speech",
        json=_payload(),
        headers={"SpeechRail-Receipt-Mode": "integrity"},
    )
    assert response.status_code >= 400
    request_id = response.json()["error"]["request_id"]

    receipt = client.get(
        f"/v1/speechrail/audio/receipts/by-request/{request_id}"
    ).json()
    assert receipt["status"] != "completed", "带着截断音频的回执不得声称完成"
    assert receipt["status"] == "error"
    assert receipt["audio"]["sample_count"] > 0, "前半段 PCM 已被记账，事实不得被抹掉"


def test_openai_custom_voice_object_is_accepted_on_v1_speech(
    tmp_path: Path,
    monkeypatch,
) -> None:
    client, synth, _revision, _pronunciation = _client(tmp_path, monkeypatch)
    payload = _payload()
    payload["voice"] = {"id": "narrator"}

    response = client.post("/v1/audio/speech", json=payload)

    assert response.status_code == 200
    assert len(synth.requests) == 1
    assert synth.requests[0].voice == "narrator"
    assert "SpeechRail-Receipt-Id" not in response.headers


def test_pcm_response_cancel_closes_backend_before_releasing_lane_or_receipt(
    tmp_path: Path, monkeypatch,
) -> None:
    import asyncio

    import pytest
    from starlette.responses import Response, StreamingResponse

    import speechrail.app as app_module

    captured = []
    original_build = app_module.build_app_services

    def capture_services(*args, **kwargs):
        services = original_build(*args, **kwargs)
        captured.append(services)
        return services

    monkeypatch.setattr(app_module, "build_app_services", capture_services)
    client, synth, _, _ = _client(tmp_path, monkeypatch)

    class Source:
        def __init__(self):
            self.entered = asyncio.Event()
            self.release = asyncio.Event()
            self.closed = False
            self.index = 0

        def __aiter__(self):
            return self

        async def __anext__(self):
            chunk = AudioChunk(
                response_id="backend-response", chunk_index=self.index, audio=_PCM,
            )
            self.index += 1
            return chunk

        async def aclose(self):
            self.entered.set()
            await self.release.wait()
            self.closed = True

    sources = []

    def synthesize(request):
        synth.requests.append(request)
        source = Source()
        sources.append(source)
        return source

    monkeypatch.setattr(synth, "synthesize", synthesize)

    class CancelResponse(StreamingResponse):
        async def __call__(self, scope, receive, send):
            iterator = self.body_iterator
            assert await anext(iterator) == _PCM
            cleanup = asyncio.create_task(iterator.athrow(asyncio.CancelledError()))
            try:
                for _ in range(10):
                    await asyncio.sleep(0)
                services = captured[0]
                receipt_id = self.headers["SpeechRail-Receipt-Id"]
                assert sources[0].entered.is_set(), "backend must be closed explicitly"
                assert services.governor.snapshot().active_tts == 1
                assert services.render_receipts.get(receipt_id)["status"] == "pending"
                cleanup.cancel()
                await asyncio.sleep(0)
                cleanup.cancel()
                await asyncio.sleep(0)
                assert not cleanup.done()
                assert services.governor.snapshot().active_tts == 1
            finally:
                sources[0].release.set()
                with pytest.raises(asyncio.CancelledError):
                    await cleanup
            assert sources[0].closed
            assert services.governor.snapshot().active_tts == 0
            assert services.render_receipts.get(receipt_id)["status"] == "cancelled"
            await Response(content=b"cancelled")(scope, receive, send)

    monkeypatch.setattr("speechrail.http.routes.audio.StreamingResponse", CancelResponse)
    payload = _payload()
    payload["response_format"] = "pcm"
    response = client.post(
        "/v1/audio/speech", json=payload,
        headers={"SpeechRail-Receipt-Mode": "integrity", "SpeechRail-Purpose": "interactive"},
    )
    assert response.content == b"cancelled"


@pytest.mark.parametrize("mode", ["start", "body", "cancel", "close-failed"])
def test_pcm_send_failure_joins_prefetched_backend_and_isolates_failed_cleanup(
    tmp_path: Path, monkeypatch, mode: str,
) -> None:
    import asyncio

    import pytest
    from starlette.requests import ClientDisconnect
    from starlette.responses import StreamingResponse

    import speechrail.app as app_module
    from speechrail.runtime.resource_governor import WorkClass

    captured = []
    original_build = app_module.build_app_services

    def capture_services(*args, **kwargs):
        services = original_build(*args, **kwargs)
        captured.append(services)
        return services

    monkeypatch.setattr(app_module, "build_app_services", capture_services)
    original_response = StreamingResponse

    client, synth, _, _ = _client(tmp_path / mode, monkeypatch)
    sources = []
    receipt_ids = []

    class Source:
        closed = False
        index = 0

        def __aiter__(self):
            return self

        async def __anext__(self):
            chunk = AudioChunk(
                response_id="backend-response", chunk_index=self.index, audio=_PCM,
            )
            self.index += 1
            return chunk

        async def aclose(self):
            await asyncio.sleep(0)
            if mode == "close-failed":
                raise RuntimeError("cleanup unconfirmed")
            self.closed = True

    def synthesize(request):
        synth.requests.append(request)
        source = Source()
        sources.append(source)
        return source

    monkeypatch.setattr(synth, "synthesize", synthesize)

    class SendFailureResponse(original_response):
        async def __call__(self, scope, receive, send):
            receipt_ids.append(self.headers["SpeechRail-Receipt-Id"])
            scope = dict(scope, asgi={"spec_version": "2.4"})

            async def failed_send(message):
                if mode in ("start", "close-failed") or message["type"] == "http.response.body":
                    if mode == "cancel":
                        raise asyncio.CancelledError
                    raise OSError("client disconnected")
                await send(message)

            await super().__call__(scope, receive, failed_send)

    monkeypatch.setattr("speechrail.http.routes.audio.StreamingResponse", SendFailureResponse)
    payload = _payload()
    payload["response_format"] = "pcm"
    def request():
        return client.post(
            "/v1/audio/speech", json=payload,
            headers={"SpeechRail-Receipt-Mode": "integrity", "SpeechRail-Purpose": "interactive"},
        )

    if mode == "cancel":
        # Headers were already sent: middleware can return 200 with a truncated
        # body. The receipt, not HTTP status alone, must reject completion.
        response = request()
        assert response.status_code == 200
        assert not response.content
    else:
        with pytest.raises((ClientDisconnect, RuntimeError)):
            request()
    services = captured[-1]
    receipt = services.render_receipts.get(receipt_ids[0])
    assert services.governor.snapshot().active_tts == 0
    if mode == "close-failed":
        assert not sources[0].closed
        assert receipt["status"] == "pending"
        assert not services.governor.lane_available(WorkClass.REALTIME_TTS)
    else:
        assert sources[0].closed
        assert receipt["status"] == "cancelled"
        assert services.governor.lane_available(WorkClass.REALTIME_TTS)
