# Realtime TTS 请求身份绑定 Implementation Plan

> 本计划由当前会话直接实施，使用 `executing-plans` 的逐项验证方式；不自动提交、发布或接管 UI。

**Goal:** 消除克隆音色建连时的 `model_revision_conflict`，并防止会话默认值污染后续 TTS 请求。

**Architecture:** `session.update` 只拥有 ASR revision 与连接级能力开关。`speechrail.tts.start` 独立拥有音色、voice revision 和模型 revision；服务端按该请求的音色模式选择制品，不继承其他请求或会话的 TTS 身份。Swift 会话 DTO 删除 TTS revision 参数，从接口上阻止再次混用。

**Tech Stack:** Python 3.14、FastAPI、pytest、JSON Schema、Swift、XCTest。

**Spec:** `contracts/realtime-openai.md`、`contracts/realtime-events.schema.json`；当前用户要求按 SOLID 彻底修复。

## Global Constraints

- 确定性验证使用 fake backend，不加载模型、访问云端或读取真实音频。
- 当前契约直接切换，旧 `session.speechrail.expected_tts_revision` 明确拒绝，不保留 alias。
- 保留 ASR pin 与 TTS 请求级 pin 的 fail-closed 校验。
- 不修改音色数据、模型组合、用户配置或数据库；安装与运行态变更按专项授权和流程执行。

## Review Focus

- 克隆模型与系统模型 revision 不同：建连成功，克隆请求使用 Base 制品。
- 同连接切换系统/克隆音色：每个 utterance 独立校验。
- 音色或模型 pin 过期：拒绝发生在 fake worker 开流前，且后续合法请求可继续。
- 旧会话字段：schema 与服务端均明确拒绝，失败不部分启用 TTS。
- 未提供请求级模型 pin：使用该次音色的当前制品，不沿用前一轮身份。

## Task 1: 先建立边界回归

**Files:** `tests/test_realtime_caller_wire.py`、`tests/test_realtime_tts_incremental.py`、`tests/test_realtime_current_schema.py`、`macos/SpeechRailApp/SpeechRailMacControlTests/RealtimeTTSStreamTests.swift`。

- [x] Python 断言旧会话 TTS pin 被解析器/schema 拒绝。
- [x] Swift 使用生产 `RealtimeASRClient.connect(using:)`，断言实际发出的握手不含 TTS pin；`startTTSStream` 仍携带克隆身份。
- [x] 运行定向测试，确认旧实现失败。

## Task 2: 收敛身份所有权

**Files:** `src/speechrail/compatibility/openai_realtime.py`、`src/speechrail/application/realtime_openai.py`、`macos/SpeechRailApp/SpeechRailControlKit/RealtimeContractTypes.swift`、`macos/SpeechRailApp/SpeechRailApp/RealtimeASRClient.swift`、`tests/realtime_wire.py`。

- [x] 删除会话 TTS revision 参数、解析、回显和校验。
- [x] 删除 session voice/model fallback，直接使用 `request.voice` / `request.expected_model_revision`。
- [x] 保留 `speechrail.tts.start` 中的 voice/model pin 校验与现有资源生命周期。
- [x] 回归覆盖系统→克隆→系统切换，以及冲突后的合法请求恢复。

## Task 3: 契约、文档与交付

**Files:** `contracts/realtime-events.schema.json`、`contracts/realtime-field-matrix.json`、`contracts/realtime-openai.md`、`tests/fixtures/realtime-current/`、`docs/users/api-contract.md`、`docs/developers/macos-app-development.md`。

- [x] 更新 schema、共享正反例和字段责任表，明确请求级 TTS 身份所有权。
- [x] 同步用户/开发文档，注明旧字段的移除与客户端更新方式。
- [x] 运行相关 Python/Swift 回归、Realtime 契约检查、相关 lint 和 `git diff --check`。
- [x] 独立审查最终 diff，记录实测结果与安装态边界。

验证命令使用项目原生命令：

```bash
uv run --frozen --extra dev pytest --no-cov tests/test_realtime_caller_wire.py tests/test_realtime_current_schema.py tests/test_realtime_tts_incremental.py tests/test_realtime_openai.py
swift test --package-path macos/SpeechRailApp --filter 'RealtimeTTSStreamTests|RealtimeContractTests'
uv run --frozen --extra dev python scripts/check_realtime_contract.py
git diff --check
```

## 验证记录（2026-10-05）

- RED：旧 Python parser/schema 接受会话 TTS pin，WS 返回 `session.updated`；旧 Swift 实际握手带 `base-catalog`。这些断言均在修改生产代码前失败。
- GREEN：相关 Python 175 项通过（caller wire、schema、incremental、Realtime session、三个档位能力矩阵）；Swift Realtime 47 项通过；调用方 revision selector / AppModel binding 11 项通过。
- 共享契约检查：45 fixtures、37 tracked fields 通过；Swift 实际 Assistant 握手与 Python/schema 使用同一 fixture 对齐。
- 相关 Ruff 通过；两个生产 Python 文件 mypy 通过（既有 unused configuration note）。Swift 有既有 Package 未声明文件 warning。
- 实现减少会话层 TTS 身份逻辑，保留每次 start 的模型/音色 pin 校验，不新增依赖或共享 fallback。
- 测试仅使用 fake backend 与合成 WAV，没有加载模型、真实音频、UI 自动化或 benchmark。
- 源码分支 `codex/realtime-tts-request-binding`；未自动提交、推送、安装或修改服务运行态。安装态 3.7.1 尚未更新。

## 执行判断

- 旧字段按既有未知字段错误语义返回 `unsupported_operation`，不另造 `invalid_event`。若判断错误，影响是客户端错误分类；schema 与 parser 仍严格拒绝。
- 当前用户未授权 commit，技能中基于 commit 的 review-package 改用当前工作区 diff（基准 `d72535c7`）及新增文件，不自动提交。
- 协议破坏性变更更新为 5.0.0；服务/App 版本未自动提升。旧客户端必须更新 start 事件，运行态更新应同步安装客户端和服务。

## 最终审查

- 独立 `luna_worker` 只读审查最终工作区 diff、必要调用点、协议/schema、共享 fixtures 与正式文档，未发现 Critical、Important 或 Minor 问题；没有修改文件或重复测试。
- 主代理核对最终 `git diff --check` 通过；上述测试全部使用与最终生产代码一致的状态，审查后只补本计划的记录。
- 源码修复与契约更新完成。当前安装态尚未替换，未宣称安装中的 App/服务已解决该问题；combined 本机更新须按项目运行态授权和 release 流程执行。

## 本机更新（用户于 2026-10-05 授权继续）

- 范围：本机 combined 构建与安装，不创建 commit/tag，不远端发布，不切换模型档位。
- 本地服务版本保留 3.7.1；App `CURRENT_PROJECT_VERSION` 三个配置由 44 递增到 45，以区分本次安装。版本一致性检查通过。
- wheel 原生平台制品构建成功，包含 `SpeechRailDiarizationWorker`；两处修复后的 Python 源文件与安装 wheel、managed runtime 逐字节一致。wheel SHA-256：`1eca98d44016ea036aa2224302ac6f955928d07e31dbdd545c61f78e58293bb8`。
- App Release 由仓库包装脚本构建成功；候选和安装后的 ad hoc 签名身份、内嵌 local XPC 与最终可执行文件摘要均一致。正式安装路径为 `~/Applications/SpeechRail.app`，版本 3.7.1、build 45。
- 停服前确认无 ESTABLISHED 客户端，Realtime/session 与 governor 请求计数为零；通过 managed CLI 正常 stop、wheel install、start。HF Hub 离线模式安装，未下载模型；quality/quality、auto=off、generation 13 保持不变。
- 新 runtime 摘要标识 `1eca98d44016`；旧 runtime 摘要标识 `43c337c6d0c7` 保留。私有配置和 selection 逐字节保持不变；目标克隆音色 revision 和全部模型制品/revision 与安装前一致。
- 2026-10-05 08:33 +08:00 实测：生产 Realtime 握手返回 `session.updated`，目标克隆音色请求返回 `speechrail.tts.started`，取消返回 `speechrail.tts.cancelled`；未提交文本或音频。服务入口 `speechrail-service` 与同一 managed runtime 的 Python 是同一文件。验证脚本最初误假设 argv 含 `python`，核对实际入口后改正，完整复核通过。
- App 正常退出后按同文件系统事务替换；LaunchServices 只登记正式 App，无 UI test runner。候选、暂存及旧 App 可执行副本已注销和清理；旧 App 保存为仓库外 ZIP 回退点，未启动新 App。
- 2026-10-05 08:35 +08:00 最终检查：health、ready、models、voices 均为 200；单一 listener PID 20014；活动连接/请求为零，App 退出不影响服务。
- 旧 App ZIP SHA-256：`b0f4c1cd89356d142ace3301ae622571cf74ec3ed4700ecfd26400ffde0c4aec`。新 App executable SHA-256：`eececb63601bbf5ebf5cc6c1af7a0caf49ea65f296a4160ff5024190adb54805`。制品、日志及两套回退点的定位信息保存在仓库外本次部署目录。
- 未执行 UI 自动化、ASR/TTS 音频输出质量或性能基准、Developer ID 签名、公证与远端发布；App 交互体验待用户重新打开验收。
