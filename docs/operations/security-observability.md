---
title: "SpeechRail 安全与可观测性"
status: active
version: "3.1.4"
date: 2026-09-25
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

HTTP access 记录在响应完成或异常退出时各写一条，字段固定为 `timestamp`、`request_id`、
模板化 `route`、`status`、`outcome`、`duration_ms`、`error_code`、`tts_warm` 和低基数
`worker_state`。`outcome` 只允许 `completed`、`error`、`cancelled`、`disconnected`；记录
不会复制请求体、响应体、Authorization 或自定义 voice 值。流式响应在已发送响应头后失败时，
记录已发送的 HTTP status 与失败 outcome，客户端不会收到第二个 JSON 错误响应。

这些记录由服务自身的 logging handler 落盘，而不是依赖 LaunchAgent 的 stdout/stderr 重定向
（后者只保留无法进入日志的崩溃输出、无时间戳且不轮转）：

| 路径 | 内容 | 轮转 |
|---|---|---|
| `~/Library/Logs/SpeechRail/speechrail.log` | 服务与 vendor 日志；结构化字段以 `key=value` 追加，可直接人读 | 8 MiB × 5 份 |
| `~/Library/Logs/SpeechRail/access.jsonl` | 每个结构化记录一行 JSON，字段与上表一致 | 8 MiB × 5 份 |

目录为 `0700`、文件为 `0600`；`SPEECHRAIL_LOG_DIR` 可改位置。uvicorn 自带的 access 行被关闭，
避免与 `http_access` 重复；日志目录不可写时退回控制台输出，不影响服务。

## 指标与可观测性

`GET /metrics` 提供 Prometheus 文本（默认，`text/plain; version=0.0.4`）与 `Accept:
application/json` 结构化两种视图。指标全部前缀 `speechrail_`，标签严格局限于低基数字典
（`endpoint`、`method`、`status`、`class`、`component`、`voice_class`、`state`、`event`、
`reason`、`le`），绝不携带 request ID、会话 ID、动态文件名或转写正文。上传端点
`/metrics` 与 `/health` 同属无鉴权系统端点（loopback-first）；非 loopback 暴露前须先完成
CORS、TLS、网段限制与速率限制。`/metrics` 的 `endpoint` 标签对未匹配路由归一为
`<unmatched>`，阻断任意路径集导致的无界基数。

`/metrics` 是进程内累计值，重启归零，单次 scrape 只能回答「现在」。服务另外每
`SPEECHRAIL_METRICS_ROLLUP_INTERVAL_SECONDS`（默认 60 秒）向
`{app_home}/state/metrics-rollup/YYYY-MM-DD.jsonl` 追加一行区间摘要：单调计数器增量、
按直方图桶插值的时延分位、区间内并发峰值、排队拒绝与 worker 驱逐、观测到的
physical footprint、worker 状态与 ready 标志。它只包含上面已经允许的低基数字段，是同一套
事实的时间序列，不是第二份监控系统。按天分文件、默认保留 30 天
（`SPEECHRAIL_METRICS_ROLLUP_RETENTION_DAYS`），只对受管安装启用
（`SPEECHRAIL_METRICS_ROLLUP_DIR` 可指定或关闭），写入失败只记一条 warning，不影响请求路径。

### Realtime 首个可见 hypothesis

`speechrail_realtime_first_hypothesis_total{outcome}` 每个输入 item 最多记录一次。
`outcome=partial` 表示首个成功写入 WebSocket 发送缓冲的 hypothesis；`missing` 表示没有
partial、直接进入 final（不是 0 ms）；`failed`、`cancelled`、`send_failed` 分别表示失败、
取消和发送未完成。`speechrail_realtime_first_hypothesis_seconds{stage}` 在 `partial` 时记录：

| stage | 起点 → 终点 | 用途 |
|---|---|---|
| `admitted_to_worker` | 服务端接纳首个语音样本 → 收到 worker partial | ASR 主链路首字延迟 |
| `upstream_to_worker` | 首个上行 PCM 到达服务端 → 收到 worker partial | 含采集前的上行与分块积累 |
| `worker_to_socket` | 收到 worker partial → `_send` 完成 | 服务端序列化与 socket 写入 |
| `admitted_to_socket` | 服务端接纳首个语音样本 → `_send` 完成 | 服务端可见上限，不等于用户屏幕可见 |

`speechrail_realtime_first_hypothesis_audio_seconds` 单独记录首个 partial 前累计接纳的音频
秒数。客户端屏幕出现时刻必须由 App/调用方独立埋点，服务端 `_send` 完成不能冒充该事件；
该指标不记录 session、request、文本或任何音频内容。冷/热模型、`chunk_duration_ms`、
VAD/manual、排队时间与样本数必须在任何性能对比中并列说明。

## 容量与隔离

`AdmissionQueue` 限制 REST / commit 后推理的排队量；满载响应为 `429 queue_full` 并带
`Retry-After`。worker 一次只处理一个模型实例，MPS profile 拒绝静默 CPU fallback。运营上
应监控进程存活、readyz、队列满、worker stderr、内存压力与磁盘空间，并可通过 `/metrics`
观测 RTF、TTFA、队列饱和度与 worker 生命周期状态。

`SPEECHRAIL_MLX_CACHE_LIMIT_MB` 与 `SPEECHRAIL_MLX_MEMORY_LIMIT_MB` 是 vendor runtime 的
缓存/分配提示，不等于 ASR、TTS 或 diarization 的驻留峰值。当前无法从它们推导真实模型
footprint；任一重计算组件启用时，Governor 对 overlap 采用未知预算并保持串行，避免在大内存
机器上误放行并发推理。

以下控制不在当前能力范围，不构成安全声明：CORS、请求级限速、远程持久化指标聚合与
集中式导出、非 loopback 的 TLS/Origin/网段防护。需要这些能力时，先实现、测试并更新
契约与本页。
