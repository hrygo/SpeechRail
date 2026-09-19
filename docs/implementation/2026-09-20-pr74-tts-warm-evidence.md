---
title: "PR #74 managed TTS warm evidence"
status: partial_external_evidence
date: 2026-09-20
---

# PR #74 managed TTS warm evidence

## 结论

这是 PR #74 的一段真实 managed-model 证据，不是完整 release 或音质验收。
测量范围为现有 `quality` profile 的 warm TTS；`release_pass` 保持 `false`，因此
不能据此关闭 #34、#44、#65、#67 或 #72，也不能替代 #68/#73 所需的身份和听感证据。

测量时间：2026-09-20（Asia/Shanghai）。PR source head：`f32a2f9`。

## 运行条件与边界

- managed runtime release：`2.7.0`；profile：`quality`；generation：`102`。
- 设备：Apple M5 Max，`arm64`，Darwin `27.0.0`，物理内存 `137438953472` bytes。
- 服务健康检查、`readyz` 和 `/v1/models` 均为 HTTP 200；health/ready 与 ASR/TTS ready 均为真。
- profile 状态声明的 TTS 制品为 `tts-1.7b-design-q8`，但官方 benchmark 输出的
  `model_identity` 为空；本报告不把 profile 配置声明当作实际 worker/量化身份证明。
- 使用外置 manifest 和安全的合成静音占位 WAV；未读取用户音频，原始 JSON、日志和
  WAV 均未写入仓库。

## 官方 profile benchmark：warm TTS

使用 `examples/perf/bench_profiles.py` 的 `quality / warm` 阶段，执行 6 个 TTS
fixtures（中文短/长各两次、英文两次）。结果为 **6/6 HTTP 200，6/6
`inference_observed=true`**；资源采样可用、真实、role-aware 且完整，采样间隔为
0.25 秒。

| 资源指标 | 实测值 |
| --- | ---: |
| simultaneous peak RSS | `3465019392` bytes |
| simultaneous peak `phys_footprint` | `3997618232` bytes |
| `sampling_complete` | `true` |

官方输出明确为 `release_pass=false`，原因包括缺少 `cold`、`local_quality`、
`quality`、`switch` 阶段，缺少真实 model/variant/quantization identity，缺少真实
quality result，以及缺少 switch evidence。

## 重复 TTS 延迟切片

在同一 managed warm 服务上，使用 `bench_tts.py` 对固定安全文本按 `n=5` 重复请求，
voice 为 `serena`。下表是流式 PCM 的实际输出时长、请求耗时、TTFA 和 continuous
RTF；它们是性能测量，不是音质、发音或音色身份结论。

| 输入类别 | 字符数 | 输出时长 | 耗时 mean [min, max] | TTFA mean | continuous RTF | n |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 中文短句 | 14 | 2.24 s | 0.63 s [0.62, 0.66] | 0.053 s | 0.28x | 5 |
| 中文长句 | 41 | 8.00 s | 2.13 s [2.12, 2.14] | 0.049 s | 0.27x | 5 |
| English | 82 | 4.72 s | 1.28 s [1.27, 1.28] | 0.051 s | 0.27x | 5 |

## 尚未证明的内容

本次没有执行 ASR、Realtime、cold-start、profile switch、并发争用、thermal/soak、
人类听感、ABX/身份匹配或声学质量评分。没有下载模型、修改 profile、重启服务、
注册 voice、关闭 issue 或合并 PR。下一步仍需按主计划补齐 managed Apple-Silicon
矩阵、worker/runtime identity、vendor/cache、matched identity/listening 与
human/acoustic evidence。

详细原始产物保留在仓库外的临时 benchmark 目录；仓库只保留本去标识化摘要。
