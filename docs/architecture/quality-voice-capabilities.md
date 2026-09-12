---
title: "Quality 档音色创造、克隆与稳定化能力架构"
status: active
audience: "SpeechRail / Sona 架构师、维护者、音频质量负责人"
version: "1.2"
date: 2026-09-12
---

# Quality 档音色创造、克隆与稳定化能力架构

## 1. 决策摘要

SpeechRail 将 `quality` 定义为唯一具有**音色创造（voice design）**和**参考音色克隆（voice clone）**能力的 Studio 档。两类任务不再由同一个模型混用：

- **提示词设计音色**：Qwen3-TTS VoiceDesign 1.7B，职责是根据自然语言描述创造声线；
- **参考音频克隆**：Qwen3-TTS Base 1.7B，职责是根据参考音频 + 准确参考文本复现 speaker identity；
- **常规内置音色**：`quality` 继续由 VoiceDesign 提供，`balanced/light` 继续由 CustomVoice 0.6B 提供；
- **双 capability worker**：Base 作为 `quality.tts_clone` capability artifact 安装，并与 VoiceDesign 使用独立 worker。两者可以同时常驻、分别处理请求；懒加载只决定首次加载时机，不会在 capability 切换时卸载另一模型。

该设计修正了旧实现把参考克隆请求送入 VoiceDesign 私有 `_generate_icl()` 的职责混用。clone 现在只允许由 `base` variant 经 MLX-Audio **公开 `generate(...)` 接口**执行。

## 2. 两条 Sona 音色创建链路

```mermaid
flowchart LR
    subgraph Sona["Sona · Voice Studio"]
        Prompt["提示词设计音色"]
        Ref["录音 / 上传参考音频"]
    end

    Prompt --> VD["VoiceDesign 1.7B\n创造目标声线"]
    Ref --> Prep["Reference Conditioning\n格式/VAD/质量/转写/按需增强"]
    Prep --> Base["Base 1.7B\nReference Clone"]
    VD --> Designed["Designed Voice / canonical reference"]
    Designed -. "稳定化阶段" .-> Base
    Base --> Profile["VoiceProfile / VoiceRevision"]
    Designed --> Profile
    Profile --> TTS["统一 TTS 调用入口"]
```

### 2.1 提示词链路

目标语义是“创造一种声音”，而不是“复刻一个已有的人”。VoiceDesign 接收文本描述，例如年龄感、音高、口音、情绪和播报风格。

本 PR 的运行时边界：

1. prompt-created voice 继续由 VoiceDesign 合成；
2. VoiceDesign 不再被允许承接 reference clone；
3. 新增显式 `POST /v1/voices/designs`：输入描述、参考文本、seed 和一个未占用的目标 ID，生成并核验规范参考，再保存为 Base-bound clone；已有 `/v1/voices` metadata-only 创建行为不变。生成与 ASR 阶段结束前不发布候选音色；旧音色不自动迁移。该注册操作不执行 Base 合成，响应明确为 `synthesis_validation=unevaluated`，后续通过普通 TTS 与 `quality-runs` 验收。当前仅开放中文实验门。详见[生成式音色注册](generated-voice-registration.md)。

长期目标是“VoiceDesign 负责创造，Base 负责稳定复现”：设计成功后生成一段经过质量门的 canonical reference，再由 Base 建立稳定 clone revision；后续目标文本不再每次重新进行开放式音色设计。

### 2.2 参考音频链路

目标语义是“像这个 speaker”。Reference clone 必须直接进入 Base：

```text
Sona capture/upload
  → decode + format verification
  → reference quality / VAD / segmentation
  → exact transcript verification
  → optional conservative enhancement
  → one canonical level-normalization boundary
  → Qwen3-TTS Base public clone path
  → cross-text quality acceptance
  → VoiceRevision
```

VoiceDesign、CustomVoice 均不得作为 reference clone fallback。Base 不可用时返回明确的 `voice_cloning_unsupported` / `voice_clone_base_model_unavailable`，不能降级到错误模型后继续返回 200。

## 3. Catalog 与能力建模

`ModelPreset` 将模型档位与 capability artifact 分离：

```yaml
quality:
  asr: asr-1.7b-q8
  tts: tts-1.7b-design-q8
  tts_clone: tts-1.7b-base-q8
  aligner: aligner-bf16
  diarization: true

balanced:
  tts: tts-0.6b-custom-q8
  tts_clone: null

light:
  tts: tts-0.6b-custom-q8
  tts_clone: null
```

`tts` 表示档位的默认 TTS；`tts_clone` 是可选的 clone capability，并不把 Base 伪装成默认 TTS。`/v1/models` 的 `supports_clone` 只有在运行时实际解析到 `base` capability 时才为 `true`。

Base artifact 使用不可变模型 revision 和逐文件 SHA-256，遵循与其他 managed artifacts 相同的离线、校验、原子发布和 fail-closed 规则。

## 4. 运行时模型槽：双 capability 并行与冷却驱逐

Quality 的 `Qwen3TtsCapabilityRouter` 维护两个独立的 capability worker，而不是在请求之间交换一个模型槽：

```mermaid
flowchart LR
    Request[SpeechRequest] --> Router[Qwen3TtsCapabilityRouter]
    Router -->|voice_design lane| VD[VoiceDesign 1.7B worker]
    Router -->|voice_clone lane| Base[Base 1.7B worker]
    VD -. 同一 worker .-> VDLock[worker lock 串行]
    Base -. 同一 worker .-> BaseLock[worker lock 串行]
    VD <-->|不同 lane| Base
    Router --> Evict[WorkerIdleEvictor
    warm standby / cooldown cold eviction]
    Evict -->|组级 trim/close| VD
    Evict -->|组级 trim/close| Base
```

运行规则：

1. 非懒加载模式下服务启动按顺序 warm primary VoiceDesign 与 Base；懒加载模式下先按请求加载所需 worker，另一 worker 在首次使用时加载；
2. 请求根据 VoiceProfile 进入 `voice_design` 或 `voice_clone` lane；不同 lane 可以并发，同一 lane 由对应 worker 的私有 lock 串行；
3. capability 切换只改变路由，不关闭另一 worker，因此连续的“设计音色 → 使用已有 clone”不会反复加载/卸载模型；
4. `/health` 的 `tts_lifecycle.warm_capability` 在双 warm 时报告 `both`，并以 `warm_capabilities` 给出 `voice_design` / `voice_clone` 明细；探测不得触发模型加载；
5. worker `backend` 只标识通用 `mlx-qwen3-tts` 运行时；具体 VoiceDesign / Base / CustomVoice 身份由独立的 `model_variant` 表达；
6. 父进程在 composition 阶段确定期望 `model_variant`（受管模型优先取 catalog；非受管本地快照才执行本地 identity inspection），并在 worker `ready` 握手中逐项比对；variant 缺失或不匹配必须 `backend_identity_mismatch` fail-closed，禁止回退成 VoiceDesign；
7. `quality-runs` 作为批量 TTS 工作必须进入带 capability key 的 `ResourceGovernor`，并使用统一绝对 deadline 与公共 `AudioChunk` 流校验，不能绕过正常运行时资源边界；
8. `WorkerIdleEvictor` 把 router 视为一个能力组：warm standby 同时 trim 两个 worker，冷却到期后一起 close；驱逐期间 worker 自己的 lock 保证活动流完成后再释放；冷驱逐后下一请求按需重新加载所需 worker，不发生请求级互斥换模；
9. 合成门通过后，先在同一请求 deadline 内释放两个 TTS worker，再进入受治理的 Batch ASR 回转录阶段；ASR 缺失或异常为 `unevaluated`，不得给出假通过。详见[输出可懂度 / ASR 复核](voice-quality-intelligibility-validation.md)。

双常驻会增加 Quality 的活动内存占用，`SPEECHRAIL_TTS_RESIDENT_BYTES` 按单个 TTS worker 的实测峰值声明，heavy-overlap 预算按 router 可能常驻的 worker 数量计入。冷却驱逐仍保留，用于释放整组权重；重新使用时只为当前请求恢复需要的 worker。

## 5. VoiceProfile / VoiceRevision 收敛方向

上层不应该长期感知底层 checkpoint。建议统一记录：

```yaml
voice_id: example
origin: recorded | generated
revision: 3
canonical_reference:
  audio_sha256: ...
  transcript_sha256: ...
  preprocessing_version: ...
identity:
  backend: qwen3_tts_base
  model_revision: ...
quality:
  policy_version: voice_quality_v1
  run_id: ...
```

对于 prompt-created voice，`origin=generated`；对于 Sona 录音，`origin=recorded`。两者在完成 Base 稳定化后都可以成为同一种可复用 VoiceRevision。当前 `VoiceProfile.creation` 已为新生成参考记录模型制品/revision、seed、文本/指令/规范音频 hash 和前处理版本，旧记录可缺省该字段。它是来源元数据，并不是完整 revision 历史或声纹相似度证据；上述其余字段与旧资产迁移仍是后续 schema evolution 的目标。

## 6. Reference conditioning 最佳实践与 Sona 边界

### 6.1 录音端

Sona 应优先得到可诊断的、未经隐藏 DSP 反复改变的参考：

- 明确记录实际 input device / channel / sample rate；
- 浏览器请求的 constraint 与实际 track settings 分开记录；
- 优先支持 PCM/WAV 采集路径，WebM/Opus 仅作为兼容输入；
- 用户可录多段自然朗读，服务端选择合适主参考，不要求用户一次达到专业播音水平；
- 原始录音、规范参考和生成试听是三个不同对象，UI 不应混淆。

### 6.2 前处理端

SpeechRail 应成为 canonical reference 的权威处理边界：

- VAD/segmentation 只保留可靠 speaker 段；
- 参考文本必须与实际发音一致；
- 降噪仅在有证据时轻度启用，并以音色损伤为反向门；
- 只做一次基于有效语音的增益/响度处理，避免 Sona 与 vendor 重复归一；
- 严重削波、混响、多人重叠优先重录，不承诺靠增强模型恢复；
- 可评估 DeepFilterNet3，但它是条件式 enhancer，不是 clone 的必经路径。

当前服务端已对新注册参考执行一次有界规范化，并关闭 vendor 的 `volume_normalize`：20 ms 窗口以 -45 dBFS 能量阈值筛选，目标 -20 dBFS，增益最多 +9 dB、衰减最多 12 dB，并以 0.95 样本峰值上限优先约束；仅裁剪首尾低能量区并保留约 200 ms 边界，内部停顿不改写。这些是工程初始值，并非目标机实测最优参数。

该能量筛选**不是神经 VAD 或降噪器**，不能保证移除背景噪声，也不能识别多人或修复混响。Sona 的录音端增益仍需协同整改；现有参考不会自动重写或迁移，因此本 PR 不宣称全链路单次归一、专业表达或旧音色迁移已经完成。旧音色必须重新注册或通过显式 revision 迁移验证，禁止用静默更换参考掩盖模型变化。

## 7. “像本人”与“播得专业”必须解耦

Reference clone 的 speaker identity 和用户录音中的 prosody 并不是同一个目标。Quality 后续提供两种体验：

- **原声保真**：优先保留用户身份、口音与自然表达；
- **自然播报/专业表达**：保留身份，但语速、停顿、重音、情绪由独立表达控制承担。

不能用简单整体变速、压缩动态或更大音量冒充 prosody 解耦。Base speaker-only/x-vector-only 模式、VoxCPM2 或“专业 TTS prosody → voice conversion”都只能作为实验后端，经身份泄漏、自然度、延迟和资源门后才能进入正式 capability。

## 8. 质量验收

创建成功、输入参考合格、输出质量合格是三个状态，不得合并。

最低验收矩阵：

- 至少覆盖陈述、疑问、数字/单位、标点、短响应、长句/停顿等不同文本；
- 同一配置和 reference 做重复生成；
- 评价 speaker similarity 的跨文本分布，不只看同文本 hash；
- 检查静音、非语音、DC、削波、峰值、可懂度、漏字/复读；
- 同时记录首次可听延迟、统一定义 RTF、换模冷启动、内存与取消行为；
- 主观比较需响度匹配，避免“更响=更好”的偏差。

现有 `voice_quality_v1` 已有输出信号、重复 PCM 与阶段化 ASR 检查，但独立声纹、真实音频 A/B 和噪声评估仍未完成。生成式注册只填写参考侧报告、输出侧 probe_count=0；绿色参考报告不能被解释为“Base 输出、跨文本身份与纯净度已证明”。

## 9. 分阶段演进

### Phase A — 本 PR：能力职责正确化

- catalog 增加 Base clone artifact；
- Quality preset 增加 `tts_clone`；
- Base 成为唯一 reference clone variant；
- clone 改走 vendor public `generate`；
- capability router 实现 VoiceDesign/Base 双 worker、分 lane 并发与组级 idle eviction；
- managed install / profile / preflight / model capability 全链同步；
- README、架构与当前边界更新；
- 保持 Balanced/Light 与现有公共请求形状不变。

### Phase B — 参考音频质量流水线

- Sona PCM capture / 多段录音；
- canonical reference pipeline；
- speech-aware normalization 与条件降噪；
- 输入/输出质量门禁修复；
- 参考特征缓存。

### Phase C — Prompt voice 稳定化

- 已实现显式 `/v1/voices/designs` 生成/验证 canonical reference，并创建新的 Base-bound clone（不覆盖旧 ID）；
- 完整 VoiceRevision 历史与已有音色迁移尚未实现；
- 显式迁移与回滚；
- 跨文本 speaker similarity 与 ABX 门。

### Phase D — 专业表达

- 身份/韵律解耦实验；
- Base conditioning 模式、VoxCPM2/VC 对照；
- 根据实时性和质量证据决定是否进入生产 capability。

## 10. 回滚

- catalog/preset 回滚到无 `tts_clone` 的版本即可恢复旧安装集合；
- runtime router 可以整体回滚，不修改已有 clone reference 文件格式；
- 本 PR 不自动重写已有 VoiceProfile，不做不可逆音色资产迁移；
- 不允许在回滚时把 clone 请求重新静默送给 VoiceDesign；若 Base 不存在，应显式把 clone capability 标记为不可用。
