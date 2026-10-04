---
title: "语音助手后续修复实施验收"
status: in_progress
date: 2026-10-04
---

# 实施与验收记录

依据：[Luna 实施方案](2026-10-04-assistant-e2e-followups-luna-guide.md) §5、§7、§8。
基线：`codex/fix-assistant-clone-tts-binding`，`7ae70b0358b6ad45161c6eb5bf056844c9297f0d`。
核验日期：2026-10-04（Asia/Shanghai）；工具链实测 Apple Swift 6.4、arm64 macOS 27。

主代理独占 `AssistantSession.swift` 集成、依赖 seam 与两套 target 登记；`tts_lifecycle` 独占 TTS 协调器及其测试；`context_policy` 独占上下文策略及其测试；`input_persistence` 独占保存队列、Store/coordinator 条件命名及相关测试。所有 SwiftPM 验证由主代理串行执行。

| 单元 | 验收条件 | 状态与本轮证据 |
|---|---|---|
| S1 / B3 | partial 经真实 request receiver 触发取消，terminal 可达；未知远端拒绝新 TTS；旧 effect 不污染新轮 | pending |
| S2 / B2、C3 | 保存等待时控制事件可达；保存成功后才回答；队列有界/保序/去重；结束屏障覆盖全部输入；标题保护 | pending |
| S3 / P3 | FIFO 与在途 PCM 有界且保序；terminal 不提前完成；cancel 回收；ACK 无重发 | pending |
| S4 / B1 | 最新音色意图串行写 client；当前 request pins 固定；真实 session/ordinal 记变更 | pending |
| S5 / P1、C2 | fake provider 实际请求满足统一预算；完整 turn 裁剪；原文与生成/播放状态分离 | pending |
| S6 / C1、文档 | 无可执行 helper 引用；相关回归与两套 target 登记通过；文档说明实际边界 | pending |

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

日志位于本机 `/tmp/`，可能被系统清理；上表保留断言与结果，源码测试保留可重跑的行为入口。Queue 一次新测试闭包缺少 `return` 导致编译失败，已修正；该次失败未计入红绿成绩。

本阶段实际执行的命令（仓库根；各次日志输出重定向到 `/tmp/`）：

```bash
swift test --package-path macos/SpeechRailApp --filter AssistantCancelReceiveTests.testTypedAndMicrophoneInputsShareTheirAcceptanceOrder
swift test --package-path macos/SpeechRailApp --filter Assistant
swift test --package-path macos/SpeechRailApp --filter 'AssistantCancelReceiveTests.testAcceptedVoiceIsRecordedWhenInterruptedBeforeStartReturns|AssistantCancelReceiveTests.testClosingVoiceFinalizesPartialReplyBeforeContinuingWithText|AssistantInputPersistenceQueueTests.testPredecessorFailureReleasesLaterKeyboardWaiterAndRetryKeepsOrder|AssistantInputPersistenceQueueTests.testWaitForResultImmediatelyReportsAnExistingFailedPredecessor|AssistantTTSStreamCoordinatorTests.testAggregateAudioCapIncludesChunkAwaitingPlaybackEnqueue|AssistantTTSStreamCoordinatorTests.testAcknowledgementTimeoutDoesNotResendAppend'
swift test --package-path macos/SpeechRailApp --filter 'AssistantCancelReceiveTests|AssistantSessionTests|AssistantInputPersistenceQueueTests|AssistantTTSStreamCoordinatorTests.testCancelCannotConfirmOrRestartWhileCancelledAppendIsInFlight'
```

### 最终回归

待取消发送屏障收束后登记最终 `--filter Assistant` 结果；中间绿不替代最终验收。

## 范围与回退

P2/P4、自动摘要、设备切换续播、长期内存分页延期。本轮不改变服务端协议、数据库 schema 或运行态，不提交、推送、创建 PR 或发布。保留原有未提交文件。回退只处理本任务精确差异，按依赖先恢复集成再恢复独立单元，保留用户数据及他人改动。
