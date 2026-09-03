---
title: "SpeechRail 安全与可观测性"
status: active
date: 2026-09-03
---

# SpeechRail 安全与可观测性

## 当前安全边界

- 默认仅绑定 `127.0.0.1`。Settings 会拒绝无 API key 的非 loopback host。
- REST 与 `/v1/realtime` 在配置 key 后要求 `Authorization: Bearer <key>`；不要把 key
  放进 query string、命令参数、截图、日志或仓库。
- `allowed_origins` 是配置字段，当前版本未安装 CORS middleware。LAN 访问不在当前能力
  范围；启用前须先实现 CORS、TLS、网段限制和速率限制并更新契约。
- snapshot 必须是仓库外绝对路径，启动时检查完整性；worker 与请求均设离线环境变量。
- REST 上传按 OpenAI 常见音频容器和 MIME/文件名提示做有界接收，调用 `ffmpeg` 固定 argv 解码，不使用 shell；MIME 和文件名不作为内容真实性证明。

## 数据处理与日志

源音频不写入仓库，服务当前不会落盘上传文件。不得记录或提交：API key、Authorization、
Base64、模型绝对路径、原始音频、完整 transcript、TTS 文本、PCM 或完整 prompt。diarization
只允许 session-scoped 匿名 label 和有界匿名状态。故障报告最小字段为时间、服务版本、request ID、
endpoint、错误 code、retryable、耗时、设备/dtype 和资源摘要。

`X-Request-ID` 可由客户端提供或由服务生成。用它关联服务日志与客户端故障，不要用
文件名、用户 ID、文本或音频散列做高基数指标标签。

## 指标与可观测性

`GET /metrics` 提供 Prometheus 文本（默认，`text/plain; version=0.0.4`）与 `Accept:
application/json` 结构化两种视图。指标全部前缀 `speechrail_`，标签严格局限于低基数字典
（`endpoint`、`method`、`status`、`class`、`component`、`voice`、`state`、`event`、
`reason`、`le`），绝不携带 request ID、会话 ID、动态文件名或转写正文。上传端点
`/metrics` 与 `/health` 同属无鉴权系统端点（loopback-first）；非 loopback 暴露前须先完成
CORS、TLS、网段限制与速率限制。`/metrics` 的 `endpoint` 标签对未匹配路由归一为
`<unmatched>`，阻断任意路径集导致的无界基数。

## 容量与隔离

`AdmissionQueue` 限制 REST / commit 后推理的排队量；满载响应为 `429 queue_full` 并带
`Retry-After`。worker 一次只处理一个模型实例，MPS profile 拒绝静默 CPU fallback。运营上
应监控进程存活、readyz、队列满、worker stderr、内存压力与磁盘空间，并可通过 `/metrics`
观测 RTF、TTFA、队列饱和度与 worker 生命周期状态。

以下控制不在当前能力范围，不构成安全声明：CORS、请求级限速、远程持久化指标聚合与
集中式导出、非 loopback 的 TLS/Origin/网段防护。需要这些能力时，先实现、测试并更新
契约与本页。
