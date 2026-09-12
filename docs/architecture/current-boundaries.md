---
title: "SpeechRail 当前边界与剩余风险"
status: active
date: 2026-09-12
---

# SpeechRail 当前边界与剩余风险

## 已确认

1. REST 文件转写使用仓库外 Qwen3-ASR worker；运行时明确设置离线环境变量。
2. 默认 Apple Silicon profile 为 MPS / `float16`，worker 拒绝自动 CPU fallback。
3. 未配置 profile 路径时不加载模型；ASR 仍由一个隔离 worker 持有。TTS 是一个逻辑 capability slot：`quality` 可在 primary VoiceDesign 与 clone Base 两个隔离 worker 之间互斥按需换模，Base 不在 startup 预热；`balanced/light` 只有 CustomVoice。运行时不应有意让 VoiceDesign 与 Base 同时常驻。WLK 只可连接外部已运行 endpoint。分人由一个按需启动的私有 Swift/CoreML worker 执行，
   固定 FluidAudio Sortformer FP16 bundle，不是 NeMo 或第三个 MLX worker。分人制品（Sortformer
   与 aligner）仅由分人档位（`balanced`/`quality`）按 catalog 供给到 `app_home/diarization/<aligner-key>`；
   `light` 不供给 aligner 与 CoreML 路径。
4. QwenPaw 的历史接入记录不能替代当前配置/模型状态；再次切换前必须单独 smoke。
5. 默认 loopback，非 loopback 配置必须有 API key；敏感音频/文本不写入仓库或常规日志。
6. 当前受管质量档为 `2.3.0`，由源码 wheel 安装；运行时 health 已验证 `auto → silero`、`speech_admission_enabled=true`、CoreML Sortformer FP16 ready。源码修改必须重新构建并走 managed release，不能直接改 `runtime/current`。
7. `server_vad` 的 generic contract 默认值与调用方策略分离：Sona subtitle 为 `0.65/300ms/400ms`，meeting 为 `0.65/300ms/900ms`（threshold/prefix/silence）。SpeechRail 不替调用方决定其业务 endpointing 窗口。
8. Realtime VAD 评分与 `SpeechAdmission` 状态机是一条 endpointing 链；continuous diarization activity 是另一条 speaker evidence 链，不是重复 VAD，也不改写 canonical completed text。
9. reference clone 仅由 `quality` 的 Qwen3-TTS Base capability 承担，并经 vendor public `generate(ref_audio, ref_text, ...)` 路径执行；VoiceDesign 不再作为 clone fallback。现有请求级 seed、低温度采样、首次有效片段后冻结响度增益、peak ceiling 与非 `1.0` speed 拒绝仍保留，但这些只覆盖确定性/电平边界，不等价于跨文本 speaker identity 已通过。
10. 词级时间戳由 ASR 原生输出提供（`timestamp_granularities`），不依赖 aligner；aligner 仅为分人路径服务，不是通用 ASR 依赖。分人（含 aligner）只在 `balanced`/`quality` 档位供给。
11. ASR∥TTS 重计算重叠是可配置策略（ADR-0016）：`SPEECHRAIL_ALLOW_HEAVY_OVERLAP=auto`（默认）按声明常驻字节与 `max(4 GiB, host_memory // 2)` 预算 fail-closed 判定——任一启用组件未声明非零峰或总量超预算即串行；`true`/`false` 为运维强制。重叠轴仅 ASR∥TTS，TTS∥TTS 与 ASR∥ASR 仍分别受单 worker 约束返回 `backend_busy`，不复制进程。本机 128 GiB 预算 64 GiB、声明总量 6.66 GiB 时放行；受控 A/B 证据见 [v2.4.0 重叠 ON/OFF 对照](../archive/performance/2026-09-11-v2.4.0-overlap-ab.md)。

## 明确限制

- `/v1/realtime` 只承载 OpenAI Realtime 协议的 ASR/TTS 子集；不伪装 LLM 对话、工具调用、
  历史或持续会话语义。分人是 `session.speechrail.diarization.enabled` opt-in 扩展；文件
  匿名分人使用 `gpt-4o-transcribe-diarize` / `diarized_json`。
- `/health` 分别反映 ASR/TTS worker readiness，并以 `realtime_vad.ready/code/message` 单独报告 `server_vad` 子能力；`/readyz` 在至少一个 ASR/TTS 能力可接受请求时返回 200，同时返回 VAD 诊断；`/metrics` 提供 Prometheus 纯文本与 JSON 指标。
- VAD 使用 512 samples/16kHz 的 32ms 帧；因此 Sona 的 `400ms/900ms` 停止配置实际量化为约 `416ms/928ms`。该量化属于帧时钟行为，不应被误读为两个 VAD 同时运行。
- 上传字节数与解码后音频时长受限（`SPEECHRAIL_MAX_AUDIO_SECONDS`，超限返回 400 `audio_too_long`）；CORS 与速率限制不在当前能力范围。
- `diarization_ready` 只表示固定 CoreML bundle 与 worker 路径可用，不表示真实质量、尾部正确性或固定物理内存开销。它只在分人档位（`balanced`/`quality`）有意义：`light` 不供给 aligner 与 CoreML 路径，`/v1/models` 不出现 `gpt-4o-transcribe-diarize`。D1 仅记录 M5 Max、90 秒输入的 564 MB max RSS；DER/JER、P95、ASR 共存与两小时 soak 仍未验收。
- 常驻运行提供 macOS `LaunchAgent` CLI、安装模板和操作手册；服务默认不自动安装或启用。
- `quality` 新增 Base clone artifact 会增加安装体积和 capability switch 冷启动；旧版 VoiceDesign-only RAM / latency 数据不能直接当作新架构 Base clone 的实测数据。需要在目标 Apple Silicon 上重新测量 VoiceDesign→Base、Base→VoiceDesign 的切换延迟、峰值 RSS 与首音时间。
- 2026-09-12 本地审计发现现有 synthesis quality-run 的最终通过条件对静音、极端削波/噪声与 deterministic 证据仍不够严格；在这些门禁修复并重新验收前，不得把绿色 `voice_quality_v1` 报告解释成跨文本音色和纯净度已经证明。

## 已实测基准（本机，MPS/float16）

| 指标 | 实测值 |
|---|---|
| REST ASR RTF（10s/30s/60s 音频） | 0.07x / 0.06x / 0.06x |
| REST ASR 并发吞吐（4/8 并发） | 1.5 req/s（单 MPS worker 串行） |
| REST TTS RTF（20/43 字符） | 0.36x / 0.34x |
| Realtime 连续会话 | 连续 5 次会话成功（修复后） |
| Realtime ASR commit→completed（10s） | 1.8-4.2s（RTF 0.18-0.42x） |
| Realtime TTS 首音频块 | 51-223ms |
| worker 常驻内存（ASR/streaming/TTS） | 1.96GB / 1.96GB / 4.76GB |
| 当前 v2.3.0 health / Realtime VAD / CoreML profile | ready；Silero + speech admission；CoreML Sortformer FP16 configured/ready |
| diarization DER/JER、unknown 比例与两小时资源行为 | 仍需独立真实语料验收，保持 `unset` |

## 验收门（未实测，须在对应场景完成）

- Hermes 的 STT 配置和聊天 endpoint 隔离 smoke；
- `sona` 的真实 ASR/TTS worker 端到端音频、播放与回滚验收（当前已完成短语音/协议级 smoke，长时与主观播放仍需独立门）；
- 多语言/长文件（>60s）的质量、失败恢复与长时间运行基准；
- diarization 的真实 CoreML smoke、DER/JER、稳定延迟、活跃与驱逐后 `phys_footprint`；
- 非 loopback 的 TLS、CORS、网段控制、速率限制和 legacy auth 实现；
- 日志收集策略与集中化导出实现；
- FastAPI startup/shutdown event 迁移到 lifespan 的未来兼容性处理。

## 发布与端口切换门

REST 自动化门禁、真实 Qwen3 ASR/TTS smoke、目标客户端真实 smoke、实时/legacy
所需契约实现、回滚演练和安全审计全部通过后，SpeechRail 才作为生产默认。当前 `8201` 是
独立服务端口；sona 的旧 TTS bridge 已退役，若需回滚只能恢复已验证版本目录与配置，
不能依赖一个仍在运行的旧 bridge 进程。
