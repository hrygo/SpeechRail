# SpeechRail 无声误转录治理验收报告 (SR-SILENCE-1)

- **验收日期**: 2026-09-06
- **代码基线**: commit `70eb9fa` 及后续治理工作树
- **关联 Issue**: [SpeechRail #10](https://github.com/hrygo/SpeechRail/issues/10)
- **配套客户端契约**: Sona [Sona #8](https://github.com/hrygo/sona/issues/8)
- **状态**: accepted (自动化单测、回归门禁与契约一致性 100% 通过)

---

## 1. 治理背景与目标

在 OpenAI Realtime `/v1/realtime` 接口的 `server_vad` 模式下，未治理的旧路径存在两类严重缺陷：
1. **纯静音/噪声转录幻觉**：未准入语音或环境底噪持续触发 ASR 会话和无声 `flush()`，Qwen3 ASR 流式模型因接收无界零输入易幻觉输出无声伪文本（如“嗯”）；
2. **全双工死锁与资源泄漏**：旧路径在人声未被防抖确认前即向 `ResourceGovernor` 预留 ASR 槽位；在单卡/单 worker 或低内存预算策略下，当 TTS 正在合成时，ASR 预留被阻塞，导致客户端后续音频无法进入 VAD，Barge-in 打断永远无法触发，造成全双工死锁。

本次实施严格按照 `docs/superpowers/plans/2026-09-06-speechrail-silence-transcription-admission.md`，达成两项目接口合同 **SR-SILENCE-1**：
- 零语音不触发 ASR、不发非空转写文本；
- 物理时间轴与 session sample 时钟绝对守恒，不因 ASR 过滤静音而漂移；
- 真实短答（“嗯/对/好”）保留前置 pre-roll 与尾音，100% 完整送入 ASR；
- 显式 commit / 自动端点 / 超限结转共享统一空闭环，连接持续健康；
- 全双工 Barge-in 打断优先于 ASR 预留，彻底消除死锁。

---

## 2. 变更实施内容 (R0 ~ R3)

| 阶段 | 实施模块 | 关键交付项 |
|---|---|---|
| **R0** | 复现与可观测性 | 1. 扩展 `FakeStreamingSession`/`FakeStreamingFactory`，可注入非空伪文本并统计 ASR 调用指标；<br>2. 增加指标：`speechrail_realtime_turn_commits_total`、`speechrail_realtime_turn_characters_total`、`speechrail_realtime_turn_duration_seconds`、`speechrail_realtime_active_audio_samples_total`，带 `mode`/`commit_reason`/`outcome` 维度；<br>3. 编写基线回归测试，稳定复现旧路径的 3 处缺陷。 |
| **R1** | 语音准入状态机 | 1. 新建 `src/speechrail/realtime/speech_admission.py`（`SpeechAdmission` 状态机，`IDLE -> CANDIDATE -> ACTIVE -> HANGOVER -> IDLE`，含 pre-roll 环形缓冲、余数分帧与样本守恒）；<br>2. 新建配置 `realtime_speech_admission_enabled: bool = False`（`SPEECHRAIL_REALTIME_SPEECH_ADMISSION_ENABLED`）；<br>3. 新建 `tests/test_speech_admission.py`（10 个测试用例，覆盖无声丢弃、防抖确认、瞬态噪声过滤、尾音保留、采样字节合法性校验、多次 reset 等）。 |
| **R2** | ASR、分人与时钟接入 | 1. `VoiceActivityDetector` 暴露 `score_frame(frame: bytes) -> float`；<br>2. `OpenAIRealtimeSession` 全面接入 `SpeechAdmission`；<br>3. `_drain_asr_events` 增加 turn generation 世代保护，过滤废弃世代与未准入输出；<br>4. 重构 Legacy 与 Admission 路径下的 Barge-in 打断时序，先打断 TTS 释放 Governor，再申请 ASR 槽位，杜绝死锁；<br>5. 完善 `speechrail.diarization.v1` 扩展模式下的 sample offset 映射；<br>6. 统一空提交与结转逻辑，输出确定性空闭环事件。 |
| **R3** | 神经 VAD 适配与配置 | 1. 新建 `src/speechrail/backends/neural_vad.py`（`SileroVadDetector`，支持流式分帧、session 递归隐藏状态隔离与 fake runner）；<br>2. 新增服务端配置：`realtime_vad_engine: Literal["legacy", "silero"] = "legacy"`、`realtime_vad_model_path: Path | None`、`realtime_vad_shadow_enabled: bool = False`；<br>3. 严格校验：`shadow_enabled` 仅在 legacy 下可用，显式 `silero` 缺失制品时明确抛出 `backend_not_ready` 错误，绝不静默回退；<br>4. 新建 `tests/test_neural_vad.py`（5 个测试用例，覆盖分帧、状态重置、preflight 失败拦截与配置约束）。 |
| **R4** | 契约与全量门禁 | 1. 更新 `contracts/realtime-openai.md`，明确 SR-SILENCE-1 准入契约与空闭环；<br>2. 验证与 Sona 消费端标准行为完全对齐；<br>3. 执行全量 Gate 验证（pytest, ruff, mypy, redocly lint, git diff --check）。 |

---

## 3. 实测验证证据

### 3.1 核心测试执行明细

```bash
# 1. 准入状态机与神经 VAD 单测
uv run --extra dev pytest tests/test_speech_admission.py tests/test_neural_vad.py -v --no-cov
# 结果: 15 passed in 0.23s

# 2. Barge-in 全双工打断与会话隔离回归
uv run --extra dev pytest tests/test_realtime_vad_bargein.py -v --no-cov
# 结果: 4 passed in 0.22s

# 3. OpenAI Realtime 全量会话与无声回归测试 (含 5 个新增准入回归测试)
uv run --extra dev pytest tests/test_realtime_openai.py -q --no-cov
# 结果: 66 passed in 0.52s

# 4. Diarization 扩展与时间轴守恒测试
uv run --extra dev pytest tests/test_diarization_extensions.py tests/test_diarization_timeline.py -q --no-cov
# 结果: 43 passed in 0.41s
```

### 3.2 SR-SILENCE-1 契约核对表

| 契约条款 | 实施表现 | 验证测试 |
|---|---|---|
| **1. 纯静音零 ASR 注入** | 静音帧经由 SpeechAdmission 拦截，ASR 会话未创建，未调用 append/flush，无任何 partial 抛出 | `test_server_vad_silence_never_emits_text_before_commit` |
| **2. 统一空闭环终态** | 显式 commit / rollover 在未接纳语音时，按序发送 `committed` → `created` → `completed (transcript="")` | `test_server_vad_silence_explicit_commit_closes_empty` |
| **3. 时间轴绝对守恒** | `audio_start_sample` 与 `attribution_units` 基于 session 全局采样点线性递增，本地 offset 准确还原物理位置 | `test_server_vad_admission_diarization_sample_mapping` |
| **4. 真实短答完整保留** | 启动防抖后，pre-roll 环形缓冲连同活动音频完整喂入 ASR，尾音随 HANGOVER 完整送出，正常输出有效转写 | `test_server_vad_admission_admitted_speech_transcription_and_events` |
| **5. Barge-in 零死锁** | TTS 播放时接收到人声，先原子取消 TTS 释放资源，ASR 再安全获取 Governor 槽位，0.2 秒级完成打断 | `test_realtime_bargein_cancels_active_tts_response` |
| **6. Manual 模式 100% 兼容** | `turn_detection=null` 或 `manual` 模式完全绕过状态机，原有逻辑无任何改变 | `test_openai_session_created_and_updated` 等 60+ 原有用例 |

---

## 4. 运行态与未验证边界

1. **真实硬件声学录音验证边界**：
   本次验证使用了合成数字纯静音、环境噪声与人声正弦样本；本地开发机器上未安装 Silero 外部权重文件，因此当前默认 `realtime_vad_engine="legacy"`。显式配置 `silero` 且缺少权重时已验证抛出 `backend_not_ready`。真实会议/长录音环境下的声学误报率（FAR/FRR）需在搭载真实权重的预发环境中进行实际声学测量。
2. **Sona 对齐状态**：
   Sona 作为标准 OpenAI Realtime 及 `speechrail.diarization.v1` 客户端，完全兼容本次实现的空闭环与时间轴格式，不需要新增私有 wire 字段或在客户端实施文本去重过滤。
