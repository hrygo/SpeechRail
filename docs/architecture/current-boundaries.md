---
title: "SpeechRail 当前边界与剩余风险"
status: active
version: "3.3.0"
date: 2026-09-26
---

# SpeechRail 当前边界与剩余风险

## 已确认

1. REST 文件转写使用仓库外 Qwen3-ASR worker；运行时明确设置离线环境变量。
2. 默认 Apple Silicon profile 为 MPS / `float16`，worker 拒绝自动 CPU fallback。
3. 未配置 profile 路径时不加载模型；ASR 仍由一个隔离 worker 持有。TTS 由 capability router 按角色管理：每个 `fast` / `quality` / `reference` spec 分别绑定 `custom_voice` 与 `base` worker，`reference` 另绑定仅用于设计任务的 `voice_design` worker；不同 capability lane 可双常驻、可并发，同一 worker 内串行，懒加载只决定首次加载时机，冷却后由 router 组级驱逐。WLK 只可连接外部已运行 endpoint。分人由一个按需启动的私有 Swift/CoreML worker 执行，
   固定 FluidAudio Sortformer FP16 bundle，不是 NeMo 或第三个 MLX worker。Sortformer 与
   aligner 不随规格继承；只有任务显式 opt-in 且两个制品都点名为就绪时，才供给到
   `app_home/diarization/<aligner-key>`。
4. QwenPaw 的历史接入记录不能替代当前配置/模型状态；再次切换前必须单独 smoke。
5. 默认 loopback，非 loopback 配置必须有 API key；敏感音频/文本不写入仓库或常规日志。
6. 仓库/源码当前 release 版本为 `3.2.1`（以 `pyproject.toml` 与版本一致性门禁为准）。历史受管运行时记录仅保留为**历史部署证据**，不能据此推断当前受管安装状态。源码修改必须重新构建并走 managed release，不能直接改 `runtime/current`。
7. `server_vad` 的 generic contract 默认值与调用方策略分离：Sona subtitle 为 `0.65/300ms/400ms`，meeting 为 `0.65/300ms/900ms`（threshold/prefix/silence）。SpeechRail 不替调用方决定其业务 endpointing 窗口。
8. Realtime VAD 评分与 `SpeechAdmission` 状态机是一条 endpointing 链；continuous diarization activity 是另一条 speaker evidence 链，不是重复 VAD，也不改写 canonical completed text。
9. reference clone 由所选 TTS spec 的 `tts_base` capability 承担，并经 vendor public `generate(ref_audio, ref_text, ...)` 路径执行；`fast` / `quality` 使用 8-bit Base，`reference` 使用 bf16 Base。VoiceDesign 只处理设计任务，不作为 clone fallback。现有请求级 seed、低温度采样、首次有效片段后冻结响度增益、peak ceiling 与非 `1.0` speed 拒绝仍保留，但这些只覆盖确定性/电平边界，不等价于跨文本 speaker identity 已通过。
10. 词级时间戳由 ASR 原生输出提供（`timestamp_granularities`），不依赖 aligner；aligner 仅为分人路径服务，不是通用 ASR 依赖。分人由任务 opt-in 触发，只有显式供给 Sortformer 与 aligner 时才按当前 readiness 声明。
11. ASR∥TTS 重计算重叠是可配置策略（ADR-0016）：`SPEECHRAIL_ALLOW_HEAVY_OVERLAP=auto`（默认）按声明常驻字节与 `max(4 GiB, host_memory // 2)` 预算 fail-closed 判定——任一启用组件未声明非零峰或总量超预算即串行；`true`/`false` 为运维强制。各 TTS spec 的 `custom_voice` / `base`（`reference` 另含 `voice_design`）是独立 capability lane：不同 lane 可并发，同一 lane 串行；未声明的 TTS lane 仍受单 worker 约束。ASR∥ASR 仍返回 `backend_busy`，不复制进程。现存 A/B 只覆盖记录中声明的组件组合，不能直接作为其他组合或双 TTS 峰值证据。
12. Realtime 并发会话的源码默认值由 `Settings.realtime_max_sessions` 唯一定义，当前为 **3**（环境变量 `SPEECHRAIL_REALTIME_MAX_SESSIONS` 可覆盖，校验范围 1–8）。历史文档中的默认值 2 已废弃；能力/运行时判断不得再复制第二套默认常量。
13. Realtime 已切换为 current-only 无状态 Speech Plane：客户端只使用 `session.update`、音频 buffer 事件、`speechrail.tts.start/append_text/finish_text/cancel` 和 diarization barrier。服务端只交付 ASR/VAD/匿名分人事实与显式 TTS 音频，不拥有 LLM、conversation history、memory、tools、播放或 barge-in 策略；新 hypothesis 不自动取消 TTS。旧事件和旧字段明确拒绝，不做 alias、双 wire profile 或 `/v2` 迁移层。
14. `reference` 使用 BF16 ASR、CustomVoice、Base 与 VoiceDesign；按用户裁定继承同族 8-bit 档位已通过的门禁证据，未在本机逐项复测。代码、准备制品和静态契约已完成；本轮不把继承证据写成质量排名、资源峰值或延迟报告。

## 明确限制

- `/v1/realtime` 是 current-only 的 ASR/TTS 子集；不伪装 LLM 对话、工具调用、历史或持续
  会话语义。分人是 `session.speechrail.diarization.enabled` opt-in 扩展；文件匿名分人使用
  `gpt-4o-transcribe-diarize` / `diarized_json`。调用方必须自己实现 LLM、历史、工具、播放
  和 barge-in 编排，TTS 由调用方显式的 `speechrail.tts.start`/`append_text`/`finish_text` 驱动。
- `/health` 分别反映 ASR/TTS worker readiness，并以 `realtime_vad.ready/code/message` 单独报告 `server_vad` 子能力；`/readyz` 在至少一个 ASR/TTS 能力可接受请求时返回 200，同时返回 VAD 诊断；`/metrics` 提供 Prometheus 纯文本与 JSON 指标。
- VAD 使用 512 samples/16kHz 的 32ms 帧；因此 Sona 的 `400ms/900ms` 停止配置实际量化为约 `416ms/928ms`。该量化属于帧时钟行为，不应被误读为两个 VAD 同时运行。
- 上传字节数与解码后音频时长受限（`SPEECHRAIL_MAX_AUDIO_SECONDS`，超限返回 400 `audio_too_long`）；CORS 与速率限制不在当前能力范围。
- `diarization_ready` 只表示显式供给的 CoreML bundle、aligner 与 worker 路径可用，不表示真实质量、尾部正确性或固定物理内存开销。未 opt-in 或未供给制品时，`/v1/models` 不出现 `gpt-4o-transcribe-diarize`。D1 仅记录 M5 Max、90 秒输入的历史 564 MB max RSS；不能外推到其他设备或组合。DER/JER、P95、ASR 共存与两小时 soak 仍未验收。
- 常驻运行提供 macOS `LaunchAgent` CLI、安装模板和操作手册；服务默认不自动安装或启用。
- **2026-09-18 边界变更（App 侧，服务契约不变）**：会话层（语音助手 / 会议助手 / 实时字幕）
  在 App 进程内采集音频，并新增一个 App 内嵌的 XPC service（`SpeechRailCaptureHelper`）用
  按进程的 Core Audio tap 抓本机音频。对服务而言边界没有移动：它仍然只收
  `/v1/realtime` 上的 24 kHz 单声道 PCM16，**不新增任何接口**，也不承载 LLM、会议持久化或
  用户资产（`docs/architecture/product-scope.md` §3 的红线）。
  新增的三件事都在 App 这一侧：设备按功能启用、功能离开即释放；PCM 不落盘、记录只落本机
  SQLite；与大模型的编排（对话 / 纪要 / 内心 OS）走 Responses API 直连用户配置的端点。
  详表见 `docs/design/2026-09-18-session-layer/TECHNICAL-DESIGN.md` §2.1。
- 每个 spec 的 Base clone 与 CustomVoice artifact，以及 `reference` 的 BF16 VoiceDesign artifact，会增加安装体积与多 worker 活跃态 RAM，但不在请求级 capability 切换时反复换模。旧版 VoiceDesign-only RAM / latency 数据不能直接当作当前多 capability 架构的实测数据；跨档数据也不可互相替代。对应资源与延迟证据仍按专项授权验收。
- 2026-09-12 本地审计发现现有 synthesis quality-run 的最终通过条件对静音、极端削波/噪声与 deterministic 证据仍不够严格；在这些门禁修复并重新验收前，不得把绿色 `voice_quality_v1` 报告解释成跨文本音色和纯净度已经证明。

## 历史实测基准（本机，MPS/float16）

> **历史证据，不代表当前 MLX-q8 / 当前 source release。** 下表保留原测量值与适用环境；E1 的当前 commit-tail / media-paced 分布必须单独重测，禁止与这些旧值直接计算“提升百分比”。

| 指标 | 实测值 |
|---|---|
| REST ASR RTF（10s/30s/60s 音频） | 0.07x / 0.06x / 0.06x |
| REST ASR 并发吞吐（4/8 并发） | 1.5 req/s（单 MPS worker 串行） |
| REST TTS RTF（20/43 字符） | 0.36x / 0.34x |
| Realtime 连续会话 | 连续 5 次会话成功（修复后） |
| Realtime ASR commit→completed（10s） | 1.8-4.2s（RTF 0.18-0.42x） |
| Realtime TTS 首音频块 | 51-223ms |
| worker 常驻内存（ASR/streaming/单个 TTS worker） | 1.96GB / 1.96GB / 4.76GB |
| Quality VoiceDesign + Base 双 worker 同时常驻峰值 | unset（需目标机实测） |
| 2026-09-12 受管 v2.3.0 health / Realtime VAD / CoreML profile（历史） | ready；Silero + speech admission；CoreML Sortformer FP16 configured/ready |
| diarization DER/JER、unknown 比例与两小时资源行为 | 仍需独立真实语料验收，保持 `unset` |

## 验收门（未实测，须在对应场景完成）

- Hermes 的 STT 配置和聊天 endpoint 隔离 smoke；
- `sona` 的真实 ASR/TTS worker 端到端音频、播放与回滚验收（当前已完成短语音/协议级 smoke，长时与主观播放仍需独立门）；
- 多语言/长文件（>60s）的质量、失败恢复与长时间运行基准；
- diarization 的真实 CoreML smoke、DER/JER、稳定延迟、活跃与驱逐后 `phys_footprint`；
- 非 loopback 的 TLS、CORS、网段控制与速率限制实现；
- 日志收集策略与集中化导出实现；
- 生产默认所需的真实客户端、长时、质量、资源和安全门仍需按上列场景分别验收。

## 发布与端口切换门

REST 自动化门禁、真实 Qwen3 ASR/TTS smoke、目标客户端真实 smoke、current-only Realtime
所需契约实现、回滚演练和安全审计全部通过后，SpeechRail 才作为生产默认。当前 `8201` 是
独立服务端口；sona 的旧 TTS bridge 已退役，若需回滚只能恢复已验证版本目录与配置，
不能依赖一个仍在运行的旧 bridge 进程。
