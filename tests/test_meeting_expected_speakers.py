"""Expected headcount limits stable identities, never forces a speaker match."""

import pytest

from realtime_wire import session_update
from speechrail.compatibility.openai_realtime import RealtimeAdapterError, apply_session_update
from speechrail.runtime.diarization_worker import validate_meeting_identity_policy


@pytest.mark.parametrize("count", [None, 1, 2, 3, 4])
def test_expected_count_is_accepted_as_meeting_identity_budget(count):
    event = session_update(
        diarization={
            "enabled": True,
            "backend": "meeting_dynamic",
            "max_speakers": count,
        }
    )
    _, config = apply_session_update(
        event,
        session_id="s",
        asr_model="speechrail/qwen3-asr-1.7b",
        registered_asr=frozenset({"speechrail/qwen3-asr-1.7b"}),
    )
    assert config["diarization_max_speakers"] == count


@pytest.mark.parametrize("count", [0, 5, True, 2.5, "3"])
def test_invalid_expected_count_is_rejected(count):
    with pytest.raises(RealtimeAdapterError) as exc:
        apply_session_update(
            session_update(
                diarization={
                    "enabled": True,
                    "backend": "meeting_dynamic",
                    "max_speakers": count,
                }
            ),
            session_id="s",
            asr_model="speechrail/qwen3-asr-1.7b",
            registered_asr=frozenset({"speechrail/qwen3-asr-1.7b"}),
        )
    assert exc.value.code == "invalid_event"


def test_sortformer_does_not_silently_accept_a_count_it_cannot_enforce():
    with pytest.raises(RealtimeAdapterError):
        apply_session_update(
            session_update(
                diarization={
                    "enabled": True,
                    "backend": "sortformer",
                    "max_speakers": 2,
                }
            ),
            session_id="s",
            asr_model="speechrail/qwen3-asr-1.7b",
            registered_asr=frozenset({"speechrail/qwen3-asr-1.7b"}),
        )


@pytest.mark.parametrize("echo", [None, 4, True])
def test_worker_cannot_ignore_requested_budget(echo):
    with pytest.raises(RuntimeError, match="budget"):
        validate_meeting_identity_policy(
            {
                "identity_policy": "stable_four_v1",
                "identity_capacity": 4,
                "max_speakers": echo,
            },
            max_speakers=2,
        )


@pytest.mark.anyio
async def test_requested_budget_reaches_worker_and_does_not_mutate_certification(
    tmp_path, monkeypatch
):
    from speechrail.backends.diarization import meeting
    from speechrail.domain.resource_limits import GovernorLimits
    from speechrail.runtime.resource_governor import ResourceGovernor

    monkeypatch.setattr(meeting, "inspect_meeting_dynamic_assets", lambda _: True)
    policy = {"certified_max_speakers": 4, "validation_digest": "a" * 64}
    monkeypatch.setattr(meeting, "read_matching_policy", lambda _: policy)
    exe = tmp_path / "worker"
    exe.touch()
    exe.chmod(0o700)
    engine = meeting.MeetingDiarizationEngine(
        model_dir=tmp_path,
        policy_path=tmp_path / "policy",
        executable=exe,
        governor=ResourceGovernor(GovernorLimits(2, 1, 8)),
    )
    session = engine.open(epoch="first", max_speakers=2)
    assert session._worker.max_speakers == 2
    assert session._max_speakers == 2
    assert engine.max_speakers == policy["certified_max_speakers"] == 4
    await session.cancel()
    default = engine.open(epoch="next")
    assert default._worker.max_speakers == 4
    await default.cancel()


def _meeting_client(certified=4):
    from fastapi import FastAPI
    from fastapi.testclient import TestClient

    from speechrail.domain.diarization.types import DiarizationReadiness
    from speechrail.http.routes.realtime_openai import create_openai_realtime_router
    from test_diarization_extensions import (
        _FakeDiarizationEngine,
        _FakeStreamingFactory,
        _FakeTextAligner,
        _services,
    )

    class BudgetEngine(_FakeDiarizationEngine):
        readiness = DiarizationReadiness(True, True, None, "test only")
        max_speakers = certified

        def __init__(self):
            super().__init__(supports_stream=True)
            self.limits = []

        def open(self, *, epoch, max_speakers=None):
            self.limits.append(max_speakers)
            return super().open(epoch=epoch)

    engine = BudgetEngine()
    services = _services(
        engine=engine, aligner=_FakeTextAligner(), streaming_factory=_FakeStreamingFactory()
    )
    services.diarization_backends["meeting_dynamic"] = engine
    app = FastAPI()
    app.include_router(create_openai_realtime_router(services))
    return TestClient(app), engine


@pytest.mark.parametrize("count", [None, 2, 3, 4])
def test_wire_budget_is_applied_and_frozen_after_first_audio(count):
    from test_diarization_extensions import _open, _pcm16, _update_session

    client, engine = _meeting_client()
    with client.websocket_connect("/v1/realtime") as socket:
        _open(socket)
        options = {"enabled": True, "backend": "meeting_dynamic", "max_speakers": count}
        updated = _update_session(socket, session_update(diarization=options))
        assert updated["type"] == "session.updated"
        assert updated["session"]["speechrail"]["diarization"]["max_speakers"] == (count or 4)
        assert engine.limits == [count]
        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(2400)})
        options["max_speakers"] = 3 if count != 3 else 2
        refused = _update_session(socket, session_update(diarization=options))
        assert refused["type"] == "error" and refused["error"]["code"] == "invalid_state"
        assert engine.limits == [count]


def test_before_audio_new_budget_reopens_matcher_instead_of_echo_only():
    from test_diarization_extensions import _open, _update_session

    client, engine = _meeting_client()
    with client.websocket_connect("/v1/realtime") as socket:
        _open(socket)
        for count in [2, 3]:
            updated = _update_session(
                socket,
                session_update(
                    diarization={
                        "enabled": True,
                        "backend": "meeting_dynamic",
                        "max_speakers": count,
                    }
                ),
            )
            assert updated["type"] == "session.updated"
            assert updated["session"]["speechrail"]["diarization"]["max_speakers"] == count
        assert engine.limits == [2, 3]
        assert engine.streams[0].closed


def test_expected_count_does_not_expand_certification():
    from test_diarization_extensions import _open, _update_session

    client, engine = _meeting_client(certified=2)
    with client.websocket_connect("/v1/realtime") as socket:
        _open(socket)
        event = _update_session(
            socket,
            session_update(
                diarization={
                    "enabled": True,
                    "backend": "meeting_dynamic",
                    "max_speakers": 4,
                }
            ),
        )
        assert event["type"] == "error" and event["error"]["code"] == "diarization_not_available"
        assert engine.limits == []


@pytest.mark.anyio
@pytest.mark.parametrize("count", [2, 3, 4])
async def test_worker_start_launches_native_with_requested_budget(tmp_path, monkeypatch, count):
    from speechrail.runtime.diarization_worker import (
        MEETING_DYNAMIC_MODEL_REVISION,
        MEETING_DYNAMIC_SDK_REVISION,
        CoreMLWorkerProcess,
    )

    async def launch(self, arguments):
        assert "--max-speakers" in arguments
        assert arguments[arguments.index("--max-speakers") + 1] == str(count)
        assert "--backend" in arguments and "--policy" in arguments

    async def request(self, header, audio=b""):
        assert header["operation"] == "preflight"
        return {
            "ok": True,
            "backend": "meeting_dynamic",
            "sdk_revision": MEETING_DYNAMIC_SDK_REVISION,
            "model_revision": MEETING_DYNAMIC_MODEL_REVISION,
            "identity_policy": "stable_four_v1",
            "identity_capacity": 4,
            "max_speakers": count,
        }, b""

    monkeypatch.setattr(CoreMLWorkerProcess, "_launch", launch)
    monkeypatch.setattr(CoreMLWorkerProcess, "request", request)
    exe = tmp_path / "worker"
    exe.touch()
    worker = CoreMLWorkerProcess(
        executable=exe,
        model_path=tmp_path,
        protocol_version=2,
        backend="meeting_dynamic",
        policy_path=tmp_path / "policy",
        max_speakers=count,
    )
    await worker.start()
