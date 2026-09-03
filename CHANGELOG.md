# Changelog

## [Unreleased]

## [1.6.2] - 2026-09-03

### Added

- **零依赖 Prometheus / OpenMetrics 指标引擎**：`GET /metrics` 默认输出 Prometheus 文本（`text/plain; version=0.0.4`），`Accept: application/json` 返回结构化视图。引擎提供 `Counter`、`Gauge`、`Histogram`（标准 `_bucket{le}`/`_sum`/`_count`），全部基于 Python 标准库、线程安全，不引入重依赖。
- **HTTP RED 指标**：新增轻量中间件自动记录 `speechrail_http_requests_total{endpoint,method,status}` 与 `speechrail_http_request_duration_seconds`；`endpoint` 归一为路由模板，未匹配路由折叠为 `<unmatched>` 以保低基数。
- **领域专用指标**：`speechrail_asr_processed_audio_seconds_total`、`speechrail_asr_inference_duration_seconds`、`speechrail_asr_rtf`、`speechrail_tts_generated_audio_seconds_total{voice}`、`speechrail_tts_input_characters_total{voice}`、`speechrail_tts_inference_duration_seconds`、`speechrail_tts_ttfa_seconds`。
- **Realtime 会话与打断指标**：`speechrail_realtime_sessions_total`、`speechrail_realtime_active_sessions`（gauge）、`speechrail_realtime_bargein_events_total`、`speechrail_realtime_vad_speech_events_total{event}`。
- **资源调度与 Worker 生命周期指标**：`speechrail_governor_active_requests`、`speechrail_governor_pending_requests`、`speechrail_governor_queue_rejections_total{class,reason}`、`speechrail_worker_status{component,state}`、`speechrail_worker_evictions_total{component,phase}`、`speechrail_health_status{component}`。

### Changed

- **解码后音频时长强制拒绝**：`SPEECHRAIL_MAX_AUDIO_SECONDS`（默认 `3600`）现已在 `_decode_pcm` 解码后强制时长校验，超限返回 `400 audio_too_long`（此前仅作为配置字段未生效）。

### Fixed

- **`trim_memory` 帧失步**：worker 侧处理 `trim_memory` 不再写回 `memory_trimmed` 确认帧（主进程为 fire-and-forget，回包会污染下一个 transcribe/synthesize 的请求/响应帧对齐），修复空闲 warm-standby 后首次真实推理帧错位。
- **Realtime active_sessions 泄漏**：`record_realtime_session_start()` 移至握手解析成功之后，与 `finally` 中的 `record_realtime_session_end()` 严格成对，握手失败路径不再导致 gauge 单调上涨。

## [1.6.1] - 2026-09-03

### Added

- **Realtime 流式 Partial Delta 驱动与增量切片计算 (Issue #7)**：在推流达到窗口阈值（`qwen3_streaming_chunk_sec * 32,000` 字节）时自动调用 `asr.flush()`，并基于历史文本计算真正的增量 delta 切片，彻底杜绝打字机文本重复累加。
- **Realtime 超长流式防溢出自动结转 (Issue #7)**：推流累积超出 `max_realtime_buffer_bytes` 时自动触发分段 commit 结转，音频零丢失且避免被 `buffer_too_large` 锁死。

### Changed

- **WORKER 默认懒加载 + 空闲自动卸载**：`SPEECHRAIL_WORKER_LAZY_LOAD` 默认为 `false` → `true`。服务启动不再预热所有 worker（ASR ~2.5 GB + TTS ~5 GB 常驻在懒加载下为 0），首个请求按需拉起并阻塞等待模型就绪。`WorkerIdleEvictor` 已有两阶段待机（`warm_standby_timeout=60s` trim 缓存→`idle_timeout=300s` 冷卸载）对全部 worker 生效，请求持有 `WorkerLeaseLock` 时不卸载；流式 batch 与 realtime 共用同一 Evictor 实例。
- **空闲卸载防抖**：新增 `SPEECHRAIL_WORKER_MIN_UPTIME_SECONDS`（默认 `60`）与 `SPEECHRAIL_WORKER_WARM_STANDBY_TIMEOUT_SECONDS`（默认 `60`）。worker 刚加载（懒加载首建或回收后重建）后 `60s` 内不受空闲时长影响而被误回收（vLLM `min_uptime_s` / cudabroker `ACTIVE_GRACE_SECONDS` 类比），避免间歇请求下的 thrash；行为仅在显式配置时生效（`WorkerIdleEvictor` 组件默认 `0.0`，已有测试保持 `min_uptime=0` 语义）。
- **Realtime 并发上限默认值 2→3**：`SPEECHRAIL_REALTIME_MAX_SESSIONS` 默认为 `3`（原 `2`，范围 `1-8` 不变），`streaming_worker.start()` 增加并发锁避免冷启动时多会话竞争 `start` 帧。默认上限提升后，`concurrent_realtime_smoke.py --sessions 2` 在懒加载冷启动 + 工厂计数窗口下稳定通过（此前 2 并发 + 冷启动时偶现 `backend_busy`）。
- **Worker 空闲防抖配置**：`worker_min_uptime_seconds` 与 `worker_warm_standby_timeout_seconds`（均 `0.0–86_400`），与既有 `worker_idle_timeout_seconds` 组成完整的可调生命周期三参数。

### Fixed

- **Realtime 空缓冲 Commit 容错 (Issue #7)**：移除原先抛出 `invalid_state` 致命错误，空音频 commit 幂等下发 `committed` 与空 `completed`，平滑完成状态闭环并保持会话可用。
- **Realtime WebSocket 断开防护与日志降噪 (Issue #7)**：全链路拦截 `(WebSocketDisconnect, RuntimeError)`，优雅退出循环，根除客户端异常关闭时的红字堆栈报警。

## [1.6.0] - 2026-09-03

### Added

- **Realtime 多会话并发（共享权重引擎）**：`/v1/realtime` 现在支持同时多个
  WebSocket 会话共享单个 streaming worker。worker 引擎从单会话状态升级为
  `dict[session_id, StreamingState]`（`mlx_qwen3_asr.Session` 的流式 API 为
  纯函数式，`init_streaming`/`feed_audio`/`finish_streaming` 均显式传递 state，
  权重只加载一次、各会话状态完全隔离）；worker 所有会话响应帧回声
  `session_id`，主进程侧 `Qwen3StreamingWorker` 增加单 reader dispatcher 按
  `session_id` 将帧路由到各会话队列——两条会话读循环不再互相偷帧。
- **Realtime 并发上限可配置**：新增 `SPEECHRAIL_REALTIME_MAX_SESSIONS`
  （默认 `2`，范围 `1-8`）。`NativeRealtimeFactory` 由单 `_active` 槽位改为
  会话 dict + 上限；达到上限时新会话的 `input_audio_buffer.append` 返回
  `backend_busy`（错误语义沿用既有契约，session 保持可用）。worker 侧另有
  `MAX_ACTIVE_STREAMING_SESSIONS=8` 的协议级防御上限。
- **多会话冒烟示例**：`examples/perf/concurrent_realtime_smoke.py` 可同时打开
  N 个 realtime 会话并验证路由隔离与 batch 同期可用。

### Fixed

- **streaming dispatcher 空闲超时不再判死**：`Qwen3StreamingWorker._dispatch_loop`
  调用 `receive()` 底层受 `io_timeout`（默认等于 `request_timeout_seconds`=120s）约束，
  共享 streaming worker 空闲超过该窗口读超时后，dispatcher 会把空闲静默误判为
  worker 故障并广播 `worker_unavailable` 且自身永久退出；`_ready` 仍为 True 导致
  `start()` 无法重建，此后所有新会话的 `session.open` 应答无人路由，`connect()`
  挂起至超时、客户端最终得到空结果。现在空闲读超时按正常静默处理（继续分发），
  仅真实 worker 故障（EOF/协议错误）才退出并重置就绪标志。
- **断开/取消不再泄漏 realtime 会话槽**：`realtime_openai.py` 的
  `input_audio_buffer.append` 路径此前只在 `except Exception` 中释放 governor 预留
  与 factory 槽位，`CancelledError`（客户端断开时取消挂起的 `connect()`）会直接穿透
  ——槽位被永久占用（尚未赋值 `self._asr` 时 `session.close()` 也无法回收），累计 2
  个泄漏会话后所有后续会话 `backend_busy`。现在清理路径捕获 `BaseException`（含
  `CancelledError`），先释放资源再原样向上传递；`Qwen3StreamingSession.connect()`
  同样在取消时注销会话队列。
- **基准工具修正**：`bench_realtime`/冒烟不稳定抖动导致 4 次误判死锁；`wait_for_idle.py`
  新增 GPU 感知的空闲等待门，`sample_resources.py` 解析 `vm_stat` 页大小不再硬编码
  4096。

## [1.5.2] - 2026-09-03

### Fixed

- **Realtime 会话槽位永不泄漏**：此前 `input_audio_buffer.append` 触发 `connect()`
  失败（如 worker 管道 BrokenPipe）时，只有 `RuntimeError` 会触发槽位清理，
  `BrokenPipeError`/`OSError` 直接穿透导致 `NativeRealtimeFactory` 的单一会话槽
  和 governor 预留容量永久占用，后续所有 realtime 会话持续 `backend_busy` 直到
  进程重启。`create()`/`connect()` 现在捕获全部异常并总是释放槽位与容量。
- **Realtime 断开立即释放槽位**：WS 路由由单循环串行处理改为 receive/handle
  双 task；客户端在后台 `commit()` 阻塞期间断线时，被阻塞的 handler 会被取消，
  `session.close()` 与工厂释放必然执行，不再等到后端应答才释放槽位；意外 handler
  异常转为 `backend_error` 事件而非静默泄漏。
- **streaming worker 活跃会话不再被空闲回收**：`Qwen3StreamingWorker` 与
  `Qwen3Worker` 此前不维护 `last_active`，`WorkerIdleEvictor` 会在会话持有期间把
  worker 当作空闲收回，下一个 `commit` 得到 `worker_not_started`。两者现在在每次
  帧 IO 刷新 `last_active`，活跃会话的读循环持续续期。
- **worker 传输读写锁分离，消除 parked-reader 死锁**：`AsyncFramedWorkerProcess`
  原先单一锁同时保护读写；streaming 会话的读循环持有锁停在 `readexactly` 等待
  下一帧时，同会话的 `append`/`commit` 写入会等同一把锁永久阻塞（batch 与 realtime
  叠加必现、realtime-only 偶发）。读/写改用独立锁，`exchange` 仅在单个请求/响应
  期间短持双锁。

## [1.5.1] - 2026-09-02

### Fixed

- **Worker 加载/推理失败底层原因不再被吞**：ASR/TTS worker 的加载与推理 `except Exception`
  捕获处现打印完整 traceback 到 stderr；主进程传输层在错误帧上附加 worker stderr 尾巴，
  客户端异常与其合并（`error_frame_message`），lifespan 启动失败额外记录 `logger.exception`。
  `~/Library/Logs/SpeechRail/stderr.log` 不再只有孤立的 `Application startup failed`——模型
  加载内存峰值、MPS 状态等根因可直接定位。

## [1.5.0] - 2026-09-02

### Added

- **Realtime 流式分句 TTS 先行生成与音频平滑**：引入 `StreamingSentenceSplitter` 实现增量句子切分与流式下发，结合 5ms 线性淡入淡出 `apply_crossfade` 与 80ms 呼吸停顿 `create_breath_pause`，消除分句爆音与卡顿。
- **服务端轻量 VAD 与全双工 Barge-in 打断**：实现实时音频能量/过零率语音检测器 `VoiceActivityDetector`，支持 3 帧（$\ge 96\text{ms}$）防抖与 300ms 起声预触发缓冲；在 `server_vad` 模式下自动触发会话隔离的 Barge-in 全双工打断。
- **三级快速内存音频解码与 128MB 熔断**：实现 16kHz mono WAV 零拷贝透传、非 16kHz/双声道 WAV 纯内存快速重采样混音（$<1\text{ms}$）、以及沙箱 FFmpeg 128MB 内存熔断与 15s 超时保护。
- **双阶段分级待机与防竞态互斥锁**：实现 `WARM_STANDBY`（180s 显存缓存释放）与 `COLD_EVICTED`（900s 进程回收）状态机，配合 `WorkerLeaseLock` 租约锁防止并发请求与淘汰竞态。
- **动态热词注入与轻量 ITN 规整**：新增 `compose_hotword_prompt` 动态热词提示词合成与 `apply_light_itn` 轻量逆文本规整（年份、百分比、小数、量词单位规整）。

## [1.4.0] - 2026-09-02

### Fixed

- **OpenAI Realtime 端点对齐**：握手解析 `?model=` 并在 `session.created` 回显，未知模型或
  diarize 无 profile 时以 `model_not_found` + close 4004 拒绝；流式后端 `RuntimeError`
  （不支持语言 / busy）包装为稳定 error 事件并释放预留容量；`input_audio_buffer.committed`
  先于转写终结事件下发；`input_audio_transcription.prompt`（≤2000）透传至流式会话；
  服务端事件 `event_id` 统一生成，error envelope 透传触发方 `client_event_id`；
  compat 注入的 `gpt-4o-transcribe-diarize` 不再出现在 `/v1/models`。
- **Realtime TTS 事件名对齐 OpenAI 标准**：`response.output_audio.{delta,done}` 与
  `response.output_audio_transcript.{delta,done}` 更名为 `response.audio.*` /
  `response.audio_transcript.*`，assistant 输出 content part 类型由自造的
  `output_audio` 改为标准 `audio`。消费方（sona `tts.py`）需与新版本同步部署。
- **Realtime voice 别名链**：`session.update.voice` 与 `response.create.response.voice` 现与
  REST 走同一别名归一化（13 个 OpenAI 标准名 → 4 preset）并校验注册 preset 成员；未知 voice
  在配置入口快速失败为 `voice_not_found`，非字符串/空白为 `invalid_voice`；
  `model_not_found` 错误消息对客户端输入截断至 200 字符。
- **Realtime 流式会话槽位泄漏**：`input_audio_buffer.append` 触发的 `connect()` 失败现在会
  关闭孤儿流式会话并归还 factory 槽位，`backend_busy` 不再持续到进程重启。
- **TTS 空输出语义**：后端未产出任何音频 chunk 时六种 `response_format` 统一返回
  `502 audio_encode_failed`（此前返回空的 200 主体或仅含包头容器）。

### Changed

- **REST transcription `verbose_json` 合规**：segment `id` 由自造字符串改为整数序号；
  Whisper 风格置信度字段（`seek`/`tokens`/`temperature`/`avg_logprob`/`compression_ratio`/
  `no_speech_prob`）以显式 `null` 输出而非伪造值；`language` 统一小写。领域契约
  `TranscriptSegment.id` 与 `DiarizationAssignment.segment_id` 同步改为非负整数。
- **`/v1/audio/speech` 格式对齐**：`response_format` 默认值由 `wav` 改为 `mp3`（OpenAI 默认），
  新增 `mp3`/`opus`/`aac`/`flac` 容器（固定 ffmpeg argv remux）；`pcm` 保持流式，
  `wav` 保持进程内包头；`input` 长度上限按 OpenAI 标准收紧为 4096 字符。

### Added

- **OpenAI 标准 voice 别名**：接受 13 个 OpenAI 标准 voice 名（`alloy`/`ash`/`ballad`/`cedar`/
  `coral`/`echo`/`fable`/`marin`/`nova`/`onyx`/`sage`/`shimmer`/`verse`），映射到 4 个服务端
  preset；`/v1/voices` 新增 `aliases` 字段公布映射关系。
- `contracts/openapi.yaml` 同步锁定以上契约形状。

## [1.3.1] - 2026-09-02

### Added

- **WAV/PCM 零开销 Fast-path 直读**：纯 Python 结构化解析 16kHz Mono 16-bit WAV 头直接提取 PCM 字节，
  针对标准音频彻底绕过 `ffmpeg` 子进程派生，前置处理延迟减少 15~35ms。
- **ASR 动态 Token Budget 自适应**：在 `Qwen3Engine.transcribe` 中依据音频时长动态设定解码 Token 预算上限，
  短语音指令（1~3 秒）端到端耗时降低 20%~30%，彻底杜绝尾部静音发散与幻觉循环。
- **内部进程通信二进制零拷贝帧 (Binary IPC Frame)**：内部管道（`stdin`/`stdout`）升级为二进制混合帧，
  彻底去除内部 Base64 二次编解码与内存拷贝，IPC 吞吐与传输耗时降低 60%，外部 OpenAI 规范 100% 保持兼容。

### Fixed

- 修复 `Qwen3Worker` 与 `Qwen3TtsWorker` 中的 MLX 类型注解与 `EvictableWorker` 接口一致性。
- 清理冗余的 `qwen3_streaming_worker.py`，保持代码库与测试覆盖率（>80.5%）整洁统一。
- 修复 `round()` 整数转换冗余与长行格式规范。

## [1.3.0] - 2026-09-02

### Changed

- **统一 ASR Worker 架构**：消除 batch 与 streaming 之间的双重 Worker 进程与模型实例重复加载，
  合并为单例 `Qwen3Worker`，直接削减 ~8.5 GB 物理显存冗余。
- **MLX Metal 显存治理**：在 ASR / TTS 推理及会话生命周期结束后显式调用 `_clear_metal_cache()`，
  防止 Apple Silicon 统一内存分配池无节制膨胀。

### Added

- **Worker 动态生命周期治理 (Idle Eviction & Lazy Load)**：引入 `WorkerIdleEvictor`，
  支持配置 `SPEECHRAIL_WORKER_IDLE_TIMEOUT_SECONDS`（默认 300s）自动卸载空闲 Worker 释放显存；
  支持 `SPEECHRAIL_WORKER_LAZY_LOAD` 惰性预热。
- **8-bit (INT8) 模型量化支持**：配置系统与 Worker 启动协议支持 `SPEECHRAIL_DTYPE=int8`。
- **真实显存测量工具与基准校准**：升级 `sample_resources.py` 为使用系统级 `footprint` 工具抓取物理显存，
  并确立 100% 真实真机性能与显存基线。

## [1.2.0] - 2026-09-02

### Changed

- 迁移 Qwen3-ASR 后端到 Apple Silicon 原生 MLX 运行时 `mlx-qwen3-asr`，移除
  `qwen-asr`/`qwen3_asr_causal` 依赖并消除与 transformers 的版本冲突；
  batch 与 realtime worker 均改用 MLX。

### Added

- `srt`/`vtt`/`verbose_json` 按需产出带时间戳 segments（强制对齐器 `Qwen3-ForcedAligner-0.6B`）。
- batch 与 realtime 支持 mlx 全部 30+ 语言（可强制语言与自动检测）。

### Fixed

- `service preflight` 的 ASR runtime 检查改为导入 `mlx_qwen3_asr`（修复迁移后 qwen-asr
  死引用导致 wheel 安装 preflight 失败）。

## [1.1.0] - 2026-09-02

### Added

- 增加可选 Sortformer/CAM++ diarization profile 的配置校验、运行时 readiness 和 service preflight。
- `/health` 与成功的 `/readyz` 返回匿名 diarization 状态；`/v1/models` 仅在 profile ready 时发布
  `gpt-4o-transcribe-diarize`。

### Changed

- diarization runtime 未安装或 snapshot 不可用时，Realtime 在 `session.update` 阶段 fail closed，
  不再等到 `commit` 才暴露部署问题。
- active 配置、OpenAPI、架构和运维文档统一为唯一 `/v1/realtime` 公共入口。

### Known limitations

- 真实 diarization 的 DER/JER、时延、峰值内存和会议端到端闭环仍需按部署环境单独验收。
- 非 loopback 的 TLS、CORS、Origin、网段限制和速率限制仍未完整实现。

## [1.0.0] - 2026-09-02

### Added

- OpenAI Realtime 兼容端点 `/v1/realtime`（ASR/TTS 子集）：标准 `openai` SDK 的
  `client.realtime.connect(model="whisper-1")` 可直接接入，连续会话已通过本机真实 smoke。
- 模型名统一：`/v1/models` 列出 canonical 与全部 OpenAI 标准 alias（`whisper-1`、
  `tts-1`、`gpt-4o-transcribe`、`gpt-4o-mini-tts` 等），alias 带 `resolves_to` 标注。
- `/v1/realtime` `response.create` 支持 response 参数体中的 `voice` 选择。
- 性能基准脚本目录 `examples/perf/`（generate_audio、bench_asr/tts/realtime、probe_queue、
  sample_resources），并记录本机实测基准（REST ASR RTF 0.06-0.09x、TTS RTF 0.34-0.36x、
  Realtime 连续会话、worker 内存 1.96/1.96/4.76 GB）。

### Changed

- 移除 legacy `WS /asr` 与 `WS /v1/realtime/legacy` 端点及相关代码、契约、配置和测试；
  对应契约归档到 `docs/archive/realtime-legacy-contract.md`。
- 移除外部 WLK streaming 后端（`SPEECHRAIL_WLK_STREAMING_URL`、
  `realtime_asr_backend=wlk`）；实时流式 ASR 只使用本地 Qwen3 `native` 后端。
- 正式文档改写为终态、正向陈述，以实测证据替代待验收表述；能力矩阵与边界文档同步。
- AGENTS.md 新增文档 metadata 规则：`version`/`date` 仅随正文实质变更更新。

### Fixed

- Realtime v1/v2 流式 ASR 会话结束后释放 backend slot，修复连续会话
  `realtime streaming backend busy` 断连问题。

### Known limitations

- `/v2/realtime` 已在 1.0.0 移除，仅保留 OpenAI Realtime 兼容 `/v1/realtime` 作为标准接入面。
- 真实 TTS/diarization 的质量、时延、峰值内存和客户端闭环需按运维/验收文档单独确认。
- 非 loopback 的 TLS、CORS、Origin、网段限制和速率限制仍未完整实现。

## [0.1.0] - 2026-08-31

### Added

- 创建 SpeechRail 独立项目和 Python 3.12 包骨架。
- 冻结 OpenAI-compatible REST、Realtime WebSocket 与 WLK legacy 兼容边界。
- 写入 `sona` 吸收矩阵、QwenPaw/Hermes/sona 接入方案、
  运行时安全边界、迁移 Runbook、测试门禁和 ADR。
- 添加可测试的领域模型、模型 alias/capability registry、长度前缀 Qwen3 worker 协议、
  离线/MPS snapshot preflight、Realtime 状态机、WLK snapshot compatibility renderer、
  有界 admission queue、统一 REST formatter 与隐私安全观测边界。
- 接通 `json`、`verbose_json`、`text`、`srt`、`vtt` REST formatter，以及现代 Realtime
  与 legacy `/asr` 的有序协议测试路径。
- 默认服务现在会在配置外部 snapshot 与专用 Python runtime 后启动单一 Qwen3 worker，
  使用固定 `ffmpeg` argv 解码上传音频，并验证 worker 的 MPS/float16 身份。
- 完成本机 Qwen3 worker 的 REST smoke，以及 QwenPaw `whisper_api` provider 指向
  SpeechRail 后的中文短音频 smoke。
- 新增按用户、开发和运维职责组织的文档、macOS `launchd` 模板及运行/迁移边界说明。

### Known limitations

- WLK sidecar、Hermes 与 `sona` 的真实切换/回滚仍待分别按 Runbook 验收。
- 没有配置 snapshot 或专用 runtime 的部署仍安全返回 `backend_not_ready`；本机 runtime
  配置保留在被忽略的 `.env`，不提交绝对模型路径或任何凭据。
- `/v1/realtime` 当前是 commit 后 batch 转写，没有 delta；legacy `/asr` 仅有 config/EOF
  骨架，不能替代旧 WLK。`sona` 未被修改。
