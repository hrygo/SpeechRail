---
title: "SpeechRail 与 VoiceStudio 竞品能力调研与设计吸收建议"
status: active
version: "1.2.0"
date: 2026-10-17
audience: "系统架构师、后端与 macOS 核心开发者、产品决策者"
---

# SpeechRail 与 VoiceStudio 竞品能力调研与设计吸收建议

本报告以证据驱动方式，对两个本地语音/有声书生成工具进行对照调研：本仓库 **SpeechRail**，以及竞品 **VoiceStudio（ObsidianAudio）**。目标不是功能罗列，而是识别「哪些设计值得吸收、在 SpeechRail 的架构与职责边界内如何落地、代价与风险、如何验收」。

> 本轮授权范围：仅产出本调研报告与更新 `docs/audits/README.md` 索引。**未修改任何 SpeechRail 产品代码，未新增或运行任何测试，未运行 build / UI 自动化 / benchmark / 服务 / 真实模型**。

---

## 0. 核验基线与证据分层

### 0.1 核验日期与版本
- **核验日期**：2026-10-17（会话环境日期）。
- **SpeechRail**：分支 `main`（`da18da8a chore: release 3.11.1`，领先 `origin/main` 1 个提交）。本轮编辑前工作区为 19 个已修改文件 + 2 个未跟踪文件；其中 `docs/audits/README.md` 是既有审计索引改动，竞品报告与另一计划未跟踪。其他 18 个修改文件与另 1 个未跟踪计划均为并行改动，保留原样（详见 §7）。
- **VoiceStudio（ObsidianAudio）**：分支 `main`，HEAD `f47221a1`，工作区干净。

### 0.2 证据分层标注（全文统一）
- **【代码实测】**：在核验日期于指定 `path:line` 直接读取源码确认的当前行为。
- **【文档·界面声称】**：来自 `docs/`、README、UI 文案或 Schema 的声明，未必等价于已实测能力。
- **【推断】**：基于结构/命名/契约的合理推断，未经运行验证，需实测才能升级为事实。
- **文件存在或函数存在 ≠ 能力可用**；`/readyz=200` 或单次 smoke 通过 ≠ 质量/性能/长时稳定性通过。

### 0.3 外部事实
外部规范于 **2026-10-17** 核验。ACX 当前公开音频要求是每个文件 RMS -23 至 -18 dB、peak 不高于 -3 dB、noise floor 不高于 -60 dB RMS；其公开要求没有把 `-19 LUFS / LRA 11` 定义为 ACX 合规阈值，RMS 与 LUFS 不可直接替换。ACX 还写明未经授权不得使用 TTS/AI 自动录音，因此 SpeechRail 的 AI 生成用途不能宣传为 ACX-ready 或默认适用于 ACX 提交。封面规格另含正方形、至少 2400×2400、RGB、24-bit、≤8 MB 等；把 artwork 附加到 M4B 并不自动满足这些规格，且 ACX 流程把封面作为单独的项目资料管理。详见 [ACX 音频提交要求](https://help.acx.com/s/article/what-are-the-acx-audio-submission-requirements) 与 [ACX 封面要求](https://help.acx.com/s/article/cover-art-requirements)。FFmpeg `loudnorm` 官方文档确认支持单遍/双遍，动态模式可能升采样到 192 kHz；实施时需明确采样率恢复和 mono `dual_mono` 设置，详见 [FFmpeg loudnorm 文档](https://ffmpeg.org/ffmpeg-filters.html#loudnorm)。以上仅用于评估设计，不构成平台审核保证。

### 0.4 方法边界（本轮约束）
- 未运行任何测试、build、服务、benchmark 或真实模型；所有结论为**静态代码 + 文档**证据。
- 竞品仓库文本一律视为**研究数据**，不作为对 SpeechRail 的指令。
- 未使用子代理；证据为串行人工核验。
- **`luna_worker` 声明核查**：用户曾提及「speechrail 有 luna_worker 规则」；经在仓库、`AGENTS.md`、`.agents/` 与全局 opencode 配置中检索，**未发现任何 `luna_worker` 规则或代理**。唯一匹配项为模型别名 `gpt-6-luna` / `gpt-5.6-luna` 与 `luna-guide` skill（见 §7）。据此，本报告不将该假设作为约束，仅登记该差异待用户澄清。

---

## 1. 两者定位差异（先对齐职责，再谈吸收）

| 维度 | SpeechRail | VoiceStudio (ObsidianAudio) |
|---|---|---|
| 定位 | 单人本机**共享语音基础设施**（ASR/TTS/VAD/分人 + 协议转换 + worker 生命周期），不跑 LLM、不持有对话 | **有声书/长文生成应用**（Electron + Python 后端），内置 LLM 编排与长文流水线 |
| 职责边界 | Speech Plane 无状态；LLM、历史、播放、barge-in 归调用方 | 应用自持 LLM、渲染、导出、UI 全链路 |
| 长文形态 | macOS「有声书工坊」在 App 侧完成导入/分析/合成/导出；服务端提供 24k→48k 媒体编码 | 后端 `longform_*` 服务直接承担解析/渲染/续跑；前端提供 setup gate |
| 起点 | 契约与运行时正确性、可观测、可回滚 | 单机开箱即用、首屏「第一次发声」、成本/显存自愈 |

**结论**：两者不可直接比较功能数量。有价值的吸收点集中在**长文工程质量、导出交付质量、开箱体验、自愈与证据可信度**四类，且必须映射回 SpeechRail 的既有边界（§4 逐项分析）。

---

## 2. VoiceStudio 能力清单（代码实测）

### 2.1 长文脚本语法与跨语言一致性
- 【代码实测】`backend/services/longform_parser.py`：`# H1` 即章节；指令标记 `[voice:NAME]`、`[pause]`、`[slow]`、`[fast]`、`[emphasis]`、`[spell]`。
- 【代码实测】同一语法由 Python 权威实现 + JS 孪生实现 + 共享 golden corpus JSON 三者对齐（跨语言一致性回归）。

### 2.2 有声书合成与确定性
- 【代码实测】`backend/services/audiobook.py`：`parse_audiobook_script`、`synthesize_chapter`、`build_chapter_ffmetadata`、`build_m4b_cmd`；`segment_seed(base_seed, text, nonce) = base + crc32(text) + nonce*2654435761 mod 2**31`（内容定址、可复现）；`MAX_JOIN_SILENCE_MS = 15min` 超限 fail-loud；**一章 = 一个 GPU-pool job**；`inference_cancellation` 在分块间协作取消。

### 2.3 渲染与交付质量
- 【代码实测】`backend/services/longform_render.py`：响度实现分为单遍 filter 与可选的 measure→apply 两遍 runner；测量失败回退单遍。ACX 参数是代码中的近似预设，尚未以当前官方规范核验，不能直接视为送审验收值。封面校验为 jpg/png、≤8MB；无效或缺失会省略封面并继续渲染。M4B 可附加封面，MP3 因 FFmpeg muxer 的兼容问题明确跳过。

### 2.4 续跑与作业库
- 【代码实测】`backend/services/longform_resume.py`：`resume.json` 清单（计划 + 参数），原子写 `fsync` + `flush_dir`，`_SAFE_ID_RE` 防路径注入，`RESUMABLE_TYPES=("audiobook","story")`，`scan_resumable`，`GET /audiobook/jobs`，`POST /audiobook/resume/{job_id}`。
- 【代码实测】`backend/api/routers/longform_jobs.py`：`GET /longform/jobs` 库从 SSE 尾部恢复，**从不 500**；删除保留音频；`BEGIN IMMEDIATE` 事务。

### 2.5 分块策略
- 【代码实测】`backend/services/chunked_tts.py`：`DEFAULT_MAX_CHUNK_CHARS = 800`；`_effective_max_chars` 按**密集脚本**缩放（下限 120）；`split_text_into_chunks` / `_merge_unspeakable` / `_safe_hard_cut`；`report_dropped_chunks`；`join_rendered_chunks` 交叉淡化；`trim_edge_silence`。

### 2.6 资源与任务调度
- 【代码实测】`inference_cancellation.py`：`InferenceCancellation`（`threading.Event`），按 job 作用域，`current_cancellation()`。
- 【代码实测】`engine_memory.py`：**单活动 TTS 引擎驻留**默认开启（`OMNIVOICE_SINGLE_ENGINE_RESIDENT=0` 关闭）——驱逐其它引擎实例（16GB OOM 修复）。
- 【代码实测】`model_manager.py`：GPU `ThreadPoolExecutor` + `_ResilientGpuPool` 自愈包装、`CPU_POOL_WORKERS`、`run_on_gpu_pool_guarded`、`GpuPoolBusyError`、`GpuJobTimeoutError`。

### 2.7 质量与证据
- 【代码实测】`dub_qc.py`：第二遍 ASR QC + drift 分数；**生成文本为权威**（不静默覆盖）；无空格脚本 CER 分词。
- 【代码实测】`engine_evidence.py`：消毒后的 `runtime_versions` + `evidence_state`（`not_loaded`/`probe_error`/`loaded`/`subprocess_loaded_provider_unreported`）、CPU 回退原因/阶段；不含路径/env；设备名字截断 ≤256。
- 【代码实测】`audio_quality.py`：**model-free 咨询性**检测，明确「从不给出感知质量分」；100ms 窗；empty/silence/quiet/loud/clipping/invalid；2h 与 100-warning 上限。

### 2.8 开箱与隐私
- 【代码实测】`electron/src/renderer/src/components/setup-gate.tsx`：4 步门禁（系统检查 → 模型包 → 隐私 → 进入工作室），preflight 门控，`models_ready`/`missing`，渐进披露，持久化 setup 进度标记，`FIRST_SOUND_EVENT`。分析同意项允许用户选择同意或拒绝后继续，不是强制同意门槛。
- 【代码实测】`first-sound-handoff.tsx`：引导完成后经**正常 controller** 生成一次设计音（「第一次发声」证明）。
- 【代码实测】`analytics-consent.tsx`：`AnalyticsRuntime`（同步 `/api/settings/analytics`）+ `AnalyticsConsent`。
- 【代码实测】`workspace-sidebar.tsx`：`WIDTHS`（default/wide/spacious）+ `usePaneResize`。

### 2.9 MCP 造声
- 【代码实测】`backend/mcp_server.py`：`clone_voice`（第 723 行；docstring 参考音 5–30s；base64 或 `OMNIVOICE_MCP_BASE_PATH` 下路径；200MB 上限；结构化错误；`kind="clone"`）；`design_voice`（第 827 行；固定词表 gender/age/pitch/whisper/EnglishAccent/ChineseDialect；`describe_voice` 预览命中/未命中；保存时固定种子做身份样本；`kind="design"`）；资源 `voice://{id}`、`history://recent`。

### 2.10 故障边界、反馈入口与本地化
- 【代码实测】`electron/src/renderer/src/components/error-boundary.tsx`：`ErrorBoundary`（class，`getDerivedStateFromError` + `componentDidCatch`）+ `ErrorRecovery`；`MODULE_RETRY_PREFIX` + `claimModuleRetry()` 用 `sessionStorage` 做**一次性模块重试护栏**，防止崩溃后无限 reload 循环（`reset`/重试按钮）。
- 【代码实测】`crash-details.tsx`：`CrashDetails` 展示 `crash.logTail`，经 `scrubText()` **消毒**后呈现，且保留可搜索文本；无 stderr 时回退 `crash.no_stderr`。
- 【代码实测】`report-bug.tsx`：`ReportBug` 经 `composeBugReportUrl(...)` 组装**预填问题报告 URL**，通过 bridge/popup **外部打开**（不内嵌上传）；含 `reachabilitySection`。
- 【代码实测】i18n：`electron/src/renderer/src/i18n/`（`locale-match.ts`、`language-switch.tsx`、`initial-language`、`lib/i18n-text.ts`）+ **21 个 locale**（`ar/de/en/es/fr/hi/id/it/ja/ko/nl/pl/pt/ru/sv/th/tr/uk/vi/zh-CN/zh-TW`）。

### 2.11 音频水印（溯源，可选）
- 【代码实测】`backend/services/watermark.py`：**不可见 + 可见**音频水印；不可见用 Meta **AudioSeal** 16-bit message（`load_generator("audioseal_wm_16bits")` / `load_detector(...)`）；`embed_watermark` / `detect_watermark`。
- 【代码实测】同文件：模型**懒加载**（首次使用才载）；水印**逐块**处理以约束 AudioSeal 激活内存；对 moshi `@torch_compile_lazy` 做 eager-guard；`_check_available()` 在 `audioseal` 缺失时**优雅禁用**并日志说明，不阻断主流程。

### 2.12 引擎目录/路由与出站端点治理
- 【代码实测】`backend/api/routers/engines.py`：引擎目录/安装/选择（TTS/ASR/LLM/分人/翻译），`engine_disk_usage`、`_is_hf_repo_id` 校验、sidecar 安装。
- 【代码实测】`backend/services/endpoint_race.py`：出站端点探测/竞速，`_is_allowed_probe_endpoint` **允许清单**、`ProbeResult`、`throughput_probe`、`env_opt_out()`、`explicit_endpoint()`、`mode()`/`set_mode_pref()`。
- 【代码实测】`backend/services/engine_routing.py`、`gpu_gateway.py`：引擎路由与 GPU 网关（存在）。

---

## 3. SpeechRail 现状清单（代码实测）

### 3.1 只读真源与 Atom 层
- 【代码实测】`docs/architecture/audiobook-llm-analysis-pipeline.md`（v1.0.0，2026-10-15）：导入转规范化只读 `source.txt`（UTF-8 标量、LF）；切分单元/章节/标注/片段**只记录半开字节区间 `[startByte, endByte)` + `sha256`**，禁止改写原文标点。
- 【代码实测】`macos/.../AudiobookDomain.swift:11`：`maxAtomScalars = 160`；`:28`：`maxFragmentScalars = 240`。
- 【代码实测】`macos/.../AudiobookFragmentPlanner.swift`：按 `policy.maxFragmentScalars` 合并，**不跨说话人边界**；策略指纹由版本/目标/上限/语速/采样率/声道拼接哈希（`:32`）。

### 3.2 滑动窗口 + 三阶段分析
- 【代码实测】`docs/architecture/audiobook-llm-analysis-pipeline.md` §3–§6：单窗预算 4,000 字符 / 256 atoms / 单边上下文 500 字符；窗口 ID 由 `(bookID, chapterID, primaryAtomIDs, policyFingerprint, configurationDigest)` **确定性哈希**；覆盖性单调（每个 atom 恰好一次）。
- 【代码实测】同上 §4：三阶段（提取 → 归并 → 标注）；短索引 `idx:"1"` + 短代号 `roleID:"R1"` 压 token、防抄写幻觉；跨窗说话人状态链 `resolvedSpeakerName`；阶段一按 `windowKey` 内存缓存。
- 【代码实测】`macos/.../AudiobookAnalysisPolicy.swift:137`：`atomCoverageViolation(String)`；`AudiobookAnalysisPipeline.swift:359` 抛 `atomCoverageViolation`。
- 【文档·界面声称】同上 §5：非对白段落确定性归属旁白，弱引语优雅回退旁白，「绝不抛致命 Coverage Violation」；但代码实测存在 `atomCoverageViolation` 抛出路径（`:359`、`:951`、`:959`、`:1111` 校验），二者关系需实测确认是否为「整体性空响应才触发」的受限路径。
- 【代码实测】同上 §5.2：递归二分回退，`maxCallsPerRootWindow = 4` 预算保护 API 额度。
- 【代码实测】同上 §6：SQLite WAL（`<app_home>/audiobooks/library.sqlite3`）；`analysis_windows.is_completed` + `policy_fingerprint`/`configuration_digest` 变更自动失效，命中则**秒级复用、零重复调用**。

### 3.3 媒体导出与验证（SpeechRail 强项）
- 【代码实测】`docs/architecture/audiobook-workshop.md`：`AudiobookExportController` 导出前核对已采用候选 SHA-256，按帧数×采样率算预期章节时长，写 `exports/<request_id>/request.json`。
- 【代码实测】同上 + `docs/developers/macos-app-audiobook.md:50`：`encoder.py` 定位 ffmpeg，整理为 **48 kHz 单声道**，生成以 `1/48000` 为时间基准的 FFMETADATA 章节轨，编码 `.m4b`（AAC、`+faststart+disable_chpl`）或分章 `.mp3`（`libmp3lame`）。
- 【代码实测】`src/speechrail/media/encoder.py:408,467,475,478`：m4b 路径确认 `aac` + `+faststart+disable_chpl`（`disable_chpl` 为 300+ 章支持）；`:504–528`：分章 `chapters/chapter_%04d.mp3`。
- 【代码实测】`docs/architecture/audiobook-workshop.md:69–70`：`AudiobookMediaVerifier` 用 `AVURLAsset` 读实际音轨/编码/时长，读不到即拒绝导出；M4B 用 AVFoundation 读**实际章节元数据组**核对数量与起止（容差 1 个 codec frame ≈24ms），摘要一致后原子安装。
- 【代码实测】`src/speechrail/media/encoder.py:267,291,311`：`normalized` = 校验 RIFF/WAVE 头 + 必须 48kHz 单声道 PCM16 + 拒绝空/错位 PCM。

### 3.4 响度与电平策略（与 VoiceStudio 分道扬镳处）
- 【代码实测】`src/speechrail/domain/tts_loudness.py:12–23`：`Pcm16LoudnessConfig`（`target_rms=-20dBFS`、`peak_ceiling=-1dBFS`、`silence_rms=-60dBFS`、200ms 校准、250ms attack、800ms release、`max_gain_db=18`、`max_attenuation_db=-6`、100ms limiter release）。
- 【代码实测】同文件 `:60–68` docstring：**按单个请求归一化，不逐块独立归一化**；frozen clone 模式测完整媒体帧、等可信校准后 ramp 到固定请求增益；sample-peak limiter 立即 attack；**因果策略、无缓冲、非 true-peak limiter**。
- 【代码实测】`src/speechrail/media/encoder.py` 中**未发现** `loudnorm`/`lufs`/`acx`/`cover`/`artwork`（grep 仅命中 `discover_media_toolchain` 与 `normalized` 重采样校验）→ **SpeechRail 导出无 ACX 交付响度归一，也无封面图支持**。
- 【代码实测】`docs/architecture/quality-voice-capabilities.md:163`：「只做一次基于有效语音的增益/响度处理，避免 Sona 与 vendor 重复归一」；`:191` 主观比较需响度匹配。
- 【代码实测】`src/speechrail/domain/tts.py:310` `_CANONICAL_REFERENCE_PEAK_CEILING = 0.95`；`:379` `gain = min(gain, peak_ceiling/peak)`。

### 3.5 声音创作/克隆门禁
- 【代码实测】`docs/architecture/current-boundaries.md:23`：reference clone 经所选 spec 的 `tts_base` 能力、走 vendor public `generate(ref_audio, ref_text, ...)`；`fast`/`quality` 用 8-bit Base，`reference` 用 bf16 Base；VoiceDesign 只做设计、**不作 clone fallback**；首次有效片段后**冻结响度增益**、peak ceiling、非 `1.0` speed 拒绝。
- 【代码实测】`src/speechrail/domain/voice_quality.py`：策略版本 `voice_quality_v1`，`CLONE_SPEED_UNSUPPORTED`。`voice_quality_evidence.py`：`EVIDENCE_POLICY_VERSION="voice_quality_evidence_v2"`。
- 【代码实测】`src/speechrail/http/routes/system.py:453–454`：`POST /v1/voices/clone/validate` 与 `/v1/voices/clone` 同管线且前者不落盘；`:222–229` `supports_voice_design`/`supports_preview`/`supports_instruction` 由 active 变体决定。
- 【代码实测】`src/speechrail/http/routes/audio.py:1638–1701`：instruction 音由 `voice_design` 任务承载；`instructions are reserved for the voice_design task`；`audio.py:1357` `model_variant="voice_design"`。

### 3.6 资源、忙碌与取消
- 【代码实测】`src/speechrail/runtime/busy.py:67` `infer_backend_busy_reason`；`src/speechrail/runtime/local_file_processor.py:246,263` `backend_busy`；`src/speechrail/assets/skills/speechrail/references/errors.md` 声明 `backend_busy`/`queue_full`/`clone_speed_unsupported`。
- 【代码实测】`docs/architecture/current-boundaries.md` + `docs/README.md`：一次只运行一个服务与一个 ASGI worker；同 lane 串行、跨 lane 可并发、空闲冷却回收。

### 3.7 有效能力与开箱
- 【代码实测】`README.md`「Public surface」：`GET /v1/speechrail/capabilities`（`effective_capabilities_v1`，读它不启动 worker、不做推理）；`/v1/jobs*` 归属者作用域、**不存原始音频/转写**。
- 【代码实测】`.agents/skills/speechrail-zero-setup/SKILL.md`（存在）；`README.md` Quick start 有 staged install → preflight → `runtime/current` 原子切换 → `--enable` 注册 `com.speechrail`。

---

## 4. 逐项设计吸收分析（含可实施任务与验收条件）

> 每项格式：**VoiceStudio 观察 → 用户收益 → SpeechRail 现状/架构适配 → 建议 → 代价与风险 → 验收条件**。

### P0-1 导出交付响度归一（通用目标；不宣称 ACX 合规）
- **VoiceStudio 观察**【代码实测 `longform_render.py:526–628,688–755`】：`build_loudnorm_filter` 是单遍路径；另有 measure/apply 辅助函数，runner 在取得测量值时使用两遍，否则回退单遍。默认关闭。ACX/podcast 参数是实现预设；ACX 正式阈值须实施前查当前官方规范，不把代码注释当规范。
- **用户收益**：让用户按明确目标得到一致的成品电平，并减少手工后期。由于 SpeechRail 输出由 TTS 生成，ACX 当前要求未经授权不得用 AI/TTS；该能力不得以 ACX 合规为产品卖点。
- **SpeechRail 现状/架构适配**【代码实测】：`tts_loudness.py` 是**流式、按请求、因果**的增益控制（首次有效片段冻结增益），**不是**导出级两遍响度归一；`media/encoder.py` 无 loudnorm。SpeechRail 已有 48kHz canonical + FFMETADATA + AVFoundation 验证，具备在 `encoder.py` 编码前插入一次性响度归一的位置（48kHz 单声道是 `loudnorm` 的理想输入）。
- **建议**：评估在 `media/` 导出阶段增加**可选、默认 off** 的通用目标档位；先定义目标单位（LUFS/RMS/peak）、测量范围（单章/整书）和是否维持章节间相对差异，再决定单遍或两遍。避免使用 `acx` 作为档位名或承诺平台通过。两遍需有测量结果回传 apply 阶段；测量失败应有明确降级或失败策略。FFmpeg 动态模式可能以 192 kHz 处理，必须固定回采样到项目 48 kHz；mono 输入须显式决定 `dual_mono` 语义。
- **代价与风险**：两遍增加一轮完整分析/解码开销；没有本机基准，不给时间数值。流式 frozen gain 与成品归一职责不同，但后者可能改变章节/片段相对响度。ACX 的 RMS 与 loudnorm LUFS 不是同一验收指标；若目标是 ACX 规格的电平代理，应实现/验证适当 RMS 与 peak/noise-floor 检测，而不是直接套 -19 LUFS 预设。当前 ACX 还限制未经授权的 TTS/AI 音频。
- **验收条件**：
  1. `encoder.py` 新增响度档位参数，默认 `off`，行为与现状逐字节一致；
  2. 目标阈值由用户选择的实际交付规范给出，使用匹配该规范的独立分析工具测量输出；ACX 场景需区分 RMS、peak 和 noise floor，并受其 TTS 授权规则约束；
  3. off 路径产物与当前输出字节一致；启用路径在成品层处理，不重复调用或改变流式冻结增益策略，并验证片段/章节相对响度没有不可接受漂移；
  4. 导出验证器（`AudiobookMediaVerifier`）对响度档位无感知、仍能通过章节/时长/SHA 校验。

### P0-2 导出封面图（cover art）
- **VoiceStudio 观察**【代码实测 `validate_cover_image`】：m4b 支持 jpg/png ≤ 8MB 封面，导出时嵌入。
- **用户收益**：成书在 Apple Books / 播放器有封面，观感与可用性显著提升。
- **SpeechRail 现状/架构适配**【代码实测】：`media/encoder.py` **无任何 cover/artwork 处理**；已有 ffmpeg 工具链与 m4b 编码路径，嵌入封面属 ffmpeg m4b/`attached_pic` 常规能力。
- **建议**：先确定坏封面策略：SpeechRail 可选择稳定错误并拒绝导出，或像 VoiceStudio 一样省略封面并给出可见警告；禁止静默宣称已嵌入。首期仅考虑 M4B。若未来支持 ACX 相关工作流，封面检查还需正方形/像素/色彩/位深等验证，并明确封面应另行提供到平台；M4B 内嵌图本身不是 ACX 交付通道。VoiceStudio 明确跳过 MP3，理由是其 FFmpeg MP3 muxer 使用 `-c:v copy` 附图在不同版本会产出损坏文件。
- **代价与风险**：这不是只改 encoder 的小功能。`audiobook_media_export_v1` 是闭合 schema，片段路径规则仅允许书籍拥有目录下的 WAV；封面输入需要安全的资产类型/路径/摘要校验。须同步 Swift `AudiobookExportController` 请求写入、Python manifest schema/验证、FFmpeg 输入映射及 `AudiobookMediaVerifier` 的验证模型。若采用可选 schema 字段，应定义版本演进与旧请求行为。封面 SHA 应纳入请求完整性；输出文件已有 SHA 与原子安装流程，不应误称封面二进制自然已被该摘要覆盖。
- **验收条件**：
  1. 提供合法 jpg/png 时 m4b 含封面元数据（AVFoundation 可读到 artwork）；
  2. 缺失、非法类型、超限、不可解码分别按已选策略给出稳定结果；若选择拒绝，导出不得产生半成品；若选择省略，UI/结果明确提示未嵌入；
  3. 不提供封面时导出产物与现状一致；
  4. manifest 校验仅接受书籍拥有范围内的允许路径，校验内容摘要；AVFoundation verifier 明确验证 artwork 存在或缺失状态，并保持音轨、章节、时长和输出 SHA 校验。

### P0-3 长文分块：密集脚本感知的「有效上限」
- **VoiceStudio 观察**【代码实测 `chunked_tts.py`】：`DEFAULT_MAX_CHUNK_CHARS=800`，`_effective_max_chars` 对密集脚本按密度缩放下限 120；`_merge_unspeakable` 合并不可发音片段；`_safe_hard_cut` 安全硬切；`report_dropped_chunks` 显式上报丢弃。
- **用户收益**：中日韩等高密度脚本不会被「按字符数」切得过长导致截断/TTS 退化；不可发音片段不静默丢失。
- **SpeechRail 现状/架构适配**【代码实测】：不能用 vendor IncrementalSession 的 4096 字符预算代表产品切块。实际共用 worker planner `TtsTextPlanner` 默认上限 240 normalized-text Unicode codepoints，按句子/次级标点/空白/硬切排序；worker 对每个 planner chunk 调用 `_generate`。REST/MCP 请求上限 4096、Realtime append/pending/wall-clock 限额、vendor session max_chars 和产品 planner 是不同层级。文档已公开 `operations.tts_text_planner` 的 planner version/max 240；当前 planner 没有密度维度。App 有声书 atom/fragment 分别约 160/180/240 预算，分章/片段规划又受说话人边界约束。VoiceStudio 密集判定以整段密度≥0.3 将默认 800 收紧到约 320（范围下限 120），属于粗粒度全局门控，不是逐块自适应算法。
- **建议**：先用离线样本评估服务端 `TtsTextPlanner` 的分块边界与长文本质量；若密度感知有收益，优先设计逐块密度决策，并明确它只调整合成 chunk 规划，不混同 HTTP 限额、Realtime 缓冲、vendor context budget 或 App 的角色/来源区间切分。同步 capability snapshot 语义、用户文档和对应回归；不要求 OpenAPI 改动，除非实际 OpenAPI schema 暴露该字段。不可发音内容的合并/丢弃策略需独立验证，不从 VoiceStudio 的实现直接推导为 SpeechRail 需求。
- **代价与风险**：阈值需以真实中/日/韩文本标定，避免过度碎片化（与 `minWindowScalars=64` 类似的下限保护）；不得改变只读源文本与字节区间模型。
- **验收条件**：
  1. 覆盖简体/繁体中文、日文、韩文、英文及混排样本，比较当前 planner 与候选策略的边界、chunk 数和截断/遗漏；阈值须由证据选出；
  2. 正文保真、标点不丢、边界可追踪；App 角色边界、时间 sidecar 和 planner 坐标语义保持一致；
  3. capability snapshot 明确暴露当前 planner 版本/上限，不把可路由声明说成质量通过；文档与测试同改；
  4. 若引入不可发音过滤，必须证明没有静默丢文，并单独记录可见诊断；不纳入第一阶段默认范围。

### P1-1 内容定址缓存与跨运行去重
- **VoiceStudio 观察**【代码实测 `audiobook.py:segment_seed`、`longform_render.py:chapter_cache_key`/`SegmentCache`】：`segment_seed` 由 base + `crc32(text)` + 线性同余 nonce 组成 → 同文本可复现；两级章节缓存 + 段缓存 + `prune_cache_dir`。
- **用户收益**：重跑/续跑零重复合成；磁盘缓存可回收。
- **SpeechRail 现状/架构适配**【代码实测】：App 侧已有 **atom/window 检查点复用**（`policy_fingerprint`/`configuration_digest` 命中即跳过，§3.2）与**片段资产 SHA-256**（§3.3），本质是「按窗口/片段定址」；但服务端 TTS 未见按**文本内容哈希**的段级缓存。
- **建议**：优先确认现有窗口/片段检查点是否已覆盖同文本零重复合成；若仍有缺口，再评估服务端段级内容定址缓存 + 回收策略。
- **代价与风险**：内容定址需固定采样/种子语义（否则同文本不同音色被误命中共）；缓存需纳入既有磁盘配额与隐私边界（不得缓存原始音频于仓库）。
- **验收条件**：
  1. 同一文本 + 同一音色 + 同一参数重跑，服务端合成调用数为 0（命中缓存）；
  2. 不同音色/参数不误命中；
  3. 缓存回收不影响续跑语义与已生成产物。

### P1-2 开箱「第一次发声」与设备/能力门禁
- **VoiceStudio 观察**【代码实测 `setup-gate.tsx` + `first-sound-handoff.tsx`】：4 步流程（系统检查 → 模型包 → 隐私 → 进入），preflight 门控，`models_ready`/`missing` 明示；用户回答分析隐私问题后，无论同意或拒绝都可继续。引导末尾经正常 controller 生成一次设计音；失败时进入 `/design` 说明页，且步骤进度持久化。
- **用户收益**：首装用户明确知道「缺什么、能不能用、下一步做什么」，并立刻获得成功体验。
- **SpeechRail 现状/架构适配**【代码实测】：已有 zero-setup skill + staged install → preflight → 原子切换 → `--enable`（§3.7），以及 `effective_capabilities_v1` 只读能力快照与 `AudiobookCapabilityProviding` 门禁；**缺**一个把「先决条件 → 能力就绪 → 首段发声」串成单一引导流的界面层。
- **建议**：设计一条**渐进披露的首装/首用引导**（可复用既有 preflight 与能力快照），末尾提供一次**经正常渲染路径**的「第一次发声」；同时设计失败恢复页、可重试条件与权限/能力缺失说明。高级项折叠入开发者详情。分析隐私选择应允许拒绝后继续非分析流程。
- **代价与风险**：属 macOS UI/UX 改动，须遵循设计系统 Token 与「傻瓜化」原则；**本轮不实施**，仅登记为任务。任何 UI 自动化验证须用户逐次明确授权。
- **验收条件**：
  1. 全新环境首屏只呈现完成当前任务所需的最少动作，明确「发生了什么/是否需确认/下一步」；
  2. 设备/能力缺失时**具体说明缺什么**，不谎报可用；
  3. 引导末尾「第一次发声」走与正常业务相同的渲染路径（非特例），失败时能解释原因并恢复；
  4. 键盘可达、焦点顺序、状态播报和隐私选项通过实际 UI 验收；
  5. 全部实现仅复用既有语义 Token 与共享组件。

### P1-3 运行证据状态机（信度分级）
- **VoiceStudio 观察**【代码实测 `engine_evidence.py`】：消毒后的 `runtime_versions` + `evidence_state`（`not_loaded`/`probe_error`/`loaded`/`subprocess_loaded_provider_unreported`）+ CPU 回退原因/阶段；不含路径/env。
- **用户收益**：诊断「为什么慢/为什么是 CPU/为什么未就绪」时有可信、可追溯且不泄漏隐私的状态。
- **SpeechRail 现状/架构适配**【代码实测】：`effective_capabilities_v1` + `runtime/busy.py:infer_backend_busy_reason` + 能力诊断文档已具备分层就绪语义；可对照评估「已加载但 provider 未上报」这类探测状态是否揭示有用的故障信息（当前未见同名状态）。
- **建议**：把 VoiceStudio 的运行探测状态与 SpeechRail 的能力快照门禁做语义映射审查；两者来源和职责不同，不机械新增同名状态。仅当当前诊断确实无法区分重要故障原因，且不改变 `effective_capabilities_v1` 原子快照与 `available`/`production_ready` 语义时，才提出契约变更。
- **代价与风险**：新增状态属于对外可见语义，必须同步契约/用户文档并在关键路径保持一致（对齐 `AGENTS.md` 契约要求）。
- **验收条件**：
  1. 先列出现有状态、生成来源、消费者和诊断缺口，再决定是否扩展；
  2. 如新增对外状态，证明它与 capability snapshot、`/readyz`、`/health` 的职责语义一致且无歧义；
  3. 输出不含绝对路径、env 或凭证。

### P1-4 model-free 音频质量咨询检测
- **VoiceStudio 观察**【代码实测 `audio_quality.py`】：100ms 窗检测 empty/silence/quiet/loud/clipping/invalid，**明确不做感知质量分**，有 2h 与 100-warning 上限。
- **用户收益**：合成后立刻发现静音/削波/异常，且不误导为「质量评分」。
- **SpeechRail 现状/架构适配**【代码实测】：App 侧有 `AudiobookMediaVerifier`（媒体事实校验）与播放生命周期；服务端 `tts_loudness.py` 有 peak ceiling 与响度统计；**未见**面向用户的 model-free 信号健康提示层。
- **建议**：长文/成书流程增加一个**纯信号层**的体检（静音段、削波、异常长度），定位为「事实提示」而非质量评分；遵守「不做感知分」的措辞纪律。
- **代价与风险**：应与 P0-1 共用一个导出期音频分析设计，避免响度测量、静音/削波扫描各自重复解码。需界定在服务端还是 App 侧计算；不得把客观信号提示包装成感知质量判断。
- **验收条件**：
  1. 能对给定音频给出静音/削波/异常区间的事实提示；
  2. 文案与契约中**不出现**主观质量分；
  3. 计算有界（时长/告警数上限），不显著增加导出耗时。

### P2-1 长文脚本语法单一真源 + 跨语言 golden corpus
- **VoiceStudio 观察**【代码实测 `longform_parser.py`】：Python 权威 + JS 孪生 + 共享 golden corpus JSON。
- **用户收益**：多端解析行为一致，回归可覆盖语法边界。
- **SpeechRail 现状/架构适配**【代码实测】：解析主要在 Swift（`AudiobookSourceIndex`/`AudiobookTXTImporter`）与服务端；跨语言一致性风险点存在但当前无 golden corpus 概念。
- **建议**：若未来出现多端解析，建立**单一语法真源 + 共享 golden 语料**；当前仅登记，不实施。
- **验收条件**：同一语料在各端解析出完全一致的 atom 边界与类型（未来落地时）。

### P2-2 作业库从流尾部恢复
- **VoiceStudio 观察**【代码实测 `longform_jobs.py`】：`GET /longform/jobs` 从 SSE 尾部恢复、**从不 500**。
- **用户收益**：客户端断连/刷新后仍能看到真实作业状态。
- **SpeechRail 现状/架构适配**【代码实测】：`/v1/jobs*` 已是**归属者作用域的持久作业记录**（`README.md`），设计上更强（有状态存储而非仅流尾部推断）。
- **建议**：**不吸收** VoiceStudio 的「从流尾部恢复」做法（SpeechRail 已是持久作业模型）；仅记录该差异。
- **验收条件**：不适用（无变更）。

### P2-3 面板宽度预设与拖拽
- **VoiceStudio 观察**【代码实测 `workspace-sidebar.tsx`】：`WIDTHS`（default/wide/spacious）+ `usePaneResize`。
- **用户收益**：长文工作区空间可调。
- **SpeechRail 现状/架构适配**【代码实测】：`WindowLayoutPolicy.swift` 已在工作区被其它并行改动引入（见 §7 待确认），与设计系统 Token 相关。
- **建议**：**不重复引入**，交由既有 `WindowLayoutPolicy`/设计系统承接；本轮仅登记关联，避免与并行改动冲突。
- **验收条件**：不适用。

### P2-4 崩溃恢复护栏 + 消毒诊断 + 预填反馈
- **VoiceStudio 观察**【代码实测 `error-boundary.tsx` + `crash-details.tsx` + `report-bug.tsx`】：`ErrorBoundary`/`ErrorRecovery` + `sessionStorage` 一次性模块重试护栏（防崩溃 reload 死循环）；`CrashDetails` 经 `scrubText()` 消毒后展示日志尾；`ReportBug` 组装**预填 URL 外部打开**。
- **用户收益**：崩溃可自助恢复且不陷入死循环；诊断信息可读且不泄漏隐私；反馈路径一键可达。
- **SpeechRail 现状/架构适配**【代码实测】：macOS App 有诊断/`diagnose` 与开发者文档入口，但未见「渲染层崩溃 → 一次性重试护栏 + 消毒日志 + 预填反馈」这一组合。
- **建议**：若评估引入，移植**护栏**（一次性重试）与**消毒**思路；反馈沿用外部打开、不内嵌上传，且不得违反「日志/报告不含原始音频、凭证、绝对路径」的红线。
- **代价与风险**：属 UI 改动，须遵循设计系统与渐进披露；消毒逻辑须覆盖 SpeechRail 隐私红线字段。
- **验收条件**：
  1. 崩溃后最多重试一次，不出现无限 reload；
  2. 展示的诊断/日志经消毒且不含隐私红线字段；
  3. 反馈入口为外部打开、不自动上传任何本地数据。

### P2-5 多语言（21 locale）
- **VoiceStudio 观察**【代码实测 `i18n/`】：`ar/de/en/es/fr/hi/id/it/ja/ko/nl/pl/pt/ru/sv/th/tr/uk/vi/zh-CN/zh-TW` 共 21 locale + 语言切换与初始语言匹配。
- **用户收益**：面向多语种用户。
- **SpeechRail 现状/架构适配**【代码实测】：`AGENTS.md` 未声明多语言；界面文案以中文为主（README 双语）。
- **建议**：视目标受众再评估；若引入，界面文案须遵循「用户语言、非术语主标题」与设计系统规范。
- **代价与风险**：全量本地化维护成本；术语翻译须与契约保持一致。
- **验收条件**：不适用（本轮不实施）。

### P2-6 音频水印（溯源）
- **VoiceStudio 观察**【代码实测 `watermark.py`】：不可见 AudioSeal 16-bit message + 可见水印；懒加载、逐块、缺失优雅禁用。
- **用户收益**：生成音频可溯源/版权标识。
- **SpeechRail 现状/架构适配**【代码实测】：SpeechRail 为隐私优先本机服务，约束「一次一个服务/worker」「重计算并发受资源预算 fail-closed 控制」；引入 AudioSeal 会新增常驻/按需模型与重计算，须纳入 Resource Governor 与能力快照。
- **建议**：若评估，作为**可选、默认关闭、懒加载**能力，并在 `effective_capabilities_v1` 显式暴露可用性；与「不复制模型进程提吞吐」约束对齐。
- **代价与风险**：新增模型与内存预算；水印鲁棒性/可检出性需独立质量基准（不得据「能嵌入」宣称有效）。
- **验收条件**：
  1. 关闭时零模型驻留、零额外重计算；
  2. 开启时能力快照如实暴露，且受资源预算约束；
  3. 可检出性经独立基准与人工验收，不据单次成功宣称有效。

### P2-7 出站端点探测/竞速治理
- **VoiceStudio 观察**【代码实测 `endpoint_race.py`】：出站端点探测/竞速，`_is_allowed_probe_endpoint` **允许清单**、`env_opt_out()`、`explicit_endpoint()`、`mode()`/`set_mode_pref()`。
- **用户收益**：自动选优上游端点并支持显式覆盖/退出。
- **SpeechRail 现状/架构适配**【代码实测】：SpeechRail 明确「请求路径不得静默访问网络」（`AGENTS.md`/`README.md` Boundaries），与「探测竞速」模式取向相反。
- **建议**：**不吸收探测竞速**；仅记录其「允许清单 + 显式 opt-out + 显式 endpoint」的治理模式可作未来任何出站能力的参照。
- **代价与风险**：引入即破坏既有无静默网络边界。
- **验收条件**：不适用（无变更）。

---

## 5. 采纳矩阵（P0/P1/P2）

| 编号 | 主题 | 优先级 | 证据强度 | 建议动作 | 本轮是否实施 |
|---|---|---|---|---|---|
| P0-1 | 通用导出响度处理（不承诺 ACX） | P0候选 | 代码实测 + 官方规范已核验 | 定义目标单位/范围并评估路径与相对响度风险 | 否（设计/评估前置） |
| P0-2 | 导出封面图 | P0候选 | 代码实测 | manifest schema + M4B 编码 + artwork 验证端到端设计 | 否（设计前置） |
| P0-3 | 密集脚本感知有效分块上限 | P0候选 | 代码实测 | 以服务端 240 codepoint planner 为基线，先离线评估 | 否（研究前置） |
| P1-1 | 内容定址缓存/跨运行去重 | P1 | 代码实测 | 先核对既有检查点覆盖，再评估段级缓存 | 否 |
| P1-2 | 首装/首用「第一次发声」引导 | P1 | 代码实测 | 隐私可选择、成功/失败恢复、无障碍闭环 | 否（UI，需授权） |
| P1-3 | 运行证据状态机映射审查 | P1 | 代码实测 | 先映射职责与诊断缺口，不预设新增状态 | 否 |
| P1-4 | model-free 音频体检 | P1 | 代码实测 | 信号层事实提示，非质量分 | 否 |
| P2-1 | 脚本语法单一真源+golden corpus | P2 | 代码实测 | 多端出现时再建 | 否 |
| P2-2 | 作业库从流尾部恢复 | P2 | 代码实测 | **不吸收**（SpeechRail 更强） | 否 |
| P2-3 | 面板宽度预设 | P2 | 代码实测 | **不重复引入**（交设计系统） | 否 |
| P2-4 | 崩溃恢复护栏 + 消毒诊断 + 预填反馈 | P2 | 代码实测 | 借鉴一次性重试护栏与 scrub 诊断 | 否（UI） |
| P2-5 | 多语言（21 locale） | P2 | 代码实测 | 视目标受众再评估 | 否 |
| P2-6 | 音频水印（溯源） | P2 | 代码实测 | 可选、懒加载；须权衡常驻模型约束 | 否 |
| P2-7 | 出站端点探测/竞速治理 | P2 | 代码实测 | **不吸收**（SpeechRail 请求路径无静默网络） | 否 |

---

### 5.1 第二轮复核后的计划修订（2026-10-17）

| 工作项 | 修订结论 | 先决条件 / 主要依赖 | 建议阶段 |
|---|---|---|---|
| Export manifest 扩展 | 封面与响度参数都不能只接 encoder；当前 `audiobook_media_export_v1` 闭合拒绝未知 schema，输入路径仅允许 book-owned WAV | 先定 schema version / optional fields / 旧请求处理；Swift `AudiobookExportController` 写入、Python `manifest.py` 校验、encoder 参数与 verifier 模型协同 | 0：接口设计与边界审查 |
| 交付响度 | 保留通用候选但先定义目标、单遍/两遍与 off 行为；不把竞品的 ACX 注释当正式标准 | ACX 音频数值与 AI/TTS 政策已按官方文档核验；选择实际适用的交付目标，定义独立测量容差，评估相对响度漂移和两遍资源成本 | 1：先技术验证，再实现 |
| M4B 封面 | 保留候选；坏封面策略需产品决策。VoiceStudio 对无效图省略并继续，SpeechRail 可选择 fail-loud，但要清晰报错 | manifest 安全路径/内容摘要、FFmpeg M4B stream mapping、AVFoundation artwork 验证；MP3 不列首期 | 1：与 manifest 设计一并推进 |
| 密集文本 chunking | 以服务端共用 240 codepoint planner 为比较基线，不拿 vendor 4096 或 App atom budget 代替；先验证收益，后改策略 | planner version 与 capability snapshot、用户文档同步；保留正文来源区间、chunk timing sidecar、说话人边界 | 1：先离线评估，再作契约化变更 |
| 首次发声引导 | 隐私回答是选择项而非强制同意；补失败恢复路径、进度持久化与无障碍要求 | 复用现有 preflight/capability snapshot；“第一次发声”走正常渲染；UI 自动化按逐次授权执行 | 2：产品设计后立项 |
| 信号体检 | 与响度分析合并成单一导出期扫描设计；不输出感知质量分 | 规定静音/削波/异常长度检测边界、扫描成本与告警上限 | 2：依赖导出分析设计 |
| 水印、缓存 | 作为独立可选研究，不进入当前 P0；缓存先核对现有检查点覆盖范围 | 水印需资源准入、默认关闭与可检出性评估；缓存需完整键空间、隐私和回收策略 | 3：ROI 再评估 |

### 5.2 第二轮补充观察与不采纳项
- **Dub QC 候选**：VoiceStudio `dub_qc.py` 做第二遍 ASR 漂移检查，生成文本仍是权威，不静默覆盖。可研究为有声书的“只读抽检 + 漂移提示”，但会增加 ASR 资源与音频隐私处理；未进入当前优先级，需先确认 SpeechRail 是否已有可组合的读回能力及客观收益。
- **已有能力不重复建设**：取消、忙碌反馈/退避在 SpeechRail 有现成机制；VoiceStudio 的重复文本变体、合成前静音上限、SSE 尾部畸形记录降级处理可作为实现观察，尚无证据证明值得复制。
- **切分算法差异**：VoiceStudio 的密度门控对整段算一次，再统一收紧各块上限；若进入实施阶段，应比较逐块密度决策，而不是照抄其全局阈值。其边缘静音裁剪与章节短交叉淡化也未证明优于 SpeechRail 现有首块淡入和媒体校验，不列为采纳项。
- **证据修正**：本轮撤回“ACX 阈值已核实”“隐私同意是继续门槛”“VoiceStudio MP3 可嵌图”“SpeechRail planner 上限为 4096”及“新增状态可直接对齐”的旧表述。OpenAPI 是否需要变化按实际公开 schema 决定；本次核对到的是 capability snapshot 与用户文档声明 planner 信息，未发现 OpenAPI 字段证据。

## 6. SpeechRail 已有而 VoiceStudio 未见（保持自信项）
- 【代码实测】只读真源 + 半开字节区间 + SHA-256（VoiceStudio 为可变脚本模型）。
- 【代码实测】结构化滑动窗口 + `policyFingerprint`/`configurationDigest` 确定性失效与检查点复用。
- 【代码实测】覆盖性校验 + 优雅旁白回退 + 递归二分回退 + 4 次调用预算。
- 【代码实测】媒体导出双验证（AVFoundation 实际章节 + SHA-256 + 原子安装）；`disable_chpl` 300+ 章支持。
- 【代码实测】`effective_capabilities_v1` 只读能力快照；`/v1/jobs*` 归属者作用域持久作业；`backend_busy` 稳定语义。
- 【代码实测】非 `1.0` speed 显式 `clone_speed_unsupported`（VoiceStudio 未见同名拒绝）。

---

## 7. 会话内并行改动与未决项（只读核实，未触碰）
- **VoiceStudio 证据覆盖已闭合**：在 `f47221a1` 上核实了长文管线（`longform_parser/audiobook/longform_render/longform_resume/longform_jobs/chunked_tts`）、造声与引导（`mcp_server.py` clone/design、`setup-gate`、`first-sound-handoff`、`analytics-consent`）、故障边界与本地化（`error-boundary`/`crash-details`/`report-bug`/`i18n` 21 locale）、引擎与出站治理（`engines.py`/`endpoint_race.py`/`engine_routing.py`/`gpu_gateway.py`）、资源与取消（`engine_memory`/`model_manager`/`inference_cancellation`）与质检证据（`audio_quality`/`dub_qc`/`engine_evidence`/`watermark`）。所有结论均为**静态代码证据**，未运行竞品程序。
- **工作区 19 改 + 2 未跟踪**：除本报告与 `docs/audits/README.md` 外，其余 18 改 + 1 未跟踪均为**并行改动**；本报告**未写入、未回退、未整文件还原**任何这些文件。
- **`AudiobookWorkflowTests.swift` 归属**：测得起因与本任务无关。核验时间线：`08:46:22` 计划文档 → `08:49:05/09` → `08:52:17/19/21` → `08:52:48` 测试文件；内容对应 `docs/superpowers/plans/2026-10-16-audiobook-ux-ui-redesign.md` §3.5/§3.6（AC-5.x/AC-6.x），并调用 `WindowLayoutPolicy.swift`（mtime `06:37`）。本会话对其**零写入**，故**不删除、不修改**。
- **`luna_worker` 差异**：未在仓库/`AGENTS.md`/`.agents/`/全局配置中找到该规则或代理；仅有模型别名 `gpt-6-luna`/`gpt-5.6-luna` 与 `luna-guide` skill。**待用户澄清**，本报告不作约束。
- **`photos`**：未跟踪新增 `docs/superpowers/plans/2026-10-17-teleprompter-ux-ui-redesign.md`（另一并行工作流产物），本报告未触碰。

---

## 8. 结论
- 目前有 3 个值得继续验证的高价值候选：**P0-1 通用交付响度、P0-2 M4B 封面、P0-3 密集文本规划**。它们都不是可直接开工的实现清单：P0-1 已核验 ACX 官方音频数值与 AI/TTS 限制，但该限制使 SpeechRail 不应承诺 ACX-ready；仍需验证通用目标的两遍成本与成品相对响度。P0-2 依赖 manifest schema、Swift/Python 边界和 artwork verifier 协调；P0-3 需以实际共用 240 codepoint planner 为基线做多语样本评估。P1-2 是独立产品方向，需覆盖隐私选择、失败恢复和无障碍体验。
- SpeechRail 在**只读真源、确定性窗口/检查点、覆盖性回退、媒体双验证、能力快照与作业模型**上已强于或等价于 VoiceStudio，不应为「对齐功能数」而削弱这些边界。
- 本报告第二轮补足了关键依赖与纠错。所有候选仍处于研究/方案阶段；本轮**仅修改审计文档与索引**，未实施产品代码、未新增或运行测试，未改变服务运行态。实施时按实际授权和项目规则选择最小验证，UI 自动化仍须逐次明确授权。

---

## 附录 A：关键证据索引（核验日期 2026-10-17）

**VoiceStudio（HEAD `f47221a1`）**
- `backend/services/longform_parser.py`：章节/指令语法
- `backend/services/audiobook.py`：`segment_seed`、`synthesize_chapter`、`MAX_JOIN_SILENCE_MS`
- `backend/services/longform_render.py`：`build_loudnorm_filter`、`validate_cover_image`、缓存键
- `backend/services/longform_resume.py`：`resume.json`、`_SAFE_ID_RE`、`RESUMABLE_TYPES`
- `backend/services/chunked_tts.py`：`DEFAULT_MAX_CHUNK_CHARS=800`、`_effective_max_chars`
- `backend/services/engine_memory.py`、`model_manager.py`、`inference_cancellation.py`：驻留/池/取消
- `backend/services/dub_qc.py`、`engine_evidence.py`、`audio_quality.py`：QC/证据/信号体检
- `electron/src/renderer/src/components/setup-gate.tsx`、`first-sound-handoff.tsx`、`analytics-consent.tsx`、`workspace-sidebar.tsx`
- `backend/mcp_server.py`：`clone_voice`(723)、`design_voice`(827)
- `electron/src/renderer/src/components/error-boundary.tsx`、`crash-details.tsx`、`report-bug.tsx`
- `electron/src/renderer/src/i18n/`（21 locale + `locale-match.ts` + `language-switch.tsx`）
- `backend/services/watermark.py`：AudioSeal 不可见 + 可见水印
- `backend/api/routers/engines.py`、`backend/services/endpoint_race.py`、`engine_routing.py`、`gpu_gateway.py`

**SpeechRail（HEAD `da18da8a`）**
- `docs/architecture/audiobook-llm-analysis-pipeline.md`（v1.0.0）
- `docs/architecture/audiobook-workshop.md`、`docs/developers/macos-app-audiobook.md`
- `docs/architecture/current-boundaries.md`、`docs/architecture/quality-voice-capabilities.md`
- `macos/SpeechRailApp/SpeechRailApp/AudiobookDomain.swift:11,28`、`AudiobookFragmentPlanner.swift:7,32,102,120,142`、`AudiobookAnalysisPolicy.swift:137`、`AudiobookAnalysisPipeline.swift:359,951,959,1111`
- `src/speechrail/media/encoder.py:408,467,475,478,504,528`（m4b/mp3）、`:267,291,311`（48k 校验）
- `src/speechrail/media/manifest.py:15,99–133,186–211`（schema/version、book-owned WAV 路径与 profile allowlist）
- `macos/SpeechRailApp/SpeechRailApp/AudiobookExportController.swift:381`、`AudiobookMediaVerifier.swift:9–14`（请求清单写入与验证结果模型）
- `src/speechrail/domain/tts_text_planner.py:22–92`、`src/speechrail/backends/qwen3_tts_worker.py:441–459`、`docs/users/effective-capabilities.md:135–141`（实际 planner、worker 接线及对外能力说明）
- `src/speechrail/domain/tts_loudness.py:12–23,60–68`、`src/speechrail/domain/tts.py:310,379`
- `src/speechrail/domain/voice_quality.py`、`voice_quality_evidence.py`、`asr_policy.py:132`
- `src/speechrail/runtime/busy.py:67`、`local_file_processor.py:246,263`
- `src/speechrail/http/routes/system.py:222–229,453–454`、`audio.py:1357,1638–1701`
- `src/speechrail/backends/qwen3_tts_incremental.py:29`
- `README.md`、`docs/README.md`、`docs/audits/README.md`

**外部官方规范（核验日期 2026-10-17）**
- [ACX 音频提交要求](https://help.acx.com/s/article/what-are-the-acx-audio-submission-requirements)：RMS/peak/noise floor、AI/TTS 限制及章节文件要求。
- [ACX 封面要求](https://help.acx.com/s/article/cover-art-requirements)：方形、尺寸、格式、色彩与文件大小要求。
- [FFmpeg loudnorm filter](https://ffmpeg.org/ffmpeg-filters.html#loudnorm)：单遍/双遍选项、动态模式升采样提示、dual-mono 与测量参数要求。
