---
title: "生成式音色注册：VoiceDesign 参考到 Base 音色"
status: active
audience: "SpeechRail / Sona 维护者与客户端工程师"
version: "1.3"
date: 2026-09-26
---

# 生成式音色注册

## 当前范围

`/v1/voice-designs` 将 VoiceDesign 生成、参考确认、Base 新文本复验和人工听审拆成显式步骤。
候选先保存在私有存储中，只有通过当前 revision 的完整验证并显式
`publish` 后，才 create-only 地创建 `mode=clone` 生产音色；后续正常 TTS 经现有
capability router 路由到 Base。候选不会出现在 `/v1/voices`。

这不是旧音色的原地迁移。已有 `/v1/voices` 仅保存 instruction 的契约、预览接口和
参考上传接口保持独立；MCP 也使用候选、确认、验证、发布四步工具，不后台代替用户确认。

## 流水线与发布时点

```text
描述 + reference_text + seed + 未使用的目标 ID
→ 当前 VoiceDesign capability 检查（当前 catalog 由 reference spec 提供）
  → 确认本地 TTS 与 Batch ASR 已配置，目标 ID 未占用
  → BATCH_TTS reservation：VoiceDesign 生成有界 PCM
  → 完成并关闭流；校验原始信号，再执行一次参考规范化
  → 在原请求 deadline 内释放 TTS 模型槽
  → BATCH_ASR reservation + admission：回转录规范参考（prompt 为空）
  → 规范化文本相似度达标
  → 原子保存私有 WAV、参考报告及来源信息（generated）
  → confirm：固定参考文本与 transcript revision（confirmed）
  → validate：目标 Base 使用不同文本合成、质检、转写和 runtime identity 绑定
  → human review：用户实际听审后写入 identity/naturalness 证据（publishable）
  → publish：锁内复核 revision 后 create-only 注册生产 voice（published）
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

创建成功为 201，返回安全的 `candidate` 元数据，不返回参考文本、私有路径或生产 `voice`。
`candidate.reference.quality` 的 ASR 分数只代表参考自检，合成部分
`probe_count=0`；不得把创建成功显示成“Base 输出质量通过”。

`validate` 必须使用不同于参考文本的测试文本。机器结果只写
`machine_status`；`identity_status` 与 `naturalness_status` 初始为
`not_reviewed`。只有机器通过后才能附加人工听审，机器数值不能填充人工结论。
发布成功为 201，返回已发布 `candidate` 与不可变 `voice`；重复发布同一
candidate 返回 200 且不创建第二个 revision。

ID 冲突为 409 `voice_already_exists`。候选创建支持持久化
`Idempotency-Key`；同一 payload 的重试返回原候选且不重复生成，不同 payload
复用同一 key 返回 409。目标 ID 被其他未终结候选占用时返回
`voice_design_target_in_use`。发布在 registry 提交锁内再次核对 revision，
并发发布最多一个能创建该 ID，另一个不能覆盖先完成的结果。

队列满或 ASR 模式冲突为 429；统一请求超时为 503 `backend_timeout`；
参考不合格为 400 `voice_quality_reject`，确认内容不匹配为 400 `transcript_mismatch`，
畸形或超限输出为 502 `output_invalid`。异常响应不带 vendor 原始正文或路径。
未确认或未通过机器/人工验证时发布返回 409，候选和参考资产保留以供审计。

## 来源记录与 revision 状态

新音色可包含 `creation`，其类型为不可变 `VoiceCreation`：

- 固定 `origin=generated` 与 `method=voice_design_reference_v1`；
- VoiceDesign catalog artifact、不可变 model revision、seed；
- 指令、实际参考文本和最终规范 WAV 的 SHA-256；
- 前处理版本 `energy_v1`。

registry 在写入前核对参考音频及文本 hash。旧记录可缺省 creation，不自动重写；
无效的新 metadata 会让 registry fail-closed。hash 用于可追溯性，不是密码学签名，
也不替代独立说话人向量或声学质量证据。当前 registry 已持久化有界 VoiceRevision 历史，
并提供 revision list、CAS update、rollback、revoke 与 delete；`creation` 仍是来源元数据，
不能单独证明跨文本 speaker similarity。Base 由当前有效能力路由，后端升级时的旧资产
不提供自动迁移或跨模型兼容；模型或生成路径变化后，必须重新注册或按当前路径显式重新验收。

## Sona 对接与回退

保留“描述声音”和“录制/上传参考”两个入口。描述声音使用候选创建、确认、验证和发布；
参考音频仍调用 `/v1/voices/clone`。客户端必须显式展示机器验证和人工听审结果，
不能因为候选创建成功就宣称生产音色已注册。

发布后正式成片仍按当前 output validation 与 production-ready 规则判断；用户不满意时
取消候选、继续使用旧 ID，不需要覆盖旧参考。降级到缺少 Base 的档位时，已发布音色按
现有 capability 规则不可用，不回退到 VoiceDesign 私有 ICL。

## 软件回归与目标机验收

代码回归覆盖：候选生命周期、不同文本约束、机器验证不能代替人工审听、失败不发布、
幂等重试不重复生成/发布、revision 编辑隔离、来源落盘与重载、无绝对路径泄露、
参数与档位拒绝、ASR 缺失/失败/空转写/不匹配、静音/削波/畸形/短/超长输出、
取消、队列拒绝、并发占用目标 ID、持久化失败清理、metadata 篡改拒绝和旧资产不变。

仍需 Apple Silicon 真实 VoiceDesign / Base / ASR 连续测试，包含规范参考试听、
Base 跨文本声纹、数字/单位/标点误识别、冷启动与峰值内存；软件 CI 不能替代这些结果。
