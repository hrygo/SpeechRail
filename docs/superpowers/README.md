# Superpowers 过程目录

本目录保存近期设计规格与实施计划。公共协议以 [Realtime ASR/TTS 契约](../../contracts/realtime-openai.md)为准，
无状态 Speech Plane 的决策背景见 [ADR-0019](../decisions/0019-stateless-speech-plane-caller-orchestration.md)；
旧的 preset / 四档体系（含 `extreme`）已由 [Issue #95 目标架构](plans/2026-09-25-issue-95-asr-tts-target-architecture-luna-guide.md)
移除，档位只选择 ASR / TTS 两项独立 spec（`fast` / `quality` / `reference`）。标记为
`superseded` 的旧方案只用于历史追溯，不得作为当前契约、兼容策略或实施入口。

## 设计规格

- [SpeechRail App 性能与资源治理设计](specs/2026-10-16-app-performance-design.md)（`active`；代码与确定性集成完成，实际性能与交互待验收）
- [会议分人前处理质量实验](specs/2026-10-17-meeting-diarization-preprocessing-experiment.md)（`active`；基于 AISHELL-4 开发集验证分段密度和短段嵌入）
- [会议分人模型家族对照](specs/2026-10-17-meeting-diarization-model-family-experiment.md)（`active`；在隔离 R003 开发集评估 3D-Speaker CAM++ 管线）
- [macOS 26 App 最佳实践整改](specs/2026-09-13-macos26-app-best-practices-remediation-design.md)（`approved`）
- [OpenAI Realtime 交接设计](../archive/superpowers/specs/2026-09-02-openai-realtime-handover-design.md)（`superseded`）
- [资源优化设计](specs/2026-09-02-resource-optimization-design.md)
- [TTS 分段边界稳定性设计](specs/2026-09-05-tts-segment-boundary-stability-design.md)
- [GitHub Actions 现代化设计](specs/2026-09-06-github-actions-modernization-design.md)
- [服务运维效率设计](specs/2026-09-07-service-operator-efficiency-design.md)
- [讲话人分离整洁架构](specs/2026-09-08-diarization-clean-architecture-design.md)（`accepted`；Realtime wire 以 Realtime ASR/TTS 契约为准）
- [讲话人分离 D1 选择证据](specs/2026-09-08-diarization-d1-selection-evidence.md)
- [Clone frozen-gain 边界修复候选](specs/2026-09-12-clone-loudness-boundaries.md)（`draft`）
- [无状态 Speech Plane 与调用方编排设计](specs/2026-09-20-stateless-speech-plane-caller-orchestration-design.md)（`approved`）
- [macOS App 音色 revision 一致性与文档一致性收敛](specs/2026-09-20-macos-app-voice-revision-consistency-design.md)（`approved`）
- [Extreme BF16 第四档设计](specs/2026-09-23-extreme-tier-bf16-design.md)（`superseded`；preset/四档体系已被目标架构移除，仅历史追溯）

## 实施计划

- [会议助手模块端到端体验优化：竞品调研、用户旅途、UI 盘点与落地验收方案](plans/2026-10-17-meeting-assistant-ux-ui-redesign.md)（`completed`；四竞品调研、七阶段用户旅途、全量 UI 盘点与会前/会中/会后 UX 落地及 144 项单测验收通过）
- [语音助手、会议助手与 AI 提词器 UI 文案与无障碍体系化优化方案](plans/2026-10-17-assistant-meeting-teleprompter-ui-copy-redesign.md)（`completed`；三模块全量按钮/标签/状态/无障碍文案清单与 AC 核验通过）
- [AI 提词器模块体验优化：调研、方案与落地验收记录](plans/2026-10-17-teleprompter-ux-ui-redesign.md)（`completed`；修复就绪态回改死锁、口述字符稿连续文档流减负、按 ID 复制回退、场景预设坞与舞台键盘焦点守卫）
- [有声书制作模块 UX/UI 现代化重构方案](plans/2026-10-16-audiobook-ux-ui-redesign.md)（`completed`；流线型工作台减负）
- [SpeechRail App 性能治理实施计划](plans/2026-10-16-app-performance-implementation-plan.md)（A 层完成；覆盖 App、采集与播放，B/C 层及服务侧条件排查见待办）
- [会议分人前处理质量实验计划](plans/2026-10-17-meeting-diarization-preprocessing-experiment-plan.md)（开发集 screen 与候选细化；不触碰留出集或生产默认）
- [会议分人模型家族对照计划](plans/2026-10-17-meeting-diarization-model-family-experiment-plan.md)（隔离 R003 模型评估；不接入生产默认）
- [会议分人第一阶段（1–4 人 Sortformer 与联合 SA-ASR）计划](plans/2026-10-17-meeting-diarization-sortformer-1to4-plan.md)（`active`；1–4 人语料锁、分层与 CER/DER/cpWER/tcpWER 联合评测工具已就绪，待外部语料目录授权后实测）
- [Wheel 本地安装器计划](plans/2026-09-01-wheel-local-installer.md)
- [OpenAI Realtime 交接计划](plans/2026-09-02-openai-realtime-handover.md)（`superseded`）
- [资源优化计划](plans/2026-09-02-resource-optimization.md)
- [说话人分离 E2E 计划](plans/2026-09-05-speaker-diarization-e2e.md)
- [TTS 分段边界稳定性计划](plans/2026-09-05-tts-segment-boundary-stability.md)
- [卡通头像计划](plans/2026-09-06-cartoon-avatar.md)
- [SpeechRail 生命周期优化计划](plans/2026-09-06-speechrail-lifecycle-optimization.md)
- [SpeechRail 静音转写准入计划](plans/2026-09-06-speechrail-silence-transcription-admission.md)
- [服务运维效率计划](plans/2026-09-07-service-operator-efficiency.md)
- [Clone TTS 响度稳定性计划](plans/2026-09-08-clone-tts-loudness-stability.md)
- [Clone TTS 审查修复计划](plans/2026-09-08-clone-tts-review-fixes.md)
- [讲话人分离验收矩阵](plans/2026-09-08-diarization-acceptance-matrix.md)
- [讲话人分离 OpenAI 实施方案](plans/2026-09-08-diarization-openai-implementation.md)（`superseded`；领域历史）
- [讲话人分离验证卡](plans/2026-09-08-diarization-validation-cards.md)
- [单机语音基座计划](plans/2026-09-08-single-machine-speech-foundation.md)
- [v1.13.0 高 ROI 优化计划](plans/2026-09-09-full-stack-memory-evidence.md)
- [v1.13.0 高 ROI 优化计划](plans/2026-09-08-v1.13.0-high-roi-optimization.md)
- [三档用户定位重排与按档位精度策略](plans/2026-09-11-tier-user-repositioning-and-precision-policy.md)
- [无状态 Speech Plane 与调用方编排实施计划](plans/2026-09-20-stateless-speech-plane-caller-orchestration.md)（`ready`）
- [macOS App 音色 revision 一致性与文档一致性收敛](plans/2026-09-20-macos-app-voice-revision-consistency.md)（`completed`）
- [Extreme BF16 候选档实施计划](plans/2026-09-23-extreme-tier-bf16.md)（`superseded`；preset/四档体系已被目标架构移除，仅历史追溯）
- [Issue #95 ASR/TTS 目标架构与验收指导](plans/2026-09-25-issue-95-asr-tts-target-architecture-luna-guide.md)（`active`；本轮实施与验收）
- [macOS App 契约对齐旧计划](plans/2026-09-20-macos-app-contract-alignment-plan.md)（`superseded`；已被无状态 Speech Plane 方案取代）

## 当前正式架构文档

讲话人分离的正式架构设计已同步至 [docs/architecture/](../architecture/README.md)。
