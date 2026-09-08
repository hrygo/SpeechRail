---
title: "SpeechRail Realtime VAD 运行时修复验收"
status: accepted
audience: "发布负责人、运维人员、Sona 集成工程师"
version: "1.0.0"
date: 2026-09-08
---

# Realtime VAD 运行时修复验收

## 结论

`2.0.1` 的问题是应用 release 没有声明 `onnxruntime`。因此，配置了 Silero 模型时，ASR/TTS/diarization 可以正常 ready，但首个 `server_vad` 会话在协商阶段返回 `onnxruntime is not installed`。这是 VAD 子能力的部署缺口，不是 SpeechRail 进程或核心模型离线。

`2.0.2` 已将 `onnxruntime==1.29.0` 纳入 Apple Silicon（macOS 14+）应用 wheel，并把应用 Python 的导入检查与 Silero 模型文件检查接入 managed preflight。`/health`、成功的 `/readyz` 和 `/metrics` 现在独立返回 `realtime_vad.ready/code/message`；配置了 Silero 模型但运行时不完整时继续 fail closed，不静默改用 legacy。

## 交付与静态门

- 修复提交：`6fed764` (`fix: bundle VAD runtime and expose capability readiness`)
- wheel：`speechrail-2.0.2-cp312-cp312-macosx_26_0_arm64.whl`
- wheel SHA-256：`ca5ea3f943d1402d7ca5087d3bc4f8b6597073b41c6e86699214be2e3c185948`
- 版本一致性、全量 pytest、ruff、mypy、OpenAPI lint 均通过；全量测试结果为 `1312 passed, 1 skipped, 2 warnings`。
- 本轮没有执行性能基准测试。

## 运行态证据

受管 `quality` profile 已切换到 `2.0.2`，服务保持单一 `com.speechrail` LaunchAgent 和单一 8201 listener。当前安全状态摘要：

- `speechrail service preflight`：`realtime_vad_model`、`realtime_vad_runtime` 均 `OK`；ASR/TTS、CoreML diarization 检查也均 `OK`。
- 应用 venv 实际导入：`speechrail=2.0.2`、`onnxruntime=1.29.0`。
- `/health`：`asr_ready=true`、`tts_ready=true`、`diarization_ready=true`、`realtime_vad.ready=true`，`realtime_vad.code=null`。
- `/readyz`：HTTP 200，并包含同一份 `realtime_vad` 子能力诊断；顶层 `ready` 仍只表示 ASR 或 TTS 至少一项可用。
- Realtime 功能 smoke：`session.update` 使用 `turn_detection.type=server_vad` 成功收到 `session.updated`；发送 4 个 16 kHz mono PCM16 帧后提交，收到单次空转写终态，无 `error` 或 `backend_not_ready`。
- 公共功能 smoke：真实 TTS 返回非空 WAV，随后真实 ASR 返回非空转写和 request ID。

## 集成边界与回退

标准 OpenAI Realtime 客户端与 Sona 无需安装额外 VAD SDK，也无需改变 `server_vad` 请求形状。实时字幕接入方只需在发起会话前检查 `/health.realtime_vad.ready`；`vad_runtime_missing` 或 `vad_model_missing` 应交给 SpeechRail managed release/preflight 处理。

TTS 的 `cold_evicted`/`tts_warm=false` 只表示未预热，不属于本次 VAD 故障。真实声学 FAR/FRR、DER/JER、长会话和性能指标仍按各自验收手册执行，本记录不替代这些质量门。
