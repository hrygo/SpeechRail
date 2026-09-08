---
title: "SpeechRail 实时 VAD 对齐 2026 行业最佳实践方案"
status: active
audience: "SpeechRail 核心开发者、架构评审、质量门"
version: "0.2.0"
date: 2026-09-08
---

# SpeechRail 实时 VAD 对齐 2026 行业最佳实践方案

> **方案定位**：改善 SpeechRail `/v1/realtime` 的服务端 VAD（Voice Activity Detection）与打断（Barge-in）能力，使其在质量、维护性与契约保真度上对齐 2026 年实时语音 Agent 行业最佳实践。D1–D4 已落地；本文同时记录应用 wheel 依赖与 managed preflight 这一部署不变量。
>
> **证据分层**：与 AGENTS.md 一致，本文区分：
> - **代码可证**：得自 `src/speechrail/` 源码读取、`tests/` 与 `contracts/realtime-openai.md`；
> - **外部最佳实践**：得自 LiveKit Agents 文档、Silero-vad 官方仓库（`snakers4/silero-vad`，Context7 版本 v6.2）、Picovoice 2026 指南及多篇 2026 实时语音工程文；
> - **推断**：低置信度的架构取舍，明确标注。

---

## 一、背景与目标（Context）

**为什么现在改。** 当前 VAD 实现已在架构层显著高于一般水平，但存在结构性偏差，导致它无法代表 2026 年行业共识，且对当前 Silero 模型有部署摩擦：

1. **历史默认引擎是 `legacy`（能量 + 过零率启发式）** —— 当前默认解析已改为 `auto`；配置 Silero 模型时走神经 VAD，未配置模型时才保留 legacy 的零依赖路径。
2. **`SileroVadDetector` 硬编码 Silero v4 的 ONNX 图 schema，明确拒绝当前 v5/v6** —— 用户无法使用当前官方分发的 `silero_vad_16k.onnx`，必须寻找旧 v4 导出。
3. **应用 wheel 未声明 Silero 的 ONNX runtime** —— managed 服务可以通过 ASR/TTS readiness，但配置了模型的 `server_vad` 会在会话协商时才发现 `onnxruntime` 缺失；这是 VAD 子能力部署缺口，不应改判为整个 SpeechRail 服务离线。

**目标（不扩大范围）。** 在不引入多租户/分布式/云控制面（AGENTS.md 硬边界）的前提下：

- 让**神经 VAD 成为默认主路径**，legacy 仅作为零依赖、强确定性 fallback；
- 让 Silero 适配器**同时支持 v4 与当前 v5/v6 schema**，自动探测、失败关闭；
- 统一 `turn_detection.threshold` 的**契约语义**，避免 legacy/silero 语义漂移；
- 为全双工打断增加**服务端回声/冷却防护**（可选）；
- 保持**有界资源、样本时钟对齐、shadow 观测、会话隔离**等既有亮点不回归。

**非目标**：端到端语义 endpointing（STT partial + LLM judge）、服务端 AEC/降噪——均因本地单用户、低复杂度、客户端拥有音频 I/O（AGENTS.md `0005`）而明确排除，仅在「边界」一节记录。

---

## 二、现状基线（代码可证）

| 层 | 位置 | 内容 |
|---|---|---|
| **评分器（legacy）** | `src/speechrail/backends/vad.py` | `VoiceActivityDetector`：RMS（噪声底约 -46dBFS，`rms < 120` 即 0）+ 过零率 → sigmoid 打分；16kHz、512 采样帧（32ms）；`VadConfig(threshold=0.5, prefix_padding_ms=300, silence_duration_ms=400, debounce_frames=3)` |
| **评分器（silero）** | `src/speechrail/backends/neural_vad.py` | `SileroVadDetector`：ONNX；每模型路径共享一个 `InferenceSession`（`InferenceSession.run` 线程安全），每流独立 h/c 或 consolidated state/context；`inter/inter_op_threads=1`；按输入名自动识别 v4 与 v5/v6 schema |
| **决策状态机** | `src/speechrail/realtime/speech_admission.py` | `SpeechAdmission`：`IDLE→CANDIDATE→ACTIVE→HANGOVER→IDLE`；有界 prefix-ring / candidate；整数 16k 样本时钟；双阈值迟滞（entry `threshold`，exit `threshold-0.15`） |
| **接线层** | `src/speechrail/application/realtime_openai.py` | 接入 OpenAI Realtime `server_vad`：`input_audio_buffer.speech_started/stopped` 事件、自动 commit（`vad_stop`）、全双工打断（`record_bargein` + `_cancel_response`）；`_bargein_pending_audio` 有界（`_bargein_pending_max_bytes` 默认 9600） |
| **配置** | `src/speechrail/config/__init__.py` | `realtime_vad_engine: Literal["auto","legacy","silero"] = "auto"`；`realtime_vad_model_path`；`realtime_vad_shadow_enabled`（仅 legacy 可用）；`realtime_speech_admission_enabled=True` |
| **可观测** | `src/speechrail/observability/metrics.py` | `speechrail_realtime_vad_speech_events_total{event=started|ended}`；`speechrail_realtime_vad_shadow_frames_total{agreement=both_speech|both_silence|primary_only|shadow_only}` |
| **契约** | `contracts/realtime-openai.md` | server_vad 默认 `threshold=0.5 / prefix_padding_ms=300 / silence_duration_ms=400`；`silero` 引擎要求 `realtime_speech_admission_enabled=true` 且配置 `realtime_vad_model_path`；v4/v5/v6 schema 均受支持；受支持 managed wheel 锁定 `onnxruntime==1.29.0`，preflight/health 单独报告 VAD runtime |
| **测试** | `tests/test_realtime_vad_bargein.py`、`tests/test_neural_vad.py` | 防抖/静音/hysteresis/barge-in 会话隔离；Silero 帧长校验、schema fail-closed、shadow agreement 指标、sub-frame commit 不崩溃、共享 session 复用 |

**既有亮点（须保持，不回归）：** 双阈值迟滞、有界准入（防 DoS + 防静音幻听）、前置 padding 防首音裁剪、失败关闭（fail-closed）、fake runner 可测试性、shadow/A-B 观测、整数样本时钟对齐、会话级 VAD 状态隔离、单线程低 CPU 神经推理。这些与 2026 最佳实践高度一致，方案只在之上增量改动。

---

## 三、问题定义（Gaps）

| 编号 | 问题 | 证据 | 严重度 |
|---|---|---|---|
| **G1** | 历史默认 `legacy` 能量 VAD，非 2026 主流 | 当前默认已解析为 `auto`；配置模型后走 Silero，未配置模型才使用 legacy；外部：能量/WebRTC VAD 在高噪声下不适用于生产 turn detection | 🔴 结构（已修复） |
| **G2** | 历史 `SileroVadDetector` 锁死 v4 schema，拒绝当前 v5/v6 | 当前适配器按输入名支持 v4 与 v5/v6；v5/v6 使用 `input=[1,576]` 与 consolidated state，并在流内维护 64 sample context | 🔴 结构/维护（已修复） |
| **G3** | `threshold` 语义随引擎漂移（legacy=能量分值，silero=真实概率） | `config/__init__.py`、`contracts/realtime-openai.md` 已文档化，但对 OpenAI drop-in 客户端是语义失真 | 🟡 契约 |
| **G4** | 全双工打断无服务端回声/冷却防护 | `realtime_openai.py` 在 `speech_started` 即取消 TTS，无 `cooldown`、无 `playback/silence` 双模式 | 🟡 加固（边界内） |
| **G5** | 无语义 endpointing、无前置降噪/AEC | 现状为纯 VAD 评分 + 状态机 | 🟢 知悉（非目标） |

---

## 四、最佳方案设计

### D1 · VAD 引擎策略：新增 `auto` 默认档

**决策**：`realtime_vad_engine` 由 `Literal["legacy","silero"] = "legacy"` 改为 `Literal["auto","legacy","silero"] = "auto"`。

| 取值 | 行为 |
|---|---|
| `auto`（默认） | 若 `realtime_vad_model_path` **已配置** → 走 `silero`（2026 主路径）；**未配置** → 回退 `legacy`（零依赖开箱即用） |
| `silero` | 显式强制神经 VAD；`realtime_vad_model_path` 必配（现有校验保留） |
| `legacy` | 显式强制能量 VAD；保留现有行为 |

**关键细节（fail-closed，不静默降级）**：`auto` 仅在 `realtime_vad_model_path` **未配置**时回退 `legacy`。若模型路径**已配置**但 Silero 预检失败（缺失 `onnxruntime`、模型文件不存在、schema 不支持），**显式返回 `backend_not_ready`**——与现有 `test_realtime_session_silero_preflight_failure_fails_explicitly` 语义一致，避免把"配置损坏"伪装成"零配置可用"，从而掩盖问题。

**决策理由**：`auto` 兼顾"零依赖默认仍可用"（legacy）与"一旦提供模型即用最佳实践"（silero），把 2026 主路径变成缺省结果而不破坏开箱体验。代价是 `auto` 要求更高测试覆盖（三种解析分支）。

### D2 · Silero 适配器 schema 感知（核心改动）

**决策**：`SileroVadDetector` 在打开 session 时**自动探测** ONNX 图 schema，支持 `v4` 与 `v5/v6` 两种，统一对外接口保持 `score_frame(frame: bytes) -> float`（16kHz、512 采样帧），并按探测结果维护对应流状态。

**Schema 探测**（读 `session.get_inputs()` + 输入形状，取代现有单分支 `_validate_session`）：

| 特征 | v4 | v5/v6 |
|---|---|---|
| 输入名 | `{input, h, c, sr}` | `{input, state}`（部分模型另有 `sr`，按需透传） |
| `input` 形状 | `[1, 512]` | `[1, 576]`（512 采样 + 64 上下文） |
| 状态形状 | `h/c` 各 `[2, 1, 64]` | `state` `[2, 1, 128]` |
| 输出 | `[prob, h, c]`（位置序） | `{output, stateN}` |
| 上下文处理 | 无（LSTM 状态自带） | **手动**拼接上一帧末 64 采样 + 冲刷 |

**探测逻辑伪码**：

```python
input_names = {i.name for i in session.get_inputs()}
if {"input", "state"} <= input_names and "h" not in input_names:
    kind = V56
elif {"input", "h", "c"} <= input_names:
    kind = V4
else:
    raise RuntimeError("Unsupported Silero VAD ONNX schema: ... 提供 v4 或 v5/v6 模型")
```

**v5/v6 推理路径**（`_infer_frame` 分支）：

```python
samples = np.frombuffer(frame, "<i2").astype(np.float32) / 32768.0   # [512]
chunk = samples[None, :]                                              # [1,512]
x = np.concatenate([self._context, chunk], axis=1)                    # [1,576]
if self._state is None:
    self._state = np.zeros((2, 1, 128), dtype=np.float32)             # LSTM 上/下 hidden+cell
inputs = {"input": x, "state": self._state}
out = self._session.run(None, inputs)
prob = float(out["output"][0, 0]) if isinstance(out, dict) else float(out[0][0, 0])
self._state = out["stateN"] if isinstance(out, dict) else out[1]
self._context = x[:, -64:].copy()                                      # 冲刷 last-64
return prob
```

**流状态维护**（每个 detector 实例独立，`run()` 线程安全、权重共享不变）：

- v4：维持现有 `_state_h/_state_c = None`，`[2,1,64]`；
- v5/v6：`_state: np.ndarray | None`（`[2,1,128]`）+ `_context: np.ndarray`（`[1,64]`，初值全零）；
- `reset()` 视 `_schema_kind` 清空对应状态。

**关键不变量**：`score_frame` 的输入仍是 **1024 字节 = 512 采样**，与现有 `realtime_openai.py` 的 1024 字节分帧、`admission` 路径完全兼容，**无需改接线层**；v5/v6 的 64 上下文在 detector 内部跨连续帧冲刷。

**失败关闭**：探测到不支持的 schema 仍 `raise RuntimeError`（不静默）；探测出的 `_schema_kind` 保存，`_validate_session` 只接受 v4 / v5/v6，其余明确拒绝。

**向后兼容**：现有 v4 用户不受影响；文档标注 v4 为"到期支持"，**推荐新部署使用 v5/v6 模型**。

### D3 · `threshold` 语义统一与契约保真

**决策**：保持每个引擎的**实际语义不变**（避免行为回归），但把语义在契约与实现层"显式化"，并让默认主路径（`auto`→silero）天然回到 OpenAI 语义：

- `silero` 引擎：`threshold ∈ [0,1]` 为**真实语音概率**（对齐 OpenAI Realtime）。
- `legacy` 引擎：`threshold` 为**能量分值门限**（非概率）。在 `contracts/realtime-openai.md` 与 `config` 注释中**明确标注**，避免客户端误解。
- 未来可选增强（**不在本方案必做**）：把 legacy 打分经校准映射为伪概率 `[0,1]`，统一 `threshold` 语义——因会改变现有 legacy 灵敏度（默认 0.5 对应能量阈值），**推迟**至有真实质量数据时再做。

### D4 · 全双工打断加固：服务端冷却

**决策**：增加可配置 `realtime_vad_bargein_cooldown_ms`（默认 `250`，范围 `0..5000`，`0` 关闭）。语义：在触发一次打断（`_cancel_response`）或 `speech_stopped` 之后，冷却窗口内**忽略**新的 `speech_started` 打断触发，杜绝「TTS 尾部回声再次触发 VAD 导致 agent 永远说不完」的 echo-barge-in bug（2026 工程文明确该 bug）。

- `realtime_openai.py` 在 `_handle_admission_decision`/legacy 路径记下 `time.monotonic()` 的冷却截止点，`speech_started` 时若在冷却窗口内则记录指标、不取消 TTS。
- 由于 SpeechRail 只见用户输入通道（AGENTS.md `0005`：客户端拥有麦克风/播放/AEC），服务端冷却仅为**加固**；播放期灵敏度与 AEC 属客户端职责。若未来同通道同时可见 agent 播放 + 用户输入，须由客户端加 AEC + 双模式敏度。

### D5 · 可观测（增量，可选）

保留现有 `shadow`（legacy 主 + silero shadow）。未来增强（**不在本方案必做**）：允许"任选主引擎 + 任选 shadow 引擎"，可对比 `silero` 主 vs 另一引擎，用于 `threshold`/模型迁移前的 A/B 验证。

---

## 五、实施阶段（Phased Plan）

> 每阶段独立可测、可回退；公共行为变更遵循 AGENTS.md「先写失败契约/回归测试再改」。

| 阶段 | 内容 | 出入口 |
|---|---|---|
| **P0 前置（契约+测试）** | 在 `contracts/realtime-openai.md` 增补 `auto` 档、v5/v6 支持、`threshold` 语义、`bargein_cooldown`；新增/更新 `tests/test_neural_vad.py` 与 `tests/test_realtime_vad_bargein.py` 的失败回归（v5/v6 score_frame 正确性、`auto` 解析三态、cooldown 行为） | 失败回归测试先红 |
| **P1 D2** | `neural_vad.py`：schema 探测 + v5/v6 推理/状态/`reset`；`_validate_session` 改造；共享 session 复用保持 | `tests/test_neural_vad.py` 全绿；共享 session 测试仍绿 |
| **P2 D1** | `config/__init__.py`：`realtime_vad_engine` 加 `auto` 默认；`realtime_openai.py` 引擎解析分支（`check_readiness` 依配置）；`Settings` 校验扩展 | `Settings` 校验测试 + `auto` 解析测试绿 |
| **P3 D3/D4** | `contracts/realtime-openai.md` 语义文档化 + `config`/`realtime_openai.py` 冷却字段与逻辑 | 契约门 + barge-in 回归绿 |
| **P4 全量 gate** | `uv run --extra dev pytest`、`ruff check src tests`、`mypy src`、`redocly lint contracts/openapi.yaml`、`git diff --check` | 全绿 |

---

## 六、验收标准（Acceptance）

- [x] `auto` 默认：未配 `realtime_vad_model_path` → silero 预检跳过、走 legacy；已配且就绪 → 走 silero。
- [x] `auto` 已配模型但预检失败 → 显式 `backend_not_ready`（不静默降级）。
- [x] `SileroVadDetector` 可对 v4 ONNX 与 v5/v6 ONNX 两种模型给出连续、单调合理的概率，且 `reset()` / 会话切换后状态正确清零。
- [x] v5/v6 路径下 `score_frame` 输入仍为 1024 字节（512 采样 + 64 上下文在内部处理），接线层无需改动。
- [x] shadow 指标在 `auto→silero` 主路径下不失效（或按 D5 定义行为）。
- [x] barge-in cooldown 生效：冷却窗口内重复 `speech_started` 不取消在途 TTS；`cooldown=0` 关闭。
- [x] 受支持 Apple Silicon wheel 声明 `onnxruntime==1.29.0`，managed preflight 使用应用 Python 检查模型文件与 runtime 导入；health/readyz 独立呈现 VAD 状态。
- [x] 现有 `tests/test_realtime_vad_bargein.py`、`tests/test_neural_vad.py` 回归通过。

---

## 七、影响面（Impact）

| 面 | 影响 |
|---|---|
| **配置** | `realtime_vad_engine` 新增 `auto`（默认）；新增 `realtime_vad_bargein_cooldown_ms`；managed wheel 固定 `onnxruntime==1.29.0` |
| **契约** | `contracts/realtime-openai.md` 更新 v5/v6 支持、`threshold` 语义、`auto` 与冷却说明；`/health`/`/readyz` 提供 VAD 子能力状态 |
| **代码** | `neural_vad.py`（schema 感知）、`config/__init__.py`（字段）、`realtime_openai.py`（引擎解析 + 冷却）、`application/services.py` 与 `service/preflight.py`（诊断与安装门） |
| **测试** | `test_neural_vad.py`（v5/v6、auto 三态、缺 runtime 会话回归）、`test_realtime_vad_bargein.py`（cooldown）、preflight/packaging/health 契约测试 |
| **文档** | 本文件；`README.md` 或 `docs/architecture/README.md` 索引（可选） |
| **不涉及** | ASR/TTS 推理协议、模型 profile 选择、diarization wire protocol；LaunchAgent 仍按同一单实例流程管理 |

---

## 八、风险与边界（Risks & Boundaries）

- **风险：v5/v6 上下文冲刷若与分帧边界脱节会引入概率漂移。** 缓解：`score_frame` 输入永远按 512 采样连续切分（admission 路径已保证连续性）；`reset()`/`session.update` 清空 `state`/`context`。
- **风险：`auto` 三态引入更多测试面。** 缓解：用**确定性 fake runner / stub session** 覆盖三态，不依赖真实模型。
- **边界：语义 endpointing、服务端 AEC/降噪** 明确**非目标**（本地单用户、低复杂度、客户端拥有音频 I/O）。仅记录知悉。
- **边界：`threshold` 语义在 legacy 下仍是能量分值**。方案选择保留（避免回归），但文档显式标注；统一语义推迟到有质量数据。
- **边界：单线程 `inter/intra_op_threads=1`**。对 32ms 帧、<1ms 推理足够且保证确定性；多并发实时会话共享只读权重、按流隔离状态，符合现有并发模型。

---

## 九、附录：引用与佐证

- **外部最佳实践（2026）**：
  - Silero VAD 官方仓库 `snakers4/silero-vad`（MIT、6000+ 语言、<1ms/32ms 单线程、ONNX）；Context7 版本 v6.2。v5/v6 导出：`input=[1,576]`（512+64ctx）、`state=[2,1,128]`、输出 `output`+`stateN`、手动携带 last-64 上下文。
  - LiveKit Agents 文档：`min_speech_duration≈0.05`、`min_silence_duration≈0.55`、`prefix_padding_duration≈0.5`、`max_buffered_speech=60.0`、`activation_threshold=0.5`。
  - Picovoice 2026 VAD 指南与多篇工程文：能量/WebRTC VAD 在高噪音下 FPR 高、不适合生产；Silero F1≈0.86；双阈值迟滞/longest-run 平滑；trailing padding 200–300ms；barge-in 需播放期/静音期分开校准 + 能量门限防回声 + ~250ms cooldown 防 echo-barge-in；语义 endpointing F1≈0.92。
- **代码可证**：见「现状基线」表格，均得自本次源码/测试/契约读取。
