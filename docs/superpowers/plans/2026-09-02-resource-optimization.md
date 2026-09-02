# SpeechRail 低开销资源优化实施计划

> 设计文档：[`docs/superpowers/specs/2026-09-02-resource-optimization-design.md`](../specs/2026-09-02-resource-optimization-design.md)  
> 目标：实施 ASR Worker 统一、生命周期动态回收、MLX 显存治理与 INT8 量化支持。

---

## 阶段规划与交付物

### Phase 1：架构整合与 MLX 显存治理（0% 品质损失）

- [x] **Task 1.1：统一 ASR Worker 协议与进程**
  - 在 `src/speechrail/backends/qwen3_worker.py` 中增加流式支持（实现 `init_streaming`、`feed_audio`、`finish_streaming` 及帧命令）。
  - 更新 `src/speechrail/backends/qwen3_native.py`，增加对流式调用的 Python 封装。
  - 重构 `qwen3_streaming.py`，使 `NativeRealtimeFactory` 与 `Qwen3StreamingSession` 基于 `StreamingWorkerProtocol` 直接复用统一的 `Qwen3Worker`。
- [x] **Task 1.2：MLX Metal 显存缓存清理与上限配置**
  - 在 `Qwen3Worker` 与 `Qwen3TtsWorker` 中增加 `_clear_metal_cache()` 显式内存释放机制。
- [x] **Task 1.3：服务装配与回归测试**
  - 更新 `src/speechrail/application/services.py` 中的 `build_app_services`，移除对独立 streaming worker 的重复实例化。
  - 运行 `pytest tests/` 验证非流式 ASR、流式 Realtime 及 TTS 全部测试通过。

### Phase 2：Worker 生命周期治理（惰性加载 + 空闲回收，0% 品质损失）

- [x] **Task 2.1：Worker 动态租约与生命周期管理器 (`WorkerIdleEvictor`)**
  - 在 `src/speechrail/runtime/worker_lease.py` 中实现 `WorkerIdleEvictor`。
  - 支持后台巡检 `idle_timeout`，超时自动异步关闭 Worker。
- [x] **Task 2.2：配置项扩展**
  - 在 `src/speechrail/config/__init__.py` 中新增：
    - `worker_idle_timeout_seconds: float = 300.0`
    - `worker_lazy_load: bool = False`
    - `dtype: Literal["float16", "float32", "int8"] = "float16"`
  - 同步更新 `configs/speechrail.example.env`。
- [x] **Task 2.3：单元与集成验证**
  - 编写生命周期模拟测试（`tests/test_worker_lease.py`），验证冷启动加载、请求加锁预热、超时卸载与再次唤醒行为。

### Phase 3：模型 8-bit (INT8) 量化支持（品质损失 ≤ 1.2%）

- [x] **Task 3.1：ASR 与 TTS 8-bit 配置支持**
  - 在 Worker 启动参数中透传 `--dtype int8`。
  - 在 `Qwen3BackendConfig` 与 `Qwen3TtsBackendConfig` 中支持 `dtype="int8"` 校验与加载。
- [x] **Task 3.2：文档与用户指南更新**
  - 更新 `docs/operations/runtime-deployment.md` 与 `README.md` 中的模型量化配置说明与显存推荐表。

---

## 验证与验收指令

```bash
# 1. 自动化回归测试
uv run --extra dev pytest tests/ -q --no-cov

# 2. 真实模型 smoke 验证
curl http://127.0.0.1:8201/health
curl http://127.0.0.1:8201/readyz
curl http://127.0.0.1:8201/v1/models
```
