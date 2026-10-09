"""R03 (#235): voice validation execution binds same-run audio + identity.

`voice_designs` must not import private helpers from `system` (or `audio`);
the candidate-validation and quality-runs executions share one execution
module that binds same-run audio + runtime identity evidence.  The execution
result must carry the identity observed while the run holds its resources --
a revision read after the executing reservation is released (or after an
eviction) must not be stitched onto the audio as if they were one execution.
"""

from __future__ import annotations

import ast
import asyncio
from pathlib import Path

import pytest

from speechrail.backends.tts_execution_adapter import bind_tts_execution

_VOICE_DESIGNS = Path(__file__).resolve().parent.parent / (
    "src/speechrail/http/routes/voice_designs.py"
)

_BANNED_MODULES = frozenset(
    {
        "speechrail.http.routes.system",
        "speechrail.http.routes.audio",
    }
)


@pytest.mark.anyio
@pytest.mark.parametrize("timeout_first", [False, True])
async def test_validation_asr_repeated_cancel_joins_cleanup_before_releasing_reservation(
    timeout_first: bool,
) -> None:
    from contextlib import asynccontextmanager

    from speechrail.application.voice_validation_execution import transcribe_pcm

    entered = asyncio.Event()
    cleaning = asyncio.Event()
    release = asyncio.Event()
    reclaimed = asyncio.Event()
    reserved = False

    class Governor:
        @asynccontextmanager
        async def reserve(self, *args, **kwargs):
            nonlocal reserved
            reserved = True
            try:
                yield
            finally:
                reserved = False

    class Admission:
        async def run(self, operation, *, deadline):
            if timeout_first:
                async with asyncio.timeout(0.01):
                    return await operation()
            return await operation()

    class Transcriber:
        async def transcribe(self, request):
            entered.set()
            try:
                await asyncio.Event().wait()
            finally:
                cleaning.set()
                await release.wait()
                reclaimed.set()

    task = asyncio.create_task(
        transcribe_pcm(
            transcriber=Transcriber(),
            governor=Governor(),
            admission=Admission(),
            pcm=b"\x01\x00" * 240,
            language="zh",
            expires_at=asyncio.get_running_loop().time() + 30,
            request_id_prefix="test",
        )
    )
    try:
        await asyncio.wait_for(entered.wait(), 1)
        if not timeout_first:
            task.cancel()
        await asyncio.wait_for(cleaning.wait(), 1)
        task.cancel()
        await asyncio.sleep(0)
        task.cancel()
        await asyncio.sleep(0)
        await asyncio.sleep(0)
        assert reserved
        assert not task.done()
        release.set()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert reclaimed.is_set()
        assert not reserved
    finally:
        release.set()
        if not task.done():
            task.cancel()
        await asyncio.gather(task, return_exceptions=True)


@pytest.mark.anyio
async def test_quality_close_failure_stops_probes_and_quarantines_lane() -> None:
    from speechrail.application.voice_validation_execution import (
        VoiceValidationExecutionError,
        synthesize_probes,
    )

    calls = 0
    quarantined = False

    class Source:
        def __aiter__(self):
            return self

        async def __anext__(self):
            raise StopAsyncIteration

        async def aclose(self):
            raise RuntimeError("synthetic close failure")

    class Synthesizer:
        def synthesize(self, request):
            nonlocal calls
            calls += 1
            return Source()

    def quarantine():
        nonlocal quarantined
        quarantined = True

    with pytest.raises(VoiceValidationExecutionError) as failure:
        await synthesize_probes(
            Synthesizer(),
            "test",
            2,
            on_close_failure=quarantine,
            expires_at=asyncio.get_running_loop().time() + 30,
        )
    assert failure.value.code == "backend_reclamation_failed"
    assert calls == 1
    assert quarantined


@pytest.mark.anyio
@pytest.mark.parametrize("phase", ["audio", "eviction"])
async def test_validation_tts_repeated_cancel_waits_for_owned_cleanup(phase: str) -> None:
    from speechrail.application.voice_validation_execution import (
        collect_audio,
        evict_quality_tts_if_supported,
    )
    from speechrail.domain.ports import SpeechRequest

    entered = asyncio.Event()
    cleaning = asyncio.Event()
    release = asyncio.Event()
    reclaimed = asyncio.Event()

    class Synthesizer:
        def synthesize(self, request):
            async def chunks():
                entered.set()
                try:
                    await asyncio.Event().wait()
                    yield  # never reached; this is an async iterator
                finally:
                    cleaning.set()
                    await release.wait()
                    reclaimed.set()

            return chunks()

        async def evict_warm_capability(self):
            entered.set()
            try:
                await asyncio.Event().wait()
            finally:
                cleaning.set()
                await release.wait()
                reclaimed.set()

    expires_at = asyncio.get_running_loop().time() + 30
    operation = (
        collect_audio(
            Synthesizer(),
            SpeechRequest(text="test", voice="test"),
            expires_at=expires_at,
            design=False,
            max_bytes=1024,
        )
        if phase == "audio"
        else evict_quality_tts_if_supported(Synthesizer(), expires_at=expires_at)
    )
    task = asyncio.create_task(operation)
    try:
        await asyncio.wait_for(entered.wait(), 1)
        task.cancel()
        await asyncio.wait_for(cleaning.wait(), 1)
        task.cancel()
        await asyncio.sleep(0)
        await asyncio.sleep(0)
        assert not task.done()
        release.set()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert reclaimed.is_set()
    finally:
        release.set()
        if not task.done():
            task.cancel()
        await asyncio.gather(task, return_exceptions=True)


def _private_imports() -> list[str]:
    tree = ast.parse(_VOICE_DESIGNS.read_text(encoding="utf-8"))
    found: list[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.module in _BANNED_MODULES:
            found.extend(alias.name for alias in node.names if alias.name.startswith("_"))
    return found


def test_voice_designs_imports_no_private_route_helpers() -> None:
    assert _private_imports() == []


@pytest.mark.anyio
@pytest.mark.parametrize("observed_revision", ["known", "unknown"])
async def test_candidate_execution_keeps_producing_identity_after_eviction(
    observed_revision: str,
) -> None:
    """A revision read after the run's reservation must not backfill audio.

    The flip synthesizer reports revision A while producing audio, then flips
    to B on eviction (the quality-phase eviction between synthesis and the
    evidence projection). The resulting evidence must preserve the producing
    revision, including unknown, without adopting the replacement worker.
    """

    import numpy as np

    from speechrail.application.voice_validation_execution import (
        execute_candidate_validation,
    )
    from speechrail.domain.contracts import TranscriptResult
    from speechrail.domain.ports import (
        AudioChunk,
        SpeechRequest,
        TranscriptionRequest,
    )

    revision_a = "rt_" + ("a" * 64)
    revision_b = "rt_" + ("b" * 64)

    def _sine_pcm(seconds: float = 4.0, sample_rate: int = 24_000) -> bytes:
        n = int(seconds * sample_rate)
        timeline = np.arange(n, dtype=np.float32) / sample_rate
        samples = np.asarray(
            np.round(0.3 * np.sin(2 * np.pi * 220 * timeline) * 32767),
            dtype="<i2",
        )
        return samples.tobytes()

    class _FlipSynthesizer:
        def __init__(self) -> None:
            self.runtime_revision: str | None = revision_a if observed_revision == "known" else None

        def runtime_revision_for_voice(self, voice: str) -> str | None:
            del voice
            return self.runtime_revision

        async def evict_warm_capability(self) -> None:
            self.runtime_revision = revision_b

        def synthesize(self, request: SpeechRequest):
            assert request.expected_voice_revision == ("vr_" + "a" * 32)

            async def chunks():
                yield AudioChunk(response_id="r03", chunk_index=0, audio=_sine_pcm())

            return chunks()

    class _EchoTranscriber:
        async def transcribe(self, request: TranscriptionRequest) -> TranscriptResult:
            return TranscriptResult(
                request_id=request.request_id,
                model_id="fake-asr",
                text="执行绑定回归文本，长度满足二十字以上的有效验证输入。",
                language="zh",
                duration_ms=4000,
            )

    class _NullGovernor:
        from contextlib import asynccontextmanager

        @asynccontextmanager
        async def reserve(self, *args, **kwargs):
            del args, kwargs
            yield

    class _DirectAdmission:
        async def run(self, operation, *, deadline: float) -> object:
            del deadline
            return await operation()

    synthesizer = _FlipSynthesizer()
    result = await execute_candidate_validation(
        synthesizer=synthesizer,
        runtime_identity=bind_tts_execution(synthesizer).runtime_identity,
        transcriber=_EchoTranscriber(),
        test_text="执行绑定回归文本，长度满足二十字以上的有效验证输入。",
        candidate_voice_id="candidate_flip",
        candidate_language="zh",
        candidate_revision=("vr_" + "a" * 32),
        governor=_NullGovernor(),
        admission=_DirectAdmission(),
        resource_key="candidate_flip",
        max_pcm_bytes=30 * 24_000 * 2,
        expires_at=asyncio.get_running_loop().time() + 30,
    )
    assert result.evidence.model_runtime_revision == (
        revision_a if observed_revision == "known" else None
    )


@pytest.mark.parametrize(
    "module_name",
    [
        "voice_validation_execution",
        "candidate_validation",
        "voice_quality_run",
    ],
)
def test_validation_usecases_have_no_http_dependencies(module_name: str) -> None:
    import inspect
    from importlib import import_module

    module = import_module(f"speechrail.application.{module_name}")
    tree = ast.parse(inspect.getsource(module))
    imports = [
        node.module
        for node in ast.walk(tree)
        if isinstance(node, ast.ImportFrom) and node.module is not None
    ]
    assert not any(name.startswith(("fastapi", "starlette", "speechrail.http")) for name in imports)


@pytest.mark.parametrize("change", ["replacement", "revocation"])
def test_quality_commit_rejects_changed_voice_snapshot(tmp_path: Path, change: str) -> None:
    import io
    import wave

    from speechrail.domain.tts import VoiceRegistry, VoiceRevisionConflictError, VoiceRevokedError

    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(24_000)
        wav.writeframes(b"\x01\x00" * 24_000)
    registry = VoiceRegistry(storage_path=tmp_path / "voices.json", voices_dir=tmp_path / "voices")
    profile = registry.create_cloned_profile(
        name="test",
        ref_text="original reference",
        audio_bytes=buffer.getvalue(),
        voice_id="run_pin",
        duration_seconds=1,
    )
    if change == "replacement":
        replacement = registry.create_cloned_profile(
            name="test",
            ref_text="replacement reference",
            audio_bytes=buffer.getvalue(),
            voice_id=profile.id,
            duration_seconds=1,
        )
        assert replacement.revision != profile.revision
    else:
        assert profile.revision is not None
        registry.revoke_revision(profile.id, revision=profile.revision)
    with pytest.raises(
        VoiceRevisionConflictError if change == "replacement" else VoiceRevokedError
    ):
        registry.update_quality_validation(
            profile.id,
            {"voice_revision": profile.revision, "status": "pass"},
            expected_revision=profile.revision,
        )


@pytest.mark.anyio
@pytest.mark.parametrize("known_identity", [True, False])
@pytest.mark.parametrize("save_fails", [True, False])
async def test_quality_usecase_owns_same_run_binding_and_commit(
    known_identity: bool,
    save_fails: bool,
) -> None:
    from contextlib import asynccontextmanager, contextmanager

    import numpy as np

    from speechrail.application.voice_quality_run import run_voice_quality
    from speechrail.application.voice_validation_execution import ValidationRuntime
    from speechrail.config.model_catalog import load_catalog
    from speechrail.config.selection import ActiveModelCatalog
    from speechrail.domain import voice_quality as vq
    from speechrail.domain.contracts import TranscriptResult
    from speechrail.domain.ports import AudioChunk
    from speechrail.domain.tts import VoiceProfile
    from speechrail.domain.voice_validation import VoiceValidationStoreUnavailableError

    revision = "rt_" + "a" * 64 if known_identity else None
    profile = VoiceProfile(id="probe_voice", mode="clone", revision="vr_" + "b" * 32)
    base = next(artifact for artifact in load_catalog().artifacts if artifact.variant == "base")
    active = ActiveModelCatalog(
        profile="quality",
        asr=None,
        tts=None,
        tts_clone=base,
        aligner=None,
        diarization=False,
        tts_spec="quality",
    )
    depth = 0
    lease_held = False
    commits = []

    class Governor:
        @asynccontextmanager
        async def reserve(self, *args, **kwargs):
            nonlocal depth
            assert kwargs["expires_at"] == expires_at
            assert kwargs["purpose"].value == "quality_validation"
            depth += 1
            try:
                yield
            finally:
                depth -= 1

    class Registry:
        @contextmanager
        def lease_profile(self, voice_id):
            nonlocal lease_held
            assert voice_id == profile.id
            lease_held = True
            try:
                yield profile
            finally:
                lease_held = False

        def update_quality_validation(self, voice_id, validation, *, expected_revision):
            assert lease_held
            assert voice_id == profile.id
            assert expected_revision == profile.revision
            if save_fails:
                raise VoiceValidationStoreUnavailableError("fake storage unavailable")
            commits.append(validation)

    class Synthesizer:
        runtime_revision = revision

        def runtime_revision_for_voice(self, voice_id):
            assert depth > 0, "identity must be observed before reservation release"
            assert voice_id == profile.id
            return self.runtime_revision

        async def evict_warm_capability(self):
            self.runtime_revision = "rt_" + "c" * 64

        def synthesize(self, request):
            assert request.expected_voice_revision == profile.revision

            async def chunks():
                timeline = np.arange(4800) / 24_000
                pcm = (0.3 * np.sin(2 * np.pi * 220 * timeline) * 32767).astype("<i2").tobytes()
                yield AudioChunk(response_id="probe", chunk_index=0, audio=pcm)

            return chunks()

    class Transcriber:
        probes = iter(vq.VOICE_QUALITY_V1_ZH_PROBES)

        async def transcribe(self, request):
            assert request.prompt == ""
            return TranscriptResult(
                request_id=request.request_id,
                model_id="fake",
                text=next(self.probes)["text"],
                duration_ms=200,
            )

    class Admission:
        async def run(self, operation, *, deadline):
            assert deadline > 0
            return await operation()

    expires_at = asyncio.get_running_loop().time() + 30
    synthesizer = Synthesizer()
    result = await run_voice_quality(
        voice_id=profile.id,
        registry=Registry(),
        active=active,
        runtime=ValidationRuntime(
            synthesizer=synthesizer,
            tts_execution=bind_tts_execution(synthesizer),
            transcriber=Transcriber(),
            governor=Governor(),
            admission=Admission(),
            tts_ready=True,
            asr_ready=True,
        ),
        runs=2,
        probe_set="voice_quality_v1_zh",
        request_id="run_test",
        expires_at=expires_at,
    )
    assert not lease_held
    assert depth == 0
    assert result.validation_persisted is not save_fails
    assert result.report.status == "pass"
    assert result.evidence["identity"]["model"]["runtime_revision"] == revision
    if not save_fails:
        assert len(commits) == 1
        assert commits[0]["model_runtime_revision"] == revision
        assert (commits[0]["runtime_fingerprint"] is not None) == known_identity


@pytest.mark.parametrize(
    "route_file,handler",
    [
        ("voice_designs.py", "validate_candidate"),
        ("system.py", "run_voice_quality"),
    ],
)
def test_validation_handlers_do_not_own_execution_or_commit(route_file: str, handler: str) -> None:
    path = _VOICE_DESIGNS.with_name(route_file)
    tree = ast.parse(path.read_text())
    function = next(
        node
        for node in ast.walk(tree)
        if isinstance(node, ast.AsyncFunctionDef) and node.name == handler
    )
    forbidden = {"reserve", "update", "update_with_validation_audio", "update_quality_validation"}
    assert not any(
        isinstance(node, ast.Attribute) and node.attr in forbidden for node in ast.walk(function)
    )
