# SpeechRail Worker Process Transport Refactor Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task-by-task, with a review checkpoint after each commit.

**Goal:** 让 Qwen3 ASR 与 Qwen3 TTS host adapter 共用一套有界的异步子进程、framed IPC 和终止实现，同时保留各自不同的 ready identity、请求/响应 schema、流式策略和错误映射。

**Architecture:** `runtime/worker_protocol.py` 提供可被同步 worker 与异步 host 共同复用的纯 frame codec；`runtime/worker_process.py` 只拥有受控环境、进程启动、读写 deadline 与 terminate/kill；`qwen3_native.py`、`qwen3_tts.py` 继续拥有 profile policy。共享层不理解 `transcribe`、`synthesize`、PCM、voice、model identity 或 public request ID。

**Tech Stack:** Python 3.12、asyncio subprocess、length-prefixed JSON、pytest、Ruff、mypy。

---

## 执行边界

- 工作目录：`/Users/hrygo/Documents/SpeechRail`
- 可在 app composition 计划之后执行；不得与其他任务同时修改 `qwen3_native.py` 或 `qwen3_tts.py`。
- 不改变 worker command、离线环境键、64 MiB frame 上限、单进程串行请求、2 秒 terminate→kill 收口或外部 Python/snapshot 配置。
- 不自动重启失败中的请求，不把旧 stdout frame 交给新请求，不记录 payload、PCM、文本、模型绝对路径或凭据。
- 私有 IPC 校验仍在 backend adapter；本计划不替代 public REST/Realtime 的二次校验。

## 目标文件

- Modify: `src/speechrail/runtime/worker_protocol.py`
- Create: `src/speechrail/runtime/worker_process.py`
- Modify: `src/speechrail/backends/qwen3_native.py`
- Modify: `src/speechrail/backends/qwen3_tts.py`
- Modify: `tests/test_worker_protocol.py`
- Create: `tests/test_worker_process.py`
- Create: `tests/fixtures/fake_framed_worker.py`
- Modify: `tests/test_qwen3_backend.py`
- Modify: `tests/test_qwen3_tts_worker.py`
- Modify: `tests/test_qwen3_tts.py`

## Task 1: 把 frame codec 拆成纯函数，保持同步 API

**Files:**

- Modify: `src/speechrail/runtime/worker_protocol.py`
- Modify: `tests/test_worker_protocol.py`

- [ ] **Step 1: 写纯 codec 失败测试**

覆盖 object round-trip、非 object JSON、空 body、超限 frame、非法 UTF-8、truncated header/body。现有 `read_frame`/`write_frame` 测试必须继续通过。

- [ ] **Step 2: 实现可复用 codec**

```python
def encode_frame(payload: Mapping[str, object]) -> bytes:
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if not 0 < len(body) <= MAX_FRAME_BYTES:
        raise ProtocolError("invalid worker frame size")
    return struct.pack(">I", len(body)) + body


def decode_frame_body(body: bytes) -> dict[str, object]:
    if not 0 < len(body) <= MAX_FRAME_BYTES:
        raise ProtocolError("invalid worker frame size")
    try:
        decoded = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProtocolError("invalid worker frame JSON") from exc
    if not isinstance(decoded, dict):
        raise ProtocolError("worker frame must be an object")
    return {str(key): value for key, value in decoded.items()}
```

`read_frame` 和 `write_frame` 改为调用纯函数，函数名、返回值和 flush 行为保持兼容。

- [ ] **Step 3: 运行并提交 codec**

```bash
uv run --extra dev pytest tests/test_worker_protocol.py -q --no-cov
uv run --extra dev ruff check src/speechrail/runtime/worker_protocol.py tests/test_worker_protocol.py
uv run --extra dev mypy src/speechrail/runtime/worker_protocol.py
git add src/speechrail/runtime/worker_protocol.py tests/test_worker_protocol.py
git commit -m "refactor: share speechrail worker frame codec"
```

## Task 2: 实现无 profile 语义的异步进程传输

**Files:**

- Create: `src/speechrail/runtime/worker_process.py`
- Create: `tests/test_worker_process.py`
- Create: `tests/fixtures/fake_framed_worker.py`

- [ ] **Step 1: 写真实 pipe 的失败测试**

fake worker 只实现 echo、malformed、hang、exit 四种私有测试动作；它不得导入模型 SDK 或访问网络。覆盖 start 幂等、未启动读写、读写 timeout、truncated frame、child exit、close 幂等、terminate 超时后 kill。

- [ ] **Step 2: 定义窄传输接口**

```python
@dataclass(frozen=True, slots=True)
class WorkerProcessSpec:
    command: tuple[str, ...]
    cwd: Path
    env: Mapping[str, str]
    io_timeout_seconds: float
    shutdown_timeout_seconds: float = 2.0


class AsyncFramedWorkerProcess:
    async def start(self) -> None: ...
    async def send(self, payload: Mapping[str, object]) -> None: ...
    async def receive(self) -> dict[str, object]: ...
    async def abort(self) -> None: ...
    async def close(self) -> None: ...
```

共享对象只启动一个显式 command，使用 `encode_frame`/`decode_frame_body`，对 stdin `drain()`、stdout `readexactly()` 和 `wait()` 设置 deadline。`abort()` 与 `close()` 都必须清空 process 引用后再终止旧对象，避免旧帧进入重启后的 process。

- [ ] **Step 3: 集中构造离线环境**

只继承 `PATH`、`TMPDIR`、`LANG`、`LC_ALL`，再设置当前已有的 `PYTHONPATH`、Hugging Face/Transformers/Datasets offline、MPS fallback 与 tokenizer 键。spec 不接收请求侧路径或任意 shell string；始终使用 `asyncio.create_subprocess_exec(*command)`。

- [ ] **Step 4: 运行红绿验证并提交**

```bash
uv run --extra dev pytest tests/test_worker_protocol.py tests/test_worker_process.py -q --no-cov
uv run --extra dev ruff check src/speechrail/runtime/worker_process.py tests/test_worker_process.py tests/fixtures/fake_framed_worker.py
uv run --extra dev mypy src/speechrail/runtime/worker_process.py
git add src/speechrail/runtime/worker_process.py tests/test_worker_process.py tests/fixtures/fake_framed_worker.py
git commit -m "refactor: add framed worker process transport"
```

## Task 3: 迁移 ASR adapter，保留单结果策略

**Files:**

- Modify: `src/speechrail/backends/qwen3_native.py`
- Modify: `tests/test_qwen3_backend.py`
- Modify: `tests/test_worker_process.py`

- [ ] **Step 1: 增加 ASR profile 保护测试**

断言 start payload 仍含 `model_dir/device`，ready 必须匹配 `device/dtype`，transcribe request 仍是 16 kHz mono PCM16、同一个 request ID，只接受单个 `result`，非法 text/language 仍映射为 `worker_result_invalid`。

- [ ] **Step 2: 用共享传输替换重复实现**

`Qwen3Worker` 保留自身 `_lock`、identity 与 `start()/transcribe()/close()`；删除本地 JSON/struct、环境和 terminate 代码，改为组合 `AsyncFramedWorkerProcess`。共享传输异常在 adapter 边界转换为当前稳定 `RuntimeError` code。

- [ ] **Step 3: 运行并提交 ASR 迁移**

```bash
uv run --extra dev pytest tests/test_worker_process.py tests/test_qwen3_backend.py tests/test_transcription_api.py -q --no-cov
uv run --extra dev ruff check src/speechrail/backends/qwen3_native.py tests/test_qwen3_backend.py
uv run --extra dev mypy src
git add src/speechrail/backends/qwen3_native.py tests/test_qwen3_backend.py tests/test_worker_process.py
git commit -m "refactor: migrate qwen asr worker transport"
```

## Task 4: 迁移 TTS adapter，保留流式与取消策略

**Files:**

- Modify: `src/speechrail/backends/qwen3_tts.py`
- Modify: `tests/test_qwen3_tts_worker.py`
- Modify: `tests/test_qwen3_tts.py`

- [ ] **Step 1: 增加 TTS profile 保护测试**

断言 ready 继续校验 `backend/device/dtype/sample_rate`；每个 synthesis 使用独立 response ID；只接受连续 `audio* → completed`；跨 request ID、非法 base64、奇数字节 PCM、gap/duplicate、consumer cancel 都会 abort 当前 process。

- [ ] **Step 2: 用共享传输替换进程 primitive**

`Qwen3TtsWorker` 继续拥有 async generator、`expected_chunk_index`、private response ID 与未完成流的 abort。共享层不得判断 `audio/completed/error`，不得把 ASR 单响应策略抽成基类模板。

- [ ] **Step 3: 运行并提交 TTS 迁移**

```bash
uv run --extra dev pytest tests/test_worker_process.py tests/test_qwen3_tts_worker.py tests/test_qwen3_tts.py tests/test_speech_api.py -q --no-cov
uv run --extra dev ruff check src/speechrail/backends/qwen3_tts.py tests/test_qwen3_tts_worker.py tests/test_qwen3_tts.py
uv run --extra dev mypy src
git add src/speechrail/backends/qwen3_tts.py tests/test_qwen3_tts_worker.py tests/test_qwen3_tts.py
git commit -m "refactor: migrate qwen tts worker transport"
```

## Task 5: 故障与项目门禁

- [ ] **Step 1: 运行 worker 故障矩阵**

```bash
uv run --extra dev pytest \
  tests/test_worker_protocol.py tests/test_worker_process.py \
  tests/test_qwen3_backend.py tests/test_qwen3_tts_worker.py tests/test_qwen3_tts.py \
  -q --no-cov
```

- [ ] **Step 2: 运行项目门禁**

```bash
uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
git diff --check
```

- [ ] **Step 3: 人工检查进程边界**

确认无 `shell=True`、无请求侧 command/env、无 payload 日志、无后台 orphan reader、无自动模型下载、无 ASR/TTS profile policy 进入共享层。

## 完成标准

- [ ] 同步 worker protocol API 保持兼容，新增 codec 被同步/异步路径共同使用。
- [ ] ASR/TTS adapter 不再复制 subprocess、frame read/write、离线环境和 terminate/kill。
- [ ] ASR 单结果与 TTS 流式/取消语义仍由各自 adapter 测试锁定。
- [ ] timeout、malformed frame、child exit 与 cancel 均无进程或 task 泄漏。
- [ ] 未启动真实模型、未修改公共契约或跨仓库文件。
