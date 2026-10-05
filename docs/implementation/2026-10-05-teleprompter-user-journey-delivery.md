---
title: "提词器用户旅程 E1-E8 交付说明"
status: active
version: "1.0.0"
date: 2026-10-05
base: "d72535c7"
---

# 提词器用户旅程 E1-E8 交付说明

执行方案：[2026-10-03-teleprompter-user-journey-luna-guide.md](2026-10-03-teleprompter-user-journey-luna-guide.md) §3 / §5 / §8；原始方案：[SpeechRail_Teleprompter_User_Journey_Executable_Plan_2026-10-03.md](SpeechRail_Teleprompter_User_Journey_Executable_Plan_2026-10-03.md)。
方向：返璞归真，界面简单可靠；每阶段只有一个主要动作，高级操作渐进披露。

## 基线

- 基线 `d72535c7`，分支 `main`，与 `origin/main` 同步。
- 本次 16 个文件、1387+/145-，全部未提交（仓库规则：无明确授权不自动提交）。
- `git diff --check` 通过。

## 改动

- E1 草稿所有权：`TeleprompterSession.updateQuickDraft` + `flushPendingDraftSave() throws` + `draftSaveState`；View 绑定 Session 记忆。
- E2 稳定前缀：`stable - dropped` 换算到保留坐标 + `lastStableAlignedScalarCount`。
- E3 同位确认：`lastPreviewedPosition` 回写；空 final 有假设时保位 + `uncertainty=1` + `.catchingUp`；adapter `.confirmed`/`.unconfirmed`；回放 `teleprompter.eval.v2`。
- E4 接管：`staleEmptyFinalAfterTakeoverIsIgnored`，旧空 final 不能推动新位置。
- E5 默认手动开台：原稿主动作打开提词器（唯一 Cmd+Return），AI 整理为次动作；prepared 主动作用这份稿；prepare/annotate 用途隔离。
- E6 段落编辑：按块连续编辑，保留 ID/区间/用途；有界撤销快照 20 份；全跳过以 `noReadableBlocks` 拒绝采用；`preparedBlockEditorMinHeight=144`。
- E7 失败与状态：生成失败按证据分类；试读已证据分离；舞台按键统一 `acceptsReadingKeyCommands`；§6.4 文案对齐。
- E8 关闭继续与测量：`saveProgress` 持久化 `viewportAnchor`；数字冲突对永不等价；回放分母与告警口径保留；时延仍为客户端接收到决策。
- 文档同步：`macos-app-teleprompter.md` v0.7.1、`macos-app-design-system.md` v0.11.1、`teleprompter-benchmark-script.md` v0.4.1（2026-10-05）。

## 验证（2026-10-05 本轮实测）

- `swift test --package-path macos/SpeechRailApp`：419 tests / 17 suites passed（2026-10-05 15:20 CST 本轮重跑）。
- `scripts/macos_app_build.sh --configuration Debug`：BUILD SUCCEEDED（本轮早前实测）。
- `git diff --check` 通过（2026-10-05 15:20 CST 本轮重跑）。
- 敏感扫描：`git diff HEAD` 仅命中测试中断言“不得回显上游正文”的 `secret-body` 用例本身，无真实凭据、令牌或密钥落盘。
- `teleprompter-replay --help` 可用，输出含 `teleprompter.replay.v1` 输入与 `teleprompter.eval.v2` 输出口径；实际回放缺授权素材记 `not_run`。
- 关键验收用例已在源码中核对：`quickDraftSurvivesSessionReload` / `failedFlushPreservesCurrentDocument`（E1 内容验收）、`staleEmptyFinalAfterTakeoverIsIgnored` / `manualOpeningWithoutAITouchesNothingButTheDeterministicVersion`（E4/E5 控制验收）、`conflictingNumeralsAreNeverEquivalent` / `emptyFinalAfterPreviewIsCountedAsUnconfirmedNotSuccess` / `outOfRangeStablePrefixIsCountedAsContractAnomaly`（E8 阅读质量验收）。

## 未推进

- 前台 UI 走查、VoiceOver、Reduce Motion 实测、真人音频验收、提交/推送/PR/发布均暂不执行，按逐次授权另行安排。
- 性能基线未立，不做性能测试（E9 无瓶颈证据，不展开优化）。
- E9 条件增强记 `deferred`：无 E8 瓶颈证据、无成对真人样本、无后续产品范围确认；TP-13/TP-14/TP-15 均 deferred。

## 回退

- 无持久化升级（`formatVersion=3` 不变）；回退本任务代码即可，保留稿件与位置。
- 未提交时仅手工撤回对应 hunk，保留并行改动；不 `reset --hard`，不整文件覆盖。

## 风险

- View / StageView 不在 SwiftPM 测试目标内：逻辑由定向回归覆盖，编译由包装构建覆盖；几何、焦点、VoiceOver、Reduce Motion 未实测，单测通过不代表视觉通过。
- 无真人音频与端到端显示时延证据：逻辑回归结论不写成真人跟读质量已通过。
- 性能未立基线未测量：E9 无优化依据，不展开优化。
- 改动未提交：提交时按逻辑主题拆分，先查暂存 diff / `git diff --staged --check` / 敏感信息，只提交本任务文件；推送与发布另行授权。
