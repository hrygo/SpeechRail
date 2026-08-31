---
title: "SpeechRail 安全与可观测性"
status: active
date: 2026-08-31
---

# SpeechRail 安全与可观测性

## 当前安全边界

- 默认仅绑定 `127.0.0.1`。Settings 会拒绝无 API key 的非 loopback host。
- REST 与 `/v1/realtime` 在配置 key 后要求 `Authorization: Bearer <key>`；不要把 key
  放进 query string、命令参数、截图、日志或仓库。
- `/asr` 当前没有认证实现，且不转写；只能保留在 loopback 开发环境，不能对 LAN / 公网开放。
- `allowed_origins` 是配置字段，但 `0.1.0` 未安装 CORS middleware。LAN 访问不是首发
  支持场景；如需暴露，先补齐 CORS、TLS、网段限制、速率限制和 `/asr` 认证。
- snapshot 必须是仓库外绝对路径，启动时检查完整性；worker 与请求均设离线环境变量。
- REST 上传仅接受 `audio/*`，以内存有界读取，调用 `ffmpeg` 固定 argv 解码，不使用 shell。

## 数据处理与日志

源音频不写入仓库，服务当前不会落盘上传文件。不得记录或提交：API key、Authorization、
Base64、模型绝对路径、原始音频、完整 transcript 或完整 prompt。故障报告最小字段为
时间、服务版本、request ID、endpoint、错误 code、retryable、耗时、设备/dtype 和资源摘要。

`X-Request-ID` 可由客户端提供或由服务生成。用它关联服务日志与客户端故障，不要用
文件名、用户 ID、文本或音频散列做高基数指标标签。

## 容量与隔离

`AdmissionQueue` 限制 REST / commit 后推理的排队量；满载响应为 `429 queue_full` 并带
`Retry-After`。worker 一次只处理一个模型实例，MPS profile 拒绝静默 CPU fallback。运营上
应监控进程存活、readyz、队列满、worker stderr、内存压力与磁盘空间。

以下控制尚未在当前代码中完整实现，不能作为安全声明：CORS、请求级限速、持久化指标导出、
解码后 `max_audio_seconds` 拒绝、legacy WebSocket 认证、实时优先级调度。需要这些能力时
先实现、测试并更新契约/本页。
