---
title: "语音助手用户旅程最终实施报告（VA-01～VA-18 / A01～A60）"
status: draft_uncommitted
version: "0.1.0"
date: 2026-10-04
---

# 语音助手用户旅程最终实施报告

- 需求依据：[SpeechRail 语音助手：按用户旅程优化的详细可执行方案](SpeechRail_Voice_Assistant_User_Journey_Executable_Plan_2026-10-03.md)
- 执行方案：[语音助手用户旅程优化：Luna 详细执行方案](2026-10-03-voice-assistant-user-journey-luna-guide.md)
- 过程账本：[语音助手用户旅程验收账本](2026-10-04-voice-assistant-acceptance-ledger.md)（D 明细与变异验证以账本为准，本报告只汇总结论）
- base `71fc9231`；HEAD `71fc92319b7ea46354d28ad8b6fbc46a1c38b4bd`（基线即 HEAD，无基线后提交）；分支 `codex/voice-assistant-journey-va`；日期 2026-10-04 Asia/Shanghai
- 交付形态：未提交 diff（无 commit hash）；无 push/PR/merge/release；无服务启停、模型下载、录音与 UI 自动化。
- 口径：D 结论来自确定性测试；U/R 未授权执行一律 `not_run`，不得用 D 代替。`done（D）` ≠ 真实质量证明。

## 18 包状态

| 包 | 状态 | 包 | 状态 |
|---|---|---|---|
| VA-17a 工装与账本 | done（D） | VA-10 模态提示 | done（D 部分；R not_run） |
| VA-01 结束隔离 | done（D） | VA-11 分包保真 | done（D 部分；R not_run） |
| VA-02 取消接收解耦 | done（D） | VA-12 播放交付 | done（D 部分；R/U not_run） |
| VA-03 排空封存 | done（D） | VA-13 接话策略 | done（D 必修；R not_run，聚合/duck 关闭） |
| VA-04 回复幂等 | done（D） | VA-14 上下文记忆 | done（D 部分；R not_run） |
| VA-05 身份过滤 | done（D 部分；R not_run） | VA-15 记录闭环 | done（D 部分；schema v2 deferred） |
| VA-06 路由冻结 | done（D 部分；U not_run） | VA-16 观测 | done（D） |
| VA-07 文字可用 | done（D 部分；U not_run） | VA-17b 完整资产 | done（D+资产；A59/A60 R not_run） |
| VA-08 可信首屏 | done（D；U not_run） | VA-18 交付门禁 | partial（见下） |
| VA-09 草稿阅读 | done（D；A31/A32 U not_run） | | |

VA-18 未闭环项：Xcode membership 未补（6 个新生产文件 + 新增测试文件 + `AssistantReplayTool` runner 仅进 SPM，pbxproj 0 命中；须 Xcode 内操作，不手工改）；安装/性能对照未做；U/R 真机未执行。

## A01～A60 结论

- D：A01～A30（除纯 U 的 A31/A32）、A33～A55 有确定性用例，`--filter 'Assistant'` 162 项通过（含新增 A43 true 分支 + A13 unknown 终态 + A35 代码块跨片 + A50 seed 超限 + A47 活跃保护）；`swift package clean` 后全包 `Executed 611 tests` 通过（旧摘要行 384/16 suites 为缓存口径）；`git diff --check` 通过。
- U：A01/A02/A16～A19/A21/A24～A32/A42/A43/A46/A47/A49/A51 全部 `not_run`（清单已落盘 `2026-10-03-voice-assistant-ui-acceptance.md` v0.1.0）。
- R：A33/A34/A38/A40/A52/A56～A60 全部 `not_run`（入口已落盘 `2026-10-03-voice-assistant-real-acceptance.md` v0.1.0；`assistant-replay` 合成冒烟通过，真实素材未跑）。
- §7.3 交叉变体：A03/A04（prefetch/旧终态/新 start）3 项、A12（并发/顺序）2 项、A40/A52（ledger）2 项、A35/A39（服务端小限额）1 项、A47/A50（future-schema）1 项，均变异验证有效；其余变体记限制（见账本）。

## 三方一致与迁移

- Store/内存/history：A09～A12/A41/A50 用例分别检查三方，不靠完成时间 append；保存失败正文仍可见且标未保存，重试不重调模型。
- schema：`SessionStore.schemaVersion` 仍为 1，无真实数据操作；A50 续接用内存种子实现（删父后子种子仍可用），schema v2 deferred；future 版本 open 拒绝已回归。

## 设备/网络/保存与误停

- 设备停止：`stopPlayback` 可等待；`AudioEngineSession.stop()` 硬件 teardown 异步，返回不证明释放完成（A52/A60 真机未验）。
- 网络 receipt：服务累计接受样本数证明处理水位，不证明应用落库；应用保存屏障为 marker 前保存 settled 聚合（receipt/marker 独立时序无 Fake 可排，记限制）。
- 无跨会话误停：A01/A02/A18 断言会议 occupancy/phase/record/stopper 逐项不变；旧结束任务不结束新 lease。

## 模型/声学/性能对照

- 未执行：无 baseline/candidate 对照，无样本一律 N/A；UI 回执/停止/归约候选门槛未测；聚合/duck/VAD 保持 `deferred_evidence` 关闭。

## policy/构建/安装与并行改动

- 未开启：turn aggregation、提前 duck、TTS-only 独立通道、ASR-only/按住说话（条件增强，见执行方案 §4.2/§9）。
- 构建：SPM 全包通过；Xcode membership 未补，`xcodebuild` 未跑；安装/LaunchServices 未验证。
- 并行改动：同一文件只由本任务写入；`AssistantSession.swift` 为主要冲突文件，保持串行 owner；未发现需保留的并行修改。

## 未验证风险与所需条件

- Xcode 内补成员后复验（用户在 Xcode 内操作）。
- U 人工走查、R 真机/长时/性能对照、安装验证（逐次明确授权）。
- schema v2（如需）、提交/推送/PR/发布（明确授权；拟按 VA 包拆原子单元）。

## 回退

- 源码：只作用本任务改动，先 `git status --short` 确认唯一写入文件，按 VA 包逐个 revert；本轮未改变运行态，无需回滚服务/档位/安装/模型。
