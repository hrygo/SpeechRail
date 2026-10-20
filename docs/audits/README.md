---
title: "SpeechRail 审计与专项审查记录索引"
status: active
version: "1.5.2"
date: 2026-10-20
---

# 🔍 审计与专项审查记录 (Audits & Reviews)

本目录集中收录针对特定缺陷、时效问题排查、能力调研复盘及架构/算法阶段性审查的专项技术报告。

常态开发规范、系统架构设计与测试流程请参阅：
- [开发者文档](../developers/README.md)
- [架构设计文档](../architecture/README.md)
- [运维文档](../operations/README.md)

---

## 📑 审查与排障记录

- **[2026-10-20 VoxCPM2 调研与投入产出评估](2026-10-20-voxcpm-roi-review.md)**：记录可控克隆的潜在价值、Mac 流式能力缺口与 ROI 假设，结论为放弃本次验证和接入，继续现有 Qwen3-TTS 路线。

- **[2026-10-20 有声书业务流程与用户体验审查](2026-10-20-audiobook-business-ux-review.md)**：从导入、分析、配声、制作、听书、导出到废纸篓逐段核对“下一步是否可见、失败是否后置、恢复是否就近”，落地导出门禁前置与内联错误、听书空态与跳过一致性、废纸篓即时撤销、TXT/EPUB 拖放导入；含残留的资产级预检与角色卡选择语义。

- **[2026-10-19 有声书工坊全流程优化审计与实施记录](2026-10-19-audiobook-full-workflow-optimization.md)**：从用户旅程、体验、功能完备度与算法四个层面审计工坊，落地目录页识别与排除、编码歧义可核对预览、收听实时时间码与自动书签、换声影响确认、分析窗口/制作候选查找优化与失效计算防崩溃；含未实施缺口与回退方式。

- **[2026-10-17 VoiceStudio 代码级能力复核与吸收候选](2026-10-17-voicestudio-capability-reaudit.md)**：对本地竞品 VoiceStudio（HEAD `f47221a1`）做实现级核对，覆盖响度预设与失败语义、发音词典（含空值删除词与 CJK 边界）、起点吸附对齐、音频质量自检、分块合成与 OpenAI 兼容面；给出 V1–V5 吸收候选与"明确不吸收"边界，并更正此前把 `-1.5 dBTP` 记为 ACX 预设的口径错误（该值来自 podcast 预设）。

- **[2026-10-17 SpeechRail 对 ElevenLabs 的分阶段吸收方案](2026-10-17-speechrail-elevenlabs-absorption-plan.md)**：把 ElevenLabs（云端商用参照）的产品/开发者设计语义转译为本地可行候选（E1–E7），含分阶段方案、定性 ROI、依赖、风险、验收条件与明确不做项（不引入云 API/计费/发行/商业条款）。
- **[2026-10-17 SpeechRail 与 VoiceStudio、ElevenLabs 竞品能力调研与设计吸收建议](2026-10-17-speechrail-voicestudio-competitive-research.md)**：三方对照（v1.3.0 纳入 ElevenLabs 与 E1–E7 矩阵）；含 VoiceStudio 两轮证据校正（响度/封面/分块/隐私同意、manifest schema 与 verifier 依赖、阶段顺序与验收门槛），并按网页版/PDF 来源范围修订 ACX 封面规格（含 ≤8 MB）。仅改方案，不动产品代码。
- **[2026-10-16 合并后音频与转录链路回归审查](2026-10-16-post-merge-regression-review.md)**：rebase 前后修复核对、音频预取消、会议收尾保存、字幕正文保留和动态分人认证人数边界。
- **[2026-10-16 App 性能优化实施与验收记录](2026-10-16-app-performance-acceptance.md)**：跨模块确定性回归、资源容量、取消回收与真实 CPU/交互待测矩阵。
- **[2026-10-15 有声书工坊流程、算法与用户旅程审查记录](2026-10-15-audiobook-workshop-review.md)**：覆盖 TXT 导入、章节规划、全书分析、角色确认、章节制作、返修恢复、收听和导出的模块审查与缺陷复盘。
- **[2026-10-05 流式 TTS 结束边界与异常尾音排查记录](2026-10-05-tts-stream-eos-review.md)**：针对生成结束时偶发尾音/打嗝样声音的 codec EOS 边界排查与修复依据。
- **[2026-10-01 音频稳定性与生命周期边界审计](2026-10-01-audio-stability.md)**：围绕音频采集通道、淡出机制与生命周期边界的确定性验证报告。
- **[2026-09-21 VoiceDesign 与 Base 能力及使用方式调研报告](2026-09-21-voice-design-base-practice-review.md)**：VoiceDesign + Base 参考声音创造与克隆机制的官方实现对标与预热排障复盘。
