# SpeechRail

<p align="center">
  <img src="docs/assets/logo.png" alt="SpeechRail Logo" width="128" height="128" />
</p>

<p align="center">
  <strong>Local speech infrastructure for Apple Silicon macOS</strong><br>
  <em>One bounded runtime · OpenAI-compatible REST and Realtime · a macOS control plane</em>
</p>

<p align="center">
  <a href="https://github.com/hrygo/SpeechRail/actions/workflows/ci.yml"><img src="https://github.com/hrygo/SpeechRail/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI status" /></a>
  <a href="https://github.com/hrygo/SpeechRail/releases"><img src="https://img.shields.io/github/v/release/hrygo/SpeechRail?label=release" alt="Release" /></a>
  <img src="https://img.shields.io/badge/macOS%2026%2B-Apple%20Silicon-000000.svg?logo=apple&logoColor=white" alt="macOS 26+ Apple Silicon" />
  <img src="https://img.shields.io/badge/Python-3.14-3776AB.svg?logo=python&logoColor=white" alt="Python 3.14" />
  <img src="https://img.shields.io/badge/API-OpenAI%20compatible-412991.svg?logo=openai" alt="OpenAI compatible" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green.svg" alt="MIT License" /></a>
</p>

<p align="center">
  <strong>English</strong> · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="#what-speechrail-is">What it is</a> ·
  <a href="#public-surface">Public surface</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#model-specs">Model specs</a> ·
  <a href="#documentation">Documentation</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

SpeechRail is a single-user local speech service for one Apple Silicon Mac,
shared by desktop agents, meeting tools, content workflows, and the bundled
macOS app. It hosts ASR, TTS, and optional speaker-diarization workers behind a
single local endpoint, and exposes the narrow OpenAI-compatible subset that
SpeechRail actually implements and verifies.

The **service** owns protocol translation, model adapters, worker lifecycle,
resource admission, and capability reporting. The **calling application** owns
microphone capture, playback, meeting storage, UI, and LLM orchestration.

> [!NOTE]
> `/readyz` returning 200 and a successful smoke request confirm that the
> service is wired up. They are not quality, latency, or stability
> certifications — see [Boundaries](#boundaries) for what remains unproven.

## What SpeechRail is

One process tree, one model set, one contract. Applications stop loading their
own speech models and stop inventing their own OpenAI-compatible adapters.

It is a good fit when you need:

- local ASR and TTS without a cloud round trip;
- one HTTP/WebSocket service shared by several desktop applications;
- a narrow, inspectable OpenAI-compatible surface with a machine-readable
  contract;
- optional Realtime ASR/TTS, session-scoped anonymous diarization, or MCP
  access for agents.

It is **not** a voice-agent platform. SpeechRail does not run an LLM, hold
conversation history, call tools, or decide when to interrupt playback. The
caller owns all of that; SpeechRail delivers speech facts and renders audio.

## Public surface

### REST and WebSocket

| Endpoint | Purpose | Notes |
|---|---|---|
| `GET /health`, `/readyz`, `/metrics` | Diagnostics | Process, subsystem, readiness, and Prometheus metrics. `server_vad` reports separately from ASR/TTS readiness. |
| `POST /v1/audio/transcriptions` | File ASR | OpenAI-compatible multipart input; `json`, `verbose_json`, `text`, `srt`, `vtt`, plus opt-in `diarized_json` with anonymous speaker labels. |
| `POST /v1/audio/speech` | TTS | Streaming `mp3`, `opus`, `aac`, `flac`, `wav`, or raw `pcm`. Select a voice with `available=true` from `/v1/voices`. |
| `GET /v1/models`, `GET /v1/voices` | Discovery | Projection of the active profile and currently serviceable voices. |
| `GET /v1/speechrail/capabilities` | Effective capabilities | `effective_capabilities_v1`: one internally consistent snapshot of models, voices, and parameter domains. Reading it starts no worker and runs no inference. |
| `/v1/voice-designs*`, `/v1/voices/clone*` | Voice creation and cloning | Design a voice from a description, preview it, clone from a reference recording, validate, and publish to the voice library. |
| `/v1/speechrail/voices*`, `/v1/speechrail/pronunciation-sets*` | Voice library and pronunciation | Immutable voice revisions with rollback and revocation; versioned pronunciation sets for synthesis. |
| `/v1/jobs*` | Durable async jobs | Owner-scoped job records for long transcriptions. You pass opaque references; the service never stores raw audio or transcripts. |
| `WS /v1/realtime` | Realtime ASR/TTS | current-only stateless Speech Plane (contract `4.1.0`): transcription sessions, server VAD facts, word-level alignment and diarization as independent opt-ins, and explicit `speechrail.tts.*` render control. |

The full machine-readable contract is
[`contracts/openapi.yaml`](contracts/openapi.yaml); the WebSocket contract is
[`contracts/realtime-openai.md`](contracts/realtime-openai.md).

### speechrail-mcp

`speechrail-mcp` is a stateless proxy that exposes the current REST
capabilities to MCP clients over `stdio` (default, no listening port) or
`streamable-http` (default `127.0.0.1:8202`). It hosts no model, never switches
profiles, and does not proxy Realtime — agent clients connect to
`/v1/realtime` directly. `speechrail agents install --client codex` installs
the bundled skill and MCP config for Codex.

### macOS app

`macos/SpeechRailApp` is a SwiftUI control plane for the installed service. It
does not load models and does not replace the user-level `com.speechrail`
LaunchAgent; it drives the existing Python CLI through a constrained XPC
delegate. It is organized into three groups:

- **Create** — dubbing desk, voice design, voice cloning, voice library, and
  local works.
- **Sessions** — voice assistant, meeting assistant, live captions, and the
  AI teleprompter.
- **Engine** — service status, runtime monitoring, model combinations,
  preflight and diagnostics, and in-app developer docs.

Microphone capture and playback exist only while a session feature is active
and are released when you leave it. Session PCM is never written to disk;
only text and records are stored locally. Teleprompter camera and window
capture stay in your streaming software — SpeechRail supplies the script
follow-along, not the video.

## Boundaries

These are deliberate, and they are load-bearing:

- **No LLM, history, tools, or playback policy.** Realtime carries the ASR/TTS
  subset only. The caller owns orchestration and barge-in.
- **No named speakers.** Diarization returns session-scoped anonymous labels.
  There is no voiceprint database, no cross-session identity, and no speaker
  enrollment.
- **No silent network on the request path.** Inference does not download
  models, fetch remote audio URLs, or call a cloud. Installing and preparing
  models is an explicit operator action.
- **One service, one ASGI worker.** Throughput is not scaled by replicating
  model processes. Contention returns `backend_busy` by design.
- **No cloud inference, multi-tenancy, or high availability.** This is a
  single-user local runtime.

Speaker diarization additionally requires the local CoreML Sortformer bundle
and a named aligner to be provisioned, and the task to opt in. VoiceDesign is
an on-demand artifact bound to no spec.

## Requirements

- Apple Silicon Mac, macOS 26.0 or later, for the managed runtime. Intel Macs
  and Linux are not supported runtime targets; Linux is usable for
  platform-neutral development checks only.
- The bundled app also targets macOS 26.0+, `arm64`.
- Python `>=3.14,<3.15` for source development and the service CLI.
- [`uv`](https://docs.astral.sh/uv/) for dependency and environment
  management.
- Model snapshots and vendor runtimes, stored outside the repository.

`ffmpeg` is used by the audio decode/transcode paths. The managed installer
ships a pinned `imageio-ffmpeg` inside the isolated runtime, so a system copy
is optional for `speechrail install`.

## Quick start

### From a release asset

Download the wheel and `SHA256SUMS` from
[Releases](https://github.com/hrygo/SpeechRail/releases), verify the
checksums, then install with `uv` alone — no source checkout:

```bash
cd ~/Downloads
shasum -a 256 -c SHA256SUMS
uvx --python 3.14.7 --from ./speechrail-*.whl \
  speechrail install \
  --asr-spec quality \
  --tts-spec quality \
  --yes \
  --enable
```

The wheel ships the `speechrail install` entry point. It stages the release,
prepares and verifies the tier's model artifacts, runs preflight, switches
`runtime/current` atomically, and with `--enable` registers and starts
`com.speechrail`. It refuses a wheel whose version differs from the
installer, so the two can never drift. Repeating the command upgrades an
existing install; stop the running service first, because the installer
refuses to replace `runtime/current` while port 8201 is owned. Verified local
model snapshots are reused instead of re-downloaded.

Then install the app (optional) from the unsigned DMG in the same release.
The DMG ships the control plane only; it installs no service.

### From the repository

Use this path on a fresh Apple Silicon Mac that also needs prerequisites. The
bootstrap flow installs prerequisites, prepares the selected local model
artifacts, and registers the `com.speechrail` LaunchAgent. It performs
external setup work and therefore requires an explicit `--yes`:

```bash
git clone https://github.com/hrygo/SpeechRail.git
cd SpeechRail
./.agents/skills/speechrail-zero-setup/scripts/bootstrap_mac.sh \
  --yes \
  --asr-spec quality \
  --tts-spec quality
```

Read the [zero-setup guide](.agents/skills/speechrail-zero-setup/SKILL.md)
first: it documents disk requirements, spec selection, model verification,
and recovery behavior. The
[install guide](docs/users/installing-speechrail.md) explains what each
release asset is for, the install order, and the common failure states.

After installation, inspect the service without starting a second instance:

```bash
SPEECHRAIL_APP_HOME="$HOME/Library/Application Support/SpeechRail"
SPEECHRAIL_CLI="$SPEECHRAIL_APP_HOME/runtime/current/.venv/bin/speechrail"
"$SPEECHRAIL_CLI" service status --app-home "$SPEECHRAIL_APP_HOME"
"$SPEECHRAIL_CLI" diagnose --app-home "$SPEECHRAIL_APP_HOME"
curl http://127.0.0.1:8201/health
curl http://127.0.0.1:8201/readyz
```

### Source development

This path is useful for deterministic contract and application work. It can
serve HTTP without real model snapshots; inference then returns
`503 backend_not_ready` until a local ASR/TTS runtime is configured.

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
starting the service. Keep snapshots, `.env`, audio, logs, and benchmark raw
data outside the repository.

Useful read-only checks:

```bash
curl http://127.0.0.1:8201/health
curl http://127.0.0.1:8201/readyz
curl http://127.0.0.1:8201/v1/models
curl http://127.0.0.1:8201/v1/voices
uv run speechrail diagnose
```

## OpenAI-compatible usage

The standard OpenAI Python client targets the local service by changing its
base URL. Loopback access uses a placeholder key; use a real bearer key only
when you deliberately expose the service beyond loopback.

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

Realtime clients connect to `ws://127.0.0.1:8201/v1/realtime` and follow
[`contracts/realtime-openai.md`](contracts/realtime-openai.md). The wire is
current-only: `delta` partials are append-only, the optional `snapshot`
extension replaces an item's text by monotonic `revision`, and both
`partial_mode` and `chunk_duration_ms` must be confirmed by
`transcription_session.updated` before the first PCM frame. SDK, cURL,
Open-WebUI, LiveKit/Pipecat, and OpenClaw examples live in
[`docs/users/integrations.md`](docs/users/integrations.md).

## Model specs

ASR and TTS select independently. The advertised capability set follows the
active catalog selection and current readiness; BF16 weight dtype alone does
not establish a quality ranking.

| Spec | ASR | TTS lanes | Diarization and voice behavior |
|---|---|---|---|
| `fast` | `asr-0.6b-q8` | `tts-0.6b-custom-q8` + `tts-0.6b-base-q8` | CustomVoice system voices and Base reference clone; diarization requires explicit Sortformer + aligner provisioning. |
| `quality` | `asr-1.7b-q8` | `tts-1.7b-custom-q8` + `tts-1.7b-base-q8` | 1.7B CustomVoice and Base roles; diarization requires explicit provisioning. |
| `reference` | `asr-1.7b-bf16` | `tts-1.7b-custom-bf16` + `tts-1.7b-base-bf16` | Reference precision inherits the same-family 8-bit gate evidence and was not separately retested. Diarization still requires explicit provisioning. |

Every spec routes system voices through `custom_voice` and reference cloning
through `base`. VoiceDesign (`tts-1.7b-design-bf16`) is a single on-demand
artifact bound to no spec: any `tts_spec` can run design jobs once that
snapshot is supplied, and its absence only removes the design capability.
Different lanes may run concurrently while one lane stays serialized. The
capability group can still trim or close workers after the configured idle
cooldown and restore the roles the next request needs lazily.

![Three-spec model and TTS capability relationship](docs/architecture/diagrams/three-tier-model-architecture.svg)

Use the CLI to inspect or change a managed selection. `setup` provides a
memory-based starting suggestion; it is not a hardware guarantee.

```bash
SPEECHRAIL_APP_HOME="$HOME/Library/Application Support/SpeechRail"
SPEECHRAIL_CLI="$SPEECHRAIL_APP_HOME/runtime/current/.venv/bin/speechrail"
"$SPEECHRAIL_CLI" profile list --app-home "$SPEECHRAIL_APP_HOME"
"$SPEECHRAIL_CLI" profile status --app-home "$SPEECHRAIL_APP_HOME"
"$SPEECHRAIL_CLI" profile apply \
  --asr-spec quality \
  --tts-spec quality \
  --app-home "$SPEECHRAIL_APP_HOME" \
  --yes
"$SPEECHRAIL_CLI" profile rollback --app-home "$SPEECHRAIL_APP_HOME" --yes
```

Select voices from `/v1/voices` rather than assuming a registered voice works
on every spec. VoiceDesign and Base clone availability follow the current
effective capability. See
[`docs/users/api-contract.md`](docs/users/api-contract.md).

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
| Install and first run | [`docs/users/installing-speechrail.md`](docs/users/installing-speechrail.md) |
| API and client integration | [`docs/users/README.md`](docs/users/README.md), [`docs/users/integrations.md`](docs/users/integrations.md) |
| Public API contract | [`docs/users/api-contract.md`](docs/users/api-contract.md), [`contracts/openapi.yaml`](contracts/openapi.yaml) |
| Realtime protocol | [`contracts/realtime-openai.md`](contracts/realtime-openai.md) |
| Effective capabilities | [`docs/users/effective-capabilities.md`](docs/users/effective-capabilities.md) |
| MCP agent integration | [`docs/users/mcp-agent-integration.md`](docs/users/mcp-agent-integration.md) |
| Operations and rollback | [`docs/operations/README.md`](docs/operations/README.md), [`docs/operations/operations-runbook.md`](docs/operations/operations-runbook.md) |
| Development and testing | [`docs/developers/README.md`](docs/developers/README.md), [`docs/developers/testing-acceptance.md`](docs/developers/testing-acceptance.md) |
| macOS control plane | [`docs/developers/macos-app-development.md`](docs/developers/macos-app-development.md), [`docs/developers/macos-app-release.md`](docs/developers/macos-app-release.md) |
| Architecture and boundaries | [`docs/architecture/README.md`](docs/architecture/README.md), [`docs/architecture/current-boundaries.md`](docs/architecture/current-boundaries.md), [`docs/decisions/README.md`](docs/decisions/README.md) |
| Release history | [`CHANGELOG.md`](CHANGELOG.md) |

## Contributing

Before opening a pull request, read
[`CONTRIBUTING.md`](CONTRIBUTING.md) and run the deterministic quality gates:

```bash
uv sync --extra dev
uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
git diff --check
```

The CI workflow also builds the wheel and tests the SwiftUI macOS control
plane. Please use the repository's issue templates for bug reports and
feature requests. Questions and integration discussions belong in
[GitHub Discussions](https://github.com/hrygo/SpeechRail/discussions).

Please also follow the
[Code of Conduct](CODE_OF_CONDUCT.md) when participating in the project.

## Support and security

For usage questions and troubleshooting, start with
[`SUPPORT.md`](SUPPORT.md) and
[GitHub Discussions](https://github.com/hrygo/SpeechRail/discussions). For
confirmed bugs, use the
[issue templates](https://github.com/hrygo/SpeechRail/issues/new/choose).

For security vulnerabilities, follow [`SECURITY.md`](SECURITY.md) instead of
opening a public issue.

## License

SpeechRail is released under the [MIT License](LICENSE).
