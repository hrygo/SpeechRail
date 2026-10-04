---
title: "语音助手后续修复实施验收"
status: completed
verification_scope: targeted_fake_regression
date: 2026-10-04
---

# 实施与验收记录

依据：[Luna 实施方案](2026-10-04-assistant-e2e-followups-luna-guide.md) §5、§7、§8。
基线：`codex/fix-assistant-clone-tts-binding`，`7ae70b0358b6ad45161c6eb5bf056844c9297f0d`。
核验日期：2026-10-04（Asia/Shanghai）；工具链实测 Apple Swift 6.4、arm64 macOS 27。

本轮 S1～S6 实施与定向 fake 验收完成；此状态不代表 App 发布、真实设备、模型质量、性能或长时稳定性验收完成。实施后的源码起点为本地提交 `e6421d5caf3032f319590b00282521e5987059ce`；主代理收尾仅补两处测试屏障的 `defer` 清理与文档登记，未执行提交或推送。

## 实施团队目标（约 500 字）

团队以所引方案为共同实施依据，由主代理负责集成与最终验收，Luna 分别负责输入保存、上下文策略与朗读生命周期，同一文件只由一人写入。核对分支、基线和现有改动后，依次完成 B3、B2/C3、P3、B1、P1/C2、C1。目标是让接收循环持续处理控制事件，将取消、保存和播放等待移入有身份、可回收的任务，保证旧任务不能影响新轮。打字与语音共用有界保存队列，保存成功后才回答，重复输入不重存，失败保留正文与恢复入口，结束屏障覆盖已经接纳的尾句。朗读取消必须确认匹配终态并等待旧发送任务退出；归属未知时拒绝新请求。音频保序、缓存有界、终态不提前完成，ACK 超时不重发正文。下一请求使用最新音色与固定版本，变更记录绑定真实会话及回复序号。上下文按完整问答轮裁剪，预算覆盖指令、记忆与当前问题，失败状态和朗读状态分开，原始正文不改写。首条正式用户输入才自动命名，迟到操作不得覆盖人工标题。验收使用可重跑的 fake 行为用例，先证实缺陷再证明修复，核对实际 provider 请求、资源回收与双 target 登记。保留用户数据和其他改动，不改变服务端协议、数据库 schema 或运行态；延期项单列。交付实际命令、日期、结果、未验范围与精确回退方式，全部条件满足后关闭团队目标。

## 团队分工与验收标准

主代理独占 `AssistantSession.swift` 集成、依赖 seam 与两套 target 登记；`tts_lifecycle` 独占 TTS 协调器及其测试；`context_policy` 独占上下文策略及其测试；`input_persistence` 独占保存队列、Store/coordinator 条件命名及相关测试。所有 SwiftPM 验证由主代理串行执行。
收尾阶段冻结团队写入，主代理接手两处测试清理和文档登记；团队最终审查保持只读。

| 单元 | 验收条件 | 状态与本轮证据 |
|---|---|---|
| S1 / B3 | partial 经真实 request receiver 触发取消，terminal 可达；未知远端或旧 outbound 未退出时拒绝新 TTS；旧 effect 不污染新轮 | 通过；`testA03BargeInTerminalThroughReceiveLoop`、`testA04CancelTimeoutFailsClosed`、`testA55ProviderFailureUsesOwnedCancellationBarrier`，以及旧 append/cancel send 在途门禁、关闭被 retry 替代的回归 |
| S2 / B2、C3 | 保存等待时控制事件可达；保存成功后才回答；打字/语音队列有界、保序、去重；结束屏障覆盖全部输入；标题保护 | 通过；真实 receiver 保存 gate、typed/语音顺序与 end 屏障；Queue 10 项；首正式行条件命名与人工标题保护用例 |
| S3 / P3 | FIFO 与在途 PCM 有界且保序；terminal 不提前完成；cancel 回收；ACK 无重发 | 通过；TTS 协调器 30 项及真实 receiver 播放 gate；覆盖累计/协商 cap、终态排空、旧 epoch、ACK 超时不重发 |
| S4 / B1 | 最新音色意图串行写 client；当前 request pins 固定；真实 session/ordinal 记变更 | 通过；`testLatestVoiceBindingWinsWhenOlderSelectionReturnsLate`、`testAcceptedVoiceIsRecordedWhenInterruptedBeforeStartReturns`、`testExplicitVoiceChangeTargetsTheProvidedSessionWithoutActiveOccupancy`，及 Session 音色/pins 回归 |
| S5 / P1、C2 | fake provider 实际请求满足统一预算；完整 turn 裁剪；原文与生成/播放状态分离 | 通过；ContextPolicy 11 项；实际请求的输出预算/当前问题一次、完整历史裁剪/Store 原文保留、失败正文状态与必需内容超限回归 |
| S6 / C1、文档 | 无可执行 helper 引用；相关回归与两套 target 登记通过；文档说明实际边界 | 通过；App/测试 Swift 源码无 `takeSentences` 引用；208 项定向 fake 回归、target 登记检查、pbxproj lint、View 语法检查与文档登记 |

测试仅使用 fake provider、合成 PCM、临时 SQLite 和独立 defaults。每个缺陷记录可编译的行为红及修复后绿；不以旧任务账本、编译失败或退出码替代行为证据。构建、安装、UI 自动化、真实设备、模型、性能和长时验证均未执行。

## 本轮测试记录

### 行为红与中间结果

以下为本任务实测，不引用旧验收账本代替当前证据。红用例均已通过编译；后续编译错误另记，不算行为红。

| 证据 | 本轮实际结果 |
|---|---|
| `speechrail-assistant-followups-red.log` | 真实 request 的 partial 插话回归：1 项、5 个失败；旧预算策略：9 个行为断言失败 |
| `speechrail-assistant-tts-red.log` | 隔离基线中的取消准备、音频接收解耦、单块与协商预算：4 项、8 个失败 |
| `speechrail-assistant-integration-red.log` | 隔离基线加最小保存 seam；保存 gate、首正式标题、B→C 音色、真实 provider 输出预算：4 项、7 个失败。标题用例另有插话缺陷影响，标题为空仍独立证明命名门错误 |
| `speechrail-assistant-ownership-red.log` | 取消未知归属与完整轮续接：3 项、5 个失败 |
| `speechrail-assistant-typed-order-red.log` | 打字保存暂停时，后来的语音提前调用 provider，user 入库次序倒置：1 项、2 个失败 |
| `speechrail-assistant-final-boundary-red.log` | `started` 已到但启动未返回时漏记音色；主动关闭漏收尾；失败前序不释放 keyboard waiter：4 项、8 个失败。另两项累计音频 cap 与 ACK 不重发已通过 |
| `speechrail-assistant-final-focused.log` | 首轮 `--filter Assistant`：187 项 XCTest 中 5 项失败，11 项 Swift Testing 通过。失败为旧提示未清和四个虚构 request ID 夹具；修复后继续回归 |
| `speechrail-assistant-outbound-red-session-green.log` | Session 接收集成 18 项、Session 38 项、Queue 10 项通过；不响应取消的旧 append 尚在途时，取消错误确认且新 begin 被放行：1 项、2 个失败 |
| `speechrail-assistant-final-ownership-check.log` | 关闭被 retry 替代后，旧 intentional 标志抑制新上传并吞掉断连：1 项、2 个失败；真实 receiver 播放 gate 另 1 项及 TTS 30 项通过 |
| `speechrail-assistant-final-green.log` | 197 项 XCTest 中 2 个失败，11 项 Swift Testing 通过；fake 采集重连复用已结束 stream、A09 误以旧回答判断新回答就绪。改为每次 start 新流及按新回答正文等待后再次回归 |

日志位于本机 `/tmp/`，可能被系统清理；上表保留断言与结果，源码测试保留可重跑的行为入口。Queue 一次新测试闭包缺少 `return` 导致编译失败，已修正；该次失败未计入红绿成绩。
cancel send 超时保留 outbound owner 的用例属于补充边界覆盖，没有独立修复前行为红，不伪记为红绿闭环。

本阶段实际执行的命令（仓库根；各次日志输出重定向到 `/tmp/`）：

```bash
swift test --package-path macos/SpeechRailApp --filter AssistantCancelReceiveTests.testTypedAndMicrophoneInputsShareTheirAcceptanceOrder
swift test --package-path macos/SpeechRailApp --filter Assistant
swift test --package-path macos/SpeechRailApp --filter 'AssistantCancelReceiveTests.testAcceptedVoiceIsRecordedWhenInterruptedBeforeStartReturns|AssistantCancelReceiveTests.testClosingVoiceFinalizesPartialReplyBeforeContinuingWithText|AssistantInputPersistenceQueueTests.testPredecessorFailureReleasesLaterKeyboardWaiterAndRetryKeepsOrder|AssistantInputPersistenceQueueTests.testWaitForResultImmediatelyReportsAnExistingFailedPredecessor|AssistantTTSStreamCoordinatorTests.testAggregateAudioCapIncludesChunkAwaitingPlaybackEnqueue|AssistantTTSStreamCoordinatorTests.testAcknowledgementTimeoutDoesNotResendAppend'
swift test --package-path macos/SpeechRailApp --filter 'AssistantCancelReceiveTests|AssistantSessionTests|AssistantInputPersistenceQueueTests|AssistantTTSStreamCoordinatorTests.testCancelCannotConfirmOrRestartWhileCancelledAppendIsInFlight'
```

### 最终回归

在仓库根执行：

```bash
swift test --package-path macos/SpeechRailApp --filter Assistant
uv run python scripts/check_macos_test_target_coverage.py
plutil -lint macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj
swiftc -parse macos/SpeechRailApp/SpeechRailApp/AssistantView.swift
rg -n --glob '*.swift' '\btakeSentences\b' macos/SpeechRailApp/SpeechRailApp macos/SpeechRailApp/SpeechRailMacControlTests
git diff --check
```

- 2026-10-04 22:55:10：`speechrail-assistant-final-green-2.log`，197 项 XCTest、0 failures；11 项 Swift Testing 全通过。
- 补两处 gate 的 `defer` 后，2026-10-04 23:00:51 再验：`speechrail-assistant-final-green-3.log`，197 项 XCTest、0 failures；11 项 Swift Testing 全通过，共 **208 项**。实际发现并执行 Queue 10 项、TTS 协调器 30 项、receiver 集成 20 项；未运行整个 SwiftPM 包的完整测试套件。
- target coverage 与 pbxproj lint 均为 OK；`AssistantView.swift` 语法解析退出 0。源码搜索无 helper 命中（退出 1 是无匹配），不将其写作测试通过。两份收尾文档的相对链接均存在，空白与最终 `git diff --check` 检查通过。

SwiftPM 编译和 fake 回归覆盖其配置的源码集合；`AssistantView` 本轮仅做语法解析与源码检查，未声称完整 App 编译、视觉或设备验证通过。状态细分类仍仅存在于本场内存，旧库记录重开后无法恢复全部生成/播放原因。

## 范围与回退

P2/P4、自动摘要、设备切换续播、长期内存分页延期。本轮不改变服务端协议、数据库 schema 或运行态，不执行提交、推送、创建 PR 或发布；工作区已有提交保持原样。本轮收尾三文件差异保留为未提交改动。

如需回退本轮收尾，只核对并撤回 TTS 测试的两个 `defer` 及两份文档对应差异。若另行授权回退整项实施，以方案基线和 `e6421d5c` 的精确文件 diff 为依据，先恢复 Session 集成与 target 登记，再恢复 Queue、TTS、Context 与 Store/coordinator 单元及对应测试；不整片还原、不修改数据库、不清除用户数据或其他改动。此处只说明回退方式，没有执行回退。
