---
title: "SpeechRail 测试与验收"
status: active
date: 2026-08-31
---

# SpeechRail 测试与验收

## 1. 测试层级

```text
纯函数单元测试
  → adapter/vendor fixture 测试
    → FastAPI/WS 契约测试
      → 本机真实模型 smoke
        → 三客户端集成验收
```

多数测试不加载模型、不访问网络、不读真实音频；真实模型只作为发布前的少量门禁。

## 2. 单元测试

必须覆盖：

- language alias normalization。
- model canonical/alias resolution。
- segment 时间戳和 source epoch 校验。
- WLK full snapshot → `TranscriptWindow`。
- `TranscriptWindow` → WLK `lines`/`buffer_transcription`。
- Qwen worker framed protocol 的长度、request ID、错误码和 EOF。
- Base64 realtime event 解析和非法状态拒绝。
- OpenAI response format：json、verbose_json、text、srt、vtt。
- 错误 envelope、request ID、retryable 和 `Retry-After`。
- 临时文件在成功、失败、超时和取消路径都清理。

## 3. 契约测试

### REST

```bash
uv run pytest tests/test_app_contract.py -q --no-cov
```

要求：

- `/health` 在 backend not ready 时仍返回 200 且 `ready=false`。
- `/readyz` 在 backend not ready 时返回 503。
- `/v1/models` 返回 canonical ID 和兼容 alias。
- multipart 缺 file 返回 422 的统一 envelope。
- 未认证、未知模型、队列满、模型未 ready 返回稳定错误码。
- OpenAPI operationId、响应 schema 和代码路由一致。

### Realtime

- 创建 session 后只能按规定顺序发送 update/append/commit。
- partial delta 不被误判为 completed。
- commit 后只产生一次 completed 或一个明确 error。
- 超过单帧/单连接上限会释放资源。

### Legacy WLK

- 首帧为 `config`。
- 二进制 PCM 顺序不变。
- full snapshot 字段与旧 `voice-realtime` consumer 兼容。
- 空 PCM 能触发 `ready_to_stop`。
- token header/query 规则与弃用策略一致。

## 4. 真实模型 smoke

模型准备完成后执行：

```bash
curl http://127.0.0.1:8201/health
curl http://127.0.0.1:8201/readyz
curl -X POST http://127.0.0.1:8201/v1/audio/transcriptions \
  -F 'file=@fixtures/zh-short.wav' \
  -F 'model=speechrail/qwen3-asr-1.7b' \
  -F 'language=zh' \
  -F 'response_format=verbose_json'
```

记录文本、duration、segment 数量、TTFT/RTF、峰值内存、device/dtype 和 request ID；
不要把真实音频或完整 transcript 提交到仓库。

实时 smoke 使用固定 16 kHz mono PCM：

1. 发送 session update。
2. 发送 100–500 ms PCM append。
3. 检查 delta 到达。
4. commit。
5. 检查 completed 和时间轴。
6. 断线/重连时检查资源释放和 session 行为。

## 5. 三客户端验收矩阵

| 客户端 | 接口 | 必验行为 |
|---|---|---|
| QwenPaw | REST multipart | 录音 → 中文文本；完整 app 重启后仍生效 |
| Hermes Agent | REST multipart via OpenAI SDK | 语音消息 → 文本；不影响聊天 endpoint |
| voice-realtime | legacy `/asr` → realtime | partial、confirmed、EOF、会议封存和 SRT 不回退 |

## 6. 质量门禁

```bash
uv run pytest
uv run ruff check src tests
uv run mypy src
```

OpenAPI 校验：

```bash
npx @redocly/cli lint contracts/openapi.yaml
```

发布前还需要真实运行时检查：

- `lms ps`/系统资源没有异常；SpeechRail worker identity 与 profile 相符。
- 没有隐式模型下载。
- 单 worker 不会因 HTTP 并发复制模型。
- `SIGTERM` 能优雅关闭 WebSocket、队列和 worker。
- 旧 WLK 端口可以按 Runbook 回滚。

## 7. 验收证据

每次发布保存：

- 命令、时间和退出码。
- 测试总数/失败数和 coverage。
- OpenAPI lint 输出。
- 模型/runtime/snapshot 指纹。
- 三客户端 smoke 结果。
- 未验证事项和剩余风险。

不能以“命令退出码为 0”单独替代 API 响应、模型身份和客户端行为验收。
