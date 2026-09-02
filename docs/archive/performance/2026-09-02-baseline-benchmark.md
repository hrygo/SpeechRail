# SpeechRail 优化前性能基准测试与资源存档 (Baseline Benchmark)

> 存档时间：2026-09-02  
> 测试环境：Apple M5 Max (18 核 CPU / 128GB 统一内存)，macOS 26.6.2，Python 3.12，MLX (float16/bf16)  
> 测试工具：macOS 原生 `footprint -f bytes`（采集 `phys_footprint` 物理显存/内存）、`bench_asr.py`、`bench_tts.py`、`bench_realtime.py`  
> 测试目标：在启动低开销资源优化前，对当前完整运行版本（v1.2.0）的真实物理内存占用、推理延迟、吞吐及首包响应建立 100% 实机测量基准数据。

---

## 1. 真实进程与物理显存/内存基线 (Physical Footprint Baseline)

> **测量口径说明**：Apple Silicon 采用统一内存架构（Unified Memory），MLX / Metal 分配的模型权重与计算缓冲直接归属于系统物理显存池。传统 `ps -o rss` 严重漏统 Metal 驱动显存。本基准采用 macOS 原生 `footprint` 工具，采集各 Worker 在真实推理负载下的物理常驻内存（`phys_footprint`）与历史峰值（`phys_footprint_peak`）。

| 进程组件 | 运行命令 / 框架 | 预热常驻内存 (Idle Footprint) | 压测峰值内存 (Peak Footprint) | 峰值 CPU | 说明与显存行为分析 |
|---|---|---|---|---|---|
| **主服务进程 (Host FastAPI)** | `speechrail serve` | **559.8 MB** | **560.1 MB** | 1.0% | 负责 HTTP/WS 路由、ffmpeg 音频解码与调度 |
| **Qwen3 Batch ASR Worker** | `qwen3_worker.py (MLX)` | **6,475.7 MB** (~6.48 GB) | **14,711.0 MB** (~14.7 GB) | 33.4% | Qwen3-ASR-1.7B 批量转写（权重 3.4GB + MLX 未限额 Metal 缓存池） |
| **Qwen3 Streaming ASR Worker** | `qwen3_streaming_worker.py (MLX)` | **8,446.2 MB** (~8.45 GB) | **12,503.4 MB** (~12.5 GB) | 0.0% | Qwen3-ASR-1.7B 流式转写（独立进程，存在全量模型重复加载与缓存滞留） |
| **Qwen3 TTS Worker** | `qwen3_tts_worker.py (MLX)` | **4,826.8 MB** (~4.83 GB) | **5,314.8 MB** (~5.31 GB) | 0.6% | VoiceDesign 1.7B bf16 合成（权重 3.4GB + MLX 运行时） |
| **总常驻物理内存 (Total Footprint)** | -- | **20,308.6 MB (~20.3 GB)** | **33,089.3 MB (~33.1 GB)** | -- | **待机状态全量常驻，无空闲回收、无显存池上限管理、ASR 进程重复** |

### 历史勘误与根因追溯 (Errata & Root Causes)
早期版本曾将 ASR Worker 误记为 `874 MB` 和 `321 MB`，经真机排查确认为：
1. **统计工具口径严重失实**：历史测试直接截取了 `ps aux` 的 `RSS` 列（880MB / 323MB）。在 Apple Silicon 上，`ps rss` 仅统计非 Metal 的匿名脏页，遗漏了 MLX Metal 驱动高达数 GB 的统一内存分配；
2. **MLX 显存缓存激增**：MLX 默认保留前向计算后的 Metal 显存分配池，若未定期调用 `clear_cache()`，物理显存 Footprint 会急剧膨胀至 6GB~14GB；
3. **已实施的采样规范升级**：采样工具 [`examples/perf/sample_resources.py`](../../../examples/perf/sample_resources.py) 现已固定使用 macOS `footprint -f bytes` 精确抓取 `phys_footprint`，并在全量 Warmup 下执行监控，确保数据 100% 真实可复核。

---

## 2. 非流式 ASR 延迟与 RTF 实测基线 (`POST /v1/audio/transcriptions`)

> 测试参数：`model=speechrail/qwen3-asr-1.7b`, `language=zh`, `response_format=json`, 重复 $N=3$ 次取均值。音频为 24kHz/16kHz 真实中文语音切片。

| 音频时长 | 平均耗时 (Mean Latency) | 实时率 (RTF) | 最小 / 最大耗时 | 识别文本与准确表现 |
|---|---|---|---|---|
| **3.0 秒** | **0.56 s** | **0.19x** | 0.54s / 0.61s | “你好，这是本地语音识别与合成。” (100% 准确) |
| **10.0 秒** | **1.13 s** | **0.11x** | 1.13s / 1.14s | “你好，这是本地语音识别与合成服务的性能基准测试...” (准确) |
| **30.0 秒** | **2.91 s** | **0.10x** | 2.90s / 2.91s | 长语音连续转写，吐字对齐清晰无丢字 |
| **60.0 秒** | **6.21 s** | **0.10x** | 6.19s / 6.24s | 吞吐平稳，长音频处理极平稳，RTF 稳定在 0.10x |

---

## 3. 语音合成 (TTS) 性能实测基线 (`POST /v1/audio/speech`)

> 测试参数：`model=speechrail/qwen3-tts`, `voice=default`, 重复 $N=3$ 次取均值。

| 指标 | 实测数值 (47 字符长句) | 实测数值 (20 字符短句) | 说明 |
|---|---|---|---|
| **输入文本字符数** | 47 字符 | 20 字符 | “你好，这是本地语音合成服务的性能基准测试。SpeechRail 能够快速高效地输出高品质语音。” |
| **输出音频时长** | 平均 **7.97 秒** (382 KB PCM16) | 平均 **3.25 秒** (156 KB PCM16) | 24 kHz, 16-bit Mono |
| **合成总耗时** | **2.54 秒** (Min: 2.33s, Max: 2.84s) | **1.06 秒** (Min: 0.98s, Max: 1.11s) | 包含文本归一化、Instruct 生成与 chunk 转换 |
| **生成实时率 (RTF)** | **0.32x** | **0.33x** | 合成速度约为播放速度的 3.1 倍 |

---

## 4. 双向流式 WebSocket 实测基线 (`WS /v1/realtime`)

> 测试协议：标准 OpenAI Realtime 协议 (`client.realtime.connect(model="whisper-1")`)，使用 10s PCM16 语音流测试。

| 测试项 | Session 1 实测值 | Session 2 实测值 | 说明 |
|---|---|---|---|
| **WebSocket 会话建立 (Setup)** | **30 ms** | **0 ms** | 握手与 `conversation.created` 极速完成 |
| **流式 ASR Commit 延迟** | **1,382 ms** | **1,335 ms** | 发送 `input_audio_buffer.commit` 到收到 `completed` 转写事件 |
| **流式 ASR 实时率 (RTF)** | **0.14x** | **0.13x** | 流式分块推理与最终合并耗时极低 |
| **TTS 首包延迟 (TTFA)** | **46 ms** | **46 ms** | 从 `response.create` 到收到第一个 `output_audio.delta` |
| **TTS 下发总音频量** | 199,680 字节 | 148,480 字节 | 连续流式分块下发，无断流或卡顿 |

---

## 5. 待优化项与对比参照点 (Target References)

根据真机实测数据，优化前系统存在**极度严重的显存冗余**：

1. **显存冗余参照**：
   - **当前现状**：ASR 双 Worker 重复常驻占用 $6.48\text{GB} + 8.45\text{GB} \approx \mathbf{14.9\text{ GB}}$，TTS 常驻 $\mathbf{4.83\text{ GB}}$，总常驻物理内存高达 **~20.3 GB**（峰值激增至 33GB）。
   - **优化目标**：
     - **ASR Worker 统一进程化**：消除 8.5GB 重复实例与缓存，合并后 ASR 常驻控制在 **~3.5 GB**；
     - **MLX Metal 显存治理**：实施 `clear_cache()` 与缓存上限，杜绝峰值向 14GB 膨胀；
     - **生命周期空闲回收 (Idle Eviction)**：TTS 与 Diarization 超时自动卸载，待机释放 ~5.0GB；
     - **系统待机常驻**：从 **~20.3 GB 降低至 < 300 MB**（仅主进程）。
2. **延迟与精度保护参照**：
   - ASR 10s 音频基线延迟 **1.13s (RTF 0.11x)**。优化后（INT8 / 统一 Worker）目标保持延迟在 **≤ 1.25s (RTF ≤ 0.13x)**，字错误率相对劣化 **≤ 1.0%**。
   - TTS 首包延迟 **46ms**，生成 RTF **0.32x**。优化后保持首包延迟 **< 100ms**，MOS 劣化 **< 1.5%**。
