# SpeechRail 唯一 ASR 运行迁移 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `executing-plans` task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 QwenPaw 和 sona 的 ASR 运行时唯一切换到本机 SpeechRail，并以真实本地 Qwen3-ASR 模型完成端到端验收。

**Architecture:** SpeechRail 在 `127.0.0.1:8201` 管理一份仓库外 Qwen3-ASR worker；QwenPaw 只使用其 OpenAI-compatible REST API，sona 的字幕/会议和语音助手只使用其 Realtime v2 API。客户端不配置 WLK、SenseVoice、`/asr` 或自动回退；失败通过明确错误暴露，而不是静默切换模型。

**Tech Stack:** Python 3.12、FastAPI、Qwen3-ASR、本地 MPS、QwenPaw、sona、WebSocket Realtime v2。

**Spec:** `docs/superpowers/specs/2026-08-31-speechrail-asr-tts-runtime-design.md`

## Global Constraints

- SpeechRail 仅绑定 `127.0.0.1:8201`；不暴露 LAN，也不下载模型。
- 模型 snapshot 与 worker Python 必须是仓库外绝对路径，设备固定 `mps`、dtype 固定 `float16`。
- QwenPaw 使用 `http://127.0.0.1:8201/v1` 与 `speechrail/qwen3-asr-1.7b`。
- sona 只使用 `ws://127.0.0.1:8201/v2/realtime`；字幕和交互均不保留运行时 fallback。
- 不记录、提交或输出音频、转写正文、API key 或完整私有配置。

---

### Task 1: 建立可恢复的运行配置基线（已完成）

**Files:**
- Create: `/Users/hrygo/Documents/SpeechRail/.env`（gitignore，私有运行配置）
- Modify: `/Users/hrygo/.qwenpaw/config.json`（私有运行配置）
- Modify: `/Users/hrygo/Documents/sona/.env`（gitignore，私有运行配置）
- Modify: `docs/08-migration-runbook.md`

- [x] **Step 1: 只读取非敏感配置键，记录当前 endpoint、model 和默认值。**
- [x] **Step 2: 使用时间戳备份三个私有配置文件，校验备份存在且权限未放宽。**
- [x] **Step 3: 配置 SpeechRail ASR worker 的两条外部绝对路径与 loopback 端口。**
- [x] **Step 4: 将 QwenPaw 的 provider endpoint/model 改为 SpeechRail REST。**
- [x] **Step 5: 将 sona 字幕与交互 ASR 指向 SpeechRail Realtime v2，并禁用 legacy `/asr`。**
- [x] **Step 6: 更新 Runbook，明确该机器已经完成唯一 ASR 切换及回退仅能恢复备份。**

### Task 2: 启动并验证 SpeechRail 真实本地 worker（已完成）

**Files:**
- Modify: `/Users/hrygo/Documents/SpeechRail/.env`
- Test: `/health`、`/readyz`、`/v1/models`、`/v1/audio/transcriptions`

- [x] **Step 1: 验证 Qwen3-ASR snapshot 必要文件与专用 Python 的 `qwen_asr` import；不联网。**
- [x] **Step 2: 启动单一 SpeechRail 进程并等待 worker ready。**
- [x] **Step 3: 用操作者拥有的短音频请求 REST 转写；只记录 HTTP 状态、request ID、时延和非空断言。**
- [x] **Step 4: 保留唯一已验证服务进程；未并行启用旧 `8001` ASR worker。**

### Task 3: QwenPaw 与 sona 端到端验收（已完成）

**Files:**
- Modify: `/Users/hrygo/.qwenpaw/config.json`
- Modify: `/Users/hrygo/Documents/sona/.env`
- Test: QwenPaw `/api/workspace/transcribe`、sona Realtime v2 字幕与 VAD turn

- [x] **Step 1: 完整重启 QwenPaw；调用其转写 API 并验证由 SpeechRail 返回。**
- [x] **Step 2: 验证 sona 字幕与交互配置均加载 `speechrail-realtime-v2`。**
- [x] **Step 3: 使用本机短 PCM 验证 `session.update → append → commit → transcription.completed`。**
- [x] **Step 4: 验证一个 VAD turn 产生最终文本且 TTS bridge 未被改动。**
- [x] **Step 5: 未触发回退；保留私有备份仅作人工恢复。**

### Task 4: 删除 sona 源码中的旧 ASR adapter（独立后续任务，未开始）

**Files:**
- Modify: `src/sona/config.py`
- Modify: `tests/test_config.py`
- Modify: `docs/08-migration-runbook.md`

- [ ] **Step 1: 列出可删除的 WLK、SenseVoice 与 Qwen 内嵌 adapter 的公开配置、测试和运维依赖。**
- [ ] **Step 2: 以破坏性变更的形式删除旧 backend 值、factory 分支和依赖，并更新部署迁移说明。**
- [ ] **Step 3: 在无私有 `.env` 污染的测试配置中运行目标测试、完整 Python tests、Ruff、mypy 和前端构建。**
- [ ] **Step 4: 审查差异、提交并合并到 `main`；不得 push。**

Task 4 不属于本次运行配置切换：当前机器没有活动的 ASR fallback，旧 adapter 仅是
`sona` 仓库内尚未删除的兼容代码。删除会破坏其现有公开配置和基准工具，应作为
独立的有版本迁移任务执行，不能用“改默认值”的方式伪装为无破坏变更。
