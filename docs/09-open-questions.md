---
title: "SpeechRail 当前边界与剩余风险"
status: active
date: 2026-08-31
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

- `/v1/realtime` 是 commit 后 batch 转写，只产生最终 completed；没有 partial/delta 或
  持续会话语义。
- `/asr` 只有 config 与空 PCM EOF/`ready_to_stop`，没有模型调用和认证，不能替代 WLK。
- `/readyz` 反映推理入口配置；真实 worker 健康仍需短音频 smoke 确认。
- 上传字节数受限；解码后音频时长、CORS、速率限制、指标导出与 legacy auth 尚未实现。
- 常驻运行仅提供 `launchd` 安装模板/操作手册，尚未在本机自动安装。

## 待验收或待实现

- Hermes 的 STT 配置和聊天 endpoint 隔离 smoke；
- `voice-realtime` adapter 的真实 shadow、切换和回滚验收；
- 多语言/长文件的质量、吞吐、峰值内存和失败恢复基准；
- 非 loopback 的 TLS、CORS、网段控制、速率限制和 legacy auth；
- 解码后实际音频时长限制、观测指标与日志收集策略；
- FastAPI startup/shutdown event 迁移到 lifespan 的未来兼容性处理。

## 发布与端口切换门

只有同时具备 REST 自动化门禁、真实 Qwen3 smoke、目标客户端真实 smoke、实时/legacy
所需契约实现、回滚演练和安全审计后，才可以用 SpeechRail 替换旧 WLK `8001`。在此之前，
`8201` 是独立旁路端口，旧服务仍是 `voice-realtime` 的回退路径。
