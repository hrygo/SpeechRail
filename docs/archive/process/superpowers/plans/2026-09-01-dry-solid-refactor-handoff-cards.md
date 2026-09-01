# SpeechRail DRY/SOLID 重构工作交接任务卡

> **交接状态：** Ready for assignment（2026-09-01）
>
> **用途：** 供 SpeechRail 团队按依赖顺序领取、实施、审查和验收结构重构。
>
> **总控计划：** [2026-09-01-dry-solid-refactor.md](2026-09-01-dry-solid-refactor.md)

本文件是执行调度与交接证据清单，不替代子计划。实现者必须逐项执行对应子计划；若本卡与当前代码、契约或测试结果冲突，以当前实测和总控计划规定的事实层级为准，并在继续前更新交接记录。

## 交接快照与工作规则

- 2026-09-01 交接快照：`HEAD=54dc81a`；工作树已有大量并行文档、代码和测试改动，四份本轮计划尚未跟踪。执行前必须重新记录 HEAD 和 dirty files，不能假定该快照仍是当前状态。
- 执行顺序固定为 `SR-00 → SR-01 → SR-02 → SR-03 → SR-04 → XR-01`。
- 本仓库 WIP 上限为 1：同一时刻只允许一张结构重构卡进入“进行中”。不让两个执行者同时修改 `app.py`、route、adapter 或共享测试。
- 每个子计划使用独立分支或 PR；子计划内部按其 Task 边界提交。只暂存本卡归属的 hunk，不使用广泛 `git add`。
- 状态流转为 `待领取 → 进行中 → 待审查 → 完成`；无法满足开始门槛或发现公共行为变化时标记 `阻塞`，不得绕过门禁。
- 实施负责人维护代码和聚焦测试；审查负责人核对契约、边界与 diff；验证负责人独立运行完成门禁。三类责任必须在 issue 或 PR 元数据中登记。
- `contracts/`、accepted ADR、外部模型、`.env` 和另一个仓库均为只读边界。发现必须修改公共契约时，停止本卡并新建独立 ADR/contract 任务。
- 不启动、重启、安装或卸载本机服务；真实 runtime smoke 只有在运行条件与授权同时具备时执行。

## 任务看板

| 卡号 | 工作包 | 依赖 | 默认状态 | 主要完成信号 |
|---|---|---|---|---|
| SR-00 | 执行前基线与所有权锁定 | 无 | 待领取 | HEAD、dirty files、目标 hunk 和基线结果均已登记 |
| SR-01 | Application composition | SR-00 | 待领取 | lifespan、route factory 与现有公共契约通过 |
| SR-02 | Worker process transport | SR-01 | 待领取 | 共用 framed transport，ASR/TTS profile policy 保持分离 |
| SR-03 | TTS delivery | SR-02 | 待领取 | application stream 校验复用，三层 defense in depth 保留 |
| SR-04 | SpeechRail 仓库级验收 | SR-03 | 待领取 | pytest、Ruff、mypy、OpenAPI lint、diff gate 全部通过 |
| XR-01 | 两仓公共契约闭环 | SR-04、voice-realtime `VR-07` | 待领取 | fake/contract 与真实 runtime 状态分别留证 |

## SR-00：执行前基线与所有权锁定

**责任角色：** SpeechRail 技术负责人领取；审查负责人确认目标文件无人并行写入。

**写入范围：** 无生产文件写入；只在团队 issue/PR 中记录执行信息。

**阻塞后续：** SR-01。

### 执行清单

- [ ] 记录当前分支、HEAD、dirty files，以及每个既有 hunk 的归属。

```bash
git status --short
git log -5 --oneline
```

- [ ] 确认 SR-01 的 `src/speechrail/app.py` 和相关测试不存在未协调的并行 code hunk。
- [ ] 运行总控计划 Stage 0 聚焦基线。

```bash
uv run --extra dev pytest \
  tests/test_app_contract.py tests/test_transcription_api.py tests/test_speech_api.py \
  tests/test_jobs_api.py tests/test_websocket_contract.py \
  tests/test_realtime_v2_websocket.py tests/test_wlk_compatibility.py \
  tests/test_tts_voices_api.py tests/test_security_boundaries.py \
  tests/test_qwen3_backend.py tests/test_qwen3_tts_worker.py \
  tests/test_worker_protocol.py -q --no-cov
```

- [ ] 若基线失败，记录失败测试、错误摘要、与现有 dirty hunk 的关系；未完成归因前不开始 SR-01。
- [ ] 在 issue/PR 中登记实施负责人、审查负责人、验证负责人、执行分支和回退基点。

### 完成证据

- 开始时的 `git status --short` 与 HEAD。
- 聚焦基线的命令、退出码、passed/failed 数量。
- SR-01 目标 hunk 的唯一所有权声明。
- 无代码 commit；本卡只解除执行阻塞。

## SR-01：Application composition

**来源：** [2026-09-01-speechrail-app-composition-refactor.md](2026-09-01-speechrail-app-composition-refactor.md)

**责任角色：** FastAPI/application 负责人实施；公共契约负责人审查。

**依赖：** SR-00 完成。

**阻塞后续：** SR-02、SR-03。

### 目标与写入边界

- 把 `src/speechrail/app.py` 收敛为 composition root，提取 `application/`、lifespan、HTTP/WS route factories。
- 保留 `create_app(...)` 现有八个参数 seam、公开路径、HTTP error envelope、WS close code 与 terminal event。
- 只修改子计划“目标文件”列出的 `src/speechrail/app.py`、新 application/http modules 和对应契约测试；不修改 `contracts/`。

### 执行清单

- [ ] 按子计划 Task 1–5 执行：先补生命周期/路由失败测试，再提取依赖快照与 lifespan，然后依次迁移 HTTP、jobs 和三类 WebSocket route。
- [ ] 每个 Task 后运行其聚焦测试并检查 staged diff；不得让 route 直接构造 Qwen/WLK/NeMo。
- [ ] 运行完整路由回归。

```bash
uv run --extra dev pytest \
  tests/test_application_composition.py tests/test_app_contract.py \
  tests/test_transcription_api.py tests/test_speech_api.py tests/test_jobs_api.py \
  tests/test_websocket_contract.py tests/test_realtime_v2_websocket.py \
  tests/test_wlk_compatibility.py tests/test_tts_voices_api.py \
  tests/test_security_boundaries.py -q --no-cov
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
git diff --check
```

### 完成门槛

- [ ] `@app.on_event` 已由 lifespan 替代，部分启动失败、正常退出和重复 close 均有测试。
- [ ] `app.py` 不再承载 endpoint 业务分支或 concrete worker lifecycle。
- [ ] v1、v2 与 legacy 仍是三个显式协议边界；OpenAPI paths 和既有调用 seam 未改变。
- [ ] 子计划项目门禁通过，审查者核对实际 diff 只含 SR-01 范围。
- [ ] 交接记录包含 commit 列表、测试结果、未验证项与可回退 commit。

## SR-02：Worker process transport

**来源：** [2026-09-01-speechrail-worker-process-refactor.md](2026-09-01-speechrail-worker-process-refactor.md)

**责任角色：** Runtime/IPC 负责人实施；ASR 与 TTS adapter 负责人共同审查。

**依赖：** SR-01 完成且工作树无目标文件冲突。

**阻塞后续：** SR-03。

### 目标与写入边界

- 在 `runtime/worker_protocol.py` 保留同步 API 并提取纯 codec，新建无 profile 业务语义的 `runtime/worker_process.py`。
- 依次迁移 `qwen3_native.py` 和 `qwen3_tts.py`；只复用 environment、subprocess、frame、deadline 与 terminate/kill。
- ASR 的 ready/单结果策略与 TTS 的 ready/stream/cancel 策略继续留在各自 adapter。

### 执行清单

- [ ] 按 `codec → async transport → ASR → TTS` 顺序执行子计划 Task 1–5；ASR 绿灯后才能迁移 TTS。
- [ ] fake child process 覆盖 malformed、truncated、timeout、exit、cancel、close 和 terminate 后 kill；不得加载模型 SDK 或访问网络。
- [ ] 运行 worker 故障矩阵。

```bash
uv run --extra dev pytest \
  tests/test_worker_protocol.py tests/test_worker_process.py \
  tests/test_qwen3_backend.py tests/test_qwen3_tts_worker.py tests/test_qwen3_tts.py \
  -q --no-cov
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
git diff --check
```

### 完成门槛

- [ ] 同步 protocol API 保持兼容，纯 codec 被同步与异步路径共用。
- [ ] 两个 adapter 不再复制进程/帧/离线环境/退出逻辑，且未形成通用业务基类。
- [ ] timeout、malformed frame、child exit、consumer cancel 均无 orphan process 或 task 泄漏。
- [ ] 错误 code、request/response ID 和 ASR/TTS profile 语义未改变。
- [ ] 交接记录明确真实模型未启动，并给出按 profile 回退的 commit 边界。

## SR-03：TTS delivery

**来源：** [2026-09-01-speechrail-tts-delivery-refactor.md](2026-09-01-speechrail-tts-delivery-refactor.md)

**责任角色：** TTS/application 负责人实施；REST 与 Realtime v2 负责人审查。

**依赖：** SR-01 必须完成，本看板要求 SR-02 完成后再开始。

**阻塞后续：** SR-04。

### 目标与写入边界

- 新建 `application/tts_delivery.py`，让 REST 和 Realtime v2 共用 public `AudioChunk` stream 校验。
- 保留 private IPC、application port、wire/session state 三层独立校验；REST rendering 与 Realtime event rendering 不合并。
- 最后单独删除内部 `SpeechRequest.instructions`；若搜索发现调用方，停止删除步骤并重新评审。

### 执行清单

- [ ] 按子计划 Task 1–5 执行：先写三层保护测试，再实现 iterator，随后分别接入 REST/Realtime，最后处理内部字段。
- [ ] backend response ID 只用于 backend stream 一致性，不得替代 public `SpeechSession` response ID。
- [ ] 运行 TTS 聚焦矩阵。

```bash
uv run --extra dev pytest \
  tests/test_tts_delivery.py tests/test_speech_api.py \
  tests/test_realtime_v2_websocket.py tests/test_realtime_v2_session.py \
  tests/test_qwen3_tts.py tests/test_qwen3_tts_worker.py tests/test_tts_voices_api.py \
  -q --no-cov
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
git diff --check
```

### 完成门槛

- [ ] chunk index、response ID、terminal order、PCM bytes 和 cancellation 均由对应层测试锁定。
- [ ] REST PCM/WAV 与 Realtime v2 事件形状、错误语义和 voice catalog 不变。
- [ ] `SpeechRequest.instructions` 删除前已证明无调用方；公共 schema 未变化。
- [ ] 真实 TTS runtime 不具备时明确记录 `real runtime: unverified`，不以 fake backend 冒充质量验收。
- [ ] 交接记录给出 route 接入和内部字段删除的独立回退点。

## SR-04：SpeechRail 仓库级验收

**责任角色：** 未参与主要实现的验证负责人执行；技术负责人签收。

**依赖：** SR-01、SR-02、SR-03 均处于待审查或完成，目标 diff 已冻结。

**写入范围：** 默认无代码写入；发现失败时退回对应卡，不在本卡顺手修复。

### 验收清单

- [ ] 运行项目级 gate，并记录每条命令的退出码与测试数量。

```bash
uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
git diff --check
```

- [ ] 对照重构前证据核对 route set、OpenAPI paths、错误 code、WS close code 和 terminal event fixture。
- [ ] 审查正常、异常、timeout 与 cancel 路径，确认 process、task、async generator 释放。
- [ ] 确认提交不含 `.env`、模型、音频、日志、缓存、构建产物、并行 hunk 或 voice-realtime 文件。
- [ ] 分别标记 `contract/fake`、`real ASR`、`real TTS`、`performance/resource` 为 passed、failed 或 unverified。

### 完成证据

- 完整 gate 结果与审查结论。
- SR-01 至 SR-03 的 commit/PR 对应关系和回退顺序。
- 公共契约“无变化”证据，或导致阻塞的精确差异。
- 可交给 voice-realtime 团队的脱敏 fixture、事件字段与错误语义摘要。

## XR-01：两仓公共契约闭环

**共同责任：** SpeechRail 团队发布服务端证据；voice-realtime 团队执行客户端 adapter/workflow 验证；跨团队验证负责人汇总。

**依赖：** 本仓 SR-04 与 voice-realtime `VR-07` 均完成。

**写入范围：** 默认只生成验收记录；任何修复必须回到所属仓库的新任务和独立 commit。

### 验收清单

- [ ] 两仓先分别运行 contract/fake tests，确认 voice-realtime 未导入 SpeechRail 内部 Python 模块。
- [ ] 核对 ASR final/segments/speaker/remap/error 与 TTS audio/completed/cancel/slow-consumer 的 public field 和顺序。
- [ ] 缺少真实 runtime 时记录 `contract/fake: passed` 与 `real runtime: unverified`，不得声明生产闭环。
- [ ] 条件与授权具备时，依次验证 `/health`、`/readyz`、`/v1/models`、`/v1/voices`、REST ASR/TTS、Realtime v2 ASR/TTS、cancel、slow consumer 与 reconnect。
- [ ] 只记录状态码、request ID、错误码、事件类型/顺序、耗时与资源摘要；不记录凭据、音频、完整文本、embedding 或绝对模型路径。
- [ ] 两仓分别提交、分别回退，不制造跨仓原子 commit。

### 完成门槛

- [ ] 两仓 gate 证据可相互引用，且公共契约没有未解释差异。
- [ ] 真实 runtime 的 passed/failed/unverified 状态明确。
- [ ] 失败项已落入唯一所属仓库的新任务，不在闭环卡内直接改代码。

## 强制交接记录模板

每张卡进入“待审查”前，执行负责人须在 issue 或 PR 填写以下字段；不得只写“测试通过”。

```text
卡号与状态：
仓库、分支、开始 HEAD、结束 HEAD：
实施负责人、审查负责人、验证负责人：
实际修改文件与未触碰的并行文件：
提交列表及每个提交的职责：
聚焦验证：命令、退出码、passed/failed 数量：
项目门禁：命令、退出码、passed/failed 数量：
公共契约/ADR 结论：
真实 runtime、客户端、性能与资源状态：passed / failed / unverified：
已知风险与后续任务：
回退点与回退后必须复跑的验证：
```

## 回退与升级规则

- 优先 revert 当前卡最近的结构性 commit；不使用 `reset --hard`、`checkout --`、`clean` 或 force-push。
- SR-01 回退不删除外部配置；SR-02 按 adapter/profile 回退；SR-03 分开回退 route 接入和内部字段删除。
- 任何数据、外部模型、`.env`、运行目录或另一个团队的改动均不在回退范围。
- 发现公共 contract、accepted ADR、安全边界或运行态必须变化时，停止执行并升级为独立决策任务。
