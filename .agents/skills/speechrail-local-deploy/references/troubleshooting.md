# SpeechRail Local Deployment Troubleshooting

## 1. Common Issues and Resolutions

### Issue 1: Port 8201 Conflict / Address already in use
- **Cause**: An old LaunchAgent instance or manual foreground process is still running.
- **Diagnostics**:
  ```bash
  lsof -i :8201
  ```
- **Resolution**:
  ```bash
  uv run speechrail service disable --app-home "$HOME/Library/Application Support/SpeechRail"
  ```
  If an orphaned PID remains:
  ```bash
  kill -TERM <pid>
  ```

### Issue 2: `this wheel is already staged`
- **Cause**: An earlier install attempt was interrupted after creating the release directory under `runtime/releases/`.
- **Resolution**:
  Remove the specific release folder:
  ```bash
  rm -rf "$HOME/Library/Application Support/SpeechRail/runtime/releases/speechrail-<version>-*"
  ```

### Issue 3: Preflight Failure on `config_permissions`
- **Cause**: `~/Library/Application Support/SpeechRail/config/.env` does not have mode `0600`.
- **Resolution**:
  ```bash
  chmod 0600 "$HOME/Library/Application Support/SpeechRail/config/.env"
  ```

### Issue 4: LaunchAgent Plist Syntax Error
- **Diagnostics**:
  ```bash
  plutil -lint ~/Library/LaunchAgents/com.speechrail.plist
  ```
- **Resolution**:
  Reinstall plist from clean runtime:
  ```bash
  uv run speechrail service install --app-home "$HOME/Library/Application Support/SpeechRail"
  ```

---

## 2. Inspecting Live Service Logs

- **Standard Output**:
  ```bash
  tail -n 50 "$HOME/Library/Logs/SpeechRail/stdout.log"
  ```
- **Standard Error / Tracebacks**:
  ```bash
  tail -n 50 "$HOME/Library/Logs/SpeechRail/stderr.log"
  ```
