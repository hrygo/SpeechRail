---
title: "音色验证失败与证据保存"
status: active
audience: "API 消费者"
version: "3.8.0"
date: 2026-10-07
---

# 音色验证失败与证据保存

音色 quality-runs 返回计算报告时，请同时检查 `validation_persisted`。
`false` 表示本次输出证据未保存，不能据此判断该音色已经可用于生产。
运行中音色 revision 改变或被撤销时，旧快照的结果同样不能覆盖当前证据。

候选生成、候选机器验证和 quality-runs 如果不能确认 TTS 流已关闭或驱逐正常完成，会停止后续阶段。
关闭失败返回 `503 backend_reclamation_failed`，`retryable=false`；受影响的 lane
保持隔离，须恢复 runtime 后再验证。驱逐超时仍返回 `503 backend_timeout`，
但超时本身不证明资源已回收。错误响应不包含音频或 backend 原始异常文本。

候选自动验证不能代替人工听审。实际执行身份未知时保持 unknown，不能拼入后续 worker
的身份；机器生成的结果不会填写人工 identity/naturalness 审核结论。
详见 [生成式注册](../architecture/generated-voice-registration.md)、
[执行与清理边界](../architecture/voice-validation-usecases.md) 和
[公共 API 手册](api-contract.md)。
