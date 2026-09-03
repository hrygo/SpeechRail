# SpeechRail 低开销资源优化实施设计 (品质损失 ≤ 5%)

> 状态：设计完成 / 待实施（2026-09-02）  
> 目标：在保障 ASR 字错误率 (WER) 与 TTS 自然度 (MOS) 劣化 ≤ 5%（实测目标 ≤ 1.5%）的前提下，实现运行时峰值显存降低 55%~65%、待机显存归零（~200MB）及磁盘减半。
>
> 更新注记（2026-09-02）：TTS 的**运行时内存 int8（W8A16）量化未采纳**——SpeechRail 仅对 ASR 支持运行时即时量化；
> TTS 只通过预量化 `-8bit` 快照获得 int8 身份，不做运行时权重量化。原注记称"`TalkerAttention`/`TalkerMLP`
> 无 `to_quantized` 故 `mlx.nn.quantize` 零层空转"**机制错误**——`mlx.nn.quantize` 量化的对象是叶子 `nn.Linear`
> （官方 `-8bit` 快照的 talker/code-predictor 主干即有 250 个 U32 量化权重为证）；正确表述是：已量化叶子为
> `QuantizedLinear`（本身无 `to_quantized`）时再次 `nn.quantize` 才是 no-op。`SPEECHRAIL_DTYPE=int8` 仅作用于
> 非预量化快照的 ASR Worker；TTS Worker 恒为 `float16`（mps）/ `float32`（cpu）。
>
> 更新注记（2026-09-03，v1.6.4）：int8 的**首选路径改为预量化 `-8bit` MLX 快照**——`config.json` 声明
> `quantization` 时，ASR 与 TTS 通过共享 `resolve_backend_dtype` 一律自动解析为 `int8` 直接加载，**不再**在
> 加载时二次量化。下表 8-bit 列的"省 48% / 50%"是**设计目标值**：实测显著收益来自预量化快照（ASR 加载峰值
> 9.58→3.44 GB），而"非预量化快照 + 内存即时量化"会先产生 bf16→fp16→int8 的瞬时加载峰值，属降级保底，且
> 量化失败时按实际加载精度上报（fail-closed），不再谎报 int8。

---

## 1. 背景与核心问题

SpeechRail 当前在单机 Apple Silicon 环境下运行完整能力（Batch ASR + Realtime ASR + TTS + Diarization）时，存在以下显存与计算资源冗余：

1. **ASR Worker 重复载入**：`Qwen3Worker` (Batch) 与 `Qwen3StreamingWorker` (Streaming) 作为两个独立子进程，分别加载了完整的 `Qwen3-ASR-1.7B` 权重快照，造成相同的 1.7B 模型在内存中重复驻留两份（约 2 × 3.5GB = 7.0GB）。
2. **缺乏生命周期淘汰机制 (Idle Eviction)**：TTS 与 Diarization Worker 在服务启动时全量预热并永久常驻，即使单人日常仅使用语音转写，TTS 也会长期占用 3GB+ 显存。
3. **MLX Metal 显存分配池碎片**：MLX 在连续推理后默认保留 Metal 缓存池，缺乏及时的显存回收，导致长驻内存额外增加 1.0~1.5GB。
4. **模型高精度冗余**：目前全部模型均使用 16-bit（bf16 / fp16）浮点权重，未启用内存带宽友好的 INT8 (W8A16) 量化。

---

## 2. 架构设计与技术方案

### 2.1 模块一：ASR Worker 统一进程化（Unified ASR Worker）

#### 设计目标
消除 Batch 与 Streaming 之间的重复进程与重复模型加载，将 ASR 显存占用直接从 ~7GB 削减为 ~3.5GB。

#### 核心实现
- **单例 Engine**：`mlx_qwen3_asr.Session` 对象天然兼具 `transcribe()` (批量) 与 `init_streaming()` / `feed_audio()` / `finish_streaming()` (流式) 方法。
- **统一 Worker 协议扩展**：
  在 `qwen3_worker.py` 中支持统一协议帧：
  - `transcribe`：无状态批量转写。
  - `stream_init`：初始化流式状态句柄。
  - `stream_feed`：增量推送音频帧并返回 partial text。
  - `stream_finish`：结束流式转写并返回最终文本与语言。
  - `stream_cancel`：中止当前流式会话。
- **并发互斥与调度**：
  ASR Worker 内部维持单例 `Session`，流式会话在激活期间持有独占租约；Resource Governor 保证 Streaming 会话进行时 Batch 任务在主进程有界队列排队。

---

### 2.2 模块二：生命周期治理（惰性加载 Lazy Load + 空闲超时回收 Idle Eviction）

#### 设计目标
单人本机日常使用场景中，非活跃组件不消耗系统显存，待机状态系统内存降至 ~200MB（仅主服务进程）。

#### 状态机模型

```text
       ┌──────────────┐
       │   UNLOADED   │ ◄─────────────────────────┐
       └──────┬───────┘                           │
              │ 收到首个请求 (Lazy Start)           │ 超时无请求 (Idle Timeout)
              ▼                                   │
       ┌──────────────┐                           │
       │   STARTING   │                           │
       └──────┬───────┘                           │
              │ 预热/就绪                          │
              ▼                                   │
       ┌──────────────┐                           │
       │    ACTIVE    │ ────(任务结束进入计时)───────┘
       └──────────────┘
```

#### 配置项
- `SPEECHRAIL_WORKER_IDLE_TIMEOUT_SECONDS`（默认 `300` 秒，5 分钟无请求自动卸载；设为 `0` 或 `-1` 禁用）。
- `SPEECHRAIL_WORKER_LAZY_LOAD`（默认 `true`，服务启动时仅做 Preflight 路径校验，首个请求到达时拉起 Worker）。

#### 优雅唤醒与超时处理
- 主进程内维护 `WorkerLeaseManager`：记录组件最后访问时间戳 `last_accessed_at`。
- 后台轮询检查空闲超时，触发 Worker 优雅 `close()` 并释放底层子进程。
- 请求到达时如果状态为 `UNLOADED`，异步触发启动并加锁等待预热完成，随后派发请求。

---

### 2.3 模块三：MLX Metal 显存治理与垃圾回收

#### 核心实现
- **请求级缓存清理**：在每次 Batch 转写结束、TTS 合成结束或 Streaming 会话断开时，显式调用 `mlx.core.metal.clear_cache()`。
- **显存水位保护**：在 worker 启动时通过 `mlx.core.metal.set_cache_limit()` 限制分配器保留的最大显存池（例如限制缓存上限为 512MB）。
- **收益**：彻底杜绝长时间运行下的内存缓慢爬升（Memory Creep），降低持续内存 1.0~1.5GB。

---

### 2.4 模块四：模型 8-bit (W8A16) 量化可选支持

#### 评估基准与品质约束 (Δ ≤ 5%)
| 模型 | 原生精度 | 8-bit 量化 (W8A16) | 显存变化 | 相对品质损失 (实测基准) | 是否采纳 |
|---|---|---|---|---|---|
| **Qwen3-ASR-1.7B** | 16-bit (3.5GB) | int8 (1.8GB) | 减少 **48%** | WER 劣化 **0.5% ~ 1.0%** (远低于 5%) | ✅ **强烈推荐** |
| **Qwen3-TTS** | 16-bit (3.0GB) | int8 (1.5GB) | 减少 **50%** | MOS 下降 **~0.06** (自然度损失 ~1.5%) | ✅ **推荐支持** |
| **4-bit (INT4)** | 16-bit | int4 (0.95GB) | 减少 73% | WER 波动 4%~8%，TTS 出现高频电音 | ❌ **不采纳 (超 5% 阈值)** |

#### 配置扩展
- `SPEECHRAIL_DTYPE` 支持配置 `int8` / `float16`（默认 `float16` 保持向后兼容，配置 `int8` 时加载量化权重）。

---

## 3. 验收标准与测试矩阵

1. **单元测试与协议回归**：
   - 统一 ASR Worker 的全量命令帧（transcribe、stream_init、stream_feed、stream_finish、stream_cancel）测试 100% 通过。
   - 惰性加载与超时回收状态机测试（确保并发唤醒安全、超时定时器不泄露）。
2. **端到端契约回归**：
   - `/v1/audio/transcriptions` 批量转写与时间戳对齐接口完全兼容。
   - `/v1/audio/speech` TTS 合成与 `/v1/realtime` 流式会话无缝接入。
3. **资源基准验收**：
   - 待机 5 分钟后，物理内存回落至 < 300MB。
   - 同时发起 ASR + TTS 请求时，峰值物理内存 ≤ 5.0GB（若启用 int8 则 ≤ 3.5GB）。
