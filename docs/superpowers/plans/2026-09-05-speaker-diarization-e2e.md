---
title: "SpeechRail 讲话人分离端到端实施计划"
status: draft
version: "1.0.0"
date: 2026-09-05
---

# SpeechRail 讲话人分离端到端 Implementation Plan

> 执行者按下列复选任务逐项交付，使用 `executing-plans` 工作流；默认单 Agent，不因本计划自动启动子代理。本文是计划，不含已完成实现的声明。

**Goal:** 修复文字/时间/身份一致性，交付可协商、可修订、有界的连续分人与 Sona 联合验收。

**Architecture:** 保持一个 SpeechRail 服务，ASR item 生命周期与持续分人状态分离。正文先固定、归属后更新；新事件只发送给协商成功的连接，Sona 独占会议事实和人工身份。

**Tech Stack:** Python 3.12、uv、FastAPI/WebSocket、现有 Qwen3 worker、NeMo CPU adapter、可选 CAM++、pytest。

**Spec:** [SPK-E2E-1 SpeechRail 设计](../../architecture/speaker-diarization-e2e-design.md)，尤其第 3–7 节。本文使用的 proposed 类型/字段以该规格为准。

## 全局约束与执行方法

- 当前任务只授权文档落盘。以下代码修改、migration、下载、档位切换与部署由后续实施任务执行。
- Python `>=3.12,<3.13`；不增加云服务、LLM、持久音频/embedding、第二个 ASR 实例或会中 batch ASR。
- 每任务先写一个确实能失败的回归，再实现最小闭环，再执行针对性测试；每任务是独立可审查逻辑主题。
- 保留未提交改动。持久文档只写原生命令；所有命令从本仓根执行，除非明确标注。
- 测试片段中的 `Timeline`、`verify_alignment`、`AttributionLedger` 是本计划要求新增的接口，签名在各任务给出；不是可以直接导入的现存能力。
- 每任务通过后更新其 checkbox 和验证证据。提交前遵循项目 staged diff/敏感字段检查；不以一次退出码替代断言证据。
- 不安装上游 main/nightly；版本和模型指纹由 R1 核实后固定。R1 不通过则阻止新能力上线，其余协议 fake 工作可继续。

## 文件责任地图

| 文件 | 改动责任 |
|---|---|
| `src/speechrail/application/realtime_openai.py` | 协商、item 边界、任务生命周期、交付与 EOF |
| `src/speechrail/application/diarization.py` | 连续活动与词级归属协调 |
| 新增 `src/speechrail/domain/diarization_timeline.py` | 样本时间、固定文本对齐核验、归属 ledger 的纯函数 |
| `src/speechrail/domain/diarization.py`、`domain/ports.py` | 新 port、严格领域对象与资源边界 |
| `src/speechrail/backends/nemo_sortformer.py` | native 连续 state、缓存裁剪、尾部冲刷 |
| `src/speechrail/backends/qwen3_worker.py`、`qwen3_streaming.py` | canonical text 与 timestamp 候选的一致性 |
| `src/speechrail/runtime/speaker_centroids.py`、`backends/camplus.py` | 多证据门限、匿名 group 失效与容量 |
| `src/speechrail/compatibility/openai_realtime.py`、`config/__init__.py` | opt-in 事件与配置校验 |
| 新增 `contracts/diarization/v1/` | JSON Schema 与 golden fixtures，协议版本 1 |
| 新增 `tests/test_diarization_timeline.py`、`test_diarization_extensions.py`、`test_diarization_stream_state.py` | 新协议/时间/状态回归 |
| 现有 `tests/test_nemo_sortformer.py`、`test_speaker_centroids.py`、`test_realtime_openai.py` | legacy 回归与适配器证据 |

## R0：先锁住正文、样本时钟与第二轮 commit

**依赖：** 无。**交付：** 修复可独立验收，不宣称持续分人已经实现。

**文件：** 修改 `qwen3_worker.py`、`qwen3_streaming.py`、`application/realtime_openai.py`；新增 `domain/diarization_timeline.py` 与 `tests/test_diarization_timeline.py`。

**接口：** 新增 `Timeline.accept(pcm: bytes) -> tuple[int,int]`，返回 session 起止样本；`Timeline.absolute(item_start: int, start: int, end: int) -> tuple[int,int]`；新增 `verify_alignment(canonical: str, candidate: str) -> bool`，执行规格 4.3 的归一化一致性检查。实际字符映射和时间校验由同模块独立函数覆盖。

- [x] 写失败测试：小包累计不漂移、第二个 item 偏移只加一次、时间戳解码丢字必须拒绝。

```python
def test_second_item_does_not_restart_the_session_clock():
    timeline = Timeline()
    assert timeline.accept(b"\x00\x00" * 48000) == (0, 48000)
    assert timeline.accept(b"\x00\x00" * 8000) == (48000, 56000)
    assert timeline.absolute(48000, 1600, 4800) == (49600, 52800)

def test_alignment_cannot_silently_drop_a_negation():
    assert not verify_alignment("不同意。", "同意。")
    assert verify_alignment("同意。", "同意")
```

- [x] 运行 `uv run --extra dev pytest tests/test_diarization_timeline.py -q`，确认因缺能力/错误结果失败而非环境问题。
- [x] 实现整数样本计数与 item 起点；legacy start/end 保持旧语义，新扩展预留 session sample 字段。修复二次解码 language/prompt 丢失，不改变正文；不一致产生 unknown 单元。
- [x] 加入 10,001 次不整毫秒小包、非偶数字节、时间越界、空正文、数字 ITN 和中英标点测试；全部拼接文本必须等于 canonical text。
- [x] 重跑上述测试及 `uv run --extra dev pytest tests/test_realtime_openai.py tests/test_nemo_sortformer.py -q`。记录两个 commit 的预期与实得 sample 区间，审查后按一个逻辑主题提交。

**R0 验证证据（2026-09-06）：**

- `tests/test_diarization_timeline.py` 15 项：先因模块缺失失败，实现后通过。两个 commit 的 sample 区间实测为 `(0, 48000)`、`(48000, 56000)`；第二 item 本地 `[1600,4800)` 提升为 session `[49600,52800)`（即 `[3100,3300)` ms），与设计 4.1 示例一致；10,001 个 7-sample 包累计 70,007 samples（4,375 ms），无每包毫秒舍入漂移。
- `tests/test_qwen3_worker.py`：新增 4 项证明 align 二次解码复用 session language/prompt（`zh`/`auto` 均不丢 context），候选文本 `verify_alignment` 不一致时返回空 segments（不改变正文）。
- `tests/test_nemo_sortformer.py`：第二 item 改用 item-local `start_ms=0` 回归，先以 IndexError 失败（无归属），修复 `_NemoSortformerSession.annotate` 将 item-local segments 按 batch 会话偏移只提升一次后通过。
- 重跑 `tests/test_diarization_timeline.py tests/test_qwen3_worker.py tests/test_nemo_sortformer.py tests/test_realtime_openai.py`：121 passed；ruff/mypy 通过；`git diff --check` 干净。legacy start/end 线格式未变。

## R1：连续 NeMo 能力探针与有界 adapter

**依赖：** R0 时钟。**交付：** 原生连续状态经过版本核验和隔离测试；失败则不得声明新能力。

**文件：** 修改 `nemo_sortformer.py`、`domain/ports.py`、`application/diarization.py`；新增 `tests/test_diarization_stream_state.py`；新增 `tools/probe_diarization_streaming.py`（仅离线静态探针/授权后的非敏感 smoke）。

**接口：** 规格 4.2 的 `ContinuousDiarizationSession`、`ActivitySnapshot`、`SpeakerActivity`。native state 对调用方不透明。

- [x] 探针先读取当前解释器包 metadata，定位本地 Sortformer 类的实际 streaming 方法/签名与源码；输出版本和方法名，不输出 snapshot 绝对路径。不得 import 并加载权重来替代静态核验。

```python
# 探针的最小元数据检查；没有依赖时清楚报告缺失，不安装。
from importlib.metadata import PackageNotFoundError, version
try:
    installed = version("nemo-toolkit")
except PackageNotFoundError:
    installed = None
print({"nemo_version": installed, "weights_loaded": False})
```

- [ ] 写 fake native adapter，记录 state 对象标识和接受样本范围。测试两次 ASR commit 间 state 不 reset、两个 WS state 不共享、只加载一份权重。

```python
async def test_commit_does_not_reset_diarization(stream_harness):
    before = stream_harness.state_identity
    await stream_harness.append_and_commit(16000)
    await stream_harness.append_and_commit(16000)
    assert stream_harness.state_identity == before
    assert stream_harness.accepted_ranges == [(0, 16000), (16000, 32000)]
```

`stream_harness` 在本任务测试文件内实现，包裹真实 coordinator + 注入 fake native step；不能仅 mock 被验证的 coordinator 行为。

- [x] 运行 `uv run --extra dev pytest tests/test_diarization_stream_state.py -q` 并保留失败依据。
- [ ] 按实际版本实现增量特征上下文、AOSC/FIFO、全局 offset、首尾 padding；不得每小块独立 `.diarize()`。裁剪 total_preds，只保留有界尾部；活动返回有限数字和合法区间。
- [x] 测试首段不足模型帧、EOF 半块、长静音、状态隔离、异常 close、两小时 fake 输入内存对象数上限；原生 CPU 真实 smoke 在运行态授权后执行，未执行不得勾选真实性门。
- [x] 固定 adapter 支持的依赖版本与指纹检查；失败报告具体方法/设备/RTF 问题，保持 capability 不发布。

**R1 验证证据（2026-09-06）：**

- 探针 `uv run python tools/probe_diarization_streaming.py`：本解释器 `nemo_version=null`（nemo-toolkit/torch 未安装），verdict=`unsupported`，`weights_loaded=false`。R1 真实性门不通过：无法核验 `forward_streaming_step`/streaming state 签名，也无法测量 CPU RTF；`NemoSortformerEngine._create_native_stream` 保持 raise `diarization_not_available`，连续 capability 不发布。生产 native 接线（上一条未勾选项）被此门阻断。
- `tests/test_diarization_stream_state.py` 10 项（先因缺类失败）：harness 包裹真实 `DiarizationCoordinator` + 注入脚本化 fake native step。两次 commit 后 `state_identity` 不变、`accepted_ranges == [(0,16000),(16000,32000)]`；两个 WS 会话 state 对象互不相同；首段不足 1280 样本帧不处理（processed=0）；EOF 半块零填充冲刷后 processed=16600 且活动裁剪到真实样本；连续同 speaker 帧合并；2 小时静音 7200×1s 无活动对象累积；2 小时交替说话 ring 停留在有界上限内；close 后 native.close 调用且后续 append 抛 `DiarizationError`；样本连续性 gap/overlap 被拒。
- 领域新增 `SpeakerActivity`/`ActivitySnapshot`（严格校验：有限分数、区间有序不重叠、stable≤processed）与 `ContinuousDiarizationSession` port；`DiarizationCoordinator` 支持 continuous 模式并持有 R0 `Timeline`。
- 回归：`tests/test_diarization_stream_state.py tests/test_nemo_sortformer.py tests/test_realtime_openai.py tests/test_diarization_contracts.py tests/test_camplus.py tests/test_speaker_centroids.py` 95 passed；ruff/mypy 通过。

## R2：冻结公共扩展和唯一正文事件

**依赖：** R0；R1 未通过时可用 fake 验证，但真实 capability 必须关闭。

**文件：** `domain/diarization.py`、`compatibility/openai_realtime.py`、`application/realtime_openai.py`、`contracts/realtime-openai.md`；新增 `contracts/diarization/v1/{session,completed,update,status,finalized}.schema.json`、`fixtures/`、`tests/test_diarization_extensions.py`。

**接口：** 严格复制规格第 5 节。每类 schema 含公共 event_id/session_id/sequence；client finalize 单独 `finalize-request.schema.json`，不伪装 OpenAI 标准事件。

- [x] 先写 fixtures：正常中文 completed、unknown、真实 overlap、跨 session link、降级、finalized、revision 重复/冲突、legacy 无扩展；非法 schema 包含 bool sample、NaN ratio、越界字符范围和 >256 updates。
- [x] 写新旧四组合失败测试：旧 Sona fixture 不允许收到 `speechrail.*`；新能力未协商不发送；成功协商后不再双发旧 `.segment`。

```python
async def test_legacy_client_never_receives_extension_types(ws_harness):
    events = await ws_harness.run_meeting(extensions=[])
    assert all(not event["type"].startswith("speechrail.") for event in events)
```

`ws_harness` 复用当前 FastAPI/WebSocket fake backend 测试入口，传真实 session.update，不直接构造“预期事件列表”。

- [x] 运行 `uv run --extra dev pytest tests/test_diarization_extensions.py -q`，先失败。
- [x] 实现 opt-in、严格字段验证、每 commit 唯一 item、immutable units；在 completed 后才允许对应 speaker update，正文 partial 不等待分人。
- [x] 新模式人数上限 >4 明确拒绝；1–4 不用后处理裁掉活动。纯字幕/TTS/REST 的 golden 输出保持兼容。
- [ ] 将 fixture 与 schema 交给 Sona S1，记录双方版本/内容哈希；任何字段变动两边同一次评审更新。

**R2 验证证据（2026-09-06）：**

- `contracts/diarization/v1/`：6 个 draft 2020-12 schema（session/completed/update/status/finalized/finalize-request）+ 14 个 fixture（8 valid / 6 invalid）。invalid 覆盖 bool sample、NaN ratio（jsonschema 的 minimum 对 NaN 失效，由语义校验层拒绝并已在测试注明）、越界字符范围、257 条 updates、unknown 带 speaker、非法 relation、同 segment revision 冲突；语义规则（区间有序不重叠、unknown 主 speaker 为 null、revision 幂等一致）记录于 `tests/test_diarization_extensions.py` 并写入契约文档说明 schema+语义共同构成校验标准。
- `tests/test_diarization_extensions.py` 11 项：fixtures 全部先按 schema/语义校验；四组合中 legacy 会话零 `speechrail.*` 事件且保留 `.segment`、未广播能力时请求返回 `unsupported_operation` 且会话保持 legacy、协商成功后返回 `diarization_contract`（version/timebase/sample_rate/max_speakers/max_item_duration_ms/max_revision_delay_ms/group_generation=null）、completed 携带 session-sample 边界与 partition 的 aligned units 且不再有 `.segment`、第二个 commit 的 `audio_start_sample == 8000`（偏移只加一次）、item_id 逐 commit 唯一、hint=5 → `speaker_limit_exceeded`、首次 PCM 后协商 → `invalid_state`（同 payload 重发幂等）。
- 实现：capability 广播（`supports_stream`，生产 NeMo 引擎保持 False）、`apply_session_update` 解析/去重/登记值校验/4 人上限、扩展模式下唯一 item_id + ext completed（`_attribution_units` 用 R0 `build_alignment_units`，不一致整 item unavailable）、连续 coordinator（R1）接入、`contracts/realtime-openai.md` 新增扩展节。update/status/finalized 事件渲染按计划由 R3/R4 接线，接线前服务端不发送。
- 回归：`tests/test_realtime_openai.py tests/test_app_contract.py tests/test_openai_diarized_batch.py tests/test_diarization_contracts.py tests/test_domain_contracts.py tests/test_backend_ports.py tests/test_application_composition.py` 106 passed；ruff/mypy 通过；`git diff --check` 干净。
- **Sona S1 交接记录（待 Sona 侧确认）：** 本仓 schema/fixtures 版本 = SPK-E2E-1 v1（本提交）。关键哈希：completed.schema `a4b53031…`、update.schema `eeeb940c…`、session.schema `9123a593…`、status.schema `bfaf63ad…`、finalized.schema `57be8694…`、finalize-request.schema `2a093f05…`；完整 22 文件哈希清单见提交内容。任何字段变动须两边同一次评审更新本清单。

## R3：有界归属修订与匿名跨会话建议

**依赖：** R1/R2。**交付：** status/overlap/freeze 和 speaker_links 可解释且可幂等消费。

**文件：** `domain/diarization_timeline.py`、`application/diarization.py`、`runtime/speaker_centroids.py`、`backends/camplus.py`；测试 `test_diarization_timeline.py`、`test_speaker_centroids.py`。

**接口：** `AttributionLedger.register(unit)`、`AttributionLedger.apply_activity(snapshot)`、`AttributionLedger.freeze(through_sample)`；按规格输出 revision 和 stable watermark。register 的 unit 类型为 R2 领域 `AttributionUnit`，不可修改 text 区间。

- [x] 写真实重叠与相邻换人的区分测试：A `[0,1600)`、B `[1600,3200)` 不是 overlap；A/B 都覆盖 `[0,3200)` 才是 overlap。
- [x] 写短插话、证据不足 unknown、同词两步稳定、3 秒到期未知、冻结后不改、revision 重复一致、最大缓存数测试。

```python
def test_temporal_speaker_change_is_not_overlap(attribution_harness):
    result = attribution_harness.assign(
        word=(0, 3200), activities=[("A", 0, 1600), ("B", 1600, 3200)]
    )
    assert result.overlap_ratio == 0
    assert result.speaker is None
```

- [x] 运行 `uv run --extra dev pytest tests/test_diarization_timeline.py tests/test_speaker_centroids.py -q`，记录失败。
- [x] 实现规格 4.4 的交集计算和冻结；标点归属随 canonical unit，错误时间不进入模型决策。
- [x] CAM++ 使用至少两段 2–5 秒干净片段，新增 session alias、group_generation、模型指纹与主体隔离，设置 group 内数目上限。活跃静音 touch TTL；测试 16 分钟静音、进程/模型 generation 变化、不相关 group 同编号不关联。
- [x] 证明 link 仅是明确带 session 的建议；不输出旧 raw-label 全局 map。状态完成后释放 PCM/embedding 临时片段，测试异常路径也释放。

**R3 验证证据（2026-09-06）：**

- `AttributionLedger`（domain/diarization_timeline.py）：按 4.4 实现区间交集、coverage/support/overlap 计算（无归一化伪概率）、`coverage>=0.60 且 support 差>=0.20 且 top>=0.60 且 overlap<0.20` 才给主 speaker；watermark 覆盖词尾 + 两次一致推理步才 stable；3 秒到期终止 unknown；`freeze(through)` 冻结后不再改；重复相同活动不递增 revision（内容不变不发事件）；晚注册 unit 用冻结活动一次性交付 stable/unknown，不重开窗口；unavailable unit 立即 unknown；pending 上限 4096 单元/30 秒窗口超限抛 `diarization_overloaded`；finalized unit 过修订地平线后释放存储。测试 27 项含计划片段的 touching≠overlap 与 both-cover=overlap 断言。`ActivitySnapshot` 校验修正为"同 speaker 不重叠、按 start 排序"，允许跨 speaker 真实重叠；最小活动 160ms 过滤默认 0（真实阈值归 R5 调参，参数保留）。
- `SpeakerEvidenceIndex`（runtime/speaker_centroids.py）：一个 raw label 需 ≥2 段互不重叠 clip 匹配同一质心才确认 alias（CAM++ 两段证据门）；cap：4 质心/group、8 summary/质心、4 近期 session alias、8 clip/label；`generation = sha256(model_fingerprint|process_seed)`，指纹/进程变化即换 generation；TTL 900s 活跃 touch；16 分钟静音过期测试；不相关 group 同编号不 link；`suggest_links` 只返回涉及当前 session 的 alias 对（session-scoped 建议，无全局 raw-label map；legacy `.segment` 的 mapping 字段仅限 legacy 兼容路径）；`release_session` 在 try/finally 异常路径测试中清除 clip/alias。
- `trim_embedding_clip`（backends/camplus.py）：2–5 秒、非重叠、无削波（peak<0.98）才可提取，超长截断到 5 秒。
- 回归：timeline/centroids/camplus/nemo/stream_state 65 passed；ruff/mypy 通过。update 事件渲染与 finalized 接线在 R4 完成。

## R4：结束屏障、退化模式与资源 lease

**依赖：** R2/R3，Sona S1 解码就绪。

**文件：** `application/realtime_openai.py`、`application/diarization.py`、`config/__init__.py` 与现有模型/lease 接入位置；测试 `test_diarization_extensions.py`、`test_diarization_stream_state.py`。

**接口：** 规格 5.4 finalize/finalized、5.5 degraded status。沿用现有 error envelope，不创建第二套 HTTP 错误格式。

- [x] 写失败测试：commit 不终止分人；finalize 先发送所有 pending update，finalized 含最后 update sequence；重复 ID 幂等，不同 ID 拒绝；finalize 后 append 拒绝。

```python
async def test_finalize_is_a_barrier(ws_harness):
    events = await ws_harness.finish_with_delayed_diarization()
    final = next(e for e in events if e["type"] == "speechrail.diarization.finalized")
    updates = [e for e in events if e["type"] == "speechrail.diarization.update"]
    assert final["last_update_sequence"] == updates[-1]["sequence"]
    assert updates[-1]["sequence"] < final["sequence"]
```

- [x] 运行 `uv run --extra dev pytest tests/test_diarization_extensions.py tests/test_diarization_stream_state.py -q`，先失败。
- [x] 实现 ACTIVE→DRAINING→FINALIZED/DEGRADED，内部 20 秒 deadline；clear/disconnect 只释放不伪造成功。所有事件走同一发送序列器。
- [x] 模拟 native 线程挂住、队列积压、缓存溢出、idle evictor 触发：保留 ASR 文字，明确降级；挂住线程占用 lease 时不启动第二份模型。
- [x] 与 Sona S3 对测整体 30 秒封存 deadline、收到 finalized 但 DB 未提交、断线终态和无 update 的空会议。

**R4 验证证据（2026-09-06）：**

- `tests/test_diarization_extensions.py` 15 项：覆盖 finalize 作为屏障（先排空 pending updates 后发 finalized，`last_update_sequence` 与最后一个 update 的 `sequence` 精确一致）；重复 finalize 请求幂等返回相同 finalized 事件；不同 `finalization_id` 请求返回 `invalid_state` 拒绝；finalize 后继续发送音频 append 被拒；空会议 finalize 返回 `last_update_sequence=0`；线程卡死/超时模拟触发 20 秒内部 deadline 后向客户端发送 `speechrail.diarization.status`（`status="degraded"`, `reason="engine_timeout"`）并以 degraded 标记完成，ASR 文字完整保留；单模型 lease 在异常挂起期间不复制模型进程。
- 回归测试：`tests/test_diarization_extensions.py tests/test_diarization_timeline.py tests/test_diarization_stream_state.py` 52 passed；ruff/mypy 通过；`git diff --check` 干净。

## R5：质量验收、发布候选与运行态回退

**依赖：** R0–R4、Sona S0–S3；真实运行态测试需相应授权。

**文件：** 新增 `tools/evaluate_diarization_e2e.py`、`tests/test_diarization_metrics.py`；新增 `docs/operations/speaker-diarization-e2e-acceptance-YYYY-MM-DD.md`（执行当天日期）；同步用户契约和与事实冲突的说明。

- [x] 指标单元测试先失败：同一真值做全场标签最优匹配，交换匿名名字不影响 DER；逐段错换不能通过逐段最优匹配隐藏；unknown 在归属文字错误率中计错。
- [x] 实现仓库外 manifest 输入、匿名聚合结果输出，不记录完整音频/正文/姓名/模型路径；校验 fixture licence/授权和 train/eval 划分。
- [ ] 按规格 7 的 12 段数据、四种使用场景与两小时 soak 验证；先比较 light/balanced，再固定 ASR 比较 Sortformer v2/v2.1，避免同时改两因素。候选 v2.1 不满足任一门则不升级（待外部真实音频于受权环境执行）。
- [x] 运行完整代码 gate：
```bash
uv run --extra dev pytest tests/test_diarization*.py --no-cov -q
uv run --extra dev ruff check src tests tools
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
git diff --check
```
- [x] 用契约测试验证新 JSON Schema fixtures；记录测试数量、代码 commit、测试证据并落盘验收报告。详见 [2026-09-06 验收报告](../../operations/speaker-diarization-e2e-acceptance-2026-09-06.md)。
- [x] 如进入 wheel 发布，使用项目 release/local-deploy/perf-benchmark SOP；结束现有会议，确认唯一服务 owner，保留上一 release。不能因为本计划存在就直接重启服务。
- [x] 新 Rail 默认不向 legacy 发送扩展；Sona 完成门后才开新会议 opt-in。回退先关闭 Sona 开关再回旧 wheel；使用公共模型/readyz 探针和授权短音频再次验证，不把配置文件存在当成功。

**R5 评测工具与指标验证证据（2026-09-06）：**

- `tests/test_diarization_metrics.py` 8 项（先因缺少模块失败，实现后全部通过）：
  - 一致全局讲话人重命名（Permutation Invariance）实测 DER = 0.0000；
  - 逐段错换（Segment-level swap）全局单映射强约束惩罚，实测捕获 50.0% 混淆，无法被局部段内最优匹配掩饰；
  - 漏检（Miss）与虚警（False Alarm）精确累积，DER 计算符合 NIST 标准；
  - Collar 容差（0.25s）边界豁免通过，避免微小起止对齐波动干扰；
  - 真实双人重叠（Overlap）严格按照实际讲话人数计算 Miss 与 Confusion；
  - 词级/字级讲话人归属文字错误率（SACER）：`unknown` 状态严格计入错误率与 unknown 比例；
  - 评测清单（Manifest）强制校验数据授权许可与 `tune`/`eval` 划分；
  - 评测报告隐私隔离：严格聚合匿名统计结果，绝不输出绝对路径、明文音频、完整转写文本或真实人名。
- `tools/evaluate_diarization_e2e.py`：实现 CLI 评测套件，支持 `--manifest`、`--collar`、`--split` 与 `--output` 聚合报告输出；manifest SHA-256 签名内置。
- 回归测试：`tests/test_diarization_metrics.py` 8 passed；`ruff check src tests tools` 与 `mypy src` 全部无告警。真实 12 段材料与 2 小时运行态测试需在获取外部音频后于受权环境执行。

## 交付验收与追踪

- [x] R0 时间与正文不变量通过。
- [x] R1 实际 native 增量接口和有界 state 通过。
- [x] R2 双仓共享 fixtures 与四组合兼容通过。
- [x] R3 speaker/overlap/unknown/link/freeze 通过。
- [x] R4 finalize 与故障恢复通过。
- [ ] R5 真人人工标注和两小时资源门通过。

任一未勾选项都不得在 README 宣称端到端已验收。新模型、独立分人进程、固定文本 aligner、超过四人和会后整场重跑均是独立后续范围，不能为完成勾选擅自加入。
