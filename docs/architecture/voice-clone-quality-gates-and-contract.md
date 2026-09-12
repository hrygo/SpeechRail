---
title: "SpeechRail 克隆音色质量门禁与自量保障契约"
description: "定义克隆参考音频校验、生成后固定 probe 质量运行、VoiceQualityReport、低基数观测与 Sona 消费边界"
status: under_review
type: technical_spec
category: tts
version: "1.0.0"
date: 2026-09-09
last_updated: 2026-09-09
author: "SpeechRail Core Team"
owners:
  - "speechrail-core"
tags:
  - speechrail
  - tts
  - voice-clone
  - quality-gate
  - qwen3-tts
  - contract
scope:
  - "speechrail.domain.tts"
  - "speechrail.backends.qwen3_tts"
  - "speechrail.http.routes.system"
  - "speechrail.http.routes.audio"
  - "speechrail.application.realtime_openai"
related_documents:
  - "docs/architecture/voice-cloning-design-and-handoff.md"
  - "docs/architecture/voicedesign-capability-and-stability.md"
  - "docs/operations/capability-quality-acceptance.md"
  - "docs/operations/clone-tts-stability-acceptance-2026-09-09.md"
contracts:
  - "contracts/openapi.yaml"
tracking_issues:
  - "https://github.com/hrygo/SpeechRail/issues/36"
  - "https://github.com/hrygo/sona/issues/13"
---

# SpeechRail 克隆音色质量门禁与自量保障契约

## 1. 背景与设计结论

当前 SpeechRail 已具备 clone reference audio 的格式/时长/削波/有效语音检查、请求级稳定采样、clone-only streaming loudness controller 和 24 kHz mono PCM16 输出契约。现有验收证明了“输出稳定性”边界，但还没有把以下问题收敛成一个可消费的质量契约：

- 参考录音是否足够干净，适合让 Base clone 条件提取 speaker identity；
- clone 生成是否在多种中文 probe 上稳定；
- 用户在 Sona 清空会话、重启管道后听到的噪声是否来自 SpeechRail；
- 哪些指标可以公开给 Sona，哪些信息必须留在服务端内存或受控日志；
- clone 创建成功是否等价于“可以作为默认助手音色”。

> 2026-09-12 更新：reference clone 已从 VoiceDesign 私有 ICL 路径迁移到 Quality-only Base public generation。另一次本地回归审计发现当前 synthesis quality-run 的最终 pass 与 deterministic 判断仍存在假阳性风险；该报告契约保留，但在门禁修复前不能把 `pass` 当成 speaker identity/纯净度的充分证据。

本方案的关键决策：

1. **SpeechRail 是音频质量权威方**：负责输入校验、生成输出校验和质量策略版本。
2. **clone 创建必须重新执行权威校验**：客户端 validate 只是早反馈，不能作为绕过门禁的凭证。
3. **质量报告是 VoiceProfile 的可选附加字段**：兼容旧客户端，缺失时为 `unevaluated`，不假设通过。
4. **质量运行不保存原始 PCM**：只返回脱敏的指标摘要和失败原因码。
5. **Sona 负责用户体验和播放诊断**：不在客户端重复做服务端归一化，也不修改 SpeechRail 模型生命周期。

## 2. 现状证据与缺口

已存在的实现/契约入口：

- `src/speechrail/domain/tts.py`：`VoiceProfile`、clone 音频转码与信号校验；
- `src/speechrail/backends/qwen3_tts_worker.py`：Base public clone generation、reference load、稳定 seed、跨 chunk loudness controller；
- `src/speechrail/backends/qwen3_tts.py`：clone delivery 统计和 worker 生命周期；
- `src/speechrail/http/routes/system.py`：`/v1/voices/clone` 与音色目录；
- `src/speechrail/http/routes/audio.py`：REST TTS 的 clone speed/instruction 能力边界；
- `contracts/openapi.yaml`：`VoiceProfile`、`VoiceCapabilities` 和 clone/preview 端点。

当前缺口不是再加一个“固定增益”参数，而是缺少统一的质量结果模型、probe 运行入口和跨仓库诊断关联。

## 3. 质量报告模型

建议在 `speechrail.domain.tts` 定义内部不可变模型，并在公共 API 中序列化为可选字段：

```json
{
  "quality": {
    "policy_version": "voice_quality_v1",
    "status": "pass",
    "run_id": "vqr_01J...",
    "tested_at": "2026-09-09T12:00:00Z",
    "reference": {
      "duration_seconds": 8.4,
      "sample_rate": 24000,
      "channels": 1,
      "speech_active_ratio": 0.78,
      "noise_floor_dbfs": -52.1,
      "estimated_snr_db": 28.4,
      "clipping_ratio": 0.0,
      "leading_silence_seconds": 0.21,
      "trailing_silence_seconds": 0.34,
      "transcript_match": 0.998
    },
    "synthesis": {
      "probe_count": 3,
      "successful_probe_count": 3,
      "active_rms_dbfs": -20.8,
      "peak_dbfs": -3.2,
      "chunk_jump_p95_db": 4.6,
      "clipping_ratio": 0.0,
      "deterministic": true
    },
    "failure_codes": []
  }
}
```

### 3.1 字段约束

- `status`：`unevaluated | pass | warn | reject`；
- `policy_version`：门槛变更必须递增，禁止用服务版本隐式替代；
- `run_id`：用于 Sona UI、服务日志和 issue 证据关联，不含用户文本；
- 指标只保留聚合值/分位数，不返回原始 waveform、频谱、音频 hash 或文件路径；
- `failure_codes` 使用稳定枚举，例如 `audio_too_short`、`low_snr`、`high_noise_floor`、`clipping`、`transcript_mismatch`、`probe_failed`、`output_peak_exceeded`；
- `quality` 在旧 VoiceProfile 中可缺省；缺省客户端显示 `unevaluated`。

## 4. 输入参考音频质量门禁

### 4.1 统一处理顺序

1. 限制上传大小和解码时长，拒绝解压炸弹；
2. 转码为 mono/24 kHz/PCM16；
3. 计算信号指标；
4. 执行文本匹配（若启用 ASR 校验，结果只保留匹配分数）；
5. 生成 `reference_quality`；
6. 只有 `pass` 或产品允许的 `warn` 才进入 `create_cloned_profile`；
7. reference 文件写入受控目录后，权限保持 `0700/0600`，日志不输出路径和文本。

### 4.2 初始策略 `voice_quality_v1`

以下是产品起始门槛，不是 Qwen3-TTS 官方硬限制；必须通过 fixture 和真实录音校准：

| 指标 | pass | warn | reject |
|---|---:|---:|---:|
| 有效时长 | 4–30 s | 2–4 s 或 30–45 s | <2 s 或 >45 s |
| `noise_floor_dbfs` | ≤ -45 | -45～-35 | > -35 |
| `estimated_snr_db` | ≥20 | 15–20 | <15 |
| `clipping_ratio` | <0.01% | 0.01–0.1% | >0.1% |
| 首/尾静音 | ≤0.8 s | 0.8–1.5 s | >1.5 s |
| `speech_active_ratio` | ≥0.55 | 0.35–0.55 | <0.35 |
| `transcript_match` | ≥0.98 | 0.90–0.98 | <0.90 |

规则解释：

- 静音和低 SNR 是强风险，不能靠输出 loudness controller 修复；
- 参考音频整体电平可在 worker 内存中 `volume_normalize=True`，但不得把它当成降噪；
- 轻微 warn 可以允许用户继续，但 clone 不应自动成为默认音色；
- 质量策略以“最严重等级”为最终等级，保留全部失败原因码。

## 5. clone 与质量运行 API

### 5.1 预检：`POST /v1/voices/clone/validate`

建议新增 report-only 端点：

- 请求：与 `/v1/voices/clone` 相同的 `multipart/form-data`，但不创建 VoiceProfile；
- 响应：`200` 返回 `VoiceQualityReport`；质量拒绝仍返回报告，便于 UI 展示；
- 不写受控 reference 文件；必要的转码和指标计算只在请求内存/临时资源中完成；
- 可选 `ref_text` 用于文本匹配；未提供时将 `transcript_match` 标记为 unavailable，而不是判定通过。

### 5.2 创建：`POST /v1/voices/clone`

clone route 必须始终重新执行输入门禁，即使客户端刚刚成功调用 validate。响应的 `VoiceProfile.quality` 是创建时报告，且包含同一个 `run_id`。

新增建议：

- 支持 `Idempotency-Key`，避免网络重试创建重复音色；
- `warn` 是否允许创建由服务策略决定，但响应必须明确 `status=warn`；
- `reject` 返回稳定错误 envelope，并包含 `quality_report` 摘要；
- 不因 `quality` 失败暴露内部绝对路径、模型路径、完整参考文本或 PCM。

### 5.3 生成后质量运行：`POST /v1/voices/{voice_id}/quality-runs`

建议新增一个有界、同步优先的质量运行端点；超过单请求预算时可返回异步 job，但不引入无限轮询。

请求字段：

```json
{
  "probe_set": "voice_quality_v1_zh",
  "runs": 3,
  "include_audio": false
}
```

约束：

- probe 文本由服务端固定版本管理，客户端不能自由修改为任意文本后宣称通过；
- `runs` 表示每个固定 probe 的重复次数，限制在 `1..3`；默认 3；固定 probe 集始终完整执行，因此默认总合成次数为 `6 × 3 = 18`；
- 只返回 quality summary，试听音频仍走既有 preview/REST/Realtime 响应，不落盘；
- 质量运行必须记录模型/变体/策略版本和服务版本，但不记录 voice 自由值、文本和路径；
- 失败时区分 `probe_failed`、`clone_speed_unsupported`、`output_invalid`、`output_peak_exceeded`、`output_nondeterministic` 和服务不可用。

固定中文 probe 至少覆盖：短句、长段落、问句、数字和标点、多个停顿，以及“请进行自我介绍”这一跨清空/重启验收句。

## 6. 生成输出质量指标

SpeechRail 继续是输出 PCM 的权威方，Sona 不做第二次完整归一化。建议对每个 clone request 在 worker/ delivery boundary 计算：

- `active_rms_dbfs`：只在有效语音窗口统计；
- `peak_dbfs`、`clipping_ratio`：验证 PCM16 不回绕、不越过 ceiling；
- `chunk_jump_p95_db`：相邻有效 chunk RMS 跳变 P95；
- `successful_probe_count`：所有固定 probe × 重复次数中的有效输出数；`deterministic`：同一固定 probe 在重复运行中的 PCM SHA-256 是否完全一致（`runs=1` 时为 `false`，不宣称已验证确定性）；
- `format`：24 kHz、mono、PCM16、chunk 顺序、response 生命周期；
- `ttfa_ms`、总时长和取消结果：用于回归，不作为音色相似度分数。

初始建议门槛：active RMS 目标值 ±3 dB、chunk jump P95 不高于内置音色基线 +2 dB、peak ≤ -1 dBFS、clipping ratio 为 0。所有阈值必须与 `policy_version` 一起发布，并允许按真实数据校准。

## 7. 噪声归因与日志隐私

### 7.1 能力边界

SpeechRail 可以证明“输入参考音频或输出 PCM 是否存在统计异常”，不能单独证明用户最终扬声器听感。Sona 必须提供播放前 PCM 摘要、输出设备摘要和回声状态，才能完成端到端归因。

### 7.2 低基数观测

允许记录：

- `voice_category=clone|system|custom`；
- `quality_status`、`policy_version`、`run_result`；
- `clone_loudness_request`、`clone_loudness_calibrated`、`clone_loudness_peak_ceiling`；
- `reference_cache_hit/miss/eviction`；
- probe 成功数、失败原因码和延迟分桶。

禁止记录：

- 原始 PCM、Base64、频谱、完整 RMS 序列；
- 完整 `ref_text`、probe 文本和用户对话；
- 用户自定义 voice ID、绝对模型/音频路径、API key；
- 可由多个指标拼出用户声纹的高精度长序列。

## 8. 测试与验收

### 8.1 单元与契约测试

- reference fixture：干净、风扇、键盘、混响、削波、纯静音、低音量、错读文本；
- 逐指标边界：刚好通过、刚好 warn、刚好 reject；
- `VoiceQualityReport` 序列化/反序列化、旧客户端缺省字段、未知字段前向兼容；
- validate 不创建 profile、不写持久化 reference；
- clone 重新校验、`Idempotency-Key`、稳定错误 envelope；
- quality run 固定 probe、最多 3 次、取消/超时/模型不可用；
- 输出格式、peak、clipping、chunk jump 和 deterministic 统计；
- 不把 PCM、文本和路径写入日志的 logger capture 测试。

### 8.2 真实模型 smoke

每个候选 clone 使用至少 3 个中文 probe、串行 3 次，与一个内置音色同机对照。验收材料只包含：版本、策略、指标聚合、试听结论和 issue 链接。原始录音和输出 PCM 不进入仓库或 issue。

### 8.3 跨 Sona 闭环

Sona 触发清空 response chain、清空 memory、重建 interaction pipeline 后，再请求“请进行自我介绍”。必须能把 SpeechRail `quality_run_id`、Sona `run_id`、播放前摘要和回声状态关联起来。若 SpeechRail PCM 清洁而扬声器吵杂，验收结论归 Sona 播放链，不修改 clone 模型。

## 9. 实施阶段与回退

1. **契约阶段**：先加入可选 `quality`、稳定错误码、策略版本和 `run_id`，旧客户端继续可用。
2. **观测阶段**：计算输入/输出报告但不阻止已有 clone，统计真实数据和误拒绝率。
3. **软门禁阶段**：warn 可创建但不自动激活，reject 返回可操作报告。
4. **硬门禁阶段**：静音、严重削波、极低 SNR、严重文本不匹配禁止创建。
5. **默认激活阶段**：只有 quality probe 通过且 Sona 用户确认后才可切换默认音色。

回退方式：按策略版本关闭 hard gate 或回到上一 SpeechRail managed release；不删除已有 VoiceProfile，不在 `runtime/current` 直接编辑模型或音频。

## 10. 完成定义

- OpenAPI、VoiceProfile 和错误 envelope 能表达质量状态而不破坏旧客户端；
- 输入门禁、clone revalidate、固定 probe 和输出指标都有自动化证据；
- 真实模型验收能区分输入噪声、生成异常和客户端播放异常；
- Sona 可以展示结果、指导重录并完成清空/重启后的自我介绍闭环；
- 日志和测试产物不包含原始音频、完整文本、私有路径或凭据；
- issue 回填实现 PR、发布版本、测试摘要、人工试听与回退结论后，文档状态才从 `under_review` 改为 `implemented`/`completed`。
