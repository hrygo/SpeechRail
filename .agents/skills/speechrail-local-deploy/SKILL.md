---
name: speechrail-local-deploy
description: >-
  Standard operating procedures and runbooks for deploying, upgrading, validating,
  and troubleshooting the local SpeechRail ASR/TTS service and macOS LaunchAgent.
  Use this skill whenever deploying the service, upgrading to a new wheel release,
  managing launchd/service lifecycle, or diagnosing deployment issues.
---

# SpeechRail Local Deployment Skill

This skill guides agents through safely deploying, upgrading, configuring, and verifying the **SpeechRail** local ASR/TTS service on macOS.

---

## 1. Core Deployment Principles

1. **Local-First & Single User**: Default binding to loopback (`127.0.0.1:8201`). Never install as `LaunchDaemon` or root service; macOS services run exclusively under user domain `gui/<uid>` as `LaunchAgent`.
2. **Strict Single Instance**: Only one SpeechRail process and one port 8201 binding may run at any time. Before deploying or enabling a new release, **always disable the existing instance** to prevent port conflicts or state corruption.
3. **Immutable Config Security**: Private runtime configuration resides at `~/Library/Application Support/SpeechRail/config/.env` with strict `0600` permissions. Never overwrite existing config files, and never log raw tokens, keys, or credentials.
4. **Isolated Virtualenvs**: Production wheel installations reside in isolated release directories under `~/Library/Application Support/SpeechRail/runtime/releases/` with `runtime/current` managed atomically via symlinks.

---

## 2. Standard Wheel Deployment / Upgrade Procedure

When requested to deploy or upgrade the service, follow these exact steps:

### Step 1: Pre-deployment Cleanliness Check

Ensure git working tree is clean and dev tests pass:
```bash
uv run --extra dev pytest -q --no-cov
```

### Step 2: Build the Wheel

Build the clean runtime wheel without source packages:
```bash
uv build --no-sources --wheel
```
*Output artifact:* `dist/speechrail-<version>-py3-none-any.whl`

### Step 3: Disable Existing Service (If Running)

Stop and disable the current running instance to free up port 8201:
```bash
uv run speechrail service disable --app-home "$HOME/Library/Application Support/SpeechRail"
```

### Step 4: Execute Installer Script

Run the macOS installer to create the isolated virtualenv, install wheel dependencies (including optional `diarization` extra if configured in `.env`), run preflight checks, atomically update `runtime/current`, and enable the LaunchAgent:
```bash
python3 tools/install_macos.py \
  --wheel dist/speechrail-<version>-py3-none-any.whl \
  --env-file "$HOME/Library/Application Support/SpeechRail/config/.env" \
  --app-home "$HOME/Library/Application Support/SpeechRail" \
  --enable
```

> **Note on already-staged error**: If an earlier interrupted installation left a staged folder in `runtime/releases/`, remove the specific folder:
> `rm -rf "$HOME/Library/Application Support/SpeechRail/runtime/releases/speechrail-<version>-*"`

---

## 3. Post-Deployment Verification & Health Probing

After deployment, always run full operational verification across endpoints:

### 1. LaunchAgent Process Status
```bash
uv run speechrail service status --app-home "$HOME/Library/Application Support/SpeechRail"
```
*Expected:* `state = running`, non-empty `pid`, pointing to `runtime/current/.venv/bin/python`.

### 2. Service Endpoints Smoke Check
```bash
curl -s http://127.0.0.1:8201/health | jq .
curl -s http://127.0.0.1:8201/readyz | jq .
curl -s http://127.0.0.1:8201/v1/models | jq .
curl -s http://127.0.0.1:8201/v1/voices | jq .
```
*Verification criteria:*
- `/health`: status code 200, `status = "ok"`, `version` matches new release, `asr_ready = true`.
- `/readyz`: status code 200, `ready = true`.
- `/v1/models`: returns canonical models and standard OpenAI compatibility aliases (`whisper-1`, `tts-1`, etc.).
- `/v1/voices`: returns 4 preset voice profiles (`default`, `warm`, `bright`, `calm`) with `available = true`.

---

## 4. Foreground Development & Debugging Mode

For local debugging, live reloading, or tracing without LaunchAgent:

```bash
# Start foreground ASGI process directly
uv run speechrail serve

# Or with an explicit private env file
uv run speechrail serve --env-file "$HOME/Library/Application Support/SpeechRail/config/.env"
```

---

## 5. Rollback Procedure

If a new release fails preflight or health checks:

1. **Disable current instance**:
   ```bash
   uv run speechrail service disable --app-home "$HOME/Library/Application Support/SpeechRail"
   ```
2. **Switch `runtime/current` symlink to previous release**:
   ```bash
   ln -sfn "$HOME/Library/Application Support/SpeechRail/runtime/releases/<previous-release>" "$HOME/Library/Application Support/SpeechRail/runtime/current"
   ```
3. **Re-install and re-enable service with previous runtime**:
   ```bash
   uv run speechrail service install --app-home "$HOME/Library/Application Support/SpeechRail"
   uv run speechrail service enable --app-home "$HOME/Library/Application Support/SpeechRail"
   ```
4. **Check logs**:
   Inspect `~/Library/Logs/SpeechRail/stderr.log` for failure diagnostics.
