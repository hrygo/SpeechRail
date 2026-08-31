---
title: "SpeechRail 安全与可观测性"
status: active
date: 2026-08-31
---

# SpeechRail 安全与可观测性

## 1. 网络和认证

| 场景 | 监听 | 认证 | 备注 |
|---|---|---|---|
| 本机开发 | `127.0.0.1` | 可无 key | 默认安全边界 |
| 本机多进程 | `127.0.0.1` | 建议 key | 防止其他本地进程误用 |
| 可信 LAN | 指定 LAN IP | Bearer key 必须 | 限 origin、限网段、限速 |
| 公网 | 不在首发范围 | 需反向代理/TLS/租约 | 不直接暴露本服务 |

API key 只从环境/密钥管理器读取，不写入 YAML 示例、命令参数、URL 或日志。HTTP 使用
`Authorization: Bearer`。Realtime 使用握手 header；legacy query token 仅兼容历史
客户端，迁移后关闭。

## 2. 音频和文本隐私

- 上传音频只进入受限临时文件或内存有界缓冲。
- 推理结束、超时或异常时都删除临时文件。
- 不把原始音频、Base64 音频、完整 prompt 或完整 transcript 写入普通日志。
- 诊断 audit 只记录 `request_id`、模型/运行时指纹、时长、字数、错误码、耗时和资源；
  如果需要文本样本，必须由用户显式开启并写入隔离的、受权限保护的测试目录。
- `prompt` 只作为领域词汇提示，长度上限 2,000；不把它解释为系统指令或 shell 命令。
- 文件名、MIME、扩展名都视为不可信输入；解码通过固定 argv 调用 `ffmpeg`，禁止 shell。
- 禁止通过 URL 让 SpeechRail 代下载音频，避免 SSRF；只接受 multipart 上传。

## 3. 边界校验

启动时校验：

- host/port、CORS/origin、API key 策略。
- 模型目录绝对路径且位于仓库外。
- Python executable 是可执行文件，worker module 属于 SpeechRail。
- 依赖和模型 snapshot 完整。

请求时校验：

- Content-Type、文件大小、解码时长、sample rate/channels。
- model ID 是否 canonical 或登记 alias。
- language、response_format、timestamp granularities 是否受支持。
- realtime 事件类型、Base64、音频帧大小、session 状态和单调顺序。

vendor response 校验：

- 字段类型和长度。
- 时间戳 `start <= end` 且不为负。
- 文本和语言字段不超过上限。
- 设备/dtype 与 profile identity 匹配。
- 不支持的 word timestamp、diarization 等能力不伪造。

## 4. 队列和限流

- REST 队列有界；满载返回 `429 queue_full`、`Retry-After` 和 `request_id`。
- Realtime 单连接有音频缓冲上限；超过上限发送协议 error 并关闭，避免慢客户端耗尽内存。
- 单 client 可设置并发上限；同一 request ID 不作为音频正文缓存键。
- 实时优先于批量的 admission 只作用于尚未进入模型调用的任务，不抢占正在运行的推理。
- 超时取消必须同时释放 semaphore、临时文件、WebSocket task 和 worker request slot。

## 5. 日志字段

建议结构化字段：

```json
{
  "event": "transcription.completed",
  "request_id": "req_...",
  "session_id": "sess_...",
  "client": "qwenpaw",
  "requested_model": "Qwen3-ASR-1.7B",
  "resolved_model": "speechrail/qwen3-asr-1.7b",
  "backend": "qwen3-native-mps",
  "duration_ms": 5200,
  "queue_wait_ms": 14,
  "inference_ms": 820,
  "text_chars": 27,
  "retryable": false
}
```

禁止字段：`api_key`、Authorization、audio bytes、Base64、完整 transcript、完整 prompt、
模型绝对路径中的用户隐私目录、worker traceback。

## 6. 指标

最小指标集合：

```text
speechrail_requests_total{endpoint,status,client}
speechrail_request_duration_seconds{endpoint,client}
speechrail_queue_wait_seconds{lane}
speechrail_queue_depth{lane}
speechrail_inference_duration_seconds{backend,device}
speechrail_audio_duration_seconds{endpoint}
speechrail_errors_total{code,retryable}
speechrail_realtime_sessions{state}
speechrail_worker_restarts_total{backend}
speechrail_backend_ready{backend}
```

标签中不放 request ID、文件名、模型路径、用户文本或动态无限基数值。内部健康页面
可以展示当前进程/worker 信息，但不返回 key。

## 7. 事件审计

每次模型调用保留最小运行清单：版本、commit、model ID、snapshot hash、runtime、device、
dtype、参数指纹、音频时长、结果格式和耗时。清单不包含音频和默认不包含 transcript。
科学 benchmark 另行保存脱敏的原始 hypothesis，不能和生产普通日志混用。
