# Clone TTS Loudness Stability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** 让 SpeechRail 的 cloned-voice Realtime TTS 在保持音色与语义韵律的同时，输出稳定、不过载、可被 Sona 安全播放的 24 kHz mono PCM16。

**Architecture:** 参考音频在 TTS worker 内存中先做一次输入响度校准；每个 clone request 创建一个跨 80 ms chunk 持有状态的输出响度控制器。控制器只接入 clone 分支，使用有限校准窗口、慢速 attack/release、chunk 内增益插值和 peak ceiling，避免无状态逐块归一化造成 pumping。Realtime/REST 继续交付相同格式的 PCM16，Sona 只消费并做兼容保护。

**Tech Stack:** Python 3.12、uv、FastAPI、Qwen3-TTS/MLX、NumPy、PCM16、pytest、Ruff、mypy、Redocly、WebSocket Realtime。

**Spec:** [SpeechRail#34](https://github.com/hrygo/SpeechRail/issues/34)；客户端配套方案见 [Sona#10](https://github.com/hrygo/sona/issues/10)。

## Global Constraints

- Python 固定为 >=3.12,<3.13，使用 uv 和 PEP 621；不升级模型或第三方运行时。
- 只在 clone 路径增加响度控制；内置 generate() 路径保持现有声音行为，除非 A/B 证据证明公共输出契约必须统一。
- 参考音频只在 worker 内存中校准，不覆盖用户原始 WAV，不持久化新音频副本。
- 不记录原始 PCM、Base64、完整 prompt/transcript、voice 自由值、绝对模型路径或 API key。
- 不增加模型副本、不改变 profile/quantization、worker IPC、并发准入和 24 kHz mono PCM16 公共格式。
- 禁止按单个 80 ms chunk 独立归一化；控制器状态必须以一次 synthesize() 请求为生命周期边界。
- 所有行为变更先写失败回归测试；不覆盖工作区已有的并行修改。
- Sona 侧只做消费端兼容保护与验收，不能把两个仓库的控制器叠加成两个快速 AGC。

---

### Task 1: 建立 PCM16 流式响度控制器

**Files:**
- Create: src/speechrail/domain/tts_loudness.py
- Create: tests/test_tts_loudness.py

**Interfaces:**
- Produces: Pcm16LoudnessConfig
- Produces: StreamingPcm16LoudnessController.process(pcm: bytes) -> bytes
- Produces: StreamingPcm16LoudnessController.reset() -> None
- Consumes: little-endian signed PCM16、单声道、固定 sample_rate

- [ ] **Step 1: 写失败测试，锁定输入校验、静音和峰值行为**

    def test_controller_rejects_odd_pcm16_payload() -> None:
        controller = StreamingPcm16LoudnessController(sample_rate=24_000)
        with pytest.raises(ValueError, match="PCM16 payload length must be even"):
            controller.process(b"\x00")

    def test_controller_does_not_raise_near_silence() -> None:
        controller = StreamingPcm16LoudnessController(sample_rate=24_000)
        silence = b"\x00\x00" * 1_920
        assert controller.process(silence) == silence

    def test_controller_smooths_alternating_chunk_levels() -> None:
        controller = StreamingPcm16LoudnessController(sample_rate=24_000)
        low = _constant_pcm16(0.05, 1_920)
        high = _constant_pcm16(0.40, 1_920)
        output = [controller.process(chunk) for chunk in (low, high, low, high)]
        levels = [_rms_dbfs(chunk) for chunk in output]
        assert max(abs(levels[i] - levels[i - 1]) for i in range(1, len(levels))) < 8.0

    def test_controller_applies_peak_ceiling_without_wraparound() -> None:
        controller = StreamingPcm16LoudnessController(sample_rate=24_000)
        output = controller.process(_constant_pcm16(0.99, 1_920))
        assert _peak_dbfs(output) <= -1.0 + 0.1
        assert max(abs(value) for value in _decode_pcm16(output)) <= 32767

    测试 helper 只在测试内生成常量 PCM，不写入音频文件，也不依赖模型。

- [ ] **Step 2: 运行测试确认失败**

    Run:
    uv run --extra dev pytest tests/test_tts_loudness.py -q --no-cov

    Expected: collection FAIL，因为 speechrail.domain.tts_loudness 尚不存在。

- [ ] **Step 3: 实现最小状态机**

    @dataclass(frozen=True, slots=True)
    class Pcm16LoudnessConfig:
        target_rms: float = 0.1
        peak_ceiling: float = 10 ** (-1 / 20)
        silence_rms: float = 10 ** (-50 / 20)
        calibration_ms: int = 240
        attack_ms: int = 250
        release_ms: int = 800
        max_gain_db: float = 12.0
        max_attenuation_db: float = -6.0

    class StreamingPcm16LoudnessController:
        def __init__(
            self,
            *,
            sample_rate: int,
            config: Pcm16LoudnessConfig | None = None,
        ) -> None:
            raise NotImplementedError

        def process(self, pcm: bytes) -> bytes:
            raise NotImplementedError

        def reset(self) -> None:
            raise NotImplementedError

    process() 按以下顺序实现：校验偶数字节并解码；在 calibration_ms 内收集 RMS 高于 silence_rms 的样本；计算目标增益并限制在 [-6 dB, +12 dB]；后续 chunk 用 attack/release 的指数平滑更新增益；把旧增益到新增益线性插值到当前 chunk 的每个样本；若预测 peak 超过 peak_ceiling，只对本 chunk 做有界衰减；重新编码 little-endian PCM16。静音 chunk 不更新目标增益，也不做向上拉升。reset() 清空校准缓冲、当前增益和峰值计数。

- [ ] **Step 4: 运行控制器测试确认通过**

    Run:
    uv run --extra dev pytest tests/test_tts_loudness.py -q --no-cov
    uv run --extra dev ruff check src/speechrail/domain/tts_loudness.py tests/test_tts_loudness.py
    uv run --extra dev mypy src/speechrail/domain/tts_loudness.py

    Expected: 所有测试、Ruff、mypy PASS；测试必须证明输出没有 PCM16 回绕。

- [ ] **Step 5: 提交独立逻辑主题**

    git add src/speechrail/domain/tts_loudness.py tests/test_tts_loudness.py
    git commit -m "fix(tts): add stateful PCM loudness controller"

### Task 2: 归一化 clone 参考音频输入

**Files:**
- Modify: src/speechrail/backends/qwen3_tts_worker.py:473-517
- Test: tests/test_qwen3_tts_worker.py

**Interfaces:**
- Consumes: 现有 _audio_loader_fn 和 reference cache
- Produces: cache 中保存已归一化的 MLX audio array；cache hit/eviction 计数语义不变

- [ ] **Step 1: 写 loader 参数失败测试**

    def test_reference_audio_loader_requests_volume_normalization() -> None:
        calls: list[dict[str, object]] = []

        def loader(path: str, **kwargs: object) -> object:
            calls.append({"path": path, **kwargs})
            return _fake_audio_array()

        engine = _engine_with_audio_loader(loader)
        engine._load_reference_audio(_reference_path())

        assert calls[0]["sample_rate"] == 24_000
        assert calls[0]["volume_normalize"] is True

- [ ] **Step 2: 运行目标测试确认失败**

    Run:
    uv run --extra dev pytest tests/test_qwen3_tts_worker.py -q --no-cov

    Expected: 新断言 FAIL，当前 loader 调用没有 volume_normalize。

- [ ] **Step 3: 修改唯一 loader 调用并保留 cache 行为**

    audio_array = loader(
        str(resolved),
        sample_rate=self._sample_rate,
        volume_normalize=True,
    )

    不要修改原始文件、registry 元数据、cache key、cache 容量或错误 envelope。

- [ ] **Step 4: 回归 reference cache 测试**

    Run:
    uv run --extra dev pytest tests/test_qwen3_tts_worker.py -q --no-cov

    Expected: 原有 cache hit、路径替换 eviction、decode error 和空数组错误全部 PASS。

- [ ] **Step 5: 提交输入校准主题**

    git add src/speechrail/backends/qwen3_tts_worker.py tests/test_qwen3_tts_worker.py
    git commit -m "fix(tts): normalize clone reference audio in memory"

### Task 3: 只在 clone 请求接入控制器

**Files:**
- Modify: src/speechrail/backends/qwen3_tts_worker.py:345-384
- Modify: src/speechrail/backends/qwen3_tts_worker.py:386-471
- Test: tests/test_qwen3_tts_worker.py
- Test: tests/test_tts_voice_clone.py

**Interfaces:**
- Consumes: StreamingPcm16LoudnessController、现有 MlxQwenTtsEngine.synthesize() 生命周期
- Produces: clone 请求内跨 sentence/chunk 的稳定 PCM stream；内置 voice 输出保持原样

- [ ] **Step 1: 写 clone-only 失败回归测试**

    用 fake ICL generator 产生 [0.05, 0.40, 0.05, 0.40] 的连续 80 ms chunk，断言 clone 输出的相邻 RMS 跳变低于修复前基线；builtin generate() 的字节 fixture 保持不变。

    def test_clone_synthesis_smooths_chunk_level_without_touching_builtin() -> None:
        clone_chunks = list(engine.synthesize(
            "第一句。第二句。",
            voice="clone-test",
            speed=1.0,
            language="zh",
            ref_audio="/tmp/reference.wav",
            ref_text="参考文本",
        ))
        builtin_chunks = list(engine.synthesize(
            "第一句。第二句。",
            voice="serena",
            speed=1.0,
            language="zh",
        ))
        assert _rms_jump_p95(clone_chunks) < _rms_jump_p95_raw_clone
        assert builtin_chunks == _expected_builtin_chunks

- [ ] **Step 2: 运行测试确认失败**

    Run:
    uv run --extra dev pytest tests/test_qwen3_tts_worker.py tests/test_tts_voice_clone.py -q --no-cov

    Expected: clone 的交替 chunk 仍按原始幅度输出，新增断言 FAIL；builtin 对照保持 PASS。

- [ ] **Step 3: 在 synthesize() 建立请求级 controller**

    controller = (
        StreamingPcm16LoudnessController(sample_rate=self._sample_rate)
        if ref_audio is not None or ref_text is not None
        else None
    )
    try:
        for sentence in bounded_sentences(clean_text):
            for pcm in self._generate(
                sentence,
                voice=voice,
                speed=speed,
                language=language,
                instruction=instruction,
                seed=seed,
                ref_audio=ref_audio,
                ref_text=ref_text,
            ):
                if controller is not None:
                    pcm = controller.process(pcm)
                if pcm:
                    yield pcm
    finally:
        if controller is not None:
            controller.reset()

    控制器必须在 sentence loop 外创建，跨 bounded_sentences() 的句子边界持续工作；不能成为 engine 全局字段。保留现有首 chunk 5 ms fade。generator 异常、客户端取消或输出校验异常时也必须执行 finally。

- [ ] **Step 4: 增加取消、异常和最终 fade 覆盖**

    锁定以下回归：第二个 clone chunk 抛异常时 controller 被 reset；final chunk 的尾部 fade 仍然存在；空 PCM chunk 被跳过；clone 对 speed/instruction/seed 的拒绝不变；builtin generate() 的字节输出与修复前 fixture 相同。

- [ ] **Step 5: 运行 worker/voice clone 测试**

    Run:
    uv run --extra dev pytest tests/test_qwen3_tts_worker.py tests/test_tts_voice_clone.py tests/test_tts_streaming_splitter.py -q --no-cov

    Expected: 全部 PASS，且没有修改 public AudioChunk 字段或 chunk order。

- [ ] **Step 6: 提交 clone 接线主题**

    git add src/speechrail/backends/qwen3_tts_worker.py tests/test_qwen3_tts_worker.py tests/test_tts_voice_clone.py
    git commit -m "fix(tts): stabilize cloned voice stream levels"

### Task 4: 固化 Realtime/REST 交付契约

**Files:**
- Modify: src/speechrail/compatibility/openai_realtime.py
- Modify: src/speechrail/application/realtime_openai.py
- Modify: contracts/realtime-openai.md
- Test: tests/test_realtime_openai.py
- Test: tests/test_speech_api.py

**Interfaces:**
- Produces: speech_capabilities.audio_loudness_profile = stable_loudness_v1，仅在对应 worker 能力已启用时声明
- Consumes: 现有 session.created/session.updated 的 speech_capabilities 扩展位置

- [ ] **Step 1: 写 capability 失败测试**

    def test_session_created_advertises_stable_clone_loudness_profile() -> None:
        event = session_created(
            session_id="sess-1",
            model="speechrail/qwen3-tts",
            tts_ready=True,
            tts_loudness_profile="stable_loudness_v1",
        )
        assert event["session"]["speech_capabilities"]["audio_loudness_profile"] == (
            "stable_loudness_v1"
        )

- [ ] **Step 2: 运行 Realtime 契约测试确认失败**

    Run:
    uv run --extra dev pytest tests/test_realtime_openai.py tests/test_speech_api.py -q --no-cov

    Expected: 新增参数和 capability 字段尚不存在，测试 FAIL。

- [ ] **Step 3: 增加 namespaced capability 且保持旧客户端兼容**

    session.created 与 session.updated 在 speech_capabilities 中声明能力；不新增标准 OpenAI 未定义的顶层事件，不要求旧客户端发送 proprietary request 字段。未启用 controller 的服务不得声明该能力。Sona#10 根据该字段选择 safety-only 或 bounded compatibility 模式。

- [ ] **Step 4: 运行契约与公开 API 回归**

    Run:
    uv run --extra dev pytest tests/test_realtime_openai.py tests/test_speech_api.py tests/test_tts_voice_clone.py -q --no-cov
    npx @redocly/cli lint contracts/openapi.yaml

    Expected: Realtime event order、voice validation、PCM16 format、REST response format 和 error envelope 全部 PASS。

- [ ] **Step 5: 提交协议主题**

    git add src/speechrail/compatibility/openai_realtime.py src/speechrail/application/realtime_openai.py contracts/realtime-openai.md tests/test_realtime_openai.py tests/test_speech_api.py
    git commit -m "feat(realtime): advertise stable tts loudness capability"

### Task 5: 真实模型 A/B 验收与运行文档

**Files:**
- Modify: docs/operations/capability-quality-acceptance.md
- Create: docs/archive/performance/2026-09-08-clone-tts-loudness-acceptance.md

**Interfaces:**
- Consumes: managed service、授权的本机 API key、/v1/realtime PCM stream
- Produces: 不含原始音频的统计验收记录和回滚说明

- [ ] **Step 1: 运行静态门禁**

    uv run --extra dev pytest --no-cov
    uv run --extra dev ruff check src tests
    uv run --extra dev mypy src
    npx @redocly/cli lint contracts/openapi.yaml
    git diff --check

    Expected: 以上命令全部 exit 0；完整 pytest 另按项目配置执行覆盖率门禁。

- [ ] **Step 2: 运行内存内 realtime smoke**

    对 3 段不同长度/标点结构的中文文本、每个 clone 和一个内置音色各运行 3 次；脚本只打印 voice 类别、chunk 数、时长、RMS p10/p50/p90、相邻跳变 P95、peak ceiling 触发次数和首包延迟，不写音频文件。

    Expected: clone active RMS 中位数在 -20 dBFS ±3 dB；clone 相邻跳变 P95 不高于内置基线 +2 dB；peak <= -1 dBFS；response.done 为 completed。

- [ ] **Step 3: 验证回退**

    在隔离 release 中切回上一 release，使用原有 speechrail service 流程重启并检查 /health、/readyz、/v1/voices；不删除模型、selection、私有配置或用户 voice 文件。

- [ ] **Step 4: 更新验收报告并提交**

    git add docs/operations/capability-quality-acceptance.md docs/archive/performance/2026-09-08-clone-tts-loudness-acceptance.md
    git commit -m "docs(tts): record cloned voice loudness acceptance"

### Task 6: 跨仓库交付检查

**Files:**
- Modify: docs/superpowers/plans/2026-09-08-clone-tts-loudness-stability.md

- [ ] **Step 1: 更新 issue 关联与实现状态**

    在 [SpeechRail#34](https://github.com/hrygo/SpeechRail/issues/34) 回报提交 hash、实测指标、是否需要 Sona#10 的兼容模式；在 [Sona#10](https://github.com/hrygo/sona/issues/10) 回报服务端 capability 是否已部署。

- [ ] **Step 2: 核对跨仓库边界**

    确认 SpeechRail 是唯一的 clone 输入/生成权威；Sona 不写入参考音频、不改变协议格式，并且未声明 stable_loudness_v1 时仍可通过 bounded compatibility guard 工作。

- [ ] **Step 3: 最终检查工作区**

    git status --short
    git diff --check

    只包含本 issue 的目标文件；已有并行改动必须继续保留且不得混入提交。
