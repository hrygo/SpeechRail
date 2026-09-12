---
title: "生成式音色注册：VoiceDesign 参考到 Base 音色"
status: active
audience: "SpeechRail / Sona 维护者与客户端工程师"
version: "1.0"
date: 2026-09-12
---

# 生成式音色注册

## 当前范围

`POST /v1/voices/designs` 为 Quality 档提供显式、create-only 的生成参考注册。
它根据新的描述生成参考，将合格参考保存为 `mode=clone` 的新音色，后续正常 TTS
经现有 capability router 路由到 Base。注册请求本身不执行 Base 合成，也没有独立声纹
验收，响应因此固定包含 `synthesis_validation: unevaluated`。

这不是旧音色的原地迁移。已有 `/v1/voices` 仅保存 instruction 的契约、预览接口、
参考上传接口及 MCP 旧工具均不改变；客户端必须显式选择新入口，不得静默降级。

## 流水线与发布时点

```text
描述 + reference_text + seed + 未使用的目标 ID
  → Quality VoiceDesign / Base catalog capability 检查
  → 确认本地 TTS 与 Batch ASR 已配置，目标 ID 未占用
  → BATCH_TTS reservation：VoiceDesign 生成有界 PCM
  → 完成并关闭流；校验原始信号，再执行一次参考规范化
  → 在原请求 deadline 内释放 TTS 模型槽
  → BATCH_ASR reservation + admission：回转录规范参考（prompt 为空）
  → 规范化文本相似度达标
  → 原子 create-only 保存规范 WAV、参考报告及来源信息
  → 新 voice ID 供 Base TTS 使用；单独执行 quality-runs 验收输出
```

候选参考仅在内存中保留。生成或 ASR 未完成时，不创建临时可见 voice、不写参考文件，
避免错误、取消、超时或 ASR 缺失后留下看似成功的资产。保存时复用 VoiceRegistry 的
私有文件权限、不可变音频路径、原子 metadata 提交与失败清理。

先对原始生成信号做门禁，再规范化，防止增益衰减掩盖原始削波。ASR 针对规范参考，
保存的 ref_text 是传入 TTS 的规范化文本；不会把 ASR 输出当成可以任意替换的正确文本，
也不会把期望文本作为 ASR prompt 来影响验证结果。

## 契约与限制

请求为 JSON：`id`、`name`、`instruction`、`reference_text` 必填；`seed` 默认 42，
`language` 当前仅接受 `zh`。`id` 限 1–64 个小写字母、数字、下划线或连字符，
且不能使用内置音色或 alias。参考文本限 20–240 字符，生成音频限 2–30 秒。
不接收音频 URL、客户端参考音频、变速参数或任意额外字段。

相似度阈值暂时复用实验值 0.92；不足则不发布音色。缺少 ASR 在合成前返回
503 `transcription_unavailable`，运行时 ASR 失败也返回 503，而不是发布未核验参考。
该阈值、中文覆盖和参考能量/噪声指标均需真实模型校准；ASR 可能误识别或幻觉，
通过门禁不是任意噪声拒绝、专业韵律或跨文本身份稳定性的证明。

成功为 201，返回 `voice` 与 `synthesis_validation=unevaluated`。
`voice.quality` 的参考部分有 ASR 分数，合成部分 `probe_count=0`、`deterministic=false`。
不得将该参考报告的 pass/warn 显示成“Base 输出质量通过”。

ID 冲突为 409 `voice_already_exists`。目标 ID 检查会在 registry 提交锁内再次执行，
所以两个并发请求最多一个能创建该 ID；另一个不能覆盖先完成的结果。
没有声称提供持久化 Idempotency-Key：网络重试使用相同目标 ID，出现 409 后通过
`/v1/voices` 核实已有资产，或由用户选择另一个新 ID。

队列满或 ASR 模式冲突为 429；统一请求超时为 503 `backend_timeout`；
参考不合格为 400 `voice_quality_reject`，内容不匹配为 400 `transcript_mismatch`，
畸形或超限输出为 502 `output_invalid`。异常响应不带 vendor 原始正文或路径。

## 来源信息不是完整 revision 系统

新音色可包含 `creation`，其类型为不可变 `VoiceCreation`：

- 固定 `origin=generated` 与 `method=voice_design_reference_v1`；
- VoiceDesign catalog artifact、不可变 model revision、seed；
- 指令、实际参考文本和最终规范 WAV 的 SHA-256；
- 前处理版本 `energy_v1`。

registry 在写入前核对参考音频及文本 hash。旧记录可缺省 creation，不自动重写；
无效的新 metadata 会让 registry fail-closed。hash 用于可追溯性，不是密码学签名，
也不替代独立说话人向量或完整多版本历史。Base 仍按 Quality catalog 路由，
后端升级时的音色迁移与模型兼容策略需要另行显式验收。

## Sona 对接与回退

保留“描述声音”和“录制/上传参考”两个入口。描述声音新增“生成并注册 Base 音色”动作，
请求本接口；参考音频仍调用 `/v1/voices/clone`。本轮没有修改 Sona UI，不能宣称客户端
已经自动调用新接口。旧提示词流程仍可保留供兼容，但不要把旧流程响应标记为已固化。

注册后应提示“参考已核验，输出待验证”，允许实际试听并执行 quality-runs。
不满意时删除新 ID、继续使用旧 ID，不需要回滚或覆盖旧参考。降级到缺少 Base 的档位时，
新音色应按现有 capability 规则不可用，不回退到 VoiceDesign 私有 ICL。

## 软件回归与目标机验收

代码回归覆盖：201 + Base binding、来源落盘与重载、无绝对路径泄露、参数与档位拒绝、
ASR 缺失/失败/空转写/不匹配、静音/削波/畸形/短/超长输出、取消关闭、eviction deadline、
队列拒绝、并发占用目标 ID、持久化失败清理、metadata 篡改拒绝和旧资产不变。

仍需 Apple Silicon 真实 VoiceDesign / Base / ASR 连续测试，包含规范参考试听、
Base 跨文本声纹、数字/单位/标点误识别、冷启动与峰值内存；软件 CI 不能替代这些结果。
