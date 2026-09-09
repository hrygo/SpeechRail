---
title: "有界音频处理与 OpenAI 兼容优化记录"
status: historical
date: 2026-09-05
---

# 有界音频处理与 OpenAI 兼容优化记录

目标：在现有单进程和外部 worker 架构内，减少可验证的复制与无效等待，修复资源回收和标准 multipart 参数处理。该文件记录本次开发过程，不代替正式契约和真实模型验收。

## 约束与方案

- Python `>=3.12,<3.13`，不新增运行时依赖，不改变 IPC wire format。
- 保持错误 envelope、请求 ID、模型别名及旧 multipart 字段可用。
- 不修改已有 7 个未提交文件，不修改配置、模型或本机服务运行态。
- 开发由 `luna_worker` 执行，每次限定一个原子任务；同一文件串行移交。
- 主 Agent 审查每项 diff，完成全套 pytest、ruff、mypy、OpenAPI lint 和差异检查。

选择修复已复现的局部问题；模型替换、量化调优、扩大队列或重构运行时没有本次收益证据，不纳入实施。

## 基线证据（2026-09-05）

- 相关 4 组测试：48 项通过（不加载真实模型）。
- aging 阈值设为 20 ms，batch lane 保持占用、预留 lane 空闲，80 ms 后等待请求仍未准入。
- multipart `timestamp_granularities[]=character` 配合 `verbose_json` 返回 HTTP 200，非法标准字段被忽略。
- `_decode_pcm` 修改前使用 `communicate()` 完整收集输出后才检查大小；只在超时时 kill，取消不清理。
- `_try_fast_decode_wav` 修改前先构造重采样数组再由调用方检查限额。
- 64 bytes、1 Hz、10 frames 的合成 WAV 在 1000 bytes 限额下拒绝前，预热 NumPy 后 Python 峰值分配仍为 3,209,081 bytes。
- 合成 30 秒 FLAC（518,290 bytes）在 64 KiB 解码限额下，旧实现仍读取全部 960,000 bytes PCM 才拒绝；单次 36.56 ms，Python 峰值分配 2,011,418 bytes。单次耗时仅作参考，最终比较需重复测量。
- `_read_exact` 对完整 8 MiB BytesIO 输入，7 轮各 10 次：中位耗时 0.2135 ms，范围 0.2069–0.3091 ms；tracemalloc 峰值 16,777,386 bytes。仅证明 Python 中间复制成本，不代表模型 RTF。

## 原子任务与验收

### A：同步 IPC 完整读取

所有权：`src/speechrail/runtime/worker_protocol.py`、`tests/test_worker_protocol.py`。

- [x] 先添加分片 header/body、正常 EOF、截断和二进制 round-trip 测试并验证失败（4 项红灯）。
- [x] 完整读取时直接返回首次 `read(size)` 的 bytes，只有短读时累积剩余片段并释放首块引用；header 区分干净 EOF 与截断。
- [x] 运行 `uv run --extra dev pytest tests/test_worker_protocol.py -q --no-cov`（18 项通过），重测同等输入的耗时和峰值分配。

主 Agent 独立比较基线 `b83175b` 与修改后的 `_read_exact`，使用 8 MiB 合成字节、7 轮各 10 次读取（热缓存），tracemalloc 单次读峰值：

| 场景 | 中位耗时：修改前 → 修改后 | 峰值分配：修改前 → 修改后 |
|---|---|---|
| BytesIO | 0.2453 → 0.0001 ms | 16,777,306 → 28 bytes |
| 临时文件 BufferedReader | 0.5376 → 0.2649 ms | 25,165,947 → 8,388,981 bytes |

文件读取耗时区间分别为 0.5065–0.5756 ms 和 0.2518–0.2891 ms；读取结果逐字节相同。BytesIO 的极小耗时来自复用原 bytes，不能当作真实 IPC 吞吐。子 Agent 另验首读 7 MiB / 尾读 1 MiB 的峰值均为 17,825,955 bytes，短读路径未增加峰值。

### B：aging 唤醒

所有权：`src/speechrail/runtime/resource_governor.py`、`tests/test_resource_governor.py`。

- [x] 添加无其他 release/notify 时到期准入的失败用例。
- [x] 仅队首未到期 batch waiter 使用剩余 aging 时间的有界等待；到期重算容量，满载或已到期时不忙轮询；准入后唤醒队列后继。
- [x] 验证 FIFO、总容量、实时预留、取消和 deadline 清理。
- [x] 运行 `uv run --extra dev pytest tests/test_resource_governor.py -q --no-cov`。子任务通过 13 项；主 Agent 独立复核 13 项通过（0.27 秒）。无通知和队首交接回归在修复前均以 `TimeoutError` 失败。

主 Agent 对相同 20 ms 阈值场景重复 7 次，实际准入中位 21.130 ms，范围 20.722–21.157 ms；此前 80 ms 仍未准入。该数字只衡量无外部通知时的准入等待，不代表推理加速。

### C：WAV 分配前限额

所有权：`src/speechrail/http/routes/audio.py` 的 WAV fastpath、`tests/test_audio_fast_decoder.py`。

- [x] 用极低采样率与小限额证明在 NumPy 分配前拒绝输出膨胀。
- [x] 从已验证的 PCM header/frame 数计算输出字节，向 fastpath 传递既有限额；保留超限错误语义。
- [x] 验证正常采样率、立体声、边界大小、非法 header。
- [x] 运行 `uv run --extra dev pytest tests/test_audio_fast_decoder.py tests/test_transcription_api.py -q --no-cov`（33 项通过）。主 Agent 联同 IPC 回归验证 51 项通过。

相同 64 bytes、1 Hz WAV 和 1000 bytes 输出上限，主 Agent 实测拒绝路径峰值从 3,209,081 降至 11,473 bytes；错误仍为 `audio_too_large`。这是分配前拒绝的收益，不衡量正常模型常驻内存。

### D：ffmpeg 有界输出及回收（C 完成后）

所有权：`src/speechrail/http/routes/audio.py` 的 `_decode_pcm`、`_encode_container`；新建 `tests/test_audio_subprocess.py`。

- [x] 测试超限时提前停止读取、精确边界、超时和取消回收，验证原实现失败。主 Agent 在独立进程中加载旧源码，复跑超限/取消两个新回归，分别因未 kill、未 reap 失败；测试兜底清理了自建进程，工作树未回退。
- [x] 并发写 stdin、分块读 stdout，读取上限含探测字节；异常路径终止进程、排空管道并回收输入任务。
- [x] TTS 编码补相同的有界生命周期，不引入可配置新公共接口。
- [x] 相关测试纳入最终全量验证；主 Agent 独立运行新增 `tests/test_audio_subprocess.py`，12 项通过。测试观察捕获的 Process 对象确认回收，不由断言自身调用 `waitpid` 代替实现回收。

主 Agent 对同一个 30 秒合成 FLAC 交替执行旧/新实现，各 7 次，限额为 64 KiB：

| 指标 | 修改前 | 修改后 |
|---|---|---|
| 拒绝耗时中位数 | 37.714 ms | 20.489 ms |
| 耗时范围 | 36.450–38.188 ms | 19.912–22.335 ms |
| Python 峰值分配中位数 | 2,007,963 bytes | 497,221 bytes |
| 结果 | `audio_too_large` | `audio_too_large` |

相同音频不设置低限额，7 次正常解码中位数为 37.016 → 36.825 ms，差异在噪声内；两版 960,000 bytes PCM 逐字节相同，不宣称正常解码加速。
另以独立合成子进程验证：stdout 背压时 `kill` 后直接 `wait` 仍会等待；排空 262,144 bytes 后可回收。这是异常清理需要排空管道的实际依据。

### E：标准 multipart timestamp 字段（D 完成后）

所有权：`src/speechrail/http/routes/audio.py` 的 transcription 参数处理；新建 `tests/test_openai_multipart.py`；`contracts/openapi.yaml`。

- [x] 用标准 `timestamp_granularities[]` 的 word-only、非法值、缺少 verbose_json 测试复现问题。独立 E1 子任务先仅增加测试：9 项中 6 失败、3 通过，确认标准字段被忽略。
- [x] 同时接受标准与旧字段，混用时合并后验证；不放过任何一侧非法值。E2 先产出 7 行源码补丁，由主 Agent 在 D 交接后应用，避免同文件并行写入。
- [x] 用多字段 multipart 验证重复值和双粒度请求，同步 OpenAPI 表单描述；修正 verbose 响应 schema 强制同时要求 `segments` 和 `words` 的矛盾，并验证单粒度响应符合 schema。
- [x] 主 Agent 验证 multipart 12 项通过，转写接口同时纳入全量运行。最终整合移除了测试新增的弃用 RefResolver 用法，使用根 schema 内部引用。

标准依据：[OpenAI File transcription — Timestamps](https://developers.openai.com/api/docs/guides/speech-to-text#timestamps)，2026-09-05 核验。

## 首轮既有问题与运行边界

- 修改前全局 ruff 有 1 处错误：用户已有改动 `src/speechrail/backends/qwen3_worker.py:589`，`E501`。
- 修改前全局 mypy 有 2 处错误：同文件第 620、621 行，`call-overload`（`int(object)`）。本任务不覆盖这些并行改动。
- 09:01 CST 只读核验：`127.0.0.1:8201` 的 `/health`、`/readyz`、`/v1/models`、`/v1/voices` 均 HTTP 200；现有服务报告 1.6.7、ASR/TTS/diarization ready。此状态不是本次源码优化的部署验收。

## 首轮最终验证与回退

- [x] 审查所有变更，执行完整代码 gate，核对既有未提交文件哈希。
- [x] 用相同合成输入重测性能、资源边界和等待行为；健康端点只证明现有运行版本状态。
- [x] 将实测结果、真实模型/客户端未验证范围写入本记录和交接。

主 Agent 最终验收（2026-09-05，分支 `perf/bounded-audio-compat`，未提交）：

| 检查 | 退出码 | 实测 |
|---|---|---|
| `uv run --extra dev pytest -o addopts='--strict-markers --cov=src --cov-report=term-missing' -q` | 0 | 439 passed，9.53 秒；覆盖率 85.24%，高于 80% 门槛 |
| `uv run --extra dev ruff check src tests` | 1 | 仅原有 `qwen3_worker.py:589` 的 E501 |
| `uv run --extra dev mypy src` | 1 | 仅原有 `qwen3_worker.py:620,621` 的两个 call-overload |
| 本次 3 个源码及 5 个测试文件的定向 ruff | 0 | 全部通过 |
| 本次 3 个源码文件的定向 mypy | 0 | 无类型错误 |
| `npx --no-install @redocly/cli lint contracts/openapi.yaml` | 0 | OpenAPI valid |
| `git diff --check`、受影响文档本地链接检查 | 0 | 无差异格式错误或失效本地链接 |
| 开始时 7 个未提交文件的 SHA-256 对照 | 0 | 全部保持原样 |

全局门禁未全绿，原因是开始时已存在的并行改动错误；本次没有屏蔽或修改这些错误。
测试仍有一条已有 Starlette/httpx 弃用警告，没有新增依赖或以升级依赖消除警告。

09:46 CST 再次只读核验：现有 1.6.7 服务四个健康/清单端点均 HTTP 200，13 个模型条目、4 个可用 voice；
ASR/TTS/diarization ready。本次没有重启、部署或发布。健康响应未提供设备/dtype，未另外读取私有配置。
新版本真实 ASR/TTS 模型质量、RTF、常驻 RSS、长会话和实际 OpenAI SDK/客户端仍未验收；上述资源数字仅是合成输入的 Python 分配，不能外推为模型内存降低或端到端推理加速。

回退：逐个撤销本次新增文件和修改 hunk；不使用整树 reset，不删除或覆盖原有未提交改动、配置和外部模型。本次不发布、不部署，不需要切换线上 runtime。

## 追加任务：Qwen3 worker 问题修复

用户随后明确要求解决 `qwen3_worker.py` 的全部已发现问题，授权扩展到该文件及对应测试；
保留原有分段合并功能和其他未提交改动。以上首轮门禁结果保留为历史实测，不代表追加任务的最终状态。

采用 `luna_worker` 执行小任务，同一源码文件串行写入，主 Agent 负责复现、整合和完整门禁：

1. 分段边界：修复静态检查、无效时间戳、20 ms 最小时长及英文空格导致的 40 字符合并越界。
2. 会话隔离：修复开会话参数转换及 commit 对齐异常逃逸，确保终结清理局限于当前会话；损坏启动帧使用稳定错误。
3. 独立复核剩余批量输入、模型适配与资源边界，只修复有代码或回归证据的问题。

实现前已实测：`chunk_sec="bad"`、`right_context_ms=Infinity` 和对齐异常均会逃逸 `serve`；
损坏启动 header/JSON 会直接抛出 `ProtocolError`。这些复现只使用内存 IPC 和 fake engine，不加载模型。

独立复核确认批量限额仍不一致：worker 的 `40 MiB` 只容纳约 `1310.72` 秒 PCM，
而 `max_audio_seconds=3600` 需要 `115,200,000` bytes，当前 `128 MiB` IPC 和配置校验允许该大小。
修复将 batch 限额与 IPC 的 `4096` bytes 预留规则对齐，实时 append 和每会话对齐缓存继续保持 `40 MiB`。
容量契约使用纯算术及缩小限额的测试验证，避免为了边界测试分配百 MiB 音频。

分段子任务已验证：新增回归修复前 `4 failed, 19 passed`；修复后 worker/IPC 共 `41 passed`，
定向 ruff 和全仓库 mypy（58 个源文件）通过。

会话隔离子任务交付 24 项通过的回归，覆盖非法参数后新会话仍可打开、finish/alignment 失败不影响其他会话、
终结释放缓存和损坏首帧不加载模型。主 Agent 整合时补充 3 项整数边界回归，复现
`right_context_ms=-0.5`、`right_context_ms=1.5`、`max_new_tokens=1.5` 被截断放行；
修复后整数选项拒绝非整数浮点数，保留整数和整数字符串的精度。

追加任务最终验收（2026-09-05 10:09 CST，未提交、未部署）：

| 检查 | 退出码 | 实测 |
|---|---|---|
| `uv run --extra dev pytest -o addopts='--strict-markers --cov=src --cov-report=term-missing' -q` | 0 | 476 passed，9.35 秒；覆盖率 85.71% |
| `uv run --extra dev ruff check src tests` | 0 | All checks passed |
| `uv run --extra dev mypy src` | 0 | 58 个源文件无类型错误 |
| `npx --no-install @redocly/cli lint contracts/openapi.yaml` | 0 | OpenAPI valid |
| `git diff --check` | 0 | 无差异格式错误 |
| 原有另外 5 个改动文件 SHA-256 对照 | 0 | 配置示例、config、Realtime 路由及其测试保持原样 |

首轮的 1 个 ruff 和 2 个 mypy 阻塞现已解决。测试仍有原有 Starlette/httpx 弃用警告；
mypy 提示可选依赖配置段当前未使用，没有类型错误。

10:09 CST 只读复核：`http://127.0.0.1:8201` 的 `/health`、`/readyz`、`/v1/models`、
`/v1/voices` 全部 HTTP 200；现有服务仍为 1.6.7，ASR/TTS/diarization ready，13 个模型、4 个 voice。
此运行态未包含本次部署验收；未读取私有配置，未核验实际设备/dtype，也未执行新代码的真实模型、
长音频、RTF/RSS 或实际客户端 smoke。容量测试验证输入边界一致性，不证明长音频推理质量或性能。

追加任务只修改 Qwen3 worker、对应测试和本记录/CHANGELOG。回退时保留原有分段合并等改动，
逐项撤销本次校验、隔离和 batch 限额 hunk 及新增测试；不覆盖整个文件，不改变现有服务或外部模型/配置。
