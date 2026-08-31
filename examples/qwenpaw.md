# QwenPaw 接入示例

QwenPaw 使用 OpenAI-compatible `whisper_api` 形态时，不需要 SpeechRail 专用 SDK。把
provider 的 base URL 和模型改为：

```text
Base URL: http://127.0.0.1:8201/v1
Model: speechrail/qwen3-asr-1.7b
Provider: whisper_api
Audio mode: auto
```

如果当前 UI 只接受旧模型名，可临时使用 `Qwen3-ASR-1.7B`。新部署应使用 canonical ID，
这样 `/v1/models`、日志和运行清单能准确表达真实服务身份。

切换后完整重启 QwenPaw，再用短中文语音验证。失败时只把 base URL 恢复为旧的
`http://127.0.0.1:8001/v1`，不要同时改 provider、全局 LLM endpoint 和模型路径。
