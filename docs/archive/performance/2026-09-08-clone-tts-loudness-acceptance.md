---
title: "Clone TTS 响度验收记录"
type: acceptance_report
status: partial
date: 2026-09-08
---

# Clone TTS 响度验收记录

## 范围

- SpeechRail issue：[hrygo/SpeechRail#34](https://github.com/hrygo/SpeechRail/issues/34)
- Sona issue：[hrygo/sona#10](https://github.com/hrygo/sona/issues/10)
- 代码 review 修复：`b297694 fix(tts): align clone loudness calibration with framing`
- 前序服务端实现：`caefda3`、`79b2474`、`b20c763`
- 保护策略：SpeechRail 负责 clone normalization；Sona 读取
  `stable_loudness_v1` 并在旧服务或兼容路径保留有界 guard。

## 代码级验证

以下命令在 review 修复后执行，未写入音频、文本、Base64 或完整响度序列：

```text
uv run --extra dev pytest --no-cov tests/test_tts_loudness.py tests/test_tts_voice_clone.py -q  → 35 passed
uv run --extra dev ruff check src/speechrail/domain/tts_loudness.py tests/test_tts_loudness.py tests/test_tts_voice_clone.py  → passed
uv run --extra dev mypy src/speechrail/domain/tts_loudness.py  → passed
```

新增回归覆盖：

1. 默认 200 ms 首个 clone normalization block 完成 calibration，并使用 calibration gain 初始化请求状态；
2. calibration 不在 sparse 后续 chunk 中强行替换 live RMS target，避免重新引入 pumping；
3. 私有 200 ms 合帧保持 PCM sample count/order，残余 chunk 有界。

## 真实运行证据

在 `v2.0.1` managed quality runtime 上，前序最终验证已完成 4 个 clone、3 段文本、每项 3 次，
以及 builtin、3 段文本、每项 3 次；全部 `response.done=completed`。前序聚合 clone RMS P50
为 `-20.329` 至 `-20.763 dBFS`，clone 相邻块跳变 P95 为 `12.599` 至 `25.413 dB`，
builtin 基线为 `34.636 dB`；clone peak 最大值为 nominal `-1 dBFS` 的 PCM16 量化值，未观察到
wraparound 或硬削波。完整脱敏进度和最终评论见
[SpeechRail#34 final verification](https://github.com/hrygo/SpeechRail/issues/34#issuecomment-5587414509)
与
[Sona#10 final verification](https://github.com/hrygo/sona/issues/10#issuecomment-5587479161)。

上述真实数据产生于 review 修复部署前，因此只能作为前序实现的运行基线；`b297694` 仍需在
下一次 managed runtime 替换后重跑同一矩阵，才能把本记录状态改为 complete。

## 未完成项与回退

- 未在本记录中执行 review 修复后的 managed wheel 部署和真实 Realtime 复测；并行 agent 的未提交
  运行时改动完成交付后再进行。
- 未完成真实扬声器主观试听，也未覆盖真实设备上的 cancel/interruption。
- 回退保持原 managed runtime release、selection、模型和私有配置；不删除任何用户 voice 文件。
