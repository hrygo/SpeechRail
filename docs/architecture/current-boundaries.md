---
title: "SpeechRail 当前边界与剩余风险"
status: active
date: 2026-09-01
---

# SpeechRail 当前边界与剩余风险

## 已确认

1. REST 文件转写使用仓库外 Qwen3-ASR worker；运行时明确设置离线环境变量。
2. 默认 Apple Silicon profile 为 MPS / `float16`，worker 拒绝自动 CPU fallback。
3. 未配置 profile 路径时不加载模型；已配置 ASR/TTS profile 各自最多启动一个隔离 worker，
   WLK 只可连接外部已运行 endpoint。
4. QwenPaw 的历史接入记录不能替代当前配置/模型状态；再次切换前必须单独 smoke。
5. 默认 loopback，非 loopback 配置必须有 API key；敏感音频/文本不写入仓库或常规日志。

## 明确限制

- `/v1/realtime` 只承载 OpenAI Realtime 协议的 ASR/TTS 子集；不伪装 LLM 对话、工具调用、
  历史或持续会话语义。
- `/health` 分别反映 ASR/TTS worker readiness，`/readyz` 在至少一个能力可接受请求时返回 200。
- 上传字节数受限；解码后音频时长、CORS、速率限制与指标导出不在当前能力范围。
- 常驻运行提供 macOS `LaunchAgent` CLI、安装模板和操作手册；服务默认不自动安装或启用。

## 已实测基准（本机，MPS/float16）

| 指标 | 实测值 |
|---|---|
| REST ASR RTF（10s/30s/60s 音频） | 0.07x / 0.06x / 0.06x |
| REST ASR 并发吞吐（4/8 并发） | 1.5 req/s（单 MPS worker 串行） |
| REST TTS RTF（20/43 字符） | 0.36x / 0.34x |
| Realtime 连续会话 | 连续 5 次会话成功（修复后） |
| Realtime ASR commit→completed（10s） | 1.8-4.2s（RTF 0.18-0.42x） |
| Realtime TTS 首音频块 | 51-223ms |
| worker 常驻内存（ASR/streaming/TTS） | 1.96GB / 1.96GB / 4.76GB |

## 验收门（未实测，须在对应场景完成）

- Hermes 的 STT 配置和聊天 endpoint 隔离 smoke；
- `voice-realtime` 的真实 ASR/TTS worker 端到端音频、播放与回滚验收；
- 多语言/长文件（>60s）的质量、失败恢复与长时间运行基准；
- 非 loopback 的 TLS、CORS、网段控制、速率限制和 legacy auth 实现；
- 解码后实际音频时长限制、观测指标导出与日志收集策略实现；
- FastAPI startup/shutdown event 迁移到 lifespan 的未来兼容性处理。

## 发布与端口切换门

REST 自动化门禁、真实 Qwen3 ASR/TTS smoke、目标客户端真实 smoke、实时/legacy
所需契约实现、回滚演练和安全审计全部通过后，SpeechRail 才作为生产默认。当前 `8201` 是
独立服务端口；voice-realtime 的旧 TTS bridge 已退役，若需回滚只能恢复已验证版本目录与配置，
不能依赖一个仍在运行的旧 bridge 进程。
