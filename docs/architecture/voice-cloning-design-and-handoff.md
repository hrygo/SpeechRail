---
title: "SpeechRail 音色克隆架构设计与工程交接"
status: active
audience: "SpeechRail / Sona 核心开发者"
version: "2.0"
date: 2026-09-12
---

# SpeechRail 音色克隆架构设计与工程交接

> 本文定义 **reference voice cloning** 的当前实现边界。完整的 Quality 音色创造/稳定化路线见 [Quality 档音色能力架构](quality-voice-capabilities.md)。

## 1. 当前决策

Reference clone 与 VoiceDesign 已正式分离：

- `voice_design`：仅负责提示词驱动的开放式音色创造与普通 Quality TTS；
- `base`：仅负责 reference audio + exact transcript 的 clone；
- `custom_voice`：Balanced/Light 固定 speaker；
- 只有 `quality` preset 安装 `tts_clone=tts-1.7b-base-q8`。

旧版“VoiceDesign 私有 `_generate_icl()` 直接做 clone”的实现不再是架构基线。Base clone 使用 MLX-Audio 的公开 `generate(text=..., ref_audio=..., ref_text=...)` 路径，使 speaker encoder / ICL 条件由 Base 模型按其公开接口建立。

## 2. 三档能力矩阵

| 档位 | 默认 TTS | Clone capability | Prompt voice design | Reference clone |
|---|---|---|---|---|
| `light` | CustomVoice 0.6B q8 | — | ✗ | ✗ |
| `balanced` | CustomVoice 0.6B q8 | — | ✗ | ✗ |
| `quality` | VoiceDesign 1.7B q8 | **Base 1.7B q8（按需）** | ✓ | ✓ |

`/v1/models` 只有在 Base capability 实际解析成功时才声明 `supports_clone=true`。`/v1/voices` 对 clone profile 返回其真实 binding variant `base`，而不是把它伪装成 `voice_design`。

## 3. 请求数据流

```mermaid
sequenceDiagram
    participant S as Sona / client
    participant API as SpeechRail API
    participant VR as VoiceRegistry
    participant R as TTS Capability Router
    participant B as Qwen3-TTS Base Worker

    S->>API: POST /v1/voices/clone (audio, ref_text, name)
    API->>API: decode / validate reference
    API->>VR: create clone VoiceProfile
    API-->>S: 201 VoiceProfile (variant=base)

    S->>API: POST /v1/audio/speech (voice=clone_id)
    API->>VR: resolve clone profile
    API->>R: SpeechRequest
    R->>R: capability lock; close primary if resident
    R->>B: lazy start Base on first clone
    B->>VR: lease immutable reference revision
    B->>B: public generate(ref_audio, ref_text, target text)
    B-->>API: 24 kHz PCM16 chunks
    API-->>S: requested audio container/stream
```

## 4. 注册边界

`POST /v1/voices/clone`：

1. 只有 Quality + Base capability 可进入；
2. 上传与 `ref_text` 在服务端重新校验，客户端 validate 不能作为旁路凭证；
3. VoiceRegistry 创建不可变 reference revision；
4. 返回的 voice entry `variant=base`；
5. 切到 Balanced/Light 后该 clone `available=false`；切回有效 Quality/Base 后恢复。

不允许：

- Base 缺失后 fallback 到 VoiceDesign；
- CustomVoice 接受 clone metadata；
- 把 target text 纳入音色身份 seed 后声称是稳定 identity；
- 在错误模型上忽略 `ref_audio/ref_text` 仍返回成功。

## 5. Worker / IPC

公共 HTTP API 不暴露后端 checkpoint 名称。主进程把 clone profile 解析为 Base binding，IPC frame 包含：

- `text` / `voice` / `language`；
- `ref_audio`（本地注册 reference 路径）；
- `ref_text`；
- 不支持的 clone `speed != 1.0`、instruction、caller seed 在 adapter 边界明确拒绝。

Base worker 内部解码 reference，并调用 vendor public `generate`；不再调用 `_generate_icl` 私有方法。

## 6. 按需换模与资源边界

Quality 安装 VoiceDesign 与 Base 两套 TTS 权重，但运行时通过 `Qwen3TtsCapabilityRouter` 使用单一逻辑 TTS 槽：

- startup warm VoiceDesign；
- clone 首次请求关闭 VoiceDesign 后启动 Base；
- 下一次普通 TTS 关闭 Base 后恢复 VoiceDesign；
- capability lock 覆盖一次完整流式合成，避免切换中交叉；
- Base 也受既有 idle eviction / close 生命周期管理。

因此不能把“新增 Base artifact”直接等同于“常驻 RAM 永久增加一整个 Base 模型”。需要单独实测换模冷启动与峰值瞬态，不能沿用旧 VoiceDesign-only RAM 数据作新结论。

## 7. Reference 音频质量

模型职责正确只是必要条件，不足以解决全部噪声/韵律问题。后续 canonical reference pipeline 应做到：

- VAD + 分段筛选；
- 准确 transcript 对齐；
- 只在有证据时使用轻度降噪；
- 基于有效语音的一次性归一；
- 避免 Sona 与 vendor 双重增益；
- 严重 clipping/reverb/多人重叠直接要求重录；
- 多段录音优先用于选择可靠主参考，不盲目拼成长 prompt。

## 8. 质量验收与当前缺口

现有请求级 seed、clone-only sampling 和 loudness controller 只能证明一部分**确定性/电平边界**，不能证明跨文本 speaker identity。

2026-09-12 本地审计还发现现有 synthesis quality-run 对静音、极端 clipping、随机噪声的最终 pass 判定不够严格，并且 deterministic 字段不是由真正的重复输出比较得出。该问题属于独立质量门禁整改项；在修复前不能把 `voice_quality_v1: pass` 解释成“音色纯净且跨文本稳定”。

正式验收至少包含：

- 多文本 × 多次重复；
- 独立 speaker encoder similarity；
- 可懂度/漏字/复读；
- 静音/DC/clipping/非语音；
- 首音延迟、RTF、换模时间、RSS；
- 等响度盲听。

## 9. Sona 工程交接

Sona 保留两个明确入口：

1. **描述声音** → `quality` VoiceDesign；
2. **克隆我的声音** → `quality` Base reference clone。

Sona 不应知道具体模型目录，只消费 SpeechRail capability。创建后都进入统一“我的音色”资产体验。Prompt-created voice 的 canonical-reference→Base 稳定化是下一阶段显式注册流程，不能由客户端猜测或用同一个 clone endpoint 偷渡。

## 10. 回归门

本架构变化至少要求：

- catalog/preset schema tests；
- managed install / profile selection / preflight tests；
- VoiceBinding variant tests；
- Base public clone generation tests；
- capability router lazy-load + mutually-exclusive swap tests；
- clone HTTP API + TTS IPC tests；
- Ubuntu/macOS Python 3.12 CI 全绿。
