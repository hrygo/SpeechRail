# SpeechRail 无声误转录治理实施方案

> 执行约定：按本计划逐项实施，每项完成测试与审查后再推进；执行阶段使用可用的 executing-plans 工作流。未经用户明确要求，不启动子代理。
>
> 状态：planned。2026-09-06 已完成源码与契约可行性审查；尚未实施，尚未完成真实声学验收。
>
> 跟踪 issue：[SpeechRail #10](https://github.com/hrygo/SpeechRail/issues/10)。配套消费端：[Sona #8](https://github.com/hrygo/sona/issues/8)。

**Goal:** 阻止 server_vad 模式下无有效语音的 PCM 触发 ASR 文本输出，同时保留真实短答、实时性、连续分人时间轴和完整 EOF 闭环。

**Architecture:** SpeechRail 在会话内部统一处理语音准入、ASR 输入与输出、回合提交；连续采样时钟和 diarization 不因 ASR 跳过静音而压缩。先建立可测试状态机，再对照评测一个神经 VAD 候选；Sona 保持标准协议消费者。

**Tech Stack:** Python >=3.12,<3.13、uv、现有 Realtime ASR port、NumPy、pytest fake backend；神经 VAD 候选使用本地 Silero ONNX 制品，运行时和依赖是否可用须经 R3 preflight 核验。

**Spec:** 本文为此次治理规格；同时遵守 `contracts/realtime-openai.md`、`contracts/diarization/v1/`、`docs/developers/testing-acceptance.md`、`AGENTS.md`。跨项目配套：Sona `docs/superpowers/plans/2026-09-06-sona-silence-transcription-integration.md`。

## 全局约束

- 本次交付仅为文档与 issue；实现、下载模型、修改运行配置、重启和部署不属于此次执行范围。
- 先执行 `git status --short` 和 `git log -5 --oneline`；保留既有并行改动，仅认领本计划文件。
- SpeechRail 管理模型与资源，Sona 不安装第二套 ASR 或字幕/会议 VAD 模型。
- 不保存生产音频，不输出原始 PCM/Base64、完整转录、prompt、身份信息、密钥或绝对模型路径。测试短词为人工构造文本，声学样本放仓库外。
- 仅单服务、单 ASGI worker；不复制模型进程。模型路径必须显式本地配置，请求路径禁止下载。
- `turn_detection=null/manual` 保持显式提交语义；首期不对客户端已选择的音频另加 server VAD，也不改变交互助手的回合所有权。
- server_vad 配置保持现有 wire 字段；候选引擎选择是服务端配置，不新增未协商的 `vad_profile`、`no_speech` 或 ASR confidence 字段。
- 确认正文与归属单元时间不可变；无声回合不生成非空正文。空协议终态仍必须发送，不能用“无文本”代替“无响应”。
- 不新增语气词黑名单，不把 VAD 分数等同于 ASR 置信度。
- 首期不引入 AGC、AEC、额外降噪、semantic VAD 或跨模式通用框架；残余问题有对照证据后另立变更。

## 现状与证据边界

核验日期：2026-09-06；本地基线 HEAD 为 `6d25e61`，工作树有其他任务改动。执行时重新确认，不把该基线视为服务正在运行的制品。

| 证据 | 当前事实 | 影响 |
|---|---|---|
| `src/speechrail/backends/vad.py:VoiceActivityDetector._score_frame` | 固定 RMS 与过零率评分 | 噪声可触发，分数没有 ASR confidence 语义 |
| `src/speechrail/application/realtime_openai.py:OpenAIRealtimeSession._append_audio` | VAD 判断前创建 ASR 并送 PCM，累计音频触发 flush；缓冲超限另有 commit | 单改 VAD 结束事件不能覆盖无声推理 |
| 同文件 `_drain_asr_events` | partial 与 completed 可直接发送 | 仅在 final 处过滤不能消除可见字幕 |
| 同文件 `_commit_audio` | 空输入仍提供 committed/created/completed 闭环 | 新准入不能破坏空提交 |
| 同文件 `_handle_finalize/_drain_and_finalize` | 分人独立 finalize，使用 session samples | 不能把 commit 误当作分人 finalize |
| `contracts/realtime-openai.md` | legacy 与协商扩展有不同事件集合，扩展 max_item_duration_ms=8000 | 长发言须按既有上限分段并保持完整性 |

历史合成噪声测试仅证明存在误触发路径；尚未将真实“嗯”逐条关联到 VAD、flush、提交或重放。不得宣称根因已完全闭环或神经 VAD 效果已验收。

## 两项目接口合同 SR-SILENCE-1

首期使用既有事件，不新增公共质量字段。以下是实施目标，不是当前已实现承诺：

1. server_vad 未接纳语音时，不向 ASR 推理器送入无界静音、不执行无声 flush，不发送非空 delta/segment/completed。
2. 显式 commit 在纯静音、空缓冲和语音尾部均完成终态；空 transcript 的 attribution_units 为空。自动端点、超限结转、显式 commit 必须汇入同一提交入口。
3. legacy 保持既有事件集合；扩展每个已提交 item 的 ID、序列及正文单元一致，不并发发送 legacy segment。
4. 连续输入的 session sample 时钟与 diarization 输入按原音频推进；ASR 接纳区间的本地 offset 必须映射回 session samples，包含 pre-roll 与尾部。
5. 扩展 EOF 为 commit → speechrail.diarization.finalize → finalized；legacy 为 commit → clear/cleared。clear 不把已接收的 session 时间倒退，断线新 session 由客户端 epoch 隔离。
6. manual/null 模式保持行为；旧客户端无需新增字段。Sona 不推断缺失质量信息，也不按短文本去重。
7. 服务端启用哪个候选、模型 revision 与参数组写入脱敏验收报告；首期不要求 Sona 自动识别引擎。

## 文件与职责

| 类型 | 路径 | 职责 |
|---|---|---|
| 新建 | `src/speechrail/realtime/speech_admission.py` | 有界 pre-roll、语音准入状态、区间与结束决策；不做网络或模型加载 |
| 新建 | `src/speechrail/backends/neural_vad.py` | 单一候选评分 adapter、分帧与会话状态 |
| 修改 | `src/speechrail/backends/vad.py` | 保留 legacy detector，提供可测试检测接口接缝 |
| 修改 | `src/speechrail/application/realtime_openai.py` | ASR 生命周期、提交入口、输出世代保护、时间映射 |
| 修改 | `src/speechrail/config/__init__.py` | 服务端开关与本地模型路径验证 |
| 修改 | `src/speechrail/observability/metrics.py` | 有限标签的计数与耗时 |
| 修改 | `contracts/realtime-openai.md` | 明确准入、空闭环、时间基准和兼容语义 |
| 新建 | `tests/test_speech_admission.py`、`tests/test_neural_vad.py` | 纯状态机与 adapter fake 测试 |
| 修改 | `tests/test_realtime_openai.py`、`tests/test_realtime_vad_bargein.py`、`tests/test_diarization_extensions.py`、`tests/test_diarization_timeline.py` | 公共协议、资源与时序回归 |
| 新建 | `docs/operations/realtime-silence-transcription-acceptance.md` | 执行时生成的脱敏验收报告，记录真实已完成证据 |

## R0：建立确定性复现与诊断

**输入：**现有 `tests/test_realtime_openai.py` 的 `_client`、fake ASR factory 与 PCM helper。

**输出：**可区分 VAD、flush、commit 和输出的最小回归用例；无需真实模型。

- [ ] 扩展 fake ASR：任何一次 flush/commit 都可以产生人工文本“嗯”，同时记录 create/append/flush/commit/close 次数。检测器注入恒非语音结果。
- [ ] 新增 `test_server_vad_silence_never_emits_text_before_commit`：送入超过 streaming flush 阈值的零 PCM，断言无文本输出且准入开启时 ASR append/flush 均为零。
- [ ] 新增 `test_server_vad_silence_rollover_has_no_text`：输入超过原缓冲上限，仍不创建持续累积的 ASR 会话。
- [ ] 新增 `test_server_vad_silence_explicit_commit_closes_empty`：显式 commit 后 committed 先于空 completed，连接继续可用。
- [ ] 为指标增加固定维度 `mode`、`commit_reason`（vad_stop/client/rollover）、`outcome`；只统计字数、事件数、有效发声样本数与耗时，不以 session/item ID 作为指标标签。
- [ ] 运行下列命令，记录旧路径在上述行为断言处的失败；禁止以 import 错误作为回归复现。

```bash
uv run --extra dev pytest tests/test_realtime_openai.py tests/test_realtime_vad_bargein.py -q --no-cov
```

**通过条件：**可确定复现“检测器未启动但 ASR 仍推理/发文本”的路径；真实麦克风根因保留为待声学验证。

## R1：实现有界语音准入状态机

**输入：**16 kHz mono PCM16、有序检测分数、原始 session 采样起点。

**输出：**仅限内部的带绝对区间的 Start/Audio/End 决策。

定向测试统一使用 --no-cov，避免少量用例触发全项目 80% 覆盖率门禁；R4 全量测试保留覆盖率门禁。

建议内部签名（新建于 speech_admission.py）：

```python
from dataclasses import dataclass
from typing import Literal

@dataclass(frozen=True)
class AdmissionDecision:
    kind: Literal["start", "audio", "end"]
    start_sample: int
    end_sample: int
    pcm: bytes = b""

# SpeechAdmission.push(pcm: bytes, *, start_sample: int,
#                      probability: float) -> tuple[AdmissionDecision, ...]
# SpeechAdmission.finish() -> tuple[AdmissionDecision, ...]
# SpeechAdmission.reset(*, next_sample: int) -> None
```

- [ ] 状态按 IDLE → CANDIDATE → ACTIVE → HANGOVER → IDLE 流转；候选未达到确认条件不开放 ASR。CANDIDATE 回到 IDLE 时释放候选状态。
- [ ] pre-roll 环形缓冲长度由 prefix_padding 与启动确认窗口计算；校验内存上限。PCM 分帧保留余数，拒绝非法半采样输入，EOF 单独处理不足一帧的尾音频。
- [ ] ACTIVE 中连续送音频，包括句内短静音；HANGOVER 收齐尾部后发 End。一次活动区间内不删除内部静音，确保时间映射只有连续 offset。
- [ ] 同一网络 chunk 内多个起止边界须逐段处理，不能处理第一次 end 后直接遗失剩余帧。
- [ ] 写出重复 finish、clear、候选中 EOF、两次相邻真实短答、首尾字及跨会话 reset 测试。启动确认窗口不使用文本长度替代。
- [ ] 引入服务端开关 `SPEECHRAIL_REALTIME_SPEECH_ADMISSION_ENABLED`（新配置，初始 false）；true 仅作用于 server_vad。沿用项目现有环境前缀解析并写配置测试。

Start/End 决策仅携带元数据，Audio 决策携带与区间长度一致的 PCM；Start 的起点包括 pre-roll，后续 Audio 按顺序覆盖整个接纳区间。每次 finish 只结束尚未结束的区间，第二次返回空元组。

状态机边界测试示例（新 API 的预期用法）：

```python
from speechrail.realtime.speech_admission import SpeechAdmission


def test_silence_has_no_admission():
    gate = SpeechAdmission(
        threshold=0.5, start_frames=2, stop_frames=3,
        prefix_samples=512, frame_samples=512,
    )
    silence = bytes(1024)
    for index in range(40):
        assert gate.push(silence, start_sample=index * 512,
                         probability=0.0) == ()
    assert gate.finish() == ()
```

`SpeechAdmission.__init__` 按示例参数实现；start_frames/stop_frames 从经过验证的时长按帧向上取整得到。测试使用固定分数，不能把正弦波视为真实人声质量证据。

```bash
uv run --extra dev pytest tests/test_speech_admission.py -q --no-cov
```

**通过条件：**每个接纳区间样本守恒、内存有界、反复 reset 无跨会话污染。

## R2：接入 ASR、分人与 EOF

**输入：**R1 的 AdmissionDecision；现有 ASR 与 diarization ports。

**输出：**满足 SR-SILENCE-1 的完整协议行为。

- [ ] 原始 PCM 先进入连续采样时钟与 diarization；仅接纳区间进入 ASR。必须将 ASR 初始化从“第一包 PCM”移动到 Start，保留 governor 预留失败和释放路径。
- [ ] 在首个 partial 前固定该 turn 的内部 identity 与 generation；clear、commit 完成或取消后，旧 reader 输出不得落入新回合。
- [ ] 所有提交原因调用同一个内部提交方法；无接纳区间时仅执行现有空闭环。manual/null 模式绕过新状态机，保持原有 append/flush/commit 行为。
- [ ] flush 只对当前接纳的 ASR 数据生效；reader 在发送 delta/segment/completed 前检查 generation 和该回合已接纳标记。
- [ ] 在 ACTIVE 超限时遵守既有缓冲上限及协商扩展 8000 ms item 上限：先完整提交当前 item，再继续下一 item；不能等待新的 VAD start 才继续，不能重复 pre-roll 或漏采样。
- [ ] 将 ASR 相对时间统一映射为接纳区间 session 起点 + 局部 offset；legacy segment 与扩展 attribution_units 均验证。只有后端确实对齐成功才能标 aligned。
- [ ] 保留 commit 空完成；clear 释放未提交 PCM 和检测状态，不回退 session 时钟；finalize 推进到原始 accepted_samples，空会议也发 finalized。
- [ ] 覆盖模型报错、reader 超时、连接关闭、VAD start 时 backend_busy，确认资源预留与 reader task 最终释放。
- [ ] 分别对 legacy、扩展、manual 编写协议测试；不得仅调整旧测试的期望来掩盖时序变化。

```bash
uv run --extra dev pytest tests/test_realtime_openai.py tests/test_realtime_vad_bargein.py tests/test_diarization_extensions.py tests/test_diarization_timeline.py -q --no-cov
```

**通过条件：**零语音不发文本、真实尾音不丢、8 秒以上长发言完整、原时钟与分人终态守恒。

## R3：单一神经 VAD 候选与质量对照

**输入：**R2 功能通过的准入链路；仓库外非敏感语音评测集。

**输出：**候选配置、固定模型 revision/校验值、逐场景对照结果和是否启用的决策。

- [ ] 先核验本地 Silero ONNX 制品和 Python 3.12/目标平台运行时；依赖需要新增时精确锁定并更新 pyproject/uv.lock。制品缺失时只报告缺失，不联网下载。
- [ ] 新建 NeuralVAD adapter，按模型要求分帧，流状态按 session 隔离，clear/disconnect 重置；纯单测用 fake inference，不依赖真实权重。
- [ ] 引入新服务端配置 `SPEECHRAIL_REALTIME_VAD_ENGINE=legacy|silero`（初始 legacy）及 `SPEECHRAIL_REALTIME_VAD_MODEL_PATH`。模型路径无默认远程地址；显式 silero 但 preflight 失败时明确报错，不静默回退。
- [ ] 引入服务端布尔配置 `SPEECHRAIL_REALTIME_VAD_SHADOW_ENABLED`（初始 false），只允许 engine=legacy 且本地候选 preflight 成功；与 engine=silero 同时启用时报配置错误。shadow 仅比较检测结果并记录聚合指标，旧引擎独占输出决策；不得双倍启动 ASR 或保存影子音频。
- [ ] 对照组固定：A 原始 legacy 链路，B legacy + admission，C Silero + admission；B/C 使用相同语料、端点窗口和资源条件。
- [ ] 校准集选择启动确认窗口与阈值；冻结参数后仅在独立验收集评分。VAD 分数不是跨模型可比较的概率校准或识别置信度。
- [ ] 验证真实短答“嗯／对／好”、轻声、远场、键盘、风扇、敲击、长静音后发言、多人交叠；无授权不录制生产会议。
- [ ] CPU、内存、首字/末字延迟报告 p50/p95；模型冷启动单列，不混入稳态均值。

提议发布门槛（待执行测量，非实测结果）：

| 类别 | 门槛 |
|---|---|
| 固定 10 分钟数字静音 + 10 分钟非语音环境噪声 | 非空 partial、segment、completed 均 0；纯静音不创建 ASR 推理会话 |
| 人工标注不少于 100 条中文短答/轻声/正常句 | 关键短答集无漏掉整句；整体语句检出率相对 A 下降不超过 1 个百分点 |
| 文本质量 | 中文 CER 相对 A 恶化不超过 1 个百分点；同时报告样本量和各场景结果 |
| 延迟 | 同端点窗口下 p95 首字延迟增量 ≤200 ms，末字确认增量 ≤200 ms |
| 时间/协议 | fake 样本坐标精确守恒；重复 EOF 幂等；真实样本无可归因于本次变更的整体时间漂移 |
| 长时资源 | 30 分钟运行无持续缓冲增长、遗留 reader 或 ASR slot；达到现有 backpressure 上限时稳定退出 |

电视/扬声器播放中的真人语音属于“有语音”，不得混入非语音零输出门槛；是否排除播放内容属于另一个带播放参考的需求。

## R4：联合验收、发布与回退

- [ ] 将 R2 协议测试结果与 fixture 交给 Sona S1/S2；两项目先独立通过 fake gate，再进行真实联合验证。
- [ ] 更新 realtime 契约，说明 server_vad 准入与 manual 不变；首期不新增 public API 字段。
- [ ] 写验收报告：代码 SHA、模型 revision/校验、配置、样本类别/数量、指标、命令、时间、未验证项。不引用健康端点代替声学结果。
- [ ] 完整门禁：

```bash
uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
git diff --check
```

- [ ] 全部门槛通过后才考虑将 admission/silero 设为部署默认；需明确运行态授权并确认没有活动会话，沿用项目 release/service 流程。
- [ ] 回退保持原部署配置副本：关闭 admission、选择 legacy，按已审查服务流程切回上一制品；不在活动会话中切模型或改变时间基准。
- [ ] 实施阶段按 R1/R2/R3 可审查边界提交；提交前检查 staged diff，不混入当前工作树其他任务文件。

## 完成定义与剩余证据

- [ ] R0–R4 全部验收通过，SR-SILENCE-1 在 Sona 字幕和会议实际消费链路成立。
- [ ] manual 交互模式回归通过，现有 TTS/分人能力未因资源改造退化。
- [ ] 固定样本零误报不被表述为所有真实环境零误报；保留样本规模与风险说明。
- [ ] 当前文档只验证代码接缝与协议可设计性；真实声学效果、模型制品、运行时与性能由 R3/R4 实测决定。

## 编写阶段验证记录

2026-09-06 已核验现有文件路径、环境前缀 SPEECHRAIL_、Realtime/分人契约和现有 VAD 测试入口。定向 VAD 用例首次因继承全项目覆盖率门禁返回非零（行为断言通过，覆盖率仅 14.56%）；已将计划中的定向命令改为 --no-cov，全量门禁不变。修正后重跑现有 VAD 定向用例 1 项通过。该记录不代表新状态机或声学质量已验收。

## 依据

- [OpenAI Realtime VAD](https://developers.openai.com/api/docs/guides/realtime-vad)：端点参数与语音活动事件的职责；不证明本服务实现了所有 OpenAI 能力。
- [Silero FAQ](https://github.com/snakers4/silero-vad/wiki/FAQ)：阈值/时长调参和流式状态重置；不替代本项目评测。
