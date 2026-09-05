"""Contract tests for the real-profile benchmark harness."""

from __future__ import annotations

import json
import os
import sys
from collections.abc import Mapping
from pathlib import Path
from stat import S_IMODE

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from examples.perf.bench_profiles import (
    PROFILE_DEVICE_PHASES,
    BenchmarkDependencies,
    HttpResponse,
    build_auth_headers,
    load_manifest,
    main,
    required_phases,
    run_profile_benchmark,
    validate_base_url,
    validate_output_path,
    write_result,
)


class _FakeHttpRunner:
    def __init__(self, *, tts_body: bytes = b"tts pcm") -> None:
        self.calls: list[tuple[str, str]] = []
        self.requests: list[tuple[str, str, bytes | None, Mapping[str, str]]] = []
        self.tts_body = tts_body

    def __call__(
        self,
        method: str,
        url: str,
        body: bytes | None,
        headers: Mapping[str, str],
    ) -> HttpResponse:
        self.calls.append((method, url))
        self.requests.append((method, url, body, dict(headers)))
        if url.endswith("/health"):
            payload = {"status": "ok", "asr_ready": True, "tts_ready": True}
        elif url.endswith("/readyz"):
            payload = {"ready": True}
        elif url.endswith("/v1/models"):
            payload = {"object": "list", "data": [{"id": "speechrail/qwen3-asr-1.7b"}]}
        elif url.endswith("/v1/audio/speech"):
            return HttpResponse(status_code=200, body=self.tts_body)
        else:
            payload = {"text": "secret transcript"}
        return HttpResponse(status_code=200, body=json.dumps(payload).encode())


class _FakeClock:
    def __init__(self) -> None:
        self.value = 0.0

    def __call__(self) -> float:
        self.value += 0.5
        return self.value


def _manifest(tmp_path: Path) -> tuple[Path, Path]:
    audio = tmp_path / "fixture.wav"
    audio.write_bytes(b"fixture")
    manifest = tmp_path / "manifest.json"
    manifest.write_text(
        json.dumps(
            {
                "fixtures": [
                    {
                        "id": "fixture-1",
                        "path": str(audio),
                        "kind": "asr",
                        "language": "zh",
                    }
                ],
                "model_identity": {
                    "model": "speechrail/qwen3-asr-1.7b",
                    "variant": "asr",
                    "quantization": {"bits": 8, "group_size": 64, "format": "mlx"},
                    "real": True,
                },
                "quality": {
                    "status": "passed",
                    "real": True,
                    "independent": True,
                    "source": "human_eval",
                },
            }
        ),
        encoding="utf-8",
    )
    return manifest, audio


def _dependencies(runner: _FakeHttpRunner) -> BenchmarkDependencies:
    return BenchmarkDependencies(
        http_runner=runner,
        system_sampler=lambda: {
            "hardware": {"real": True, "chip": "Apple M1", "architecture": "arm64"},
            "os": {"name": "macOS", "version": "15.6"},
            "memory": {"physical_bytes": 8 * 1024**3},
            "process_samples": [
                {
                    "at": 1.0,
                    "processes": [
                        {
                            "pid": 10,
                            "start_time_ns": 100,
                            "rss_bytes": 100,
                            "phys_footprint_bytes": 200,
                        }
                    ],
                },
                {
                    "at": 2.0,
                    "processes": [
                        {
                            "pid": 10,
                            "start_time_ns": 100,
                            "rss_bytes": 120,
                            "phys_footprint_bytes": 240,
                        }
                    ],
                },
            ],
        },
        clock=_FakeClock(),
        ffprobe=lambda _: 2.5,
    )


def test_required_phases_are_profile_specific_and_unknown_is_fail_closed() -> None:
    light = required_phases("light")
    assert {"m1_air_8gb", "quality", "cold", "warm", "soak", "switch"} <= light
    assert PROFILE_DEVICE_PHASES["balanced"] in required_phases("balanced")
    assert PROFILE_DEVICE_PHASES["quality"] in required_phases("quality")

    with pytest.raises(ValueError, match="unknown profile"):
        required_phases("experimental")


@pytest.mark.parametrize(
    "url",
    [
        "ftp://127.0.0.1:8201",
        "file:///tmp/speechrail",
        "http://example.com:8201",
        "http://user:password@127.0.0.1:8201",
        "http://127.0.0.1:8201?token=secret",
    ],
)
def test_validate_base_url_rejects_non_loopback_credentials_and_query(url: str) -> None:
    with pytest.raises(ValueError):
        validate_base_url(url)


def test_manifest_must_be_external_and_audio_must_be_local(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    inside = repo / "manifest.json"
    inside.write_text("[]", encoding="utf-8")
    with pytest.raises(ValueError, match="outside"):
        load_manifest(inside, repository_root=repo)

    external = tmp_path / "external.json"
    external.write_text(
        json.dumps([{"id": "remote", "path": "https://example.test/audio.wav"}]),
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match=r"URL|audio"):
        load_manifest(external, repository_root=repo)

    with pytest.raises(ValueError, match="does not exist"):
        load_manifest(tmp_path / "missing.json", repository_root=repo)


def test_output_path_cannot_overwrite_existing_file(tmp_path: Path) -> None:
    output = tmp_path / "result.json"
    output.write_text("{}", encoding="utf-8")
    with pytest.raises(ValueError, match="overwrite"):
        validate_output_path(output)


def test_asr_multipart_uses_extension_mime_and_stable_model(tmp_path: Path) -> None:
    manifest, audio = _manifest(tmp_path)
    audio_mp3 = audio.with_suffix(".mp3")
    audio_mp3.write_bytes(audio.read_bytes())
    payload = json.loads(manifest.read_text(encoding="utf-8"))
    payload["fixtures"][0]["path"] = str(audio_mp3)
    manifest.write_text(json.dumps(payload), encoding="utf-8")
    runner = _FakeHttpRunner()

    run_profile_benchmark(
        "http://127.0.0.1:8201",
        manifest,
        profile="light",
        phase="quality",
        dependencies=_dependencies(runner),
    )

    request = next(item for item in runner.requests if item[1].endswith("/v1/audio/transcriptions"))
    body = request[2]
    assert body is not None
    assert b'name="model"' in body and b"whisper-1" in body
    assert b'filename="fixture.mp3"' in body
    assert b"Content-Type: audio/mpeg" in body

    audio_unknown = audio.with_suffix(".bin")
    audio_unknown.write_bytes(audio.read_bytes())
    payload["fixtures"][0]["path"] = str(audio_unknown)
    manifest.write_text(json.dumps(payload), encoding="utf-8")
    unknown_runner = _FakeHttpRunner()
    run_profile_benchmark(
        "http://127.0.0.1:8201",
        manifest,
        profile="light",
        phase="quality",
        dependencies=_dependencies(unknown_runner),
    )
    unknown_request = next(
        item
        for item in unknown_runner.requests
        if item[1].endswith("/v1/audio/transcriptions")
    )
    assert b"Content-Type: application/octet-stream" in (unknown_request[2] or b"")


def test_tts_rtf_uses_valid_returned_pcm_duration(tmp_path: Path) -> None:
    manifest, audio = _manifest(tmp_path)
    payload = json.loads(manifest.read_text(encoding="utf-8"))
    payload["fixtures"][0] = {
        "id": "tts-1",
        "path": str(audio),
        "kind": "tts",
        "text": "hello",
    }
    manifest.write_text(json.dumps(payload), encoding="utf-8")
    runner = _FakeHttpRunner(tts_body=b"\0" * (24_000 * 2))

    result = run_profile_benchmark(
        "http://127.0.0.1:8201",
        manifest,
        profile="light",
        phase="quality",
        dependencies=_dependencies(runner),
    )

    fixture = result["fixtures"][0]
    assert fixture["actual_audio_seconds"] == 1.0
    assert fixture["duration_source"] == "pcm_24khz_mono_pcm16"
    assert fixture["rtf"] == 0.5
    assert fixture["inference_observed"] is True
    request = next(item for item in runner.requests if item[1].endswith("/v1/audio/speech"))
    assert b'"model": "tts-1"' in (request[2] or b"")


@pytest.mark.parametrize("pcm", [b"", b"\0\0\0"])
def test_tts_empty_or_odd_pcm_is_not_success(tmp_path: Path, pcm: bytes) -> None:
    manifest, audio = _manifest(tmp_path)
    payload = json.loads(manifest.read_text(encoding="utf-8"))
    payload["fixtures"][0].update({"kind": "tts", "text": "hello", "path": str(audio)})
    manifest.write_text(json.dumps(payload), encoding="utf-8")
    runner = _FakeHttpRunner(tts_body=pcm)

    result = run_profile_benchmark(
        "http://127.0.0.1:8201",
        manifest,
        profile="light",
        phase="quality",
        dependencies=_dependencies(runner),
    )

    fixture = result["fixtures"][0]
    assert fixture["inference_observed"] is False
    assert fixture["actual_audio_seconds"] is None
    assert fixture["rtf"] is None


def test_auth_header_reads_environment_without_redacting_into_result(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest, _ = _manifest(tmp_path)
    secret = "unit-token-" + os.urandom(8).hex()
    monkeypatch.setenv("SPEECHRAIL_API_KEY", secret)
    assert build_auth_headers("explicit-token") == {"Authorization": "Bearer explicit-token"}
    runner = _FakeHttpRunner()

    result = run_profile_benchmark(
        "http://127.0.0.1:8201",
        manifest,
        profile="light",
        phase="quality",
        dependencies=_dependencies(runner),
    )

    assert runner.requests
    assert all(request[3].get("Authorization") == f"Bearer {secret}" for request in runner.requests)
    assert secret not in json.dumps(result)


def test_default_sampler_keeps_fully_passed_manifest_closed(tmp_path: Path) -> None:
    manifest, _ = _manifest(tmp_path)
    payload = json.loads(manifest.read_text(encoding="utf-8"))
    payload["phase_evidence"] = {
        phase: {"status": "passed", "real": True, "source": "operator"}
        for phase in required_phases("light")
    }
    payload["soak"] = {"status": "passed", "real": True, "source": "operator"}
    payload["switch"] = {"status": "passed", "real": True, "source": "operator"}
    manifest.write_text(json.dumps(payload), encoding="utf-8")
    runner = _FakeHttpRunner()
    dependencies = BenchmarkDependencies(
        http_runner=runner,
        ffprobe=lambda _: 2.5,
        clock=_dependencies(runner).clock,
    )

    result = run_profile_benchmark(
        "http://127.0.0.1:8201",
        manifest,
        profile="light",
        phase="quality",
        dependencies=dependencies,
    )

    assert result["release_pass"] is False
    assert any("default process sampler" in reason for reason in result["release_reasons"])
    assert result["resources"]["sampler"]["source"] == "not_implemented"


def test_write_result_creates_private_file_without_overwrite(tmp_path: Path) -> None:
    output = tmp_path / "result.json"
    write_result({"release_pass": False}, output)
    assert S_IMODE(output.stat().st_mode) == 0o600
    with pytest.raises(ValueError, match="overwrite"):
        write_result({"release_pass": False}, output)


def test_benchmark_result_is_redacted_and_uses_public_api_with_actual_duration(
    tmp_path: Path,
) -> None:
    manifest, audio = _manifest(tmp_path)
    runner = _FakeHttpRunner()

    result = run_profile_benchmark(
        "http://127.0.0.1:8201",
        manifest,
        profile="light",
        phase="quality",
        dependencies=_dependencies(runner),
    )

    assert result["schema_version"] == 1
    assert result["phase"] == "quality"
    assert result["fixtures"][0]["actual_audio_seconds"] == 2.5
    assert result["fixtures"][0]["duration_source"] == "ffprobe"
    assert result["resources"]["simultaneous_peak"]["phys_footprint_bytes"] == 240
    assert result["quality"]["real"] is True
    assert result["release_pass"] is False
    assert any("required phase" in reason for reason in result["release_reasons"])
    assert all(path not in url for _, url in runner.calls for path in (str(audio),))
    encoded = json.dumps(result, ensure_ascii=False)
    assert str(audio) not in encoded
    assert "secret transcript" not in encoded
    assert all(url.startswith("http://127.0.0.1:8201") for _, url in runner.calls)


def test_injected_dependencies_cannot_be_recorded_as_release_evidence(tmp_path: Path) -> None:
    manifest, _ = _manifest(tmp_path)
    payload = json.loads(manifest.read_text(encoding="utf-8"))
    payload["phase_evidence"] = {
        phase: {"status": "passed", "real": True, "source": "operator"}
        for phase in required_phases("light")
    }
    payload["soak"] = {"status": "passed", "real": True, "source": "operator"}
    payload["switch"] = {"status": "passed", "real": True, "source": "operator"}
    manifest.write_text(json.dumps(payload), encoding="utf-8")

    runner = _FakeHttpRunner()
    result = run_profile_benchmark(
        "http://127.0.0.1:8201",
        manifest,
        profile="light",
        phase="quality",
        dependencies=_dependencies(runner),
    )

    assert result["evidence_mode"] == "injected"
    assert result["release_pass"] is False
    assert "injected dependencies are not real evidence" in result["release_reasons"]


def test_main_rejects_invalid_base_url_without_creating_output(tmp_path: Path) -> None:
    output = tmp_path / "result.json"
    code = main(
        [
            "--base-url",
            "http://example.com",
            "--manifest",
            str(tmp_path / "manifest.json"),
            "--profile",
            "light",
            "--phase",
            "quality",
            "--output",
            str(output),
        ]
    )
    assert code != 0
    assert not output.exists()
