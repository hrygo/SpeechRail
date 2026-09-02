---
title: "多会话并发流式 ASR 服务调研与 SpeechRail 当前实现差距分析"
status: archived
type: research
version: "1.0"
date: 2026-09-02
area: realtime/multisession
---

# 多会话并发流式 ASR 服务调研与 SpeechRail 当前实现差距分析

## 引言

本文档记录了一次针对"同时为多个应用提供服务"的最佳实践调研，以及该调研结论与 SpeechRail 当前单会话 realtime 实现之间的差距分析。

**范围声明**：本文档是过程/归档材料（target-design），不是已实现功能，也不是当前运行行为的事实来源。调研结论来自外部开源项目的架构观察，不等同于 SpeechRail 的当前能力。任何将本文档描述的方向理解为"已实现"或"即将上线"的解读都是错误的。

当前 SpeechRail 的 `/v1/realtime` 端点（`contracts/realtime-openai.md`）对每个 WebSocket 连接只支持一个活跃会话，`NativeRealtimeFactory` 通过 `_active` 槽位强制串行化。v1.5.1 将 streaming worker 与 batch worker 分离，解决了共享管道上的崩溃/死锁问题，但并未解决多会话并发问题。

本文档的目标是为未来的 ADR 和实现决策提供事实基础，而不是给出最终方案。

---

## 外部最佳实践调研

> 本节所有结论标记为（调研结论），来源于对生产级流式 ASR 系统的架构观察，不是 SpeechRail 的事实。

### a. 生产级流式 ASR 的共同架构

调研覆盖 sherpa-onnx、Vosk、FunASR、Moonshine、NVIDIA Triton Inference Server 以及 OpenAI Realtime 参考实现。这些系统的共同模式是：

- **共享模型权重**：模型权重在进程内只加载一次，多个会话共享同一份权重。这是单机多应用场景下内存效率的唯一可行方案。复制模型进程（每会话一个 worker）在内存和启动延迟上都是不可接受的。
- **每会话独立状态**：每个会话维护独立的音频缓冲、增量解码状态、语言模型上下文和输出队列。会话状态不与传输层绑定，断连后可以在新连接上重建。
- **调度器**：主进程或调度层负责将音频帧路由到正确的会话状态机，并在会话空闲时执行清理。调度器通常基于事件循环（event loop）或协程调度，而不是线程池。

（调研结论） sherpa-onnx 的 `OnlineRecognizer` 是这一模式的典型代表：一个 `OnlineRecognizer` 实例对应一个会话，模型权重在 `OnlineRecognizerManager` 中共享。FunASR 的 streaming 后端同样采用"共享模型 + 每会话 `SpeechServerTask`"的架构。NVIDIA Triton 通过 `max-concurrency` 参数控制每模型实例的并发请求数，底层由 C++ 调度器管理。

### b. 会话路由：session_id 帧路由是共享管道的正确解法

（调研结论） 所有生产实现都采用"帧携带 session_id"的路由机制：

- 客户端在 `session.open` 帧中携带唯一 `session_id`。
- 后续 `audio.append`、`commit`、`cancel` 帧都携带相同的 `session_id`。
- Worker 引擎内部维护一个 `Map<session_id, SessionState>`，根据帧中的 `session_id` 将音频帧路由到正确的会话缓冲和解码状态机。
- 引擎侧的增量解码状态（如 sherpa-onnx 的 `OnlineRecognizer`、FunASR 的 `Faster-Whisper` streaming state）完全按会话隔离。

（推断） SpeechRail 当前的帧协议已经在 `session.open`、`audio.append`、`commit`、`cancel` 帧中携带了 `session_id` 字段（见 `qwen3_streaming.py` 第 200-232 行），但 worker 引擎侧（`qwen3_worker` 模块）并未实现多会话状态机，仍然将 `session_id` 视为"本次连接的标识"而非"路由到独立会话状态的键"。这是协议层与引擎层之间的语义鸿沟。

### c. 并发上限：信号量/连接数上限 + 背压

（调研结论） 生产系统不追求无界并发，而是通过以下机制控制并发上限：

- **信号量（Semaphore）**：限制同时活跃的会话数。超出上限的新请求返回 `backend_busy` 或排队等待。
- **连接数上限**：每个 worker 实例限制最大 WebSocket 连接数。
- **背压（Backpressure）**：当会话缓冲接近上限时，暂停读取客户端音频，避免内存无界增长。
- **不复制模型进程**：并发通过共享进程内的协程/线程调度实现，而不是复制 worker 进程。复制进程只用于故障隔离（如 Triton 的 `max-concurrency=1` 场景），不用于每会话隔离。

### d. 断连/清理：调度循环 liveness 检测 + 延迟清理

（调研结论） 多会话系统的会话泄漏是常见故障模式。生产实现通常采用：

- **调度循环 liveness 检测**：后台任务定期检查所有活跃会话的"最后活动时间"，超时则标记为待清理。
- **引用计数/引用清理**：会话状态通过引用计数管理，当最后一个引用释放时触发清理。
- **abort 检查点**：在解码循环的关键位置检查 abort 标志，允许中断长时间运行的推理。
- **没有这些机制的后果**：会话状态在断连后无法回收，内存持续增长，最终导致 OOM 或推理延迟飙升。

### e. 资源边界：单机多应用 = 共享推理进程 + 有界并发

（调研结论） 单机多应用的正确架构是：

- **共享推理进程**：一个 worker 进程加载一次模型权重，服务多个会话。
- **有界并发**：通过信号量限制同时活跃的会话数，超出时返回 `backend_busy` 或排队。
- **进程隔离仅用于安全边界与故障隔离**：主进程与 worker 进程的隔离是为了防止推理崩溃影响协议层，而不是为了每会话隔离。每会话隔离在进程内通过状态机实现。

---

## SpeechRail 当前实现与此的差距

> 本节所有结论标记为（当前代码），来源于对当前代码库的读取，是事实陈述，不是目标设计。

### 1. NativeRealtimeFactory 单会话 `_active` 槽位

（当前代码） `qwen3_streaming.py` 第 339 行：

```python
self._active: Qwen3StreamingSession | None = None
```

`create()` 方法（第 341-356 行）在 `_active is not None` 时直接抛出 `RuntimeError("realtime streaming backend busy")`：

```python
if self._active is not None:
    raise RuntimeError("realtime streaming backend busy")
```

这意味着一个 worker 实例同时只能有一个活跃会话。第二个连接请求会立即被拒绝，而不是排队或路由到独立会话状态。

### 2. Worker 帧协议不含 session_id 路由标识

（当前代码） `worker_protocol.py` 定义的帧类型包括 `start`、`session.open`、`audio.append`、`commit`、`finished`、`event`、`error`。虽然 `qwen3_streaming.py` 第 200-232 行在发送帧时携带了 `session_id` 字段，但 worker 引擎侧（`qwen3_worker` 模块）并未实现基于 `session_id` 的路由逻辑。

（当前代码） `services.py` 第 212-215 行的注释明确说明了共享管道的限制：

```python
# Dedicated streaming worker: a realtime session's read loop parks on the
# transport between frames, so it must never share a pipe with batch
# transcriptions (worker session frames carry no routing id, making one
# concurrent reader crash readexactly and a locked one deadlock).
```

（当前代码） `worker_process.py` 第 84-92 行的 `AsyncFramedWorkerProcess` 使用 `_io_lock` 序列化所有管道操作：

```python
self._io_lock = asyncio.Lock()
```

`exchange()` 方法（第 146-158 行）在锁内完成发送和接收，确保请求/响应对的原子性。`receive()` 方法（第 177-179 行）同样在锁内调用 `_receive_unlocked()`。

（推断） 如果尝试让两个会话共享同一个 `AsyncFramedWorkerProcess` 而不加锁，两个 `_read_loop` 会并发调用 `readexactly()`，导致一个读取到另一个的帧（帧错乱）或直接崩溃。如果加锁，一个会话的 `_read_loop` 在等待帧时会阻塞整个管道，导致另一个会话的 `send()` 也阻塞，形成死锁。v1.5.1 的提交 `1dae732`（"fix: run native realtime on a dedicated streaming worker"）正是为了解决这个问题，将 streaming worker 与 batch worker 分离。

### 3. 共享 transport 在协议层不成立

（当前代码） `worker_process.py` 第 181-217 行的 `_receive_unlocked()` 方法使用 `readexactly()` 读取固定长度的帧。`readexactly()` 是 asyncio 的精确读取方法，如果两个协程同时调用它，一个会读取到另一个期望的帧，导致协议解析失败。

（当前代码） `_io_lock` 的存在本身就是对"共享 transport 不支持并发读"这一事实的工程确认。锁的存在意味着：任何时刻只有一个协程可以发送或接收帧。

（推断） 要实现多会话并发，必须在 worker 引擎侧实现多会话状态机，并在主进程侧实现基于 `session_id` 的帧路由。这意味着 `AsyncFramedWorkerProcess` 需要升级为支持多路复用的传输层，或者每个会话拥有独立的 transport 实例（但这会破坏"共享模型权重"的原则）。

### 4. v1.5.1 的缓解：专用 streaming worker

（当前代码） `services.py` 第 204-236 行在 `realtime_asr_backend == "native"` 时创建专用的 `Qwen3StreamingWorker`，与 batch worker 完全分离。这是 v1.5.1 的核心变更（提交 `1dae732`）。

（当前代码） 但这只是缓解了"batch 与 realtime 共享管道"的问题，并没有解决"多个 realtime 会话共享管道"的问题。`NativeRealtimeFactory._active` 槽位仍然限制为单会话。

### 5. ResourceGovernor / WorkerLeaseLock / WorkerIdleEvictor 已有基础

（当前代码） `resource_governor.py` 已经实现了基于 `WorkClass` 的容量预留和 FIFO 排队：

- `realtime_reserved_capacity`：为 realtime 工作预留的容量。
- `max_pending_per_class`：每类工作的最大等待队列长度。
- `GovernorQueueFullError`：队列满时的错误类型。

（当前代码） `worker_lease.py` 已经实现了两阶段空闲驱逐：

- `WorkerLifecycleState.ACTIVE` / `WARM_STANDBY` / `COLD_EVICTED`。
- `WorkerIdleEvictor._last_active`：记录每个 worker 的最后活动时间。
- `WorkerLeaseLock`：带租约计数和代际号的互斥锁。

（推断） 这些组件为多会话并发提供了基础设施基础。`ResourceGovernor` 可以扩展为按会话计数而非按 worker 计数；`WorkerLeaseLock` 可以为每个会话提供独立的租约；`WorkerIdleEvictor` 可以扩展为按会话粒度管理生命周期。但这些扩展需要重新设计，当前实现是按 worker 粒度的。

---

## 目标设计方向

> 本节所有描述标记为（目标设计），是未实现的设计方向，不是当前代码状态。每个方向列出改动范围、并发上界、风险和回退成本，不给出唯一推荐。

### 方向 1：帧协议升级，worker 引擎改为多会话状态机

**核心思路**：在 worker 帧中携带 `session_id`，worker 引擎内部维护 `Map<session_id, SessionState>`，实现真正的多会话并发。

**改动范围**：
- `qwen3_worker` 模块：从单会话状态机升级为多会话状态机，维护每会话的音频缓冲、解码状态和输出队列。
- `qwen3_streaming.py`：`NativeRealtimeFactory` 移除 `_active` 槽位限制，改为维护 `Dict[session_id, Qwen3StreamingSession]`。
- `worker_protocol.py`：确认 `session_id` 字段在所有帧中的传递语义。
- `worker_process.py`：可能需要升级为多路复用传输层（如基于 `session_id` 的帧路由），或保持单锁但增加帧路由逻辑。

**并发上界**：受限于单进程内的 GIL 和模型推理的 chunking 粒度。Python 协程调度可以支持数十个并发会话，但实际吞吐取决于模型推理是否释放 GIL（MLX 推理通常释放 GIL）。

**风险**：
- worker 引擎侧改动最大，需要重新设计会话状态管理。
- GIL 竞争可能导致高并发下推理延迟增加。
- 帧路由逻辑的复杂性增加，调试难度上升。

**回退成本**：高。需要修改 worker 引擎的核心逻辑，测试覆盖要求高。

### 方向 2：保持单会话引擎，主进程维护每会话 worker 引用 + 信号量并发帽

**核心思路**：不修改 worker 引擎，而是在主进程侧维护每个会话的独立 worker 引用，通过信号量限制并发数，超出时返回 `backend_busy`。

**改动范围**：
- `qwen3_streaming.py`：`NativeRealtimeFactory` 改为维护 `Dict[session_id, Qwen3StreamingWorker]`，每个会话拥有独立的 worker 进程。
- `resource_governor.py`：扩展为按会话计数，增加 `max_realtime_sessions` 限制。
- `worker_lease.py`：为每个 worker 实例管理生命周期，支持按需创建和空闲驱逐。

**并发上界**：受限于 `max_realtime_sessions` 配置和系统资源（内存、CPU）。每个会话一个 worker 进程，内存占用线性增长。

**风险**：
- 每个会话一个 worker 进程，内存占用高（每个 worker 加载一次模型权重）。
- 进程创建和销毁的开销。
- 与"共享模型权重"的最佳实践相悖。

**回退成本**：中。worker 引擎不变，只需修改主进程侧的调度逻辑。

### 方向 3：中间方案 - 共享权重多引擎（engine-per-session in same process）

**核心思路**：在同一个 worker 进程内，为每个会话创建一个独立的模型实例（engine），权重通过共享内存或只读映射共享，避免重复加载。

**改动范围**：
- `qwen3_worker` 模块：支持多实例模式，每个实例独立维护解码状态，但共享模型权重。
- `qwen3_streaming.py`：`NativeRealtimeFactory` 维护每会话的 engine 引用。
- 模型加载逻辑：需要支持"权重只加载一次，多实例共享"的模式。

**并发上界**：受限于内存（每实例的解码状态占用）和 CPU/MPS 资源。

**风险**：
- 模型 SDK 可能不支持"多实例共享权重"的模式，需要深入调研 MLX/Qwen3 的 API。
- 实现复杂度高。
- 如果 SDK 不支持，需要自行实现权重共享机制，风险更大。

**回退成本**：高。需要修改模型加载和实例管理逻辑。

---

## 验收路径建议

如果未来决定实施多会话并发能力，建议按以下路径验收：

### 1. 多会话冒烟脚本

- 同时打开 N 个 WebSocket 连接，每个连接创建一个会话。
- 每个会话发送音频帧，验证转写结果正确且互不干扰。
- N 从 1 逐步增加到配置的上限，观察延迟和准确率变化。

### 2. 并发基准测试

- **RTF（Real-Time Factor）**：测量多会话并发下的端到端延迟。
- **内存峰值**：监控 worker 进程的物理内存占用，确认无泄漏。
- **并发上界**：找到延迟开始显著增加的并发数阈值。

### 3. 断连清理自动化测试

- 模拟客户端断连，验证会话状态是否正确回收。
- 模拟长时间空闲，验证 `WorkerIdleEvictor` 是否正确驱逐。
- 模拟突发断连（N 个会话同时断连），验证系统稳定性。

### 4. 错误语义

- 当前 `backend_busy` 错误码（`contracts/realtime-openai.md` 第 71 行）需要扩展为更细粒度的并发错误语义：
  - `backend_busy`：所有会话槽位已满。
  - `session_limit_reached`：达到配置的 `max_realtime_sessions` 上限。
  - `queue_full`：等待队列已满（由 `ResourceGovernor` 抛出）。

---

## 附：术语表

| 术语 | 说明 |
|---|---|
| **session** | 一个 WebSocket 连接上的 ASR/TTS 会话，由 `session_id` 唯一标识。 |
| **slot** | `NativeRealtimeFactory` 中的 `_active` 槽位，当前限制为 1，即单会话。 |
| **frame routing** | 根据帧中的 `session_id` 将音频帧路由到正确会话状态机的机制。 |
| **reserved capacity** | `ResourceGovernor` 中为 realtime 工作预留的容量（`realtime_reserved_capacity`）。 |
| **warm standby** | `WorkerLifecycleState.WARM_STANDBY`，worker 空闲但未驱逐，保留模型权重在内存中。 |
| **cold eviction** | `WorkerLifecycleState.COLD_EVICTED`，worker 被完全关闭，模型权重从内存中释放。 |

---

## 后续步骤

本文档是调研和差距分析的归档材料，不是实现计划。如果未来需要推进多会话并发能力，建议：

1. 基于本文档的差距分析，编写 ADR（参考 `docs/decisions/README.md` 的 ADR  convention）。
2. ADR 中明确选择哪个目标设计方向，并记录决策理由。
3. 实现前编写失败的契约测试，确保行为可验证。

本文档不替代 ADR，也不承诺任何实现时间表。
