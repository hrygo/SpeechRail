# SpeechRail 🎙️

<p align="center">
  <strong>Local speech infrastructure for Apple Silicon macOS</strong><br>
  <em>Shared ASR, TTS, and Realtime endpoints for desktop agents and local apps</em>
</p>

<p align="center">
  <a href="https://github.com/hrygo/SpeechRail/actions/workflows/ci.yml"><img src="https://github.com/hrygo/SpeechRail/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI status" /></a>
  <a href="https://github.com/hrygo/SpeechRail/releases"><img src="https://img.shields.io/github/v/release/hrygo/SpeechRail?label=release" alt="Release" /></a>
  <img src="https://img.shields.io/badge/macOS-Apple%20Silicon-000000.svg?logo=apple&logoColor=white" alt="Apple Silicon" />
  <img src="https://img.shields.io/badge/Python-3.12-3776AB.svg?logo=python&logoColor=white" alt="Python 3.12" />
  <img src="https://img.shields.io/badge/API-OpenAI%20compatible-412991.svg?logo=openai" alt="OpenAI compatible" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green.svg" alt="MIT License" /></a>
</p>

<p align="center">
  <strong>English</strong> · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="#quick-start">Quick start</a> ·
  <a href="#openai-compatible-usage">Usage</a> ·
  <a href="#documentation">Documentation</a> ·
  <a href="CONTRIBUTING.md">Contributing</a> ·
  <a href="https://github.com/hrygo/SpeechRail/discussions">Discussions</a>
</p>

SpeechRail is a single-user local speech service for desktop agents, meeting
tools, content workflows, and other applications that need reusable speech
capabilities. It hosts shared ASR/TTS workers behind one local endpoint and
exposes the narrow OpenAI-compatible subset that SpeechRail can verify.

The service owns protocol translation, model adapters, worker lifecycle,
resource admission, and capability reporting. Calling applications own
microphone capture, playback, meeting storage, UI, and LLM orchestration.

> [!NOTE]
> SpeechRail is currently published as **Beta**. `/readyz` and a successful
> smoke request confirm service readiness, not universal quality, latency, or
> performance guarantees.

## Why SpeechRail

SpeechRail is designed for one Apple Silicon Mac shared by several local
clients. It keeps model execution and request scheduling in one bounded
runtime, so applications do not each need to load their own speech models or
invent their own OpenAI-compatible adapter.

It is a good fit when you need:

- local processing for ordinary ASR/TTS requests;
- one reusable HTTP/WebSocket service for multiple desktop applications;
- a narrow, inspectable OpenAI-compatible surface;
- optional Realtime ASR/TTS, anonymous session-scoped diarization, or MCP
  access.

## What is available

| Surface | Capability | Notes |
|---|---|---|
| `GET /health`, `/readyz`, `/metrics` | Service diagnostics | Inspect process, subsystem, readiness, and metrics state. |
| `POST /v1/audio/transcriptions` | File ASR | OpenAI-compatible multipart input; `json`, `verbose_json`, `text`, `srt`, `vtt`, and optional `diarized_json` responses. |
| `POST /v1/audio/speech` | TTS | Streaming `mp3`, `opus`, `aac`, `flac`, `wav`, or raw `pcm`; select an `available=true` voice from `/v1/voices`. |
| `GET /v1/models`, `GET /v1/voices` | Capability discovery | Results describe the active profile and currently available artifacts and voices. |
| `WS /v1/realtime` | Realtime ASR/TTS | OpenAI Realtime event subset, server-side speech admission, and an opt-in namespaced diarization extension. |
| `/v1/jobs` | Asynchronous job metadata | Optional owner-scoped durable job records; callers provide opaque references, not raw audio or transcripts. |
| `speechrail-mcp` | Agent access | Stateless MCP proxy over `stdio` or `streamable-http`; it calls the local REST service and does not host models. |

Speaker diarization is available only when the active `balanced` or `quality`
profile has its local CoreML assets ready. It returns session-scoped anonymous
labels; it does not identify people or maintain a cross-session speaker
database.

The repository also contains a SwiftUI macOS control plane under
`macos/SpeechRailApp`. It reports service state and delegates profile/service
operations to the existing Python CLI. It is not the audio runtime and does
not capture microphones, play audio, load models, or replace the user-level
`com.speechrail` LaunchAgent.

## Scope and boundaries

SpeechRail is deliberately a speech runtime, not a complete voice-agent
application. It does not provide:

- microphone capture, speaker playback, conference management, or UI;
- LLM responses, tool calls, or application-level interruption policy;
- named-speaker identity, voiceprint databases, or cross-session attribution;
- cloud inference, multi-tenant isolation, high availability, or a distributed queue.

Realtime is the sole public WebSocket entry point and implements ASR/TTS
events only. Read the contract before relying on an OpenAI feature that is not
listed above.

## Requirements

- Apple Silicon Mac with macOS 14 or later for the native managed runtime;
  Intel Macs are not a supported target.
- Python `>=3.12,<3.13` for source development and the Python service CLI.
- [`uv`](https://docs.astral.sh/uv/) for dependency and environment management.
- `ffmpeg` for the audio decoding/transcoding paths used by local setup and
  selected audio formats.
- Local model snapshots and vendor runtimes stored outside the repository.

Inference requests do not download models, fetch remote audio URLs, or make
silent cloud calls. Explicit setup and operator commands may provision local
artifacts; review the relevant operation guide before running them.

## Quick start

### Managed installation

Use this path for a fresh Apple Silicon Mac or a user-level background service.
The bootstrap flow installs prerequisites, prepares the selected local model
artifacts, and registers the `com.speechrail` LaunchAgent. It performs external
setup work and therefore requires the explicit `--yes` confirmation.

```bash
git clone https://github.com/hrygo/SpeechRail.git
cd SpeechRail
./.agents/skills/speechrail-zero-setup/scripts/bootstrap_mac.sh \
  --yes \
  --preset balanced
```

Read the [zero-setup guide](.agents/skills/speechrail-zero-setup/SKILL.md)
before using the bootstrap entry point. It documents disk requirements,
profile selection, model verification, and recovery behavior.

After installation, inspect the service without starting a second instance:

```bash
uv run speechrail service status
uv run speechrail diagnose --app-home "$HOME/Library/Application Support/SpeechRail"
curl http://127.0.0.1:8201/health
curl http://127.0.0.1:8201/readyz
```

### Source development

This path is useful for deterministic contract and application development.
It can start the HTTP surface without real model snapshots; inference then
returns `503 backend_not_ready` until a local ASR/TTS runtime is configured.

```bash
git clone https://github.com/hrygo/SpeechRail.git
cd SpeechRail
uv sync --extra dev
cp configs/speechrail.example.env .env
chmod 600 .env
uv run speechrail serve
```

For real local inference, set the documented ASR and TTS snapshot/interpreter
pairs in the private `.env`, then run `speechrail service preflight` before
starting the service. Keep snapshots, `.env`, audio, logs, and benchmark
raw data outside the repository.

Useful read-only checks are:

```bash
curl http://127.0.0.1:8201/health
curl http://127.0.0.1:8201/readyz
curl http://127.0.0.1:8201/v1/models
curl http://127.0.0.1:8201/v1/voices
uv run speechrail diagnose
```

`/health` reports process and subsystem state. `/readyz` reports whether the
ASR/TTS runtime can accept inference; a successful readiness response is not a
quality or performance certification.

## OpenAI-compatible usage

The standard OpenAI Python client can target the local service by changing its
base URL. Loopback access uses a placeholder key; use a real bearer key only
when the service is deliberately exposed beyond loopback.

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:8201/v1",
    api_key="local",
)

with open("speech.wav", "rb") as audio:
    result = client.audio.transcriptions.create(
        model="whisper-1",
        file=audio,
        response_format="verbose_json",
    )
    print(result.text)

speech = client.audio.speech.create(
    model="tts-1",
    voice="serena",
    input="SpeechRail is running locally.",
    response_format="wav",
)
speech.stream_to_file("speech-output.wav")
```

For Realtime clients, connect to:

```text
ws://127.0.0.1:8201/v1/realtime
```

Then follow [`contracts/realtime-openai.md`](contracts/realtime-openai.md).
For SDK, cURL, Sona, Open-WebUI, LiveKit/Pipecat, and OpenClaw examples, see
[`docs/users/integrations.md`](docs/users/integrations.md).

## Model profiles

The public API shape is shared across profiles, but the advertised capability
set follows the active catalog selection. All active ASR/TTS profile weights
are 8-bit; only the `quality` diarization aligner remains bf16.

| Profile | ASR | TTS | Diarization and voice behavior |
|---|---|---|---|
| `light` | `asr-0.6b-q8` | `tts-0.6b-custom-q8` | No aligner and no diarization; fixed CustomVoice roles. |
| `balanced` | `asr-1.7b-q8` | `tts-0.6b-custom-q8` | `aligner-q8` and optional anonymous diarization; fixed CustomVoice roles. |
| `quality` | `asr-1.7b-q8` | `tts-1.7b-design-q8` + `tts-1.7b-base-q8` | `aligner-bf16`, optional anonymous diarization, VoiceDesign preview/design, and quality-gated Base cloning. The two TTS capability workers may stay resident and different lanes may run concurrently; each lane remains serialized. |

Quality keeps VoiceDesign and Base as independent TTS capability lanes. They do
not need to be repeatedly loaded and unloaded when switching voice workflows;
the Quality capability group can still trim/close both workers after the
configured idle cooldown and restore them lazily for the next request.

![Three-tier model and Quality dual-TTS capability relationship](docs/architecture/diagrams/three-tier-model-architecture.svg)

The diagram is the canonical overview of profile routing, model sharing,
Quality's two TTS capability lanes, and the shared resource/lifecycle boundary.

Use the CLI to inspect or change a managed selection. `setup` provides a
memory-based starting suggestion; it is not a hard hardware guarantee.

```bash
uv run speechrail profile list
uv run speechrail profile status
uv run speechrail profile apply balanced
uv run speechrail profile rollback
```

Select voices from `/v1/voices` rather than assuming that a registered custom
voice is usable on every profile. The quality-only voice endpoints include
`POST /v1/voices/previews`, `POST /v1/voices`, `POST /v1/voices/designs`, and the quality-gated clone
endpoints documented in [`docs/users/api-contract.md`](docs/users/api-contract.md).

## Security and data handling

- The default bind address is `127.0.0.1`; loopback development does not need
  an API key.
- Any non-loopback exposure requires `SPEECHRAIL_API_KEY`, bearer
  authentication, and an explicit origin policy. Never put a key in a URL
  query string.
- Ordinary ASR/TTS request data is processed locally and is not sent to a
  cloud service. Explicit voice registration and cloning are persistent
  features and may write managed custom-voice data outside the repository.
- Logs, fixtures, and reports must not contain credentials, authorization
  headers, raw audio, Base64 payloads, full prompts, full transcripts,
  embeddings, names, or absolute model paths.

## Documentation

| Need | Start here |
|---|---|
| Documentation overview | [`docs/README.md`](docs/README.md) |
| API and client integration | [`docs/users/README.md`](docs/users/README.md), [`docs/users/api-contract.md`](docs/users/api-contract.md), [`contracts/openapi.yaml`](contracts/openapi.yaml) |
| Realtime protocol | [`contracts/realtime-openai.md`](contracts/realtime-openai.md) |
| MCP agent integration | [`docs/users/mcp-agent-integration.md`](docs/users/mcp-agent-integration.md) |
| Operations and rollback | [`docs/operations/README.md`](docs/operations/README.md), [`docs/operations/operations-runbook.md`](docs/operations/operations-runbook.md) |
| Development and testing | [`docs/developers/README.md`](docs/developers/README.md), [`docs/developers/testing-acceptance.md`](docs/developers/testing-acceptance.md) |
| macOS control plane | [`docs/developers/macos-app-development.md`](docs/developers/macos-app-development.md), [`docs/developers/macos-app-release.md`](docs/developers/macos-app-release.md) |
| Architecture and boundaries | [`docs/architecture/README.md`](docs/architecture/README.md), [`docs/architecture/current-boundaries.md`](docs/architecture/current-boundaries.md), [`docs/decisions/README.md`](docs/decisions/README.md) |
| Release history | [`CHANGELOG.md`](CHANGELOG.md) |

## Contributing

Before opening a pull request, read [`CONTRIBUTING.md`](CONTRIBUTING.md) and
run the deterministic quality gates:

```bash
uv sync --extra dev
uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
git diff --check
```

The CI workflow also builds the wheel and tests the SwiftUI macOS control
plane. Please use the repository's issue templates for bug reports and feature
requests. Questions and integration discussions belong in
[GitHub Discussions](https://github.com/hrygo/SpeechRail/discussions).

Please also follow the [Code of Conduct](CODE_OF_CONDUCT.md) when participating
in the project.

## Support and security

For usage questions and troubleshooting, start with [`SUPPORT.md`](SUPPORT.md)
and [GitHub Discussions](https://github.com/hrygo/SpeechRail/discussions). For
confirmed bugs, use the [issue templates](https://github.com/hrygo/SpeechRail/issues/new/choose).

For security vulnerabilities, follow [`SECURITY.md`](SECURITY.md) instead of
opening a public issue.

## License

SpeechRail is released under the [MIT License](LICENSE).
