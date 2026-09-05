# SpeechRail 三档模型与统一运行时 Implementation Plan

> **For agentic workers:** 按用户指定的 `luna_worker` 逐项执行；每个原子任务完成后由主 Agent 审查。
> 执行时使用当前可用的 `executing-plans`、测试和验证技能；不依赖本环境未提供的
> `superpowers:subagent-driven-development`。各任务采用 checkbox 跟踪。
> 本文只完成计划交付，未执行开发、下载、加载、安装或服务切换。

**Goal:** 在统一 MLX 架构下提供 quality/balanced/light 三档，保留本机质量路径，并以 M1 Air 8GB 验收 light。
**Architecture:** 一个 FastAPI 主进程、一个共享 ASR worker、一个 TTS worker；Batch/Streaming ASR 互斥。
档位仅引用权重/量化。安装器准备制品，服务内统一运行时负责有界推理与可恢复换模。
**Tech Stack:** Python >=3.12,<3.13、uv、FastAPI、Pydantic、MLX、mlx-qwen3-asr、mlx-audio、ffmpeg、macOS LaunchAgent。
**Spec:** [用户已采纳的设计](2026-09-05-low-memory-mac-architecture-proposal.md)。
**Decision:** [ADR-0011](../../decisions/0011-unified-runtime-model-tiers.md)。
**状态:** 计划就绪，待执行。日期：2026-09-05。代码勘察基线：`001e744`（v1.6.8）。
本计划新增的接口、命令、文件均是目标设计，不代表当前代码已存在。

## 1. Global Constraints

- 三档默认：quality=ASR 1.7B 8-bit + TTS 1.7B VoiceDesign 8-bit；
  balanced=ASR 1.7B 8-bit + TTS 0.6B CustomVoice 8-bit；
  light=ASR 0.6B 8-bit + TTS 0.6B CustomVoice 8-bit。
- light 的 0.6B TTS 4-bit 只作对照候选；通过共同质量门和资源收益门才能替换 light 制品版本。
- 分档不改变依赖、进程结构、VAD、上下文、chunk、并发、缓存、调度、温度或其他生成参数。
- Batch ASR 与 Streaming ASR 不同时工作；ASR/TTS 重叠和多 Realtime 会话另验收，不删除既有会话隔离。
- 本机当前权重/音色/已启用能力保留；未知配置、.env、模型、日志和并行改动不得覆盖或清理。
- 主服务一次一个 ASGI worker；vendor runtime 在仓库外隔离环境；不能把两份 ASR 模型换成两份 Session。
- 模型请求离线；下载与依赖安装只在操作者显式应用方案时进行。不会在服务启动或 inference 中自动下载。
- 只保证已有 ASR/TTS 公共子集；不捆绑 OpenAI Realtime 采样率迁移、LLM、声音克隆、数据库和播放器。
- 档位选择不启停 diarization/jobs/LAN 等独立能力；现有配置未纳入三档的称为“当前自定义方案”，不构成第四预设。
- docs/archive/ 记录目标与过程，不能作当前功能已实现的证据。运行态操作由后续明确执行授权约束。
- 所有开发任务先写可观察行为的失败测试，再实现；模型测试默认 fake，不下载真实模型。
- 每个修改可回退到上一 release；未过 M1 门不能标注 light 已支持，不能临时抬高 4GiB 门槛。

## 2. 已核对的代码落点

图项目 `Users-hrygo-Documents-SpeechRail`，Tier 2，generation `2026-09-05T02:54:54Z`。
对下表主要实现路径调用了 check_index_coverage：metadata_match/no_recorded_issue。
这只是 best-effort 覆盖；未对整个仓库作穷尽审计。执行每张任务卡前按当时 HEAD 重新核对。

| 当前路径/符号 | 当前事实 | 对应任务 |
|---|---|---|
| src/speechrail/application/services.py: build_app_services | 分别构造 Qwen3Worker 与 Qwen3StreamingWorker；AppServices frozen | R03/R04/S04 |
| src/speechrail/backends/qwen3_native.py: Qwen3Worker | Batch 使用 exchange；结果中有固定 1.7B model_id | R03/M02 |
| src/speechrail/backends/qwen3_streaming.py: Qwen3StreamingWorker | 独立 transport/dispatcher；session 队列目前未设 maxsize | R02/R03 |
| src/speechrail/backends/qwen3_worker.py: Qwen3Engine | 一个底层 Session 已支持 batch 与 streaming；align buffer 按会话保存 | R05/A03 |
| src/speechrail/backends/qwen3_tts_worker.py: MlxVoiceDesignEngine | 拒绝非 voice_design；预量化统一报 int8 | M02/T02 |
| src/speechrail/domain/tts.py | 四个公共 voice ID、aliases、归一化和分句器 | T01/T03 |
| src/speechrail/http/routes/audio.py | 有界但整段 upload/decode；PCM TTS 流式，其他格式积累整段 PCM | A01/A02/A04/T03 |
| src/speechrail/config/__init__.py | 路径来自 env；dtype 与 IPC 整段时长限制耦合 | M04/A04 |
| src/speechrail/config/profiles.py | 现有 RuntimeProfile 是能力模型，不能直接塞档位调度配置 | M03 |
| src/speechrail/runtime/worker_lease.py + application/lifecycle.py | 生命周期分别列 ASR/streaming；需按物理 owner 去重 | R04 |
| src/speechrail/runtime/resource_governor.py | 现有按 realtime/batch 保留容量和 aging | R06 |
| src/speechrail/service/preflight.py | 检查 .env、runtime 导入和快照；不证明真实音频质量 | M04/P02 |
| tools/install_macos.py + service/paths.py | 已有 release/current 安装结构，环境和模型仍需外部准备 | P02/P03 |
| src/speechrail/cli.py | 当前只有 serve/service，尚无 setup/profile 命令 | U01 |
| contracts/openapi.yaml + contracts/realtime-openai.md | 四 voice ID、aliases、统一错误；输入 PCM 现行约束须保持 | T01/C01 |

结构查询已从 build_app_services 双向 trace 深度 1 取得 23 个下游/1 个非测试上游，
并读取相关 worker、TTS、decoder、preflight 和安装函数；无分页遗漏。
测试路径由文件清单定位，新的测试名是任务所需新增测试，不声称当前存在。
`src/speechrail/audio.py` 不存在，音频实现实际在 `http/routes/audio.py`，任务不得创建平行重复入口。

## 3. 数据与控制接口先冻结

### 3.1 目录与制品

新增发布数据放入 `src/speechrail/assets/`，随 wheel 打包：
`model-catalog.json`、`runtime-lock.json`、受许可的最小 synthetic smoke 制品。
初期普通单元测试自带 tiny fake catalog；生产目录必须由 M01 的核对结果生成，不能留空哈希或 latest/main 引用。

仓库外布局复用 ServiceLayout.app_home：
```text
config/.env                      现有私有配置，原样保留
config/selection.json             成功生效的制品选择，0600
config/selection.previous.json    上次成功选择，0600
state/profile-transaction.json   不含音频/凭据的换模日志，0600
state/control.sock               同用户 Unix socket，0600，目录0700
models/<artifact-key>/            已校验权重及附属文件
models/.staging/<operation-id>/   未完成下载，不可作为加载路径
vendor/<runtime-lock-id>/asr/     全档共同 ASR runtime
vendor/<runtime-lock-id>/tts/     全档共同 TTS runtime
runtime/releases/                现有主服务版本目录
runtime/current                  现有 release 指针
```

模型目录不得以可变 alias 当内容身份。相同文件可复用可信 cache，但不假定所有 snapshot
格式能互换，不默认复制仓库外未知用户目录；文件大小与哈希通过后才登记。

### 3.2 Python 目标接口

下列类型是相邻任务的共享合同，按卡片逐步创建，非一次性大重构。

```python
# config/model_catalog.py
# 全部 Pydantic 模型 frozen=True, extra="forbid"。
# ArtifactFile: path:str, size:int, sha256:str
# QuantizationSpec: bits:int|None, group_size:int|None, format:str
# ModelArtifact: key:str, model_id:str, revision:str, family:str,
#   variant:str, quantization:QuantizationSpec, files:tuple[ArtifactFile,...]
# ModelPreset: id:Literal["quality","balanced","light"], asr:str, tts:str
#   asr/tts 是 ModelArtifact.key；没有其他可改变执行行为的字段。
# RuntimeLock: id:str, python:str, asr_requirements:tuple[str,...],
#   tts_requirements:tuple[str,...], ffmpeg_artifact:str, file_hashes:dict[str,str]
# Artifact 的下载源记录单列 SourceLocation(provider, repository, revision)。
# 同制品镜像必须对应同一 files 哈希集合，不能因回退来源而换版本。

# backends/model_identity.py
def inspect_model(model_dir: Path) -> SnapshotIdentity: ...
# SnapshotIdentity仅含本地可验证的family/variant/quantization/weight_fingerprint，
# 不从config猜远端revision；远端身份由已校验catalog/model-store登记提供。
def verify_loaded_identity(expected: ModelArtifact, actual: dict[str, object]) -> None: ...

# config/selection.py
def resolve_selection(settings: Settings, selection: dict[str, object] | None,
                      catalog: dict[str, ModelArtifact], app_home: Path) -> Settings: ...
# 仅 overlay 模型目录/模型实际身份/必要量化信息；共同 vendor 路径在 bootstrap 后解析。
# selection.json固定字段：schema_version=1、preset、generation、asr、tts、runtime_lock_id；
# 其中asr/tts是已校验artifact key。路径从model store解析，不从客户端输入读取。
# 不改写现有 host、port、key、aliases、音色用户选择、可选能力或共同推理参数。

# runtime/asr_mode.py
class AsrModeGate:
    # 同步原子状态变更，由 asyncio 主线程调用；没有阻塞等待或 I/O。
    def acquire(self, mode: Literal["batch", "streaming"]) -> AsrModeLease: ...
    def release(self, token: AsrModeLease) -> None: ...
# 同模式 streaming 可持有多 token，数量仍由现有 session cap 限定；
# batch 排他。异模式/重复 batch acquire 抛 AsrModeBusy。
# AsrModeLease 是本gate签发的对象，内含已释放状态；重复释放幂等，其他gate token拒绝。
# 不保存无限增长的已释放字符串集合。

# backends/qwen3_shared.py
class Qwen3SharedWorker:
    async def start(self) -> None: ...
    async def request(self, frame: Mapping[str, object], binary: bytes | None = None
                      ) -> dict[str, object]: ...
    def register_session(self, session_id: str) -> asyncio.Queue[dict[str, object]]: ...
    def unregister_session(self, session_id: str) -> None: ...
    async def send(self, frame: Mapping[str, object], binary_payload: bytes | None = None) -> None: ...
    async def close(self) -> None: ...
# 所有 receive 归 owner；alive/timeout_seconds/last_active/trim_memory 延续当前协议。

# application/audio_stream.py
@dataclass(frozen=True)
class PcmBlock:
    start_sample: int
    pcm: bytes
    core_start_sample: int
    core_end_sample: int

async def decode_upload(file: UploadFile, *, max_upload_bytes: int,
                        max_audio_seconds: int) -> AsyncIterator[bytes]: ...
def split_pcm(pcm: bytes, *, window_samples: int, overlap_samples: int
              ) -> tuple[PcmBlock, ...]: ...
# split_pcm 为小片段的纯函数；生产滚动 splitter 累积 <=window+overlap，
# 不把完整上传变成 bytes 再调用此函数。

# application/managed_runtime.py
class ManagedRuntime:
    # 满足现有 BatchTranscriber / SpeechSynthesizer / RealtimeAsrFactory 端口；
    # 返回的会话/音频迭代器持有活动 generation 的租约直到完成/close。
    async def drain(self, *, deadline_seconds: float) -> str: ...
    async def resume(self, drain_token: str) -> None: ...
    async def activate(self, prepared_id: str, *, drain_token: str) -> None: ...
    def status(self) -> dict[str, object]: ...
# drain 到期只取消切换并恢复准入，不终止有效工作。
# activate 内先关闭旧模型进程，再串行加载新 ASR/TTS，失败恢复旧组合。

# service/model_store.py
async def prepare_models(preset_id: str, *, app_home: Path,
                         progress: Callable[[dict[str, object]], None]) -> str: ...
# 返回已校验 prepared_id，服务只接受该登记 ID，拒绝控制请求提供任意路径/URL。

# service/profile_store.py
def recover_selection(app_home: Path) -> dict[str, object] | None: ...
# 有未完成事务时只返回 last-known-good，不把 candidate 冒充 active。
```

这些签名中的 Path、Literal、Mapping、Callable、AsyncIterator、dataclass、asyncio、
Settings、UploadFile 均使用标准库或现有依赖的准确导入。实现任务必须补齐类型与错误类型，
不可在公共 domain 导入 MLX、Qwen 或安装 SDK。目录 JSON 的元数据与音色能力从 artifact 派生，
不会成为可随意切换的模型执行参数。

### 3.3 模式、换模和故障状态机

```text
ASR: idle -> batch -> idle
     idle -> streaming(n) -> idle
     batch 与 streaming(n) 互斥；不同请求冲突明确返回 busy，不后台预加载另一模型。

切档: PREPARING -> VERIFIED -> DRAINING -> ACTIVATING -> SMOKING -> COMMITTED
      PREPARING/VERIFIED 失败：旧服务不变
      DRAINING 取消/到期：恢复旧准入
      ACTIVATING/SMOKING 失败：ROLLING_BACK -> 上次成功组合
      回退也失败：NOT_READY，保留所有文件与诊断，禁止自动重试循环
```

- 下载在 CLI/setup 进程，服务控制 socket 无下载/安装动作。私有控制协议只允许
  status、drain、resume、activate(prepared_id)、operation_status(operation_id)。
- socket 请求长度 <=64KiB，单个控制操作，operation_id 幂等；prepared_id 必须解析到可信
  model store 内的完整校验登记。拒绝路径穿越、symlink 逃逸、未知 command 和任意命令执行。
- journal 每步原子 write+fsync+replace；COMMITTED 前 selection.json 不变，保留 previous。
  主进程意外退出后，重启按 last-known-good 恢复，未完成 candidate 不自动续推理。
- UI/CLI 在 activation 开始后退出，事务仍由服务完成或回退；drain token 有有限有效期，
  未进入 activation 的失联调用方不能永久停住服务。
- 生命周期与 IdleEvictor 对物理 owner 去重。drain/activation 期间禁止 idle eviction 干预。
- 启动成功要求 loaded identity、vendor import 与离线 smoke，不只看 readyz=200。
- 切换期间 /health 仍存活，/readyz=503；新推理返回现有形状的 503 backend_not_ready。
  正常模式冲突用 REST 429 backend_busy / WS error backend_busy，契约同步明示。
- 日志只保留 operation/request ID、阶段、错误码、计量值、模型公开 ID，不记录正文、音频、
  Base64、完整 prompt、私有绝对模型路径或 Authorization。

## 4. 执行顺序与并行规则

主 Agent 保留总体设计、接口冻结、冲突决策和最终验收责任。只用当前可用 `luna_worker`；
一次派发一张任务卡，不派发“实现整个 ASR/TTS/安装器”。每卡 1 个可拒绝/可验收的结果，
通常 20–60 分钟；每个 checkbox 是约 2–5 分钟的单一动作，超过边界先拆卡而不扩大所有权。

| 波次 | 任务 | 依赖与并行约束 | 退出门 |
|---|---|---|---|
| 0 | M01、B01 | 制品核对与基准计量可独立；模型加载/实机压测串行 | G0：制品与基线方法冻结 |
| 1 | M03→M02→M04；T01→T02 | M02/T02 都修改 TTS worker，必须串行；schema 冻结后才实现消费者 | 静态目录与两种 TTS fake 回归 |
| 2 | R01→R02→R03→R04→R05→R06 | qwen3_native/streaming/worker/services 每次仅一位 writer | 共享实例与恢复 G1a |
| 3 | A01→A02→A03→A04；T03→T04 | A04/T04 都改 audio.py，必须串行；R05/A03 不同时写 worker | 有界音频与取消 G1b |
| 4 | B02 | 同一测试设备仅一轮基准；不与任何真实模型任务重叠 | G2：模型/质量/资源可行性 |
| 5 | P01→P02→P03；S01→S02→S03→S04→S05 | P01 与 S01 可并行；S02/R04/S04 必须串行；同一 app_home 只一操作者 | 事务与安装故障矩阵 |
| 6 | U01→U02→C01→C02→V01 | CLI/契约/正式文档集成依次；不得边改边跑最终基准 | G3：发布和用户路径验收 |

总计 33 张原子任务卡。G2 未通过时仍可继续安装器/事务的 fake 开发；真实 light 推广受阻。本机已验证的共享 ASR/稳定性改动可独立交付，
但完整三档发布保持未完成；不得把配置存在当作 light 可用。

委派模板：
```text
角色：luna_worker。任务：<卡片ID与唯一结果>。
输入：本计划卡片、已采纳设计、依赖任务已通过的提交与接口。
只可写：卡片列出的实现和测试路径；其他文件只读。
你不是唯一写入者，不要回退他人的改动；接口冲突先报告主 Agent。
图证据：Tier 2；项目/当前 generation、qualified symbols、coverage 与已读遗漏范围随任务提供。
验收：卡片失败测试→实现→针对性通过，报告命令/测试数量/未验证项与差异。
禁止：模型下载/加载、service 操作、扩大依赖、修改 .env、提交外部数据，除非该卡有另行明确授权。
完成后等待主 Agent 审查，不自行领取下一模块或创建新用户任务。
```

## 5. 原子任务卡

每卡先更新图/源码位置，再执行红绿测试。命令在项目根目录执行；新模块在该卡创建。
下面代码块给出必须落地的行为种子，不能只做 import smoke 或复制实现断言。
fake helper 在其所属测试文件定义；同一进程假对象需提供当前 port 的全部必要方法。

### M01：冻结模型制品与共同运行时清单

**依赖：** 无。
**所有权 / Files：** 新建 tools/build_model_catalog.py、tests/test_model_catalog_builder.py；产出 src/speechrail/assets/model-catalog.json、runtime-lock.json。
**接口 / Inputs & Outputs：** 输入设计中的五个候选制品（含 light TTS 4-bit）；输出 revision、逐文件 size/SHA-256、量化与共同 runtime lock。生产清单由本任务生成，不使用手写猜测哈希。

- [x] **1. 写失败测试。** 在 `tests/test_model_catalog_builder.py` 落地以下行为，并补充本卡额外边界：

```python
from tools.build_model_catalog import require_immutable_revision
import pytest

def test_mutable_revision_cannot_ship():
    with pytest.raises(ValueError, match="immutable"):
        require_immutable_revision("main")
```

- [x] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_model_catalog_builder.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [x] **3. 最小实现。** 先读取当前可用 runtime 的非敏感包版本，再在发布准备环境解析同一 Python 3.12 的 ASR/TTS 锁定依赖；保留现有已验证 runtime 为回退。ModelScope 优先逐制品核对，来源不足时记录具体差异再回退转换维护者仓库。revision 必须 immutable，codec/tokenizer 必须全列；远程元数据不足以确认哈希时标记 release gate 未过并在获准制品准备后补实算。build_catalog(entries) 拒绝可变 revision、重复路径和缺哈希；只在目录全通过时写生产文件。
- [x] **4. 边界验证。** 拒绝 latest/tag-only、同名不同哈希镜像、缺 speech_tokenizer、运行时 lock 未含全部传递依赖。真实源制品数据必须核实，不以 fake fixture 通过代替生产目录完整。
- [x] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [x] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `docs: freeze reproducible three-tier artifacts`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。（已验收：commit `f040bd0` / `a52b810`，18 项测试通过）


### B01：建立真实基准口径与脱敏结果结构

**依赖：** 无；真实基线前先读 benchmark skill。
**所有权 / Files：** 新建 examples/perf/profile_metrics.py、tests/test_profile_metrics.py；修改 examples/perf/sample_resources.py、examples/perf/bench_tts.py（若超过所有权窗口分成同卡两个顺序步骤）。
**接口 / Inputs & Outputs：** 新增 rtf(elapsed_seconds, audio_seconds)->float；simultaneous_peak(samples:list[dict[int,int]])->int。结果字段固定 commit/runtime_lock/artifact_revision/hardware/phase/actual_audio_seconds/ttfa/rtf/phys_footprint。

- [x] **1. 写失败测试。** 在 `tests/test_profile_metrics.py` 落地以下行为，并补充本卡额外边界：

```python
from examples.perf.profile_metrics import rtf, simultaneous_peak

def test_peaks_are_attributed_to_the_same_instant():
    assert simultaneous_peak([{1: 3, 2: 1}, {1: 1, 2: 3}]) == 4
    assert rtf(4.0, 8.0) == 0.5
```

- [x] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_profile_metrics.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [x] **3. 最小实现。** 复用已有客户端与采样器，按 PID 去重，合并同步采样，不相加非同时的各 PID 峰值。补 PCM 首包、块间隔、完整合成 RTF、冷启动阶段；观测开销单列。真实 baseline 使用当前已授权服务与现有非敏感 fixture，未授权时只交付工具与明确未测标记。M1/12GB 缺机不伪造报告。
- [x] **4. 边界验证。** 零时长拒绝；采样丢失不能当零；PID 重用带启动时间标识；实际音频时长而非文件名时长；日志无正文。
- [x] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [x] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `test: define comparable speech profile measurements`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。（已验收：commit `2c346cc` / `adce4a9`，27 项测试通过）


### M02：识别实际模型变体与量化身份

**依赖：** M01/M03。
**所有权 / Files：** 新建 src/speechrail/backends/model_identity.py、tests/test_model_identity.py；修改 backends/qwen3_native.py 与 qwen3_tts_worker.py 的身份调用点（与 T02 串行）。
**接口 / Inputs & Outputs：** 实现 inspect_model / verify_loaded_identity；读取 quantization 与 quantization_config，保留 bits/group_size/混合精度描述；ASR/TTS ready 增量携带 model_variant/quantization_bits/artifact_key。

- [x] **1. 写失败测试。** 在 `tests/test_model_identity.py` 落地以下行为，并补充本卡额外边界：

```python
from speechrail.backends.model_identity import read_quantization

def test_quantized_does_not_mean_int8():
    q = read_quantization({"quantization": {"bits": 4, "group_size": 64}})
    assert q.bits == 4
    assert q.group_size == 64
```

- [x] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_model_identity.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [x] **3. 最小实现。** config 中预量化不再一律代表 INT8。保留现有 device/dtype 字段兼容，bits 独立用于真实校验；未知格式明确失败。只有配置声明且实际张量/loader 信息一致才 ready；不要把模型名中的 4bit 当证据。去除结果中实际权重身份的固定 1.7B 假设，同时保留公共 alias。CPU 原路径独立保留，三档只接受已验证 Apple Silicon MLX，不静默 fallback。
- [x] **4. 边界验证。** read_quantization(config:dict)->QuantizationSpec 在本卡定义；覆盖未量化、8-bit、4-bit、metadata/实际不符、未知位宽、codec 混合精度、加载失败不报 ready。
- [x] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [x] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `fix: validate actual model and quantization identity`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。（已验收：commit `84eae26`，35 项测试通过）


### M03：定义只包含权重差异的三档目录

**依赖：** M01。
**所有权 / Files：** 新建 src/speechrail/config/model_catalog.py、tests/test_model_presets.py；读取 assets 两个清单，不修改既有 config/profiles.py 的能力语义。
**接口 / Inputs & Outputs：** 实现 §3.2 的 ArtifactFile、QuantizationSpec、ModelArtifact、ModelPreset、RuntimeLock；load_catalog()->完整不可变目录；preset(id)->ModelPreset。

- [x] **1. 写失败测试。** 在 `tests/test_model_presets.py` 落地以下行为，并补充本卡额外边界：

```python
from speechrail.config.model_catalog import ModelPreset
from pydantic import ValidationError
import pytest

def test_preset_cannot_override_execution_policy():
    with pytest.raises(ValidationError):
        ModelPreset(id="light", asr="asr-small-q8", tts="tts-small-q8", chunk_ms=50)
```

- [x] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_model_presets.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [x] **3. 最小实现。** preset 的可执行字段只能 id/asr/tts；显示名称从固定文案派生。校验 balanced/light 指向同一 TTS artifact；quality/balanced 指向同一 ASR artifact。variant/capabilities 在 artifact 清单，不是推理策略开关；unknown keys fail-closed。runtime lock 只有一套发布版本，禁止 per-preset override。
- [x] **4. 边界验证。** 目录坏引用、混用 runtime 版本、缺 tokenizer、变体不支持、4-bit 候选不能自动覆盖 light 默认。
- [x] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [x] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `feat: define weight-only speech presets`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。（已验收：commit `11547dc`，28 项测试通过）


### M04：解析用户选择并保留旧配置

**依赖：** M02/M03。
**所有权 / Files：** 新建 src/speechrail/config/selection.py、tests/test_profile_selection.py；修改 src/speechrail/service/preflight.py 与 cli.py 的配置加载调用点，后续 U01 串行。
**接口 / Inputs & Outputs：** resolve_selection(settings,selection,catalog,app_home)->Settings；selection None 返回原 settings；校验已准备绝对路径；主服务和 preflight 使用相同解析器。

- [x] **1. 写失败测试。** 在 `tests/test_profile_selection.py` 落地以下行为，并补充本卡额外边界：

```python
from speechrail.config import Settings
from speechrail.config.selection import resolve_selection

def test_existing_install_without_selection_is_unchanged(tmp_path):
    original = Settings(_env_file=None, port=8299)
    assert resolve_selection(original, None, {}, tmp_path) == original
```

- [x] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_profile_selection.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [x] **3. 最小实现。** 先完整解析既有 env，再只 overlay 已明确选中的模型路径、实际身份及量化。managed sidecar 的模型选择优先于旧模型 env；非模型 env/进程配置完全保留；向导说明这一优先级。旧安装没有 sidecar 不自动生成，也不启用原来关闭的 TTS/Realtime。新 setup 的 ASR/TTS 开关在共同安装默认层设置，不在 preset 内设置。
- [x] **4. 边界验证。** fake manifests 下校验只改变允许字段；key/host/aliases/worker timeout/diarization 原样；损坏 sidecar 返回配置错误而非悄悄省资源；wheel/preflight 和源码解析一致。
- [x] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [x] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `feat: preserve user configuration across model selection`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。（已验收：commit `36f4dd4`，14 项测试通过）


### T01：建立按模型能力解析的共同音色表

**依赖：** M03。
**所有权 / Files：** 新建 src/speechrail/backends/qwen3_voice_binding.py、tests/test_voice_bindings.py；修改 src/speechrail/domain/tts.py 仅加入 vendor-neutral 能力描述类型，原 preset/alias 不删除。
**接口 / Inputs & Outputs：** resolve_binding(variant:str,voice:str)->VoiceBinding；VoiceBinding 在 backend 层含 speaker/instruction；公共描述不泄露私有路径。

- [x] **1. 写失败测试。** 在 `tests/test_voice_bindings.py` 落地以下行为，并补充本卡额外边界：

```python
from speechrail.backends.qwen3_voice_binding import resolve_binding

def test_custom_voice_is_explicitly_bound():
    binding = resolve_binding("custom_voice", "default")
    assert binding.speaker == "Serena"
    assert binding.instruction is None
```

- [x] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_voice_bindings.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [x] **3. 最小实现。** VoiceDesign 四 preset 原指令保持；CustomVoice 按设计 default/warm=Serena、bright=Vivian、calm=Uncle_Fu 解析。0.6B 不传假 instruct；default/warm 同声事实明确显示。所有 aliases 先经 resolve_voice 归一化；未知 voice/variant 失败，不默认用第一项。
- [x] **4. 边界验证。** 四 preset、13 aliases、unknown、大小写策略与现有契约一致；VoiceDesign 指令逐项原样；同源目录用于 REST 和 WS。
- [x] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [x] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `feat: describe model-specific voice bindings`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。（已验收：commit `fe869bd` / `335a83b`，25 项测试通过）


### T02：让同一 TTS worker 支持 CustomVoice

**依赖：** M02/T01。
**所有权 / Files：** 修改 src/speechrail/backends/qwen3_tts_worker.py；新增 tests/test_qwen3_tts_custom_voice.py；保留并运行 tests/test_qwen3_tts_voice_design.py。
**接口 / Inputs & Outputs：** 以兼容方式将 MlxVoiceDesignEngine 扩为 MlxQwenTtsEngine；旧类名可作为内部兼容 alias；TtsWorkerEngine.synthesize 签名不变。

- [x] **1. 写失败测试。** 在 `tests/test_qwen3_tts_custom_voice.py` 落地以下行为，并补充本卡额外边界：

```python
from speechrail.backends.qwen3_tts_worker import generation_condition

def test_small_custom_voice_does_not_fake_instructions():
    assert generation_condition("custom_voice", "default") == {
        "voice": "Serena",
    }
```

- [x] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_qwen3_tts_custom_voice.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [x] **3. 最小实现。** 只按已校验 artifact variant 选择条件构造函数，复用同一 model.generate/已锁定版本的 CustomVoice 接口，统一 streaming/PCM 校验/归一化/温度。以 G0 锁定 runtime 的真实签名为准，不复制不同版本 README 参数；fake loader 精确模拟该签名。warmup 使用当前变体有效音色。Base/未知变体继续 fail-closed。
- [x] **4. 边界验证。** generation_condition(variant,voice)->dict 为本卡唯一条件构造函数，VoiceDesign 返回原 instruction。完整 fake generate 验证两变体相同 chunk/speed/sampling、24k 偶数字节、无静音空输出、异常恢复；真实各 voice 由 B02 验收。
- [x] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [x] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `feat: run CustomVoice through the shared TTS engine`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。（已验收：commit `98f983a`，11 项测试通过）


### R01：实现 ASR 模式租约

**依赖：** 无，可在 M/T 波次之后独立启动。
**所有权 / Files：** 新建 src/speechrail/runtime/asr_mode.py、tests/test_asr_mode.py。
**接口 / Inputs & Outputs：** AsrModeGate.acquire/release 与 AsrModeBusy 按 §3.2；busy 为内部明确类型，HTTP/WS 映射在 C01。

- [x] **1. 写失败测试。** 在 `tests/test_asr_mode.py` 落地以下行为，并补充本卡额外边界：

```python
import pytest
from speechrail.runtime.asr_mode import AsrModeGate, AsrModeBusy

def test_batch_cannot_enter_unfinished_stream():
    gate = AsrModeGate()
    token = gate.acquire("streaming")
    with pytest.raises(AsrModeBusy):
        gate.acquire("batch")
    gate.release(token)
    gate.release(gate.acquire("batch"))
```

- [x] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_asr_mode.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [x] **3. 最小实现。** Batch 排他；同模式 Streaming 可计数持有；最后一 token 释放后才 idle。无 I/O 的状态变化在事件循环线程完成，不使用容易重入死锁的跨请求长 await 锁。单元测试穷举 idle/batch/streaming→状态；其他gate签发的token拒绝；租约对象记录释放状态，不维护无限增长的历史集合。
- [x] **4. 边界验证。** 双 streaming token 逐一释放；异常 finally 释放；重复 release 幂等；不能把公共 WS 是否连接当活动 ASR。
- [x] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [x] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `feat: enforce mutually exclusive ASR modes`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。（已验收：commit `73f5048`，7 项测试通过）


### R02：实现唯一 IPC owner 与有界路由

**依赖：** R01/M02。
**所有权 / Files：** 新建 src/speechrail/backends/qwen3_shared.py、tests/test_qwen3_shared.py；扩充 tests/fixtures/fake_framed_worker.py 仅增加受控多路脚本模式。
**接口 / Inputs & Outputs：** Qwen3SharedWorker 协议按 §3.2；内部 FrameRouter.route_key(frame)->tuple[str,str]|None；batch 用 request_id、stream 用 session_id，命名空间隔离。

- [x] **1. 写失败测试。** 在 `tests/test_qwen3_shared.py` 落地以下行为，并补充本卡额外边界：

```python
from speechrail.backends.qwen3_shared import FrameRouter

def test_batch_and_session_ids_have_separate_namespaces():
    assert FrameRouter.route_key({"request_id": "same", "type": "result"}) == ("batch", "same")
    assert FrameRouter.route_key({"session_id": "same", "type": "event"}) == ("stream", "same")
```

- [x] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_qwen3_shared.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [x] **3. 最小实现。** start ready handshake 由 owner 完成后才开启唯一 dispatcher；运行中 request 不调用 exchange 抢读，使用注册 future+send。会话队列初始 maxsize=64（所有档相同），总量受 session cap 约束；满时隔离慢会话并使其 terminal error 可达，dispatcher 不 await 慢消费者。terminal/error/result 不丢；未知/已退休 ID 只统计有限指标。
- [x] **4. 边界验证。** 真实 fake subprocess：两会话交织、无 ID error、单一 receive、队列满不堵另一个会话、EOF 广播一次、重启 generation 隔离、idle receive timeout 不误判故障。
- [x] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [x] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `feat: centralize ASR worker frame ownership`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。（已验收：commit `c3c22b8` / `f1256ea` / `0d44959`，18 项测试通过）


### R03：把 Batch 与 Streaming 门面接入共享 owner

**依赖：** R02。
**所有权 / Files：** 修改 src/speechrail/backends/qwen3_native.py、qwen3_streaming.py；修改 tests/test_qwen3_backend.py、test_qwen3_streaming.py。
**接口 / Inputs & Outputs：** Qwen3Worker 与 Qwen3StreamingWorker 构造允许注入 shared owner；既有 transcribe/StreamingWorkerProtocol 调用签名不破坏。facade 不再各建 transport。

- [x] **1. 写失败测试。** 在 `tests/test_qwen3_streaming.py` 落地以下行为，并补充本卡额外边界：

```python
from speechrail.runtime.asr_mode import AsrModeGate, AsrModeBusy
import pytest

def test_one_stream_finishing_does_not_release_another():
    gate = AsrModeGate()
    a, b = gate.acquire("streaming"), gate.acquire("streaming")
    gate.release(a)
    with pytest.raises(AsrModeBusy):
        gate.acquire("batch")
    gate.release(b)
    gate.release(gate.acquire("batch"))
```

- [x] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_qwen3_streaming.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [x] **3. 最小实现。** Batch 在整次转写最外层持 mode lease，按 request_id 等 owner future。Streaming connect 时取 token；收到 finished 且清理完本会话后释放，close/失败幂等兜底；不能在 commit 发出时提前释放。factory.create 仅创建对象，未 connect 不占 ASR mode。两级会话队列（owner到session、session到events消费者）均有界；不能让read_loop把有界上游全部搬入无界_events_queue。门面 close 仅清本会话，物理 owner close 由 lifecycle。
- [x] **4. 边界验证。** 另写门面集成 fake：Batch→Streaming→Batch 的 process-start 次数=1、mode token 清零；两并发 stream 隔离；取消尚在 connect、finished 后 close、batch失败、identity=model实际规模。
- [x] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [x] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `refactor: share one ASR process across both entry points`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。（已验收：commit `a373098`，48 项测试通过）


### R04：组合根与生命周期只登记物理实例一次

**依赖：** R03。
**所有权 / Files：** 修改 src/speechrail/application/services.py、application/lifecycle.py；修改 tests/test_application_composition.py、tests/test_worker_lease.py。
**接口 / Inputs & Outputs：** build_app_services 创建一个 owner 并注入两门面；RuntimeLifecycle 及 IdleEvictor 的列表以 owner identity 去重；健康诊断可保留逻辑角色但指向同一 worker_id。

- [x] **1. 写失败测试。** 在 `tests/test_application_composition.py` 落地以下行为，并补充本卡额外边界：

```python
import asyncio
from speechrail.application.lifecycle import RuntimeLifecycle

def test_lifecycle_closes_a_shared_component_once():
    class Component:
        alive = True
        starts = closes = 0
        async def start(self): self.starts += 1
        async def close(self): self.closes += 1
    async def run():
        c = Component()
        life = RuntimeLifecycle(asr=c, streaming=c)
        await life.start()
        await life.close()
        assert (c.starts, c.closes) == (1, 1)
    asyncio.run(run())
```

- [x] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_application_composition.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [x] **3. 最小实现。** 没有 streaming 配置时 Batch 仍可单独运行；只有 realtime 时不额外启动批量模型。保留 overrides、lazy loading、warm standby、last_active 与已有用户 TTL。owner 在任一活动租约下不可 evict；shutdown close exactly once。逐波保留原单元测试注入 seams。
- [x] **4. 边界验证。** 注入 fake overrides 不意外创建真实 runtime；启动中途失败仅清已启动者；逻辑角色内存统计不得重复计数。
- [x] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [x] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `feat: manage shared ASR worker lifecycle as a single physical instance`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。（已验收：commit `63e3ef5`，37 项测试通过）


### R05：共享 worker 取消、超时与进程恢复

**依赖：** R04。
**所有权 / Files：** 修改 src/speechrail/backends/qwen3_shared.py、qwen3_worker.py；新建 tests/test_shared_worker_recovery.py。
**接口 / Inputs & Outputs：** owner 暴露 generation 只读诊断；所有挂起请求关联 generation。worker 内继续按 session_id 隔离状态，frame protocol 新字段只作兼容增量。

- [x] **1. 写失败测试。** 在 `tests/test_shared_worker_recovery.py` 落地以下行为，并补充本卡额外边界：

```python
from speechrail.backends.qwen3_shared import GenerationGuard

def test_old_generation_cannot_deliver_a_result():
    guard = GenerationGuard()
    first = guard.current
    guard.advance()
    assert not guard.accepts(first)
    assert guard.accepts(guard.current)
```

- [x] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_shared_worker_recovery.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [x] **3. 最小实现。** 未送入 worker 的取消只移除等待者；已送入后超时则 abort 物理 owner，原 generation 的全部请求终结并清理token，下一请求才重建。不得静默重跑超时推理；transport 丢失最多保留一次既有 bounded retry，且只限没有交付结果的安全 batch。进程退出完成前不允许新 owner 复用管道。错误文本不含正文。
- [x] **4. 边界验证。** GenerationGuard.current:int/advance()->None/accepts(int)->bool 在本卡定义；fake子进程卡死、部分帧、EOF、连续取消100次、下一请求成功；real worker isolation/limits旧测试仍过。
- [x] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [x] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `fix: isolate failed ASR generations and recover leases`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。（已验收：commit `0d44959` / `a373098`，3 项测试通过）


### R06：统一资源保护并移除 ASR 双模式预留依赖

**依赖：** R05。
**所有权 / Files：** 修改 src/speechrail/runtime/resource_governor.py；新建 src/speechrail/runtime/model_budget.py、tests/test_model_budget.py；补 tests/test_resource_governor.py。
**接口 / Inputs & Outputs：** budget_for_hardware(total_bytes:int)->int 返回共同算法的基础服务预算；建议初始 max(4GiB,total_bytes//2)，仅 total>=8GiB 可进入已知设备候选。既有用户更明确资源上限优先。

- [x] **1. 写失败测试。** 在 `tests/test_model_budget.py` 落地以下行为，并补充本卡额外边界：

```python
from speechrail.runtime.model_budget import budget_for_hardware

def test_low_memory_acceptance_is_not_a_global_cap():
    gib = 1024 ** 3
    assert budget_for_hardware(8 * gib) == 4 * gib
    assert budget_for_hardware(128 * gib) > 4 * gib
```

- [x] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_model_budget.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [x] **3. 最小实现。** ASR mode gate 负责互斥，Governor 不再要求为不存在的另一 ASR 模式空留槽位；保留当前 TTS/Jobs 的有界准入和公共指标，禁止整类删除所有 aging 而影响真实消费者。同一算法根据实际 footprint 和已启用附加模型控制 ASR/TTS 大计算重叠；不能只按每个 worker 各设4GiB而让总量超限。内存未知时用保守有界串行，不静默改变权重；记录决策原因。
- [x] **4. 边界验证。** 函数没有 preset_id 参数；CPU/MPS identity不可混淆；同预算ASR/TTS排队后释放；没有向导自动关闭现有diarization；低资源拒绝用同一错误码矩阵。
- [x] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [x] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `refactor: apply one resource policy to all model tiers`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。（已验收：commit `019dc2b`，20 项测试通过）





### A01：有界读取上传与流式解码

**依赖：** R04。
**所有权 / Files：** 新建 src/speechrail/application/audio_stream.py、tests/test_audio_stream.py；现有 audio.py decoder 保留到 A04 接线。
**接口 / Inputs & Outputs：** decode_upload(file,max_upload_bytes,max_audio_seconds)->AsyncIterator[bytes]；每块 PCM16 <=64KiB；生产只读 UploadFile 小块。

- [x] **1. 写失败测试。** 在 `tests/test_audio_stream.py` 落地以下行为，并补充本卡额外边界：

```python
from speechrail.application.audio_stream import PcmByteCounter
import pytest

def test_duration_limit_is_checked_before_growing_buffer():
    counter = PcmByteCounter(max_samples=16000)
    counter.accept(32000)
    with pytest.raises(ValueError, match="audio_too_long"):
        counter.accept(2)
```

- [x] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_audio_stream.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [x] **3. 最小实现。** 保持 multipart/WebM/ffmpeg 真实性校验；使用固定命令与 stdin/stdout 双向并行泵，避免管道互等。累计输入字节/输出样本数先检查再分配。复用现有清理逻辑的语义，断连、超时、上限即 kill+wait。单次探测最多一块，输出奇数字节跨块拼接后校验。不得新增持久化音频；框架现有临时上传句柄在 finally 关闭，ASR不能接受客户端路径。
- [x] **4. 边界验证。** PcmByteCounter(max_samples)/accept(byte_count) 本卡定义；fakeffmpeg持续stdout、stdin堵塞、短写、空音频、恰好上限/多1样本、错误mime但有效webm、取消后的进程回收。
- [x] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [x] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `feat: bound upload decoding without whole-file PCM copies`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。（已验收：commit `0c67e65`，15 项测试通过）


### A02：建立共同滚动窗口与时间轴拼接

**依赖：** A01。
**所有权 / Files：** 扩充 src/speechrail/application/audio_stream.py；新建 src/speechrail/application/transcript_merge.py、tests/test_transcript_merge.py。
**接口 / Inputs & Outputs：** PcmBlock/split_pcm 按 §3.2；offset_ms(local_ms,start_sample)->int；生产 PcmWindowBuffer.feed(bytes)->tuple[PcmBlock,...]/finish()->tuple[...]；merge_results(blocks/results)->TranscriptResult。

- [x] **1. 写失败测试。** 在 `tests/test_transcript_merge.py` 落地以下行为，并补充本卡额外边界：

```python
from speechrail.application.transcript_merge import offset_ms

def test_sample_offset_preserves_global_time():
    assert offset_ms(250, 16000 * 30) == 30250
```

- [x] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_transcript_merge.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [x] **3. 最小实现。** 共同初始窗口30秒、边界重叠1秒，short clip不切片；以样本索引作为唯一时间轴。优先在已有 VAD 候选边界落窗，最长不能超过共同窗口上界。保留 core_start/end，重叠文本根据有界token对齐或真实时间戳归属去重；不使用简单字符串replace删除重复词。承认结果文本随输出长度增长，声称有界的仅 PCM/临时张量。
- [x] **4. 边界验证。** 连续样本覆盖无洞；奇数字节拒绝；数字/专名跨界、中文重复词、英文缩写、静音长段、最后不足一窗、语言变化、段序单调；无法无损拼接不得推广窗口优化。
- [x] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [x] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `feat: preserve transcript boundaries across bounded audio windows`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。（已验收：commit `6f0518a` / `c668cdc`，12 项测试通过）


### A03：逐窗推理与按需时间戳缓存

**依赖：** A02/R05。
**所有权 / Files：** 修改 src/speechrail/backends/qwen3_worker.py、qwen3_native.py；新建 tests/test_qwen3_chunked_transcription.py；保留 isolation/limits 回归。
**接口 / Inputs & Outputs：** 复用现有 transcribe frame，每窗有独立子 request_id 与绝对样本offset（主进程聚合）；同一整文件持 Batch lease。Streaming want_segments 的当前调用时机保持兼容。 新增Qwen3BatchTranscriber.transcribe_stream同A04签名；整文件模式租约覆盖全部子请求。

- [ ] **1. 写失败测试。** 在 `tests/test_qwen3_chunked_transcription.py` 落地以下行为，并补充本卡额外边界：

```python
from speechrail.application.audio_stream import split_pcm

def test_each_inference_window_is_bounded():
    blocks = split_pcm(b"\0\0" * 16000 * 61,
                       window_samples=16000 * 30, overlap_samples=16000)
    assert max(len(b.pcm) for b in blocks) <= 32000 * 30
    assert blocks[-1].core_end_sample == 16000 * 61
```

- [ ] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_qwen3_chunked_transcription.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [ ] **3. 最小实现。** 只为当前窗创建 float waveform，前窗临时张量及时释放，不再次装载 Session。批量时间戳逐窗返回后由 A02 合并。Streaming commit 才决定 want_segments 的既有路径，先保留当前有界 align buffer，不能无条件删掉后返回假空segments；仅在调用方开会话时已明确不用segments且合同覆盖时跳过音频副本。更大范围增量对齐作为该卡后续独立质量优化，不成为light上线前偷偷改变输出的捷径。
- [ ] **4. 边界验证。** fake Session统计一次load/多次transcribe，先窗失败不返回成功部分文件；include_timestamps开关；commit晚请求segments仍有真实结果；sampleoffset对应源音频。
- [ ] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [ ] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `perf: limit ASR inference tensors to one audio window`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。


### A04：把 REST 转写接入有界管线

**依赖：** A03/M04。
**所有权 / Files：** 修改 src/speechrail/http/routes/audio.py、domain/ports.py、config/__init__.py；补 tests/test_transcription_api.py、test_openai_multipart.py。
**接口 / Inputs & Outputs：** 新增 domain 的 StreamingBatchTranscriber.transcribe_stream(request_id,audio:AsyncIterator[bytes],language,prompt,include_timestamps)->TranscriptResult；ManagedRuntime后续实现此port。保留 BatchTranscriber 供现有fake调用方。

- [ ] **1. 写失败测试。** 在 `tests/test_transcription_api.py` 落地以下行为，并补充本卡额外边界：

```python
from speechrail.config import Settings

def test_long_audio_limit_is_independent_of_single_ipc_frame():
    settings = Settings(_env_file=None, max_audio_seconds=3600)
    assert settings.max_audio_seconds == 3600
```

- [ ] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_transcription_api.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [ ] **3. 最小实现。** 路由按 capability 选择逐块端口；旧 fake port用现有有界小音频fallback，真实Qwen路径强制流式。取消 max_audio_seconds 与单帧IPC的全文件耦合，保留时长配置上限和每帧大小限制。REST仍一次返回完整结果，不冒充新stream参数。格式text/json/verbose/srt/vtt/diarized字段与现有条件一致，上传错误/超时/请求ID不变；新模式冲突移交C01。
- [ ] **4. 边界验证。** 必须增加fake流式backend断言route不读整文件、上传超限不启动推理、长文件逐窗总时长、所有格式和WebM；这是结构验证，不以Settings一条测试代替行为回归。
- [ ] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [ ] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `refactor: stream decoded uploads into batch transcription`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。


### T03：统一长文本分句与生成上界

**依赖：** T02。
**所有权 / Files：** 修改 src/speechrail/domain/tts.py、backends/qwen3_tts_worker.py；补 tests/test_tts_streaming_splitter.py、test_tts_policy.py。
**接口 / Inputs & Outputs：** bounded_sentences(text:str,max_chars:int=240)->tuple[str,...]；两种变体复用相同函数与 generation_token_budget；Realtime 已分句输入不重复插入停顿。

- [ ] **1. 写失败测试。** 在 `tests/test_tts_streaming_splitter.py` 落地以下行为，并补充本卡额外边界：

```python
from speechrail.domain.tts import bounded_sentences

def test_long_text_is_not_silently_truncated():
    text = "今天下午三点开会。" * 100
    chunks = bounded_sentences(text, max_chars=240)
    assert "".join(chunks) == text
    assert max(map(len, chunks)) <= 240
```

- [ ] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_tts_streaming_splitter.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [ ] **3. 最小实现。** 优先句末/次级标点，保护数字、缩写、引号；单句超240字符按安全字符边界切且不丢字。token预算达到上限时分段，不悄悄截断文本；空/纯格式文本按现有规则处理。跨段平滑只做一次，不能在每个codec小块都fade导致颤音。固定参数所有档位一致，质量回归不过则共同算法回退。
- [ ] **4. 边界验证。** 超长无标点、中英混排、3.14、URL/缩写、chunk拆开标点、最后半句；同输入不同变体的分句相同；不会以硬裁音频达标。
- [ ] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [ ] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `fix: bound TTS generation without dropping long text`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。


### T04：限制 TTS 编码与交付缓冲

**依赖：** T03/A04（audio.py 串行）。
**所有权 / Files：** 修改 src/speechrail/http/routes/audio.py、application/tts_delivery.py；补 tests/test_tts_delivery.py、test_audio_subprocess.py。
**接口 / Inputs & Outputs：** 保持 iter_validated_audio 与公开六种格式；新增 PcmOutputCounter(limit_bytes).accept(byte_count)；可流式容器编码的输入输出队列各<=4块。

- [ ] **1. 写失败测试。** 在 `tests/test_tts_delivery.py` 落地以下行为，并补充本卡额外边界：

```python
from speechrail.application.tts_delivery import PcmOutputCounter
import pytest

def test_output_limit_includes_the_final_chunk():
    counter = PcmOutputCounter(limit_bytes=8)
    counter.accept(8)
    with pytest.raises(OverflowError):
        counter.accept(2)
```

- [ ] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_tts_delivery.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [ ] **3. 最小实现。** PCM继续真流式。mp3/opus/aac/flac按固定ffmpeg逐块喂入并回收，首块前错误维持错误envelope；响应开始后错误遵循已定义连接终止语义，日志不输出正文。WAV若无法给出兼容的准确长度则保留当前有界缓冲作为明确例外，不能输出伪造长度头；上限沿用现有128MiB并计入4GiB实测。断开客户端必须关闭 generator、stdin、child、worker租约。
- [ ] **4. 边界验证。** 真实ffmpeg往返解码、六格式HTTP媒体类型、speed/24k、空音频、奇数PCM、乱序chunk、消费者停读、取消后下一次TTS成功；不把解码帧和传输分块混淆。
- [ ] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [ ] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `perf: bound audio encoding and release cancelled TTS work`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。


### B02：运行 G2 三档可行性与质量对照

**依赖：** M01/B01/T04/R06/A04。
**所有权 / Files：** 新建 examples/perf/bench_profiles.py、tests/test_profile_benchmark_contract.py；新增 docs/archive/performance/2026-09-05-three-tier-feasibility.md（执行日期变化则使用实际日期，索引同改）。
**接口 / Inputs & Outputs：** bench_profiles.py --base-url --manifest --profile --phase --output；phase=baseline/quality/cold/warm/soak/switch；manifest为仓库外fixture清单，输出脱敏JSON。

- [ ] **1. 写失败测试。** 在 `tests/test_profile_benchmark_contract.py` 落地以下行为，并补充本卡额外边界：

```python
from examples.perf.bench_profiles import required_phases

def test_light_release_requires_real_device_and_soak():
    phases = required_phases("light")
    assert {"m1_air_8gb", "quality", "cold", "warm", "soak", "switch"} <= phases
```

- [ ] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_profile_benchmark_contract.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [ ] **3. 最小实现。** 同一硬件同一语料同一配置串行比较三档；按§7执行，不把ASR自生成音频作为唯一准确率证据。先本机两种TTS全voice smoke，再M1 light、12GB balanced。8-bit未过资源门才优先比较light TTS4-bit，ASR保持8-bit；不凭小模型名称保证速度。缺硬件写“未验证”，保留G2未通过。
- [ ] **4. 边界验证。** required_phases(profile)->set[str]由本卡定义；结果无真实硬件身份/缺soak/只readyz则release_pass=false；推理请求只能经过公共API。
- [ ] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [ ] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `test: establish real hardware gates for speech tiers`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。


### P01：下载制品、校验与 cache 复用

**依赖：** M01/M03；真实下载仅在明确应用授权下。
**所有权 / Files：** 新建 src/speechrail/service/model_store.py、tests/test_model_store.py。
**接口 / Inputs & Outputs：** prepare_models 按 §3.2；safe_artifact_path(root:Path,relative:str)->Path；外部下载SDK适配注入 Downloader，常规测试使用fake字节流。

- [ ] **1. 写失败测试。** 在 `tests/test_model_store.py` 落地以下行为，并补充本卡额外边界：

```python
from speechrail.service.model_store import safe_artifact_path
import pytest

def test_catalog_path_cannot_escape_model_store(tmp_path):
    with pytest.raises(ValueError):
        safe_artifact_path(tmp_path, "../config/.env")
```

- [ ] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_model_store.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [ ] **3. 最小实现。** 从锁定清单选择源，调用ModelScope官方工具或已说明原因的回退适配；精确revision，不远程执行代码。staging写入、分块进度、可取消/有限重试，复用官方可校验恢复能力；不把未知残缺文件标为完整。逐文件校验后原子登记prepared_id；全程不加载模型、不改selection。磁盘不足预检包含新权重、临时文件和旧回退资源。
- [ ] **4. 边界验证。** hash不符、断网恢复、取消、重复应用零重复下载、snapshot缺codec、symlink逃逸、镜像内容不等价、超预期文件大小中止；模型路径从manifest解析不接受音频请求传入。
- [ ] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [ ] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `feat: prepare verified model artifacts outside request handling`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。


### P02：统一 vendor runtime 的可重复准备

**依赖：** M01/M04/P01。
**所有权 / Files：** 新建 src/speechrail/service/bootstrap.py、tests/test_runtime_bootstrap.py；修改 src/speechrail/service/preflight.py。
**接口 / Inputs & Outputs：** runtime_key(lock:RuntimeLock|Mapping[str,object])->str；prepare_runtime(lock,app_home,runner)->RuntimePaths；RuntimePaths.asr_python/tts_python/ffmpeg 都在共同release布局。

- [ ] **1. 写失败测试。** 在 `tests/test_runtime_bootstrap.py` 落地以下行为，并补充本卡额外边界：

```python
from speechrail.service.bootstrap import runtime_key

def test_runtime_identity_does_not_depend_on_preset():
    lock = {"python": "3.12.0", "asr": ["a==1"], "tts": ["b==1"], "ffmpeg": "f1"}
    assert runtime_key(lock) == runtime_key(dict(lock))
```

- [ ] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_runtime_bootstrap.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [ ] **3. 最小实现。** 用锁定Python3.12和带hash的依赖安装命令，arm64预构建可用性先检查；不从源码临时编译未知native依赖、不偷偷升级全局Python。全档只准备同一ASR/TTS环境一次。preflight检查package/version/artifact匹配、模块能导入且没有加载模型/联网副作用；兼容源码与wheel的PYTHONPATH边界。旧runtime保留。
- [ ] **4. 边界验证。** runtime_key接受锁的规范化字典或RuntimeLock统一实现，测试3.12.0仅fake不是发布版本；不同preset复用key，lock变更必须新key；网络不可用/签名哈希错误保留旧env；主服务不import模型SDK。
- [ ] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [ ] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `feat: reuse one pinned vendor runtime across presets`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。


### P03：把 bootstrap 接入首次安装与 wheel

**依赖：** P02。
**所有权 / Files：** 修改 tools/install_macos.py、src/speechrail/service/paths.py、pyproject.toml（仅必要打包）；补 tests/test_installer.py、test_wheel_contents.py。
**接口 / Inputs & Outputs：** 旧install_wheel显式env_file接口保留；新增 managed安装路径接受preset_id并调用P01/P02；所有默认目录由ServiceLayout生成。

- [ ] **1. 写失败测试。** 在 `tests/test_installer.py` 落地以下行为，并补充本卡额外边界：

```python
from speechrail.service.paths import ServiceLayout

def test_managed_state_remains_outside_release(tmp_path):
    layout = ServiceLayout.for_app_home(tmp_path, user_home=tmp_path)
    assert layout.config_file == tmp_path / "config" / ".env"
    assert layout.current_runtime == tmp_path / "runtime" / "current"
```

- [ ] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_installer.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [ ] **3. 最小实现。** 首次安装生成私有基础config，统一ASR/TTS默认，监听loopback且无明文新凭据；已有env绝不覆盖。wheel包含catalog/runtime-lock/最小smoke和设置入口资源，不包含大模型/实际音频语料。复用runtime/releases/current、preflight、LaunchAgent；安装与enable分开，最终向导明确应用才启用。避免安装失败清理到原release/外部modelstore；保留可恢复staging。
- [ ] **4. 边界验证。** 补完整fake安装失败矩阵：既有env字节不变、samepreset幂等、wheel离开checkout仍可启动worker、主版本回退连同旧配置/目录兼容；无EnvironmentVariables凭据。
- [ ] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [ ] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `feat: install managed speech profiles without manual runtime setup`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。


### S01：持久化选择与可恢复事务日志

**依赖：** M03。
**所有权 / Files：** 新建 src/speechrail/service/profile_store.py、tests/test_profile_store.py。
**接口 / Inputs & Outputs：** recover_selection按§3.2；ProfileStore.begin(previous,candidate)->operation_id、mark(id,stage)、commit(id)、rollback(id)；record schema_version=1。

- [x] **1. 写失败测试。** 在 `tests/test_profile_store.py` 落地以下行为，并补充本卡额外边界：

```python
from speechrail.service.profile_store import ProfileStore

def test_uncommitted_candidate_never_becomes_active(tmp_path):
    store = ProfileStore(tmp_path)
    old = dict(schema_version=1, preset="quality", generation=1,
               asr="large-q8", tts="design-q8", runtime_lock_id="runtime-v1")
    new = dict(schema_version=1, preset="light", generation=2,
               asr="small-q8", tts="custom-q8", runtime_lock_id="runtime-v1")
    store.initialize(old)
    store.begin(old, new)
    assert store.recover() == old
```

- [x] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_profile_store.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [x] **3. 最小实现。** selection/journal/previous均0600，父目录0700；write temp/fsync/replace并fsync父目录。单写锁防多个setup同时申请；prepared摘要必须包含完整ASR/TTS配对与runtime_lock_id。commit之前不覆盖active；未完成启动恢复last-known-good。新安装无previous失败则明确unconfigured，不构造假quality默认。
- [x] **4. 边界验证。** 本卡定义initialize/recover用于首次有效登记/恢复；生产records用固定schema校验，catalog存在性由上游准备与下游activation双校验。每个journal阶段注入崩溃，symlink目标拒绝，schema未知fail-closed，损坏candidate不损坏previous。
- [x] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [x] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `feat: persist model selection as a recoverable transaction`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。（已验收：commit `3a2d83a`，14 项测试通过）


### S02：引入保持端口稳定的运行时委派对象

**依赖：** R04/T04/M04。
**所有权 / Files：** 新建 src/speechrail/application/managed_runtime.py、tests/test_managed_runtime.py；修改 application/services.py 组合注入。
**接口 / Inputs & Outputs：** ManagedRuntime实现现有ASR/TTS端口及A04流式Batch端口；持有RuntimeBundle(asr,tts,realtime_factory,artifact_identity,voice_catalog,generation)。

- [ ] **1. 写失败测试。** 在 `tests/test_managed_runtime.py` 落地以下行为，并补充本卡额外边界：

```python
from speechrail.application.managed_runtime import ActiveWork

def test_old_work_is_visible_until_its_lease_ends():
    work = ActiveWork()
    token = work.acquire(generation=1)
    assert work.count == 1
    work.release(token)
    assert work.count == 0
```

- [ ] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_managed_runtime.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [ ] **3. 最小实现。** AppServices保持frozen，routes持有稳定的ManagedRuntime门面而非旧worker引用。每次工作获取当前bundle租约直到结果/生成器finally/后端session终结，替换只在所有活动工作归零。逻辑capabilities/models/voices读取同一个活动generation快照；Settings里的网络和用户策略不被换模修改。test overrides仍绕开真实bundle。
- [ ] **4. 边界验证。** ActiveWork接口在本卡定义；核心集成断言：流式响应未消费完不可替换、空闲WS不占租约、draining时新request拒绝、同generation模型列表一致、旧port调用签名不变。
- [ ] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [ ] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `refactor: delegate inference through one managed runtime`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。


### S03：实现可取消的安全 drain

**依赖：** S01/S02。
**所有权 / Files：** 扩充 application/managed_runtime.py；新建 tests/test_profile_drain.py；必要时只修改 runtime/worker_lease.py 的drain保护调用。
**接口 / Inputs & Outputs：** ManagedRuntime.drain(deadline_seconds)->drain_token / resume(token)；DrainState记录operator token过期时间；只允许一位切换者。

- [ ] **1. 写失败测试。** 在 `tests/test_profile_drain.py` 落地以下行为，并补充本卡额外边界：

```python
from speechrail.application.managed_runtime import DrainState

def test_expired_unclaimed_drain_restores_admission():
    state = DrainState()
    state.begin(now=10.0, ttl_seconds=5.0)
    assert not state.accepting
    state.expire(now=16.0)
    assert state.accepting
```

- [ ] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_profile_drain.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [ ] **3. 最小实现。** drain只停止新推理准入，不截断活动transcription/TTS或重启worker。等待backend活动归零；对长会话展示等待，可取消；初始deadline120秒超时恢复旧准入，所有档一致。token失联过期恢复；已进入activate不可任意resume。IdleEvictor挂起且释放有finally。
- [ ] **4. 边界验证。** DrainState.begin/expire/accepting本卡实现，生产clock注入monotonic；活动会话完成竞争、二次drain、取消两次、读取HTTP音频中取消切换、deadline后当前工作仍成功。
- [ ] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [ ] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `feat: drain active speech work before switching models`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。


### S04：串行换模、真实冒烟与自动回退

**依赖：** S03/P03。
**所有权 / Files：** 扩充 application/managed_runtime.py、service/profile_store.py；新建 tests/test_profile_activation.py。
**接口 / Inputs & Outputs：** activate(prepared_id,drain_token)由服务持有后台任务；注入BundleLoader.load/close、SmokeProbe.run用于fake故障验证；state/status返回operation_id/stage/generation。

- [ ] **1. 写失败测试。** 在 `tests/test_profile_activation.py` 落地以下行为，并补充本卡额外边界：

```python
from speechrail.service.profile_store import allowed_transition
import pytest

def test_activation_cannot_commit_before_smoke():
    assert allowed_transition("SMOKING", "COMMITTED")
    assert not allowed_transition("ACTIVATING", "COMMITTED")
```

- [ ] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_profile_activation.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [ ] **3. 最小实现。** 校验prepared与runtime lock后关闭旧两个模型进程并wait，再串行启动新ASR和TTS。复用共同vendor环境；禁止新旧两套模型同时load。先身份检查和固定synthetic短ASR+TTS通过才commit并开放准入。任意一步失败关闭全部candidate，串行恢复previous并重新冒烟。回退失败只报NOT_READY，不循环restart。私有activation自测走同一服务用例/协议校验，外部/public smoke仍为B02/V01发布必需。
- [ ] **4. 边界验证。** 函数allowed_transition在本卡定义；fake BundleLoader日志必须证明close_old→load_asr→load_tts→smoke→commit；ASR成功TTS失败、空音频、identity错、cli退出、进程崩溃后store恢复、同preset不重载。
- [ ] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [ ] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `feat: activate complete model pairs with automatic rollback`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。


### S05：提供同用户私有控制通道

**依赖：** S04。
**所有权 / Files：** 新建 src/speechrail/service/profile_control.py、tests/test_profile_control.py；修改 application/lifecycle.py 生命周期挂接。
**接口 / Inputs & Outputs：** Unix socket JSON一请求一响应，§3.3白名单commands；control_request(app_home,payload)->dict；只返回公开模型ID和计量信息。

- [ ] **1. 写失败测试。** 在 `tests/test_profile_control.py` 落地以下行为，并补充本卡额外边界：

```python
from speechrail.service.profile_control import validate_control_request
import pytest

def test_control_channel_cannot_execute_commands():
    with pytest.raises(ValueError):
        validate_control_request({"command": "exec", "argv": ["anything"]})
```

- [ ] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_profile_control.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [ ] **3. 最小实现。** 同用户目录0700/socket0600，校验peer uid（macOS可用getpeereid），有界64KiB、读写超时5秒；activation长任务只返回operation_id。prepared_id不解析外部路径。lifecycle唯一创建/关闭socket，未知占用不unlink，stale socket仅确认无所属进程且本服务创建才可恢复。控制不暴露在HTTP/LAN，不执行任意命令。
- [ ] **4. 边界验证。** 超过长度、wrong uid、恶意prepared路径、重复operation_id、多个设置客户端、drain token过期、socket存在但不同app_home；主服务不可因控制错误退出。
- [ ] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [ ] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `feat: expose bounded local profile control`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。


### U01：实现三档选择与一次应用向导

**依赖：** S05/P03/B02目录验收状态。
**所有权 / Files：** 新建 src/speechrail/service/profile_commands.py、tests/test_profile_commands.py；修改 src/speechrail/cli.py、tests/test_cli.py。
**接口 / Inputs & Outputs：** 新增 speechrail setup；speechrail profile list|status|apply <id>|rollback，统一--app-home；apply支持--yes供已显示影响后的自动化调用。serve/service旧命令原样。

- [ ] **1. 写失败测试。** 在 `tests/test_profile_commands.py` 落地以下行为，并补充本卡额外边界：

```python
from speechrail.service.profile_commands import model_changes

def test_balanced_to_light_only_changes_asr():
    old = {"asr": "large-q8", "tts": "small-custom-q8"}
    new = {"asr": "small-q8", "tts": "small-custom-q8"}
    assert model_changes(old, new) == {"asr"}
```

- [ ] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_profile_commands.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [ ] **3. 最小实现。** 新装只推荐已通过对应硬件矩阵的组合；旧装显示当前selection不重选。TUI依次显示推荐/三档、缺失下载量、音色变化、回退磁盘需求，最后一次“下载并应用”覆盖准备与生效。先P01/P02准备再S03/S04，阶段进度可取消；activation阶段取消只停止UI等待，不杀服务。VoiceDesign→CustomVoice必须展示style/design能力减少和default/warm同声；balanced↔light不提示虚构TTS变化。
- [ ] **4. 边界验证。** model_changes(old,new)->set[str]本卡定义；输入错误、Ctrl-C、noTTY需显式--yes且有machine-readable影响、已缓存不重下、同档幂等、offline缺模型说明、不中断当前请求；客户端baseURL/port/key/alias未变。
- [ ] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [ ] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `feat: offer a single guided model preset workflow`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。


### U02：交付普通用户双击入口与干净机器安装

**依赖：** U01。
**所有权 / Files：** 新建 deploy/macos/SpeechRail-Setup.command、tests/test_setup_launcher.py；修改 tools/install_macos.py 生成已安装“SpeechRail 设置.command”。
**接口 / Inputs & Outputs：** release附带固定bootstrap manifest与setup launcher；已安装launcher调用当前release的 speechrail setup --app-home，路径正确shell quoting；不会另建daemon或WebUI。

- [ ] **1. 写失败测试。** 在 `tests/test_setup_launcher.py` 落地以下行为，并补充本卡额外边界：

```python
from pathlib import Path

def test_launcher_never_executes_unverified_remote_script():
    script = Path("deploy/macos/SpeechRail-Setup.command").read_text()
    assert "curl | sh" not in script
    assert "eval " not in script
```

- [ ] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_setup_launcher.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [ ] **3. 最小实现。** 干净arm64 Mac检查OS/架构/磁盘后，使用系统工具取经hash校验的固定uv与Python/runtime制品，再启动同一向导；不要求用户先安装Python/Homebrew。不得curl|sh、eval、不加检查放行Gatekeeper或要求root。打包签名/公证若分发需要则作为release制品门；未签名不能宣称无系统提示。用户权限提示只在首次必要准备出现，不能每个依赖反复确认。
- [ ] **4. 边界验证。** 静态测试不是完整验收；必须加fakebin拦截验证下载→hash失败不执行、路径含空格/中文、未安装Python/uv、网络断开恢复、用户取消、权限限制、第二次启动不重装；V01实机双击。
- [ ] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [ ] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `feat: package a double-click speech setup entry`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。


### C01：发布准确的模型/音色目录与契约扩展

**依赖：** U02/T01/S04。
**所有权 / Files：** 修改 contracts/openapi.yaml、contracts/realtime-openai.md、src/speechrail/http/routes/system.py；补 tests/test_tts_voices_api.py、tests/test_app_contract.py。
**接口 / Inputs & Outputs：** 公共voice IDs和aliases保留；/v1/voices可增量返回capabilities/variant，既有必需字段不删；/v1/models实际resolves_to一致；动态值来自ManagedRuntime同generation。

- [ ] **1. 写失败测试。** 在 `tests/test_tts_voices_api.py` 落地以下行为，并补充本卡额外边界：

```python
from speechrail.domain.tts import resolve_voice

def test_standard_voice_alias_remains_stable():
    assert resolve_voice("alloy") == "default"
    assert resolve_voice("coral") == "warm"
```

- [ ] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_tts_voices_api.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [ ] **3. 最小实现。** 建立三档参数化目录测试：模型真实resolves_to、voice描述/available/capabilities必须来自ManagedRuntime同一generation。保留所有必需字段和alias。把模式冲突REST429 backend_busy与换模503 backend_not_ready语义先写入契约，接线由C02完成；禁止在本卡引入采样率迁移或LLM语义。
- [ ] **4. 边界验证。** 增加实际ASGI fixture：三档voice列表/available、mode冲突、drain/readiness、无TTS设置、短音频和六输出格式、response终结一次、cancel/断线重连、鉴权无回归。若文件所有权冲突，卡内按system→audio→WS顺序独占。
- [ ] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [ ] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `test: preserve audio contracts across all model tiers`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。


### C02：接线忙碌与换模错误并跑客户端回归

**依赖：** C01/S05。
**所有权 / Files：** 修改 src/speechrail/http/routes/audio.py、src/speechrail/application/realtime_openai.py；补 tests/test_realtime_openai.py、test_openai_multipart.py、test_speech_api.py。
**接口 / Inputs & Outputs：** 按C01契约将AsrModeBusy映射REST429/WS error backend_busy；draining/activation映射503 backend_not_ready。保留request ID和既有错误envelope。

- [ ] **1. 写失败测试。** 在 `tests/test_openai_multipart.py` 落地以下行为，并补充本卡额外边界：

```python
from speechrail.http.errors import error_response

def test_busy_error_keeps_request_identity():
    response = error_response(429, "req_test", "backend_busy", "ASR mode is busy")
    assert response.status_code == 429
    assert response.headers["x-request-id"] == "req_test"
```

- [ ] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_openai_multipart.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [ ] **3. 最小实现。** 同一套fake三档参数化客户端测试先红后绿；REST/WS不捕获后忽略未知错误，不改sample_rate或事件语义。busy请求不创建第二worker，失败后原session保持合同规定的可用性。标准OpenAI SDK路径、multipart视频webm、六TTS格式、aliases、session/update/commit/cancel事件顺序全部回归；真实部分留V01。
- [ ] **4. 边界验证。** 若现有错误函数由middleware注入header，则本种子改为ASGI实际请求验证而不改既有责任边界。覆盖上传期间换档、active stream冲突、unknown voice、无TTS配置、鉴权和断线重建，不能只测aliases纯函数。
- [ ] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [ ] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `fix: report profile transitions through stable audio errors`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。


### V01：完成全量门禁、实机验收与交接

**依赖：** C02/B02，全部卡通过。
**所有权 / Files：** 更新 README.md、docs/users/integrations.md、docs/operations/operations-runbook.md、docs/developers/testing-acceptance.md、docs/architecture/current-boundaries.md、必要CHANGELOG；新增实际日期的三档验收报告与docs/archive/performance/README.md索引。
**接口 / Inputs & Outputs：** 发布验收结果必须区分代码gate、真实quality/balanced/light、客户端、首次安装、换档、回退；完整清单见§7/§8。

- [ ] **1. 写失败测试。** 在 `tests/test_release_verification.py` 落地以下行为，并补充本卡额外边界：

```python
from pathlib import Path

def test_model_selection_assets_are_part_of_release():
    root = Path("src/speechrail/assets")
    assert (root / "model-catalog.json").is_file()
    assert (root / "runtime-lock.json").is_file()
```

- [ ] **2. 证明测试先失败。** 执行 `uv run --extra dev pytest tests/test_release_verification.py -q --no-cov`；
  确认失败来自新行为未实现，而非环境/导入配置事故。已存在的纯函数种子若已过，必须先加入下面要求的实际边界失败测试。
- [ ] **3. 最小实现。** 冻结待发布HEAD/lock/catalog后执行完整gate；在本机、12GB设备、M1 Air8GB分别跑公共API质量/冷启动/热机/切换。干净用户目录首次安装与已有用户升级分开，所有旧配置字节校验。只对用户授权的服务执行部署/启停，安装器开发测试不等于生产安装授权。未达标列准确缺口；本机优化可独立发，但三档发布不准标complete。
- [ ] **4. 边界验证。** 该静态断言只是缺件提示，不能替代wheel隔离导入和实机门。报告中必须保存命令、退出码、测试数量、HTTP状态、模型/设备/量化身份及回退结果，禁止提交权重/音频/凭据。
- [ ] **5. 绿测试与审查。** 再执行同一针对性命令；对本卡src/tests运行ruff及受影响src的mypy，
  核对diff只在所有权范围。报告fake和真实证据分别覆盖什么。
- [ ] **6. 单主题交付。** 主 Agent 审查通过后仅暂存本卡明确文件；建议提交信息
  `docs: publish verified three-tier speech acceptance`。提交前运行 `git diff --staged --check`，不自动暂存未知并行变更。


## 6. 每卡结束的审查与 Git 规则

- 每卡一个 writer；主 Agent 最多同时派发三个不重叠任务，真实模型/服务/同机基准始终串行。
- 指定分支/工作区由执行阶段创建；本次计划不创建分支。开始执行先保存当前 HEAD 与
  git status，处理已有未提交文档，不自动 stash 或暂存整树。
- 子代理给出：最小 diff、红测试证据、绿测试数量、失败恢复用例、未测真实模型项目。
- 主 Agent 两步检查：先按卡片与规范检查需求，再检查代码/错误恢复/资源生命周期。
  任一不符发回同一 owner 小修，不让另一个 agent 同时修同文件。
- 对每卡新增 helper 必须放在卡片声明模块并补类型，不把规范里的省略号实现复制进生产。
  上面的测试种子是起点，必须扩展卡片“额外边界”；不通过镜像实现的断言代替真实边界测试。
- 针对性测试与 ruff/mypy 通过后才提交该主题；用显式文件列表暂存，检查 staged diff 和敏感信息。
  不自动 commit 本机 runtime、音频、下载清单中的私有路径、.env 或别人的改动。
- 文件超过任务上限、出现未知接口或同文件冲突时，主 Agent 拆分为后缀子卡并重排依赖；
  新子卡必须有独立验收，不把“继续优化”派给 worker。

## 7. 可执行验收矩阵

### 7.1 语料与质量

B01/B02 创建机器可读 fixture manifest，仅包含 opaque ID、仓库外引用、语言桶、真实时长、
许可证/授权来源与校验摘要。私有转写和音频不进入Git/报告。自动化CI使用合成/fake，
真实质量数据由操作者准备或授权获取；不可用本TTS生成、本ASR识别的一致性证明全部质量。

| 维度 | 最小集合 | 放行标准 |
|---|---|---|
| ASR 准确率 | 240段：中文160、英文40、中英混读40；另30段静音/非语音 | 同模型同量化优化前后：中文CER增加<=0.3个百分点、英文WER增加<=0.5个百分点；关键数字/专名错误不得增加 |
| light 模型质量 | 同一独立语料，0.6B8-bit对0.6B未量化参考（参考可在本机串行测） | 逐语言桶披露差异；阈值同上；不能用1.7B/0.6B不同权重结果宣称优化无损 |
| 分段边界 | 各语言至少20个数字/专名/重复词跨边界样例 | 无新增漏词/重复；真实时间戳单调且保持音频边界 |
| TTS 可懂度 | 60条：中文40、英文10、中英混读10，覆盖数字/日期/多音字/缩写/长句 | 人工审听无漏句、重复句、静音失败；记录所有读音问题，不仅检查非空PCM |
| TTS 音质 | 四公共voice均覆盖；每个主要映射至少10条，随机顺序盲听 | 建议3名听者、5分制均值>=3.8；相同voice优化前后均值下降<=0.2；不到人数则标证据不足 |
| 本机能力保留 | 当前quality与用户启用能力固定 | preset指令/voice aliases/时间戳/取消/已启用附加能力无未经说明退化 |

以上细化阈值是执行计划的初始放行标准，不是已有模型分数。阈值冻结在B01 manifest版本，
不得看完结果再放宽。小样本差异需报告置信区间/逐样本差异，尤其不能用均值掩盖漏句或数字错误。
真实用户自定义voice若不在可分享测试集，保持原选择并单独在本机私下验收。

### 7.2 性能与资源

每台设备记录芯片、物理内存、macOS、Python/MLX/vendor lock、模型revision/量化、
共同推理参数摘要、服务commit与测试工具版本。CPU/GPU/电源状态与前台共存负载记录为摘要，
不用完整进程清单收集无关私人数据。

1. Cold：模型未加载时串行启动ASR/TTS，至少3次，覆盖预热与加载峰值；
   不把“已加载模型请求”写成cold，不通过清空全系统缓存获得不可复现结果。
2. Warm：至少1次预热后，3/10/30/60秒按实际时长分桶，每桶至少30次。
3. ASR batch与streaming分段运行，不安排两者同时负载；TTS交替与允许的ASR/TTS重叠分别跑。
4. Streaming按1x实时输入；统计最后PCM发送至completed延迟、未处理PCM秒数趋势；
   p95完成延迟<=2s，不能用客户端上传总耗时作为模型RTF。
5. TTS记录请求/response.create至首个有效音频的TTFA、每块可播放时长、块间隔、总生成时长。
   各主要桶热机RTF p95<1，目标<=0.8；不把首包快当持续实时。
6. light 60分钟热机：交替识别/合成并周期性取消；后20分钟仍满足同一门槛，
   无OOM/重启、无持续内存增长或热降频导致积压。
7. light 物理峰值目标<=4GiB，基础组合主进程+唯一ASR+TTS+活动ffmpeg全部计入；
   schema中区分GiB与上游制品GB。已有附加模型另测，不能为了通过自动关掉用户设置。
8. 用footprint物理指标；同步采样取每个时刻各唯一PID当前值之和再求max。进程高水位单列为
   可能上界，不冒充同时峰值。记录采样周期与丢样；冷启动/切换短峰值需结合进程高水位，
   若采样不能排除越界则标资源门未充分验证。
9. memory pressure、压缩量与swap记录增量。swap初始非零不直接失败，但稳态持续增长
   或产生延迟恶化失败。监控开销高时报告对照，不静默删采样。
10. 性能改善必须同输入/硬件/共同参数、重复至少3轮且超过噪声；本机质量门先过再认性能收益。

M1 Air8GB只能在真机通过；限制M5进程内存、VM、仅TTS单模型或8GB其他芯片结果均不能替代。
12GB balanced与本机quality分别记录；16GB以上不是light验证替身。

### 7.3 故障与易用性

| 故障注入点 | 必须观察到的结果 |
|---|---|
| 下载断网/取消/hash错误/磁盘不足 | 当前服务与selection不变；可恢复准备；无半快照可加载 |
| drain遇到长ASR/TTS | 当前任务继续完成；向导可取消；超时恢复准入 |
| 新ASR加载失败 | 新TTS不启动；恢复旧组合 |
| 新TTS加载失败或smoke空音频 | 新ASR关闭后恢复旧ASR/TTS；active不部分更新 |
| activation中CLI退出 | 服务继续完成或回退，不永久drain |
| 服务在各journal阶段崩溃 | 下次启动按last-known-good恢复；未完成candidate不当active |
| rollback也失败 | readyz=503、明确错误、保留文件，不自动无限restart |
| 共享ASR EOF/timeout/旧帧 | 当前请求有一次terminal；新generation无串词/串帧 |
| Realtime慢消费者/满队列 | 单会话有界失败，不堵其他会话或泄漏mode token |
| 切balanced↔light | TTS权重不重复下载；实际音色与公共映射保持 |
| 切quality→balanced/light | 用户应用前看到VoiceDesign能力/音色变化；aliases与URL不要求改 |
| 干净M1用户目录 | 双击→选择推荐→一次应用；无需手动Python/MLX/.env/路径 |
| 已有安装升级/回退 | 原.env与未知键字节保持；原权重/可选能力保留；单实例不抢端口 |
| 用户启用附加模型 | 使用同规则准入、显式显示未验收组合，不偷偷关闭 |

M1往返quality可能本身不可加载，因此不能为了测试“切换”强迫M1加载不适合的quality。
M1先验证light重应用、受控candidate失败回退与light q8/q4候选往返；三档完整互切在本机做。
8GB不能加载的目标在准备/准入时清楚拒绝，仍保留当前light可用性。

## 8. 命令与阶段交付

### 8.1 开发门禁（每卡/每波）

每卡正文已给出针对性命令；波次完成且涉及运行时/公共行为时执行：
```bash
uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
git diff --check
```

CLI/安装器相关波次额外执行：
```bash
uv run --extra dev pytest tests/test_cli.py tests/test_launchd_service.py tests/test_installer.py tests/test_wheel_contents.py -q --no-cov
plutil -lint deploy/macos/com.speechrail.plist.example
uv run speechrail --help
uv run speechrail service --help
uv build --no-sources --wheel
```

新文件在tools/examples/perf下的部分另加：
```bash
uv run --extra dev ruff check tools/build_model_catalog.py examples/perf/profile_metrics.py examples/perf/bench_profiles.py
```
不趁机全量修复未涉及历史脚本；若工具不在mypy默认src范围，新增纯算法模块也须针对性type检查。

### 8.2 目标用户命令（U01完成前不存在，不可现在执行）

```bash
speechrail setup
speechrail profile list
speechrail profile status
speechrail profile apply light
speechrail profile rollback
```
普通用户可直接双击“SpeechRail 设置”走同一流程；自动化调用才使用--yes。
apply/rollback会改变权重运行态，开发测试中的fake成功不构成在本机生产服务执行的授权。

### 8.3 真实API与发布

仅在服务/fixture/runtime与授权具备时：
```bash
curl http://127.0.0.1:8201/health
curl http://127.0.0.1:8201/readyz
curl http://127.0.0.1:8201/v1/models
curl http://127.0.0.1:8201/v1/voices
```
随后使用B02实现的runner与仓库外manifest；认证沿用已有工具的安全环境输入，不写入参数或报告。
测试runner必须涵盖标准OpenAI SDK真实REST/WebM与Realtime，不绕过公共边界直接跑vendor SDK代替验收。

| 门 | 可交付结果 | 不可宣称的内容 |
|---|---|---|
| G0 | 制品/共同runtime锁定、假测试目录和基准方法 | 不能宣称模型可加载、8GB可用 |
| G1a | 唯一ASR owner、模式互斥、恢复回归 | 不能只凭fake证明真实MLX内存下降 |
| G1b | 有界音频、CustomVoice共同路径、完整代码gate | 不能证明真实中文音质和持续速度 |
| G2 | 已获取设备上的真实模型/质量/资源可行性 | 尚无setup时不声称切换/首次安装验收；缺M1则light未验收 |
| G3 | 真实安装/切换/回退、全部设备和客户端门通过 | 通过后才能宣布本次三档工作完成 |

G2与G3结果可以复用同一冻结HEAD/lock/语料下的质量数据；中间若改变推理路径/依赖/量化，
必须重跑受影响质量与性能桶，不能全部机械重复或全部跳过。

## 9. 回退与停止条件

- 代码回退：恢复上一已验证release与其配套目录格式，单主题commit可独立revert；
  不reset工作树、不删除用户模型/.env/日志。
- 权重回退：只选last-known-good完整ASR/TTS组合，同一drain/identity/smoke流程；
  不把手动编辑一个模型路径当完成回退。
- runtime升级回退：保留vendor旧lock目录与主release；旧.env路径继续可用。
- 首次安装失败：保留可恢复制品缓存和明确unconfigured状态；不能enable假ready服务。
- light资源/质量失败：保留原报告与失败case；优先评估已列TTS4-bit对照或共同管线优化，
  不改用另一架构、不偷偷删能力、不提高4GiB门槛。
- 本机质量下降：停止相关共同算法推广，回退该变化；不因light有收益就接受本机回归。
- 不存在M1真机、没有真实runtime/语料授权、关键制品无法校验时，仅对应实机/制品门受阻；
  其他代码/fake/文档可继续，不伪造数据，也不无限下载/重启尝试。

## 10. 计划完整性自查与执行交接

| 已采纳要求 | 任务/门 |
|---|---|
| 三档只变权重/量化、统一依赖与算法 | M01–M04、R06、B02 |
| 一个共享ASR、Batch/Streaming互斥 | R01–R05 |
| 两类TTS权重与本机VoiceDesign保留 | T01–T04、B02/V01质量门 |
| 内存、长音频、取消与稳定性 | A01–A04、R05/R06、T03/T04、B01/B02 |
| 无手工环境、低成本一次切换 | P01–P03、S01–S05、U01/U02 |
| 保留客户端与OpenAI兼容边界 | C01/C02、V01 |
| M1 Air8GB强制实机验收 | B02、V01、G2/G3 |
| 质量优先本机独立回归 | B02/V01，不受light硬件缺失取消 |
| luna_worker原子执行、共享文件互斥 | §4/§6，每卡明确所有权 |
| 失败回退、旧配置与数据保留 | M04、P03、S01–S05、V01 |

- [ ] 执行主 Agent 重新核对当前HEAD/dirty状态与图coverage；保存本次计划基线。
- [ ] 从M01/B01启动，只派发无共享写入的原子卡；不要一次把整阶段交给worker。
- [ ] 每波汇报新增证据与剩余门，明确“代码已过”和“实机已过”。
- [ ] 最终交接列出：结果、文件、测试数量/HTTP状态、运行态身份、未验证项、并行改动、回退版本。
- [ ] 所有必要门通过后才将计划状态改为完成；未过M1门不得用“其余都好了”替代完整交付。
