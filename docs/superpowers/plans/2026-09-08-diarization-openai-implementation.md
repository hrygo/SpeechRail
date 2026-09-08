---
title: "Speaker Diarization OpenAI 实施方案"
status: ready
audience: "SpeechRail 实施与评审人员"
version: "0.2.0"
date: 2026-09-08
---

# Speaker Diarization OpenAI Implementation Plan

> 执行者按任务逐项使用 `executing-plans` 工作流；本文件只编写方案，不自动派发开发工作。下列复选框是实施步骤，不是交给用户安排人员验证的任务卡。

**Goal:** 在原 OpenAI API/SDK 下交付本机匿名分人，内部只有一条连续状态链路，未使用分人的消费者不承担新增接入和推理成本。

**Architecture:** transport 只做 OpenAI/扩展 DTO 转换；应用层拥有 session actor，领域层拥有时间轴和归属账本。Qwen3 ASR、固定正文对齐与持续活动通过 ports 连接；文件和实时共用活动引擎。用户已根据 D1 runtime smoke 选择 CoreML FP16；因此只实现一个 Swift/CoreML production adapter。

**Tech Stack:** Python `>=3.12,<3.13`、uv、FastAPI/Pydantic、现有 MLX/Qwen3 worker、Swift/CoreML 私有 worker、Streaming Sortformer v2.1；测试使用 pytest、OpenAI Python/JavaScript SDK、Swift XCTest 和 pyannote.metrics。

**Spec:** [完整设计](../specs/2026-09-08-diarization-clean-architecture-design.md) 与 [D1 runtime 证据](../../archive/performance/2026-09-08-d1-diarization-runtime-smoke.md)。实施前同时阅读，接口和状态定义以前者为准，后者只证明运行时选择，不代替质量验收。

## Global Constraints

- 不新增 `/v2/transcription-sessions` 或公共二进制音频协议；保留 `/v1/audio/transcriptions` 与 `/v1/realtime`。
- 文件分人遵循 OpenAI 原生匿名分人子集；Realtime 仅 `session.speechrail.diarization.enabled` opt-in。
- 普通 OpenAI SDK 请求/事件保持原状；未启用分人的请求不进入新 session、不调用 align、不依赖分人 ready。
- 一个 SpeechRail 服务、一个 ASGI worker、一个活跃分人会话；batch ASR/streaming ASR 冲突按 `backend_busy`。
- 请求路径不下载模型、不读取远程音频、不静默联网；模型制品与私有配置在仓库外。
- 只输出 session-scoped 匿名标签；不保留原始 PCM、embedding 或跨会话声纹库。
- Python 固定为 `>=3.12,<3.13`，三档只影响既有权重组合，不产生不同 API/调度架构。
- 仅删除分人旧路径；不保留 fallback、双写或双模型常驻。部署回退通过上一 release 完成。
- 生产只使用 `v3/fp16/SortformerNvidiaLow_v2.1.mlmodelc`，D1 模型 revision `ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1`、FluidAudio source commit `5c19d5e12320e22bbfb7a1877b089d2665a69add`；release 必须再锁完整 bundle hash 和 notice。
- 已安装 `.mlmodelc` 直接加载并显式使用 `computeUnits=.all`；禁止请求下载、`MLModel.compileModel`、运行时换模型或换精度。
- D1 只完成 runtime smoke，未覆盖 RTTM/UEM、DER、分包、ASR 共存、尾部 flush、P95 或两小时稳定性；这些保留为 T4/T8/T9 的硬门。
- 不覆盖并行改动，不修改 README；本方案基线 HEAD `84c74ca`，实际执行先重新核对差异。
- 真实模型、服务切换、发布按届时授权和项目 SOP；本计划的生成不代表这些操作已经执行。

## 1. 依赖、里程碑和写入范围

```text
T0 标准契约基线
 └─ T1 领域时间/证据账本
     ├─ T2 固定正文对齐
     └─ T3 session actor + fake ports
          ├─ T5 文件 OpenAI API/SSE
          └─ T6 Realtime opt-in
已选 CoreML 制品 ─ T4 私有活动 worker ─┘
T1/T2/T3/T4/T5/T6 ─ T7 清除旧路径与资源接线
T8 可信评分可在 T0 后独立完成
T7 + T8 ─ T9 SDK/真实验收与切换准备
```

T0–T3、T5/T6 的 fake 集成和 T8 可并行。T4 已不等待模型选型，但其真实 adapter、尾部 flush 与分包不变性必须先通过；只有 T9 全部门通过才对外声明能力。

| 路径 | 动作/责任 |
|---|---|
| `src/speechrail/domain/diarization/` | 新建 `types.py`、`ports.py`、`timeline.py`、`attribution.py`；替代旧同名模块和 timeline 文件后只保留一份实现 |
| `src/speechrail/application/diarization/` | 新建 `session.py`、`transcribe.py`；领域事件不依赖 HTTP |
| `src/speechrail/backends/diarization/coreml.py` | 新建唯一生产 port adapter，固定 D1 选定的 CoreML FP16 制品 |
| `src/speechrail/runtime/diarization_worker.py` | 新建 IPC 和监督器，复用现有 lease/governor |
| `native/diarization/` | 新建 Swift package、worker executable 与 XCTest；构建随 release 安装，客户端无需 Swift |
| `src/speechrail/backends/qwen3_worker.py` | 在现有 worker 中增加直接 fixed-text alignment 命令，删除二次识别分支 |
| `src/speechrail/http/routes/audio.py`、`http/formatters.py` | 路由解耦、标准分人 serializer、SSE/multipart |
| `src/speechrail/application/realtime_openai.py`、`compatibility/openai_realtime.py` | 缩减为已有 Realtime 编排加新用例接入，删除旧分人业务分支 |
| `src/speechrail/application/services.py`、`app.py`、`config/` | 唯一组合根、惰性资源接线与能力声明 |
| `contracts/openapi.yaml`、`contracts/realtime-openai.md`、`contracts/diarization/` | 标准快照、扩展 JSON schema、正负 fixtures；旧扩展不保留运行分支 |
| `tools/evaluate_diarization_e2e.py`、`tests/` | 正确评分、反例、SDK 与集成回归 |
| `docs/users/api-contract.md`、`docs/operations/migration-runbook.md` | 受影响分人消费者迁移与发布操作说明；与并行修改逐项整合 |
| `docs/decisions/0012-openai-native-diarization.md` | 新 ADR；若执行时编号已占用取下一个空号，不覆盖；明确 supersede 0007/0010 的分人设计 |

正式迁移 `domain/diarization.py` 到 package 时，先调整其所有直接消费者和导出；不能同时留下同名文件和目录，不能用 forwarding module 保留旧行为。

## T0：固定 OpenAI 契约与普通消费者基线

**文件：** 修改 `contracts/openapi.yaml`；新增 `contracts/diarization/openai/` 响应 fixtures；修改 `tests/test_openai_diarized_batch.py`、`tests/test_openai_multipart.py`；新增 `tests/test_diarization_sdk.py`。SDK 依赖只进 dev/test，更新 `pyproject.toml`、`uv.lock`。

**输入：** 设计第 3 节及 2026-09-08 官方 schema。**输出：** 标准 JSON/SSE/multipart 的失败契约测试；普通请求原样基线。T5 消费这些 fixtures，不能重新定义字段。

- [ ] 保留现有普通模型 `json/text/verbose_json`、timestamps、错误和 Realtime 事件的通过用例；新增“分人未安装也能普通转写”的用例。
- [ ] 新建标准分人 fixture，严格断言 segment `id` 是 string、`type` 正确、speaker 为 A–D、segments 文本恰好拼回顶层正文，不包含 Whisper 专用 confidence 字段。
- [ ] 在现有 fake `_client` 装配模式上建立 `diarized_http_client` pytest fixture：返回 FastAPI `TestClient`，fake ASR 固定输出“你好。再见。”，fake 解码器输出 1.6 秒 PCM，fake 活动与对齐按 T1/T2 类型提供，不载模型。
- [ ] 锁定 OpenAI Python SDK 版本到 `uv.lock`，先跑以下 SDK 测试使现实现暴露标准缺口，而非先改测试接受 verbose 结构。

```python
from openai import OpenAI

def test_native_diarized_sdk(diarized_http_client):
    with OpenAI(
        base_url="http://testserver/v1", api_key="local",
        http_client=diarized_http_client,
    ) as sdk:
        result = sdk.audio.transcriptions.create(
            model="gpt-4o-transcribe-diarize",
            file=("clip.wav", b"fake-audio", "audio/wav"),
            response_format="diarized_json",
            chunking_strategy="auto",
        )
    payload = result.model_dump()
    assert payload["task"] == "transcribe"
    assert all(isinstance(s["id"], str) for s in payload["segments"])
    assert all(s["type"] == "transcript.text.segment" for s in payload["segments"])
    assert "".join(s["text"] for s in payload["segments"]) == payload["text"]
```

- [ ] 覆盖 `chunking_strategy` 对象的 SDK 编码、重复/冲突字段、已知 speaker 两种 form 编码明确拒绝、>30 秒缺 chunking、空正文和缺模型。畸形输入必须在调用模型前失败。
- [ ] 运行 `uv run --extra dev pytest --no-cov tests/test_diarization_sdk.py tests/test_openai_multipart.py tests/test_openai_diarized_batch.py`。记录新用例预期失败与普通用例继续通过，错误 fixture 不调成当前错误实现。

**完成标准：** 契约能够明确区分标准 `diarized_json` 与 verbose JSON，普通消费者基线可复用。此阶段允许新能力用例为红，但不可发布红态分支。

## T1：替换领域时间与证据账本

**文件：** 新建 `domain/diarization/{__init__,types,ports,timeline,attribution}.py`；迁移 `domain/diarization.py` 与 `domain/diarization_timeline.py` 的必要消费者；修改 `tests/test_diarization_timeline.py`，新增 `tests/test_diarization_attribution.py`。

**输出类型：** 后续任务共同使用下列类型，不能把秒浮点、model slot 或 transport DTO 混入应用接口。

```python
from dataclasses import dataclass
from typing import Literal

@dataclass(frozen=True)
class Span:
    start: int
    end: int

@dataclass(frozen=True)
class ActivityFrame:
    span: Span
    scores: tuple[float, float, float, float]
    active_slots: frozenset[int]

@dataclass(frozen=True)
class ActivityUpdate:
    epoch: str
    step_id: int
    replace_span: Span
    frames: tuple[ActivityFrame, ...]
    processed_through: int
    stable_through: int

@dataclass(frozen=True)
class TextUnit:
    id: str
    text_start: int
    text_end: int
    audio_span: Span | None

@dataclass(frozen=True)
class Attribution:
    unit_id: str
    speaker: str | None
    active_speakers: tuple[str, ...]
    state: Literal["provisional", "final"]
    reason: str | None
```

`Span` 非负、end≥start；有声文本单元 end>start。`active_slots` 是已锁定后处理结果；scores 保留用于诊断有效性与主 speaker 选择，不重新 softmax。所有跨进程值在 adapter 校验后才构造上述对象。

**领域接口：** `union_support(unit: Span, activities: tuple[Span, ...]) -> float`；`AttributionLedger.register(item_id, units)`；`apply(update) -> tuple[Attribution, ...]`；`terminate_pending(reason) -> tuple[Attribution, ...]`。ledger 构造时注入 accepted sample reader 和单一 AttributionPolicy；注册/应用由同一个 actor 串行调用。

- [ ] 先加入最小反例，不能用 clamp 掩盖重复计数：

```python
def test_growth_is_union_not_repeated_evidence():
    from speechrail.domain.diarization.attribution import union_support
    from speechrail.domain.diarization.types import Span
    assert union_support(Span(0, 1600), (Span(0, 1600), Span(0, 3200))) == 1.0

def test_overlap_is_not_a_probability_distribution():
    from speechrail.domain.diarization.attribution import union_support
    from speechrail.domain.diarization.types import Span
    u = Span(0, 1600)
    assert union_support(u, (u,)) + union_support(u, (u,)) == 2.0
```

- [ ] 实现裁剪后排序合并的区间并集；无交集 support=0，零时长文本不得进入除法。
- [ ] 实现按帧区间替换和 `epoch/step_id` 幂等；重复 step 不改变 revision/stable，payload 冲突失败，stable 帧修改失败。
- [ ] 实现 `stable_through <= processed_through <= accepted`，水位回退失败；final 条件是 unit.end 被真实稳定水位覆盖。
- [ ] 实现会话内 A–D 分配和主 speaker/unknown 规则；新增“重复快照仍 provisional”“末尾未稳定仍 provisional”“降级候选变 final null”“已 final 不被降级改写”的状态测试。
- [ ] 实现时间轴有状态重采样计数和包内切分；对同一 24 kHz PCM 使用不同 chunk 大小断言总 16 kHz 长度、item offset 和活动位置一致，padding 不计真实时长。
- [ ] 跑 `uv run --extra dev pytest --no-cov tests/test_diarization_timeline.py tests/test_diarization_attribution.py`，核对各类新反例确实触发正确状态。

**完成标准：** 时间支持不重复、overlap 不被压成单声道标签、final 与可靠性分离，domain 没有 vendor/HTTP 依赖。完整层边界测试在 T7 加入。

## T2：给既有 ASR worker 增加固定正文对齐

**文件：** 修改 `backends/qwen3_worker.py`、对应既有 ASR IPC DTO；新增 `application/diarization/alignment.py` 和 `tests/test_diarization_alignment.py`。

**接口：** 在 T1 `ports.py` 定义 `AlignTextPort.align(request: AlignmentRequest) -> AlignmentResult`。`AlignmentRequest` 包含 epoch/item_id、PCM16、16k owned/context span、固定 text、language；`AlignmentResult` 包含原 item_id、`tuple[TextUnit,...]` 或 failure reason，不返回替换正文。

- [ ] 写 fake aligner 测试：返回与请求不同的 canonical 字符、NaN 时间、越界、倒序、空结果时明确失败；“二〇二六”经既有 ITN 得到“2026”后使用实际冻结正文请求对齐。
- [ ] 在现有 Qwen3 worker 内用显式本地 `ForcedAligner` 初始化，新增 `align_text` 命令。操作核心为：

```python
# request.text 已由 ASR + 既有 ITN 冻结；aligner 已在 worker preflight 后加载。
aligned = aligner.align(
    audio=audio_samples,
    text=request.text,
    language=request.language,
)
# adapter 将 aligned 映射回原文 code point 范围；不调用 Session.transcribe。
```

- [ ] 编写原文到 canonical token 的显式映射，标点/空白只归入一处；未知符号保留，不按 token 数平均制造字级时间。
- [ ] 给 fake `Session.transcribe` 设置调用计数：一次转写结束后，对齐调用不能让计数增加；正文 hash 在 completed、alignment 和最终输出之间一致。
- [ ] 同一 ASR worker 内 ASR 解码优先，对齐最多排 3 个 item；释放 PCM 必须等对应消费者结束。普通请求不初始化 aligner。
- [ ] 运行 `uv run --extra dev pytest --no-cov tests/test_diarization_alignment.py` 及现有受影响 Qwen3 worker 用例。精确列出失败者再修复，不扩大到更换 ASR 模型。

**完成标准：** 固定正文直接对齐可通过 fake 回归，初始化只读本地制品，纯转写无新增对齐依赖。真实边界精度进入 T9，不生成第二张选型卡。

## T3：建立 transport 无关的单一会话 actor

**文件：** 新建 `application/diarization/session.py`、`transcribe.py`；新增 `tests/test_diarization_session.py`；在 `ports.py` 补活动接口。

**接口定义：** `StreamingActivityPort.open(epoch: str) -> ActivitySession`。`ActivitySession.append(start_sample: int, pcm16: bytes) -> None`、`updates() -> AsyncIterator[ActivityUpdate]`、`finish(through_sample: int) -> None`、`cancel() -> None` 均为 async，updates 是独立生产者。`DiarizationSession` 对 transport 提供 append、register_completed、finish、cancel、events；events 输出领域 `ItemAttributionUpdated/StatusChanged/SessionDone`，由 T5/T6 投影。

- [ ] 用 fake ports 写时序测试：活动先于文字、文字先于活动、无新 commit 但活动推进、align 晚到、finish 与 cancel 竞争、旧 epoch 迟到。
- [ ] actor 接收所有 PCM 后，分别投递活动输入与 ASR item；先交付 completed 正文，再异步获取对齐，活动循环独立 apply ledger。
- [ ] 每 item 的首份 units 固定后只修订 Attribution；无有效对齐时一个覆盖全文的 final unknown unit，时间 null。单 item revision 递增，session sequence 递增。
- [ ] 结束操作按以下固定顺序实现，不依赖客户端自行清空：

```text
finish(event_id)
  原子设置 accepting_audio=false，记录 accepted_through
  提交剩余 ASR 输入；空输入不制造空 item
  activity.finish(accepted_through) 与已提交 ASR 排空并行推进
  等待对应 alignment + activity stable；30 秒总 deadline 为进程回收预留 4 秒
  终结仍未知单元为 final unknown，得到 ok 或 degraded
  发最后的 item snapshots，再发 SessionDone(last_sequence)
  缓存 finish 结果供同 ID 幂等重发；释放输入和 lease
```

- [ ] 分人错误只终结待定 speaker、发 degraded 并继续正常正文；ASR/音频连续性错误按转写失败。degraded session 不隐式重启身份。
- [ ] 实现 5 秒活动 backlog、30 秒/4096 units ledger、最多 3 个 alignment item 的硬边界；慢客户端快照按 item 合并，不丢 standard completed 或 final。
- [ ] 运行 `uv run --extra dev pytest --no-cov tests/test_diarization_session.py`。检查 finish 重发不多做一次推理、clear 不重置身份、无音频 finish 可结束。

**完成标准：** 文件和 Realtime 能消费同一领域事件，fake 条件下时序/故障闭环；transport 无法访问模型 cache。

## T4：接入唯一活动 worker 并锁定制品

**文件：** 新建 `runtime/diarization_worker.py`、`backends/diarization/coreml.py`；新建 `native/diarization/Package.swift`、`Sources/SpeechRailDiarizationWorker/{main,Session}.swift`、对应 `Tests/`；新增 `tests/test_diarization_worker.py`。运行时已由 D1 选定为 CoreML FP16，不创建 NeMo production adapter。

**输入：** T1 ActivityUpdate 和 T3 ActivitySession。**输出：** 一个实现 ActivitySession 的真实 adapter，以及可注入 fake executable 的监督器。

- [ ] 先定义并测试私有 IPC：长度前缀消息，头含 protocol_version/request_id/epoch/operation/audio_start/audio_samples，PCM16 为二进制 payload；限制消息大小并校验长度。仅本地 pipe，不暴露为公共网络 API。
- [ ] fake worker 注入重复 step、越界水位、shape 错、NaN、挂起和崩溃，断言全部在 adapter 边界显式失败。
- [ ] 固定 D1 的 FluidAudio source commit `5c19d5e12320e22bbfb7a1877b089d2665a69add`、CoreML revision `ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1`、`v3/fp16/SortformerNvidiaLow_v2.1.mlmodelc`、`chunk=6/left=1/right=7/fifo=188/spkcache=188/update=144`、`computeUnits=.all`、完整 bundle hash 和许可 notice；使用显式本地 loader，禁止 `loadFromHuggingFace` 出现在请求调用链。
- [ ] Swift loader 只接受已安装的 `.mlmodelc`，用 `MLModel(contentsOf:configuration:)` 直接加载；对 `.mlmodelc` 调 `MLModel.compileModel` 或依赖 `Manifest.json` 必须 preflight 失败。D1 已证明无条件 compile 会失败，不能以“尝试编译后回退直接加载”保留两条路径。
- [ ] 在 worker preflight 断言实际模型输入为 `chunk=[1,112,128]`、`fifo=[1,188,512]`、`spkcache=[1,188,512]`，head 的 `pre_encoder_embs=[1,390,512]`、`speaker_preds=[1,390,4]`；所有 name、shape、dtype 或 compute units 不符均拒绝启动。不要使用模型卡误写的 `[1,390,128]` 输出 shape。
- [ ] Swift session 直接消费有限 mel/FIFO/cache 和 chunk result，提取四路活动与稳定边界；不使用累积整场 `timeline.framePredictions` 保存历史。后处理窗口有界，stable 包含后处理边缘延迟。
- [ ] 对任意 PCM 分包保持同一前端状态；尾部只补计算所需零，最终结果裁剪到 through_sample。文件使用同一 session 循环，禁止独立 offline Sortformer。
- [ ] 加入 90 秒、1,440,000 sample 的 D1 PCM 回放 smoke，并另建末尾 160 ms 含已知说话活动的 deterministic fixture。测试 `finish()` 后最后 stable watermark 和任何 final span 都不超过真实 `through_sample`，且 fixture 的尾部活动不丢失。D1 的 A/B 结果分别为 1,123/1,125 帧，只能作为待解释的 accounting 差异；不得把其中任一帧数写死为正确答案。
- [ ] Python 监督器管理精确 PID 与 lease。cancel 先通知 worker，2 秒后定向 terminate，再等 2 秒未退出则 kill 并确认；macOS 的实际进程退出结果决定何时释放资源，不能把 asyncio task 取消当作模型已停止。
- [ ] 不创建 `backends/diarization/nemo.py`、NeMo 分人 Python worker、`provider=auto` 或 try-CoreML-then-NeMo。NeMo 只保留在仓库外 D1 归档中作为对照证据。
- [ ] 运行 `uv run --extra dev pytest --no-cov tests/test_diarization_worker.py` 与 `swift test --package-path native/diarization`。真实制品 preflight、D1 PCM smoke 与断网短音频 smoke 使用锁定产物，在授权实验环境执行；`/usr/bin/time -l` 的单次 max RSS 只复现 D1 证据，不替代 T9 的 `phys_footprint` / P95 门。

**完成标准：** 只有一个生产 runtime，前端/模型/后处理状态持续且有界，取消能实际回收精确进程；不能只把 `supports_stream` 改成 true。

## T5：文件 OpenAI 原生分人和 SSE

**文件：** 修改 `http/routes/audio.py`、`http/formatters.py`、`application/diarization/transcribe.py`；更新 T0 契约与测试；新增 `tests/test_diarization_sse.py`。

**输入：** T3 领域结果流。**输出：** `format_diarized(result) -> dict[str, object]`，以及同一标准 segment 的 SSE 交付。普通 formatter 保持原行为。

- [ ] multipart 在 API 边界解析 SDK 的 scalar/list/bracketed object；冲突字段报参数错误，不通过吞掉未知参数伪装兼容。
- [ ] 用分人模型 ID 选择用例；标准输出支持 json/text/diarized_json；原生不支持项按设计表明确拒绝，普通模型约束不随之收紧。
- [ ] `auto/server_vad` 作用于 ASR chunking，保留原始时轴与分人持续状态；>30 秒校验在推理前完成，文件按背压尽快处理。
- [ ] serializer 用新标准 DTO 构造 string segment ID 和 type。按主 speaker 与相邻文本合并，保留标点和空白；合并后的 segment 时间取对应文本时间范围，不能丢未知内容。
- [ ] 遇对齐失败/无有效活动，JSON 返回 `diarization_unresolved`；SSE 发确定 error 并结束，无 done。全静音空文本成功。
- [ ] 用同一 segment DTO 发原生 delta/segment/done；不在 delta 提前发布 speaker，不给普通会话塞扩展 fields。以这类断言防止“HTTP 200 就算完成”：

```python
def assert_successful_stream(events):
    segments = [e for e in events if e["type"] == "transcript.text.segment"]
    done = [e for e in events if e["type"] == "transcript.text.done"]
    assert len(done) == 1 and events[-1] == done[0]
    assert "".join(e["text"] for e in segments) == done[0]["text"]
    assert len({e["id"] for e in segments}) == len(segments)
```

- [ ] 同时用原 SDK iterator 检查 SSE，不只用手写 parser。测试连接中断释放 PCM/lease、文件大于单块、非英文、部分尾帧、unsupported known speaker 参数。
- [ ] 运行 `uv run --extra dev pytest --no-cov tests/test_diarization_sdk.py tests/test_diarization_sse.py tests/test_openai_multipart.py tests/test_openai_diarized_batch.py`，T0 新契约全部变绿。

**完成标准：** 开发者仅使用标准 SDK 参数即可获得匿名分人；文档明确这是 OpenAI 匿名分人子集，未声称实现 known-speaker identification。

## T6：Realtime 单开关扩展

**文件：** 修改 `application/realtime_openai.py`、`compatibility/openai_realtime.py`、`contracts/realtime-openai.md`；新建 `contracts/diarization/realtime/{schema.json,fixtures/}`；修改 `tests/test_realtime_openai.py`、`tests/test_diarization_extensions.py`；新建 `examples/diarization/realtime.py`、`realtime.ts`（薄扩展类型和示例）。

**输入：** T3 领域事件。**输出：** 设计第 3.3 节唯一字段与事件，不增加新连接协议。

- [ ] 普通 session.update/append/commit/clear 的原 SDK 回归先保持通过。新增断言：未 opt-in 时 event types 不含 `speechrail.`，session.updated 无分人字段。
- [ ] 解析 `session.speechrail.diarization.enabled`；首次音频后启用拒绝，重复相同配置幂等；缺模型只拒绝启用，不破坏已有普通 session。
- [ ] 将 completed 正文原样发送，然后投影 ItemAttributionUpdated；DTO 只保留 `units/id/text_start/text_end/start/end/speaker/active_speakers/state/reason` 等设计字段，不输出 model slot/embedding。
- [ ] 测试正文“𠮷说 A。”的 code point 范围；TS 示例用 `Array.from(transcript).slice(start,end).join("")`，不能直接按 UTF-16 偏移 slice。
- [ ] 接入唯一 finish 事件，内部处理残留音频；正常 commit 的 item 自动最终化，不要求调用者学习 ledger/align/step。相同 finish ID 返回同一 done。
- [ ] status 只在变化时发送，分人异常后正文继续；未知 speaker 保留 null，不能用字符串 unknown 假装 OpenAI 原生字段。
- [ ] 示例复用官方 SDK 连接与通用事件发送，未知扩展通过该 SDK 可用的公开 JSON 通道接收。若某版 SDK 类型 union 拒绝扩展，只增加薄类型/原始 JSON 收发适配，不 fork SDK、不要求普通客户端导入它。
- [ ] 运行 `uv run --extra dev pytest --no-cov tests/test_realtime_openai.py tests/test_diarization_extensions.py tests/test_diarization_session.py`；断言 final snapshots 排在 done 前，clear 不改已提交 item 和身份。

**完成标准：** 分人消费者只多一个开关和扩展事件处理；普通消费者没有新增步骤。Python/JS SDK 对真实 WebSocket 的验证在 T9，不能仅以 fake 字典通过代替。

## T7：唯一组合根、资源隔离与旧路径删除

**文件：** 修改 `application/services.py`、`app.py`、`config/__init__.py`、`config/model_catalog.py`、`config/profiles.py`、`config/selection.py` 和必要 runtime lease/governor；删除旧 `backends/nemo_sortformer.py` 分人实现及无剩余消费者的 `backends/camplus.py`、`runtime/speaker_centroids.py`；调整旧分人 contracts/tests。新建 `tests/test_diarization_boundaries.py`、`tests/test_diarization_admission.py`。

**输入：** T3/T4 新实现。**输出：** 生产只装配一条链路，资源按实际请求参与，普通路径没有额外依赖。

- [ ] 先枚举旧符号真实调用者和配置引用，限定删除范围；同文件存在非分人消费者时保留其业务，不扩大清理。
- [ ] 所有创建统一走组合根；普通请求根本不取得 ActivityPort/AlignTextPort lease，配置存在不会改变普通 ready 或预算。
- [ ] worker lazy start；只对活跃分人资源计费，空闲释放沿用现有 lease 规则。实际分人争用超预算报 busy/degraded，不通过复制 ASR/分人进程加吞吐。
- [ ] 删除 legacy session、single-speaker native port、group linkage、CAM++ remap、unused evidence index、双开关与按 hint 裁剪；新目标不提供 speaker count hint，四人上限由能力声明表达。
- [ ] 删除旧测试中的“允许新契约未接通”断言；保留有价值场景并迁移到新领域用例。确认旧字段请求明确失败，不被静默忽略。
- [ ] 增加 dependency test，禁止新的分人 domain/application 子模块导入 NeMo/CoreML/FastAPI/具体 adapter；runtime/transport 可向内依赖，既有组合根允许导入具体实现。AST 检查本地模块导入，不能仅靠字符串不存在下结论，不借此重构无关 application 模块。
- [ ] mock 分人模型完全缺失和初始化异常，断言普通 ASR/TTS 成功；mock 活跃 lease 和 idle evict 竞争，断言未确认退出前不装载第二份权重。
- [ ] 运行 `uv run --extra dev pytest --no-cov tests/test_diarization_boundaries.py tests/test_diarization_admission.py tests/test_diarization_worker.py`，并对被删除符号做 scope 检索，确认无运行入口。

**完成标准：** 没有 fallback/provider auto、旧扩展并行处理或主进程同步 NeMo 推理。与此目标无关的普通 API 兼容归一化保留。

## T8：修复评分可信度并建立验收输入

**文件：** 修改 `tools/evaluate_diarization_e2e.py`、`tests/test_diarization_metrics.py`；必要依赖进 test/eval extra，原始音频/RTTM/转写不入仓库。

**接口：** CLI 显式接受 manifest、UEM、collar、overlap policy；输出 schema 版本、样本数、DER 分量、JER、CER、条件归属错误、unknown、cpCER 与评测指纹，不把缺失值变为 0。

- [ ] 先加“空参考且有预测不能 DER=0”“缺失 RTTM 必须失败”“所有字都不同但同 speaker 不得字符错误=0”“额外 hypothesis 计插入”的反例。
- [ ] 用 `pyannote.metrics` 的锁定实现交叉验证手算 DER/JER；每场统一匿名映射，Hungarian assignment 取代阶乘排列。UEM/overlap/collar 必须显式记录。
- [ ] CER 计算文本编辑距离；条件归属率只对已对齐同文字符计算并注明分母。cpCER 对每个 speaker 汇聚文本，按整场最优置换后的字符编辑代价求和；unknown 为未匹配槽，插删改均计入。
- [ ] 所有 reference 与 hypothesis 输入校验 finite、非负、时序、speaker scope 和存在性。合法全静音文件单列 FA 秒数，不以缺少标注伪装静音。
- [ ] 准备发布 eval manifest，按会议和真实说话人隔离 tune/eval，包含清晰/远场/重叠/短插话/相似音色/静音后返回；只用已授权标注数据，困难边界人工复核。
- [ ] 运行 `uv run --extra dev pytest --no-cov tests/test_diarization_metrics.py`。报告每类有效时长与未知比例，不用一项均值遮蔽困难类失败。

**完成标准：** 评分反例与权威基准一致，缺失/错误输入显式失败；它是实施交付的一部分，不再作为 V0 卡要求用户另派工程人员。

## T9：集成、质量门与发布准备

**文件：** 新建 `tests/sdk/` 下 Node SDK 集成测试及锁文件；完善 Python SDK 测试；更新 `docs/users/api-contract.md`、`docs/operations/migration-runbook.md`、目标 ADR 与授权范围内配置/构建流程。README 不在本任务授权内。

- [ ] 锁定 Python/JavaScript SDK 版本，fake backend 下用真实 HTTP/WebSocket 连接跑普通与分人请求。HTTP 测试能使用 ASGI/TestClient；WebSocket 另启动临时端口的 fake 测试 app，不启动第二个真实 SpeechRail 模型服务。
- [ ] Node 使用官方 `openai` SDK 和 `node:test`，在独立 `tests/sdk/package.json` 中记录实际依赖版本并提交 lock；测试 `diarized_json`、SSE、嵌套 multipart、普通 Realtime 和 opt-in 扩展。TS 薄类型另做类型检查，普通 SDK 无需导入扩展包。
- [ ] 完整 deterministic gate：

```bash
uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
git diff --check
```

- [ ] CoreML 路线执行 Swift package tests 与构建；检查 wheel/release 能定位附带的 native executable，版本/IPC 不匹配在 preflight 失败。运行 `npm ci --prefix tests/sdk` 和 `npm test --prefix tests/sdk`，测试脚本自行管理 fake server 生命周期。
- [ ] 在授权环境、D1 锁定制品上用真实公共接口跑固定中文 eval；目标与口径见设计第 9 节。保留普通 CER 对照，归属无正文丢失/重复/改写。SDK 测试成功不替代语音质量验收。
- [ ] 执行两小时 soak 和精确 worker 故障注入：晚加入、长静音后返回、8 秒 owned interval 包内边界、overlap、慢发送端、取消与 finish 竞争。测相关进程 phys_footprint，不机械累加统一内存重复统计。
- [ ] 对照分人关闭/开启，验证普通请求无分人依赖、无可重复超 5% 的新增常态开销；活跃共存 ASR P95 退化 ≤10%；达不到目标就限制能力或停止发布，不偷偷调宽门槛。
- [ ] 写 ADR：采用原生 OpenAI 文件分人、Realtime opt-in、单连续引擎、固定正文、无身份库、一个生产运行时；明确替代旧 0007/0010 的相冲突决定。
- [ ] 迁移说明只要求旧分人扩展消费者改用一个开关和新事件；普通 SDK 消费者不迁移。major 发布切换不新建 `/v2` 端点，注明这是当前用户对协议方向的明确要求。
- [ ] 形成可评审 release 清单和上一 release 回退步骤；实际发布按 `speechrail-release`、本机服务按 `speechrail-local-deploy` SOP，在已授权维护窗口操作。保留私有配置、模型与上一 runtime，不建立运行期 fallback。

**完成标准：** 全部门与实际输出核对通过；未测项明确标记，不以 readyz、测试退出码或任务勾选证明质量。发布前不得宣称两小时/质量目标已经达到。

## 2. 阶段交付和停止条件

| 里程碑 | 可评审结果 | 停止条件 |
|---|---|---|
| M1：T0–T3 | 标准失败/通过基线、正确账本、固定正文、fake 会话状态机 | 领域状态或文本一致性无法满足设计 |
| M2：T4–T6 | 锁定 CoreML port、标准文件 API/SSE、Realtime 单开关 | CoreML preflight、尾部 flush 或未知 SDK 事件行为未验证 |
| M3：T7–T8 | 无旧路径、普通请求隔离、可信评分 | 普通 API 回归或评分真值不足 |
| M4：T9 | 固定制品的本机验收报告、迁移与发布清单 | 任何硬门失败，或实际质量/资源证据缺失 |

当前阶段已完成设计、计划和 D1 runtime 决定；实现复选框均未执行。D1 的 RTTM/UEM、DER、分包、ASR 共存和长期验收缺口已归入 T4/T8/T9，不转换成更多外派卡片。

## 3. 方案覆盖自检

| 设计要求 | 实施任务 |
|---|---|
| 原生 OpenAI、SDK 零强制迁移、标准 serializer/multipart/SSE | T0、T5、T9 |
| Realtime 最小 opt-in、正文先出、finish 幂等 | T3、T6 |
| 连续时轴、多 speaker、稳定水位、unknown | T1、T3、T4 |
| 固定文本直接对齐、无二次 ASR | T2 |
| 本机 FP16、私有 worker、真实取消、有界状态 | D1 运行时证据、T4、T7、T9 |
| 普通请求无额外依赖/资源成本 | T0、T2、T7、T9 |
| 不兼容旧分人内部路径、不移除 OpenAI 标准 | T5、T6、T7、T9 |
| 正确评测与实测边界 | T8、T9 |
| 最少外派、单一选定运行时 | D1 决定、本文件依赖图 |

本计划未修改源代码、现行契约、服务、配置或并行改动，也没有提交、部署或创建外部任务。模型下载与运行仅发生在已完成、仓库外的 D1 runtime smoke，证据见归档报告。
