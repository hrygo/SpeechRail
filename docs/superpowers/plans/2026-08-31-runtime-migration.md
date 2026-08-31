# SpeechRail 唯一 ASR 运行迁移 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `executing-plans` task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 QwenPaw 和 voice-realtime 的 ASR 运行时唯一切换到本机 SpeechRail，并以真实本地 Qwen3-ASR 模型完成端到端验收。

**Architecture:** SpeechRail 在 `127.0.0.1:8201` 管理一份仓库外 Qwen3-ASR worker；QwenPaw 只使用其 OpenAI-compatible REST API，voice-realtime 的字幕/会议和语音助手只使用其 Realtime v2 API。客户端不配置 WLK、SenseVoice、`/asr` 或自动回退；失败通过明确错误暴露，而不是静默切换模型。

**Tech Stack:** Python 3.12、FastAPI、Qwen3-ASR、本地 MPS、QwenPaw、voice-realtime、WebSocket Realtime v2。

**Spec:** `docs/superpowers/specs/2026-08-31-speechrail-asr-tts-runtime-design.md`

## Global Constraints

- SpeechRail 仅绑定 `127.0.0.1:8201`；不暴露 LAN，也不下载模型。
- 模型 snapshot 与 worker Python 必须是仓库外绝对路径，设备固定 `mps`、dtype 固定 `float16`。
- QwenPaw 使用 `http://127.0.0.1:8201/v1` 与 `speechrail/qwen3-asr-1.7b`。
- voice-realtime 只使用 `ws://127.0.0.1:8201/v2/realtime`；字幕和交互均不保留运行时 fallback。
- 不记录、提交或输出音频、转写正文、API key 或完整私有配置。

---

### Task 1: 建立可回退的运行配置基线

**Files:**
- Create: `/Users/hrygo/Documents/SpeechRail/.env`（gitignore，私有运行配置）
- Modify: `/Users/hrygo/.qwenpaw/config.json`（私有运行配置）
- Modify: `/Users/hrygo/Documents/voice-realtime/.env`（gitignore，私有运行配置）
- Modify: `docs/08-migration-runbook.md`

- [ ] **Step 1: 只读取非敏感配置键，记录当前 endpoint、model 和默认值。**
- [ ] **Step 2: 使用时间戳备份三个私有配置文件，校验备份存在且权限未放宽。**
- [ ] **Step 3: 配置 SpeechRail ASR worker 的两条外部绝对路径与 loopback 端口。**
- [ ] **Step 4: 将 QwenPaw 的 provider endpoint/model 改为 SpeechRail REST。**
- [ ] **Step 5: 将 voice-realtime 字幕与交互 ASR 指向 SpeechRail Realtime v2，并禁用 legacy `/asr`。**
- [ ] **Step 6: 更新 Runbook，明确该机器已经完成唯一 ASR 切换及回退仅能恢复备份。**

### Task 2: 启动并验证 SpeechRail 真实本地 worker

**Files:**
- Modify: `/Users/hrygo/Documents/SpeechRail/.env`
- Test: `/health`、`/readyz`、`/v1/models`、`/v1/audio/transcriptions`

- [ ] **Step 1: 验证 Qwen3-ASR snapshot 必要文件与专用 Python 的 `qwen_asr` import；不联网。**
- [ ] **Step 2: 启动单一 SpeechRail 进程并等待 worker ready。**
- [ ] **Step 3: 用操作者拥有的短音频请求 REST 转写；只记录 HTTP 状态、request ID、时延和非空断言。**
- [ ] **Step 4: 停止临时进程或保留唯一已验证服务进程，禁止与旧 `8001` ASR worker 并行作为 fallback。**

### Task 3: QwenPaw 与 voice-realtime 端到端验收

**Files:**
- Modify: `/Users/hrygo/.qwenpaw/config.json`
- Modify: `/Users/hrygo/Documents/voice-realtime/.env`
- Test: QwenPaw `/api/workspace/transcribe`、voice-realtime Realtime v2 字幕与 VAD turn

- [ ] **Step 1: 完整重启 QwenPaw，而不是仅 reload agent；调用其转写 API 并验证请求由 SpeechRail 返回。**
- [ ] **Step 2: 重启 voice-realtime，验证 subtitles 与 interaction 均加载 `speechrail-realtime-v2`。**
- [ ] **Step 3: 使用本机短 PCM 验证 `session.update → append → commit → transcription.completed`。**
- [ ] **Step 4: 验证一个 VAD turn 产生最终文本且 TTS bridge 不被改动。**
- [ ] **Step 5: 出现失败时停止流程，恢复本次备份并记录无敏感错误码。**

### Task 4: 消除默认回退并完成验证

**Files:**
- Modify: `src/voice_realtime/config.py`
- Modify: `tests/test_config.py`
- Modify: `docs/08-migration-runbook.md`

- [ ] **Step 1: 写失败测试，要求 SpeechRail 是字幕和交互的默认 ASR，且不接受旧运行时后端值。**
- [ ] **Step 2: 最小化配置类型与默认值，使未设置环境时也只选择 SpeechRail。**
- [ ] **Step 3: 运行目标测试、完整 Python tests、Ruff、mypy 和前端构建。**
- [ ] **Step 4: 审查差异、提交并合并到 `main`；不得 push。**
