---
title: "SpeechRail 测试与验收"
status: active
date: 2026-08-31
---

# SpeechRail 测试与验收

## 自动化门禁

提交前运行：

```bash
cd <path-to-SpeechRail>
uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
git diff --check
```

测试使用 fake backend 和合成/脱敏数据，不加载模型、不访问网络，也不提交真实音频。
至少覆盖：模型 aliases、错误 envelope、上传限制、队列、响应格式、worker frame 协议、
snapshot preflight、Realtime 的 update/append/commit 顺序，以及 legacy config/EOF 行为。

## 真实 worker smoke

在完整外部 snapshot 和 runtime 配置下：

```bash
curl http://127.0.0.1:8201/health
curl http://127.0.0.1:8201/readyz
curl http://127.0.0.1:8201/v1/models
curl -X POST http://127.0.0.1:8201/v1/audio/transcriptions \
  -F 'file=@sample.wav' \
  -F 'model=speechrail/qwen3-asr-1.7b' \
  -F 'language=zh' \
  -F 'response_format=verbose_json'
```

验收 HTTP 状态、非空文本、`X-Request-ID`、模型设备/dtype 与预期 profile。测试音频由
操作者本地保存，结束后删除；提交/报告只保留最小结果摘要而非文本或音频。

## 集成验收矩阵

| 客户端/接口 | 当前状态 | 通过条件 |
|---|---|---|
| REST curl | 已完成本机 smoke | health / readyz / models 正常，短音频得到结果 |
| QwenPaw `whisper_api` | 已完成本机 smoke | provider 指向 `8201/v1`、应用完整重启、短中文音频有文本 |
| OpenAI SDK | 可按兼容契约接入 | multipart 调用和错误处理符合 OpenAPI |
| Hermes Agent | 待验收 | STT 专用 base URL/model 生效且不改变聊天 endpoint |
| `/v1/realtime` | 协议测试 | update → append → commit → 一次 completed；不要求 delta |
| `voice-realtime` `/asr` | 不可验收为转写 | 当前只验证 config / EOF；不允许作为替换结论 |

每次发布保存命令、时间、版本/commit、测试摘要、OpenAPI lint、设备/dtype、request ID 与
未验证风险。命令退出码不能单独替代 API 响应或客户端行为证据。
