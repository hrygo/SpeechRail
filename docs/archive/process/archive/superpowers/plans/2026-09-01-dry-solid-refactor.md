# SpeechRail DRY/SOLID Refactor Program Plan

> **For Codex:** REQUIRED SUB-SKILL: Use `executing-plans` to execute one linked child plan at a time. Do not implement this umbrella document as one change set.

**Goal:** 在不改变 SpeechRail 公共 REST/WebSocket 契约、模型所有权、资源门禁和隐私边界的前提下，把已确认的三个结构热点拆成可独立实施、验证和回退的阶段。

**Architecture:** 本文只负责依赖顺序、跨计划门禁和完成判定。具体实现分别由 application composition、worker process transport、TTS delivery 三份子计划定义；每份子计划使用独立 commit，不跨仓库提交。

**Tech Stack:** Python 3.12、uv、FastAPI、Pydantic v2、asyncio、Qwen3 private worker IPC、pytest、Ruff、mypy、OpenAPI。

**Specs:** `contracts/openapi.yaml`、`contracts/realtime.md`、`contracts/realtime-v2.md`、`docs/architecture/current-boundaries.md`。

**Status:** Draft — 2026-09-01 已完成静态审查与聚焦基线测试，尚未执行代码重构。

---

## 已核实基线

### 当前代码事实

- `src/speechrail/app.py::create_app` 仍同时组合具体 backend、队列/governor/jobs、生命周期和全部 HTTP/WS endpoint，并使用已弃用的 `@app.on_event`。
- `create_app(...)` 的八个现有参数（一个 settings 加七个 keyword override）是测试和调用方已使用的兼容 seam，必须保留。
- `Qwen3Worker` 与 `Qwen3TtsWorker` 重复受控环境、subprocess、length-prefixed JSON、deadline 和 terminate/kill；两者的 ready/request/response policy 不同，不能合并成通用业务基类。
- `runtime/worker_protocol.py` 只有同步 `read_frame`/`write_frame`；异步 host transport 需要复用纯 codec，不能直接把同步 `BinaryIO` 函数套在 `asyncio.StreamReader/Writer` 上。
- REST TTS 在 route 内只检查 `chunk_index`；Realtime TTS 由 `SpeechSession.audio_delta()` 再检查 public response/chunk/audio 状态；Qwen TTS adapter 还检查 private IPC。目标是复用 application port 校验，并保留三层 defense in depth。
- `SpeechRequest.instructions` 只在内部模型声明处出现，不在 OpenAPI、Realtime 契约或调用点出现；删除它是内部 fail-closed 清理，不是公共 API 变更。
- voice catalog 已以 `domain/tts.py::VOICE_PROFILES` 为事实源；当前不存在另一组待删除的 voice instruction 常量。

### 2026-09-01 实测基线

```bash
uv run pytest tests/test_app_contract.py tests/test_speech_api.py \
  tests/test_realtime_v2_websocket.py tests/test_qwen3_tts.py -q --no-cov
```

结果：`33 passed`。同时观察到 `app.py` 的 FastAPI `on_event` 弃用警告；这正是 application composition 子计划的迁移对象。

这组 33 项只证明聚焦基线；每份子计划仍须运行自身扩展矩阵和项目级门禁。

## 全局约束

- Python 保持 `>=3.12,<3.13`；继续使用 `uv` 和 PEP 621。
- 保持 `/v1/audio/transcriptions`、`/v1/audio/speech`、`/v1/realtime`、`/v2/realtime`、`/asr` 的现有版本和稳定错误 envelope。
- `/v1/realtime` 仍是 commit 后 batch；`/v2/realtime` 仍只承载 ASR/TTS；`/asr` 不借重构获得 WLK parity、认证或 LAN 暴露能力。
- 模型 snapshot 和 vendor Python 仍是仓库外绝对路径；请求期间不下载模型、不读取远程音频 URL。
- 不持久化音频、PCM、embedding、完整转写、完整 TTS 文本、凭据或绝对模型路径。
- 不把 `sona` 的会议、UI、PostgreSQL、播放、LM Studio 或应用提示词移入本仓库。
- 不创建跨仓库共享 Python 包；跨项目只通过现有 public contract 和脱敏 fixture 验收。
- 本轮是内部结构重构。`contracts/` 与 accepted ADR 作为只读验收依据；若实施发现必须改变公共行为，停止当前子计划，先走独立 API/ADR 决策。
- 当前工作树包含并行文档改动和未跟踪计划文件。执行时只暂存当前子计划列出的 code/test hunk，不使用 `reset`、`checkout`、`clean`、force-push 或广泛 `git add`。

## 子计划与所有权

| 顺序 | 子计划 | 写入热点 | 依赖 | 完成信号 |
|---|---|---|---|---|
| S1 | [Application composition refactor](2026-09-01-speechrail-app-composition-refactor.md) | `app.py`、`application/`、`http/routes/` | 无 | lifespan + 全路由契约通过 |
| S2 | [Worker process transport refactor](2026-09-01-speechrail-worker-process-refactor.md) | `worker_protocol.py`、`worker_process.py`、两个 Qwen adapter | S1 后串行执行 | IPC 故障矩阵与两个 profile 回归通过 |
| S3 | [TTS delivery refactor](2026-09-01-speechrail-tts-delivery-refactor.md) | `application/tts_delivery.py`、S1 创建的 audio/v2 routes、`domain/ports.py` | 必须完成 S1；建议完成 S2 | 三层 TTS 校验与 REST/WS 回归通过 |

不要让两个执行者同时修改同一文件。S2 理论上可与 S1 并行，但共享组合测试和 backend 构造上下文会增加审查成本，本仓库按 S1 → S2 → S3 串行执行。

## 目标拓扑

```text
FastAPI composition root (app.py)
        │
        ├── application/services + lifecycle
        ├── HTTP/WS route factories
        │        │
        │        └── application/tts_delivery
        │
        └── domain ports
                  │
                  ├── Qwen ASR adapter ─┐
                  └── Qwen TTS adapter ─┴── async framed process transport
```

明确不做：

- 不把 v1、v2、legacy 合并成一个带大量条件分支的状态机。
- 不把 ASR ready/single-result 与 TTS ready/stream/cancel policy 抽进同一个业务基类。
- 不把 REST WAV/PCM rendering 与 Realtime event rendering 合并。
- 不用 `Any`、reflection、service locator 或巨大 `BaseService` 替代窄 port。
- 不以架构测试、文件长度或复杂度阈值替代行为回归。

## Stage 0: 执行前检查

- [ ] 记录当前分支、HEAD 和 dirty files。

```bash
git status --short
git log -5 --oneline
```

- [ ] 运行完整聚焦基线，确认不是在红灯上开始结构重构。

```bash
uv run --extra dev pytest \
  tests/test_app_contract.py tests/test_transcription_api.py tests/test_speech_api.py \
  tests/test_jobs_api.py tests/test_websocket_contract.py \
  tests/test_realtime_v2_websocket.py tests/test_wlk_compatibility.py \
  tests/test_tts_voices_api.py tests/test_security_boundaries.py \
  tests/test_qwen3_backend.py tests/test_qwen3_tts_worker.py \
  tests/test_worker_protocol.py -q --no-cov
```

- [ ] 若任何目标文件已有未归属当前执行者的 code hunk，停止并先协调所有权；不覆盖、不回退。

## Stage 1: 执行 S1 application composition

- [ ] 完整执行 S1 的 Task 1–5，每个 commit 后复查 `git show --stat --oneline HEAD`。
- [ ] 确认 `create_app(...)` 签名、OpenAPI paths、HTTP error、WS close/terminal event 没有变化。
- [ ] 只有 S1 的全量门禁通过后，才进入 S2；不要用后续计划修复 S1 引入的红灯。

## Stage 2: 执行 S2 worker process transport

- [ ] 完整执行 S2 的 codec → async transport → ASR → TTS 顺序。
- [ ] 每次迁移只移动一个 profile；ASR 绿灯后再迁移 TTS。
- [ ] malformed/truncated/timeout/cancel/close 测试必须使用 fake child process，不加载真实模型。
- [ ] 若出现旧帧串请求、orphan process、cancel 后仍读 stdout 或错误 code 改变，回退本阶段最近 commit，保留 S1 结果。

## Stage 3: 执行 S3 TTS delivery

- [ ] 先建立 application stream 校验，再分别接入 REST 与 Realtime v2。
- [ ] backend response ID 只校验 backend stream 内一致性，不能替代 public `SpeechSession` response ID。
- [ ] 最后单独删除内部 `SpeechRequest.instructions`；若搜索发现新调用方，停止删除步骤并重新评审兼容性。

## Stage 4: SpeechRail 项目验收

- [ ] 运行全量门禁。

```bash
uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
git diff --check
```

- [ ] 比较公开路径和关键事件 fixture；确认没有修改 `contracts/`。
- [ ] 检查进程、task、async generator 均在正常退出、异常、timeout 和 cancel 路径释放。
- [ ] 检查 diff 不含 `.env`、模型、音频、日志、缓存、构建产物或另一个仓库文件。

## Stage 5: 与 sona 的闭环

本阶段只在 SpeechRail 三份子计划和 sona 的 ASR/Subtitle 子计划均通过后执行。

- [ ] 在 `sona` 仓库运行 typed SpeechRail ASR/TTS adapter 测试，不做内部 Python import。
- [ ] 有真实 runtime 和明确授权时，验证 `/health`、`/readyz`、`/v1/models`、`/v1/voices`、REST ASR/TTS、Realtime v2 ASR/TTS、cancel、slow consumer 和 reconnect。
- [ ] 没有真实 snapshot/runtime 时，分别记录 `fake/contract: passed` 与 `real runtime: unverified`；不得使用 `SPEECHRAIL_BACKEND_READY=true` 伪造真实验收。
- [ ] 两个仓库分别提交、分别回退，不创建跨仓库原子 commit 假象。

## 总体验收标准

- [ ] `app.py` 是组合根，lifespan、route factory 和 concrete backend 构造边界清晰。
- [ ] ASR/TTS 共用异步 framed process primitive，但 profile policy 仍分离。
- [ ] REST/Realtime 共用 public `AudioChunk` stream 校验，private IPC 与 wire state 校验仍保留。
- [ ] `SpeechRequest.instructions` 删除前已证明无调用方，公共契约不变。
- [ ] pytest、Ruff、mypy、OpenAPI lint 和 diff 检查通过。
- [ ] 真实模型、客户端、性能与资源 smoke 的状态分别标为 passed/failed/unverified。
- [ ] 并行文档改动未被覆盖或混入代码 commit。

## 回退原则

- 每份子计划、每个 profile 和每个 route 阶段使用独立 commit；只回退导致回归的最近结构性 commit。
- S1 回退不删除 `.env`、外部 snapshot 或运行目录；S2 回退只恢复 adapter 的旧 transport 组合；S3 回退只恢复 route 内校验和内部字段。
- 不使用 destructive Git 命令，不重写他人历史，不删除用户数据或外部模型。
