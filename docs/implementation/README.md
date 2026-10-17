---
title: "SpeechRail 实施与交付记录索引"
status: active
version: "1.0.4"
date: 2026-10-17
---

# 🛠️ 实施与交付记录中心 (Implementation & Delivery)

本目录集中存放各个工程阶段、专项 Issue、功能闭环的具体实施方案、交付记录及自动化走查指南（Luna Guides）。

若需查阅系统顶层架构、API 契约或开发者常态规范，请参阅：
- [架构设计文档](../architecture/README.md)
- [开发者指南](../developers/README.md)
- [公共契约规范](../../contracts/)

---

## 📑 模块导航

### 1. 自动化走查与测试指南 (Luna Guides)
面向自动化回归与人工交互走查的操作指引：
- `2026-10-03-voice-assistant-user-journey-luna-guide.md`：语音助手全旅程走查指南。
- `2026-10-03-teleprompter-user-journey-luna-guide.md`：AI 提词器交互走查指南。
- `2026-10-03-roi-evolution-luna-guide.md`：ROI 演进与模型调度走查指南。
- `2026-10-05-multiscene-asr-luna-guide.md`：多场景 ASR 走查与验证指南。
- `2026-09-27-openai-compat-preview-explicit-save-luna-guide.md`：OpenAI 兼容预览与保存指南。

### 2. 专项 Issue 闭环计划与交付报告
针对具体 Issue 的端到端闭环计划、执行跟踪与交付记录：
- **会议与字幕窗口**：[2026-10-16 实施及验收记录](2026-10-16-meeting-caption-acceptance.md)，区分确定性回归、真实模型回放、UI 阻塞与 no-go 启用门。
- **前五项高 ROI Issue 交接**：[2026-10-17 交接文档](2026-10-17-open-issues-handoff.md)，汇总 #369、#308、#371、#372、#370 的当前证据、接手步骤、运行限制与 #370 的“先 4 人”范围。
- **Issue #370（会议分人质量）**：[整场上下文算法诊断报告](2026-10-17-meeting-diarization-global-context-report.md)，记录全局 VBx/预处理、PLDA、zero-vote 和 CAM++/UMAP-HDBSCAN 对照；模型候选仍未通过 R003 完整门槛，R004 保持封存。
- **Issue #238（闭环与对齐）**：`2026-10-06-issue-238-solid-loop-plan.md`、`2026-10-07-issue-238-final-acceptance.md`、`2026-10-07-issue-238-alignment-audit.md`。
- **Issue #336（ASR 验收）**：`2026-10-07-issue-336-asr-acceptance.md`。
- **语音助手交付**：`2026-10-04-voice-assistant-acceptance-ledger.md`、`2026-10-04-voice-assistant-implementation-report.md`。
- **AI 提词器交付**：`2026-10-05-teleprompter-user-journey-delivery.md`、`2026-09-28-teleprompter-stage-report.md`、`2026-09-28-teleprompter-implementation-plan.md`。
- **会议助手与知识库交付**：`2026-10-04-meeting-knowledge-m0-delivery.md`、`2026-10-03-meeting-knowledge-plan.md`。
- **OpenAI 兼容与提词/助手执行计划**：`2026-09-27-openai-compatibility-plan.md`、`2026-10-03-teleprompter-user-journey-plan.md`、`2026-10-03-voice-assistant-user-journey-plan.md`。
