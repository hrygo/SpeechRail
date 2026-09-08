# D1：两个分人模型窄运行时对比

> 状态：隔离 runtime smoke 已完成；生产选型未定。
>
> 范围：同一预置 90 秒输入、同一 streaming preset、A/B 各一条连续 session。未执行 RTTM/UEM、DER、ASR 共存、分包一致性或完整发布基准。

## 一眼结论

| 项目 | A：FluidAudio CoreML FP16 | B：NVIDIA NeMo native streaming |
|---|---:|---:|
| 90 秒输入处理时间 | 7.077 s | 58.549 s |
| RTFx | 12.716 | 1.537 |
| 输出 | 1,123 帧、33 个 segment | 1,125 × 4，全部 finite |
| `/usr/bin/time -l` max RSS | 564 MB | 1,862 MB |
| runtime smoke | 成功 | 成功（CPU） |

按本次独立运行成本，A 明显更快、更省内存；B 的 NeMo native streaming 路径可以在本机 CPU 上运行，但处理速度约为 A 的 1/8，峰值 RSS 约为 A 的 3.3 倍。该结论不等同于质量结论或生产选型批准。

## 测量身份

- 硬件：Apple M5 Max，18 cores，128 GB；macOS `26.6.2`。
- 输入：`examples/autobiography-video/build/voiceover_90s.wav`，转换为 16 kHz mono PCM16，90.0 s / 1,440,000 samples。
- preset：`chunk_len=6`、`left=1`、`right=7`、`fifo_len=188`、`spkcache_len=188`、`update_period=144`、4 speaker slots。
- A：`FluidInference/diar-streaming-sortformer-coreml` 的 `v3/fp16/SortformerNvidiaLow_v2.1.mlmodelc`，revision `ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1`，显式 `compute units=all`。
- B：`nvidia/diar_streaming_sortformer_4spk-v2.1`，revision `fafaab5faa1617a0ca52d38dd3dc4bd636800d3d`，NeMo `3.0.0` / PyTorch `2.14.0`，CPU，`streaming_mode=true`、`async_streaming=false`。
- A 源代码 commit：`5c19d5e12320e22bbfb7a1877b089d2665a69add`。制品背景见 [FluidAudio Sortformer 文档](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/Sortformer.md) 与 [NVIDIA model card](https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1)。

## 实测结果

### A

- 本地 CoreML bundle 直接加载并连续处理成功；模型加载约 `1.42 s`，处理 `7.077475 s`，总 wall time `9.04 s`。
- 输出 `1,123` 个 80 ms frame，后处理得到 `33` 个匿名 segment。
- 初始 CLI 对 `.mlmodelc` 无条件调用 `MLModel.compileModel`，会因缺少 `Manifest.json` 失败；本次只在隔离副本使用 direct-load harness，patched source 与二进制保存在仓库外。
- CLI 未导出原始四路概率矩阵，因此不单独宣称 A 的 NaN/Inf gate 已完成。

### B

- checkpoint 本地恢复成功，调用 `forward_streaming_step` 连续处理成功。
- load `0.678456 s`，feature `0.013479 s`，streaming `58.548534 s`，总 wall time `63.68 s`。
- `188` chunks，输出 `1,125 × 4`；概率全部 finite，累计输出长度单调增长。
- threshold `0.5` 的四路活动时长为 `[46.24, 19.28, 5.12, 2.72]` 秒。

A/B 尾部输出相差 `2` 帧（160 ms）。本轮未继续做分包和 finish-flush 专项裁决，暂记为 end-of-stream accounting 差异，不解释为质量差异。

## 实验成本与证据位置

原始模型、输入、日志、JSON、harness 和编译 CLI 均保存在仓库外 `$APP_HOME/benchmarks/20260908-d1-diarization-runtime-smoke/`；Git 只保存本脱敏报告。

| 内容 | 保存字节数 |
|---|---:|
| A CoreML bundle | 246,275,130 |
| B `.nemo` checkpoint | 471,367,680 |
| 模型合计 | 717,642,810 |
| 输入 | 18,772,509 |
| source / tools / metadata / results | 25,895,107 |
| 全部持久化文件 | 762,310,426 |

持久目录包含 `models/`、`inputs/`、`results/`、`source/`、`tools/`、`metadata/`，并生成 `metadata/SHA256SUMS`；最后一次 `shasum -a 256 -c metadata/SHA256SUMS` 全部为 `OK`。

关键 SHA-256：16 kHz 输入 `9550029f67111773ce6ff2599dd4f47f7d68b0a1fda8e2020129208a7d0b3700`；A 两个权重 `88a98803e35186b1dfb41d7f748f7cee5093bb6efeb117f56953c17549792fa4` / `1e362707e5db14efdf2bf2900a511b8343bf10c7f8fe463b58d370d0ba2a34ff`；B checkpoint `8abd32832159c6ac1148c926b7276f35ba34582c444e559dce1f1253fea42ef8`。

## 未验证项

- 无 RTTM/UEM，DER、miss、false alarm、confusion 为 `N/A`；预置 timeline 不是 ground truth。
- 每个候选仅一轮，warm `p50/p95` 为 `N/A`。
- 未使用 `footprint -p`，内存数字只来自 `/usr/bin/time -l`，不作为 `phys_footprint` gate。
- 未执行 ASR 共存、队列趋势、服务切档、不同 PCM 分包或长时 soak。
- 因此本报告不返回 `select_coreml` / `select_nemo`，只记录 runtime smoke 与持久化成本。

原始 JSON 与日志不进入 Git，复现命令和完整制品清单见仓库外 run 目录的 `comparison-report.md` 与 `metadata/SHA256SUMS`。
