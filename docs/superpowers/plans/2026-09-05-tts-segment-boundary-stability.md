# SpeechRail TTS Segment Boundary Stability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为每次 SpeechRail TTS 独立合成的首个非空 PCM 块补齐 5 ms fade-in，同时保持现有最终块 fade-out、24 kHz PCM 和公共协议不变。

**Architecture:** 在 `MlxVoiceDesignEngine._generate()` 内维护单次合成作用域的首块状态；先复用 `_to_pcm()` 完成 PCM16 转换与最终块 fade-out，再只对首个非空块调用现有 `apply_crossfade()`。修复通过 SpeechRail 1.6.9 wheel 独立发布，不涉及消费端播放实现。

**Tech Stack:** Python 3.12、uv、Qwen3-TTS/MLX、PCM16、pytest、ruff、mypy、Redocly、macOS LaunchAgent

**Spec:** `docs/superpowers/specs/2026-09-05-tts-segment-boundary-stability-design.md`

## Global Constraints

- Python 保持 `>=3.12,<3.13`，不得新增或升级模型依赖。
- 公共 REST/WebSocket/OpenAI compatibility 契约、模型 ID、PCM16 mono 24 kHz 与 chunk index 不变。
- fade 只作用于每次合成的首个非空块和现有最终块，不得处理每个中间 codec 块。
- 不修改 voice instruction、seed、temperature、自定义音色持久化或句间 pause。
- 不记录 TTS 文本、PCM、API key；真实 PCM 仅使用临时目录并在统计后删除。
- 实施基线必须包含已提交的自定义音色改动 `d4a7c9f`；目标文件 dirty 时不得覆盖、stash、revert
  或混合提交。
- 任何提交前均须完成 SpeechRail 项目规定的完整质量门禁。

---

### Task 1: 首块淡入生产接线

**Files:**
- Modify: `src/speechrail/backends/qwen3_tts_worker.py`
- Modify: `tests/test_qwen3_tts_voice_design.py`
- Verify: `tests/test_qwen3_tts_worker.py`
- Verify: `tests/test_tts_streaming_splitter.py`

**Interfaces:**
- Consumes: `apply_crossfade(pcm: bytes, *, sample_rate: int = 24_000, fade_ms: int = 5, fade_in: bool = True, fade_out: bool = True) -> bytes`
- Produces: `MlxVoiceDesignEngine._generate()` 对每次调用的首个非空 PCM 块执行一次 fade-in。

- [x] **Step 1: 核对并行改动已经独立收口**

Run:

```bash
git merge-base --is-ancestor d4a7c9f HEAD
git status --short
git diff -- src/speechrail/backends/qwen3_tts_worker.py tests/test_qwen3_tts_voice_design.py
```

Expected: HEAD 包含 `d4a7c9f`，两个目标文件均无未提交改动。若目标文件仍 dirty，停止本 Task，
由其所有者先独立收口，再从新 HEAD 重跑本步骤。后续实现必须保留已落地的 seed/temperature
逻辑。

- [x] **Step 2: 写多块逻辑边界失败测试**

在 `tests/test_qwen3_tts_voice_design.py` 追加：

```python
class SequencedFakeMlxModel:
    config = SimpleNamespace(tts_model_type="voice_design")

    def generate(self, **kwargs: object):
        del kwargs
        yield SimpleNamespace(
            sample_rate=24_000,
            audio=np.full(2_400, 0.5, dtype=np.float32),
            is_final_chunk=False,
        )
        yield SimpleNamespace(
            sample_rate=24_000,
            audio=np.full(2_400, 0.5, dtype=np.float32),
            is_final_chunk=True,
        )


def test_mlx_voice_design_engine_fades_only_logical_synthesis_boundaries(
    tmp_path: Path,
) -> None:
    engine = MlxVoiceDesignEngine(
        tmp_path,
        device="mps",
        load_fn=lambda _: SequencedFakeMlxModel(),
        numpy_module=np,
        warmup=False,
    )

    chunks = list(engine.synthesize("边界测试", voice="default", speed=1.0, language="zh"))
    first = np.frombuffer(chunks[0], dtype="<i2")
    final = np.frombuffer(chunks[1], dtype="<i2")

    assert abs(int(first[0])) < 100
    assert abs(int(first[1_200]) - 16_383) < 100
    assert abs(int(first[-1]) - 16_383) < 100
    assert abs(int(final[0]) - 16_383) < 100
    assert abs(int(final[1_200]) - 16_383) < 100
    assert abs(int(final[-1])) < 100
```

- [x] **Step 3: 运行测试并确认当前代码失败**

Run:

```bash
uv run --extra dev pytest tests/test_qwen3_tts_voice_design.py::test_mlx_voice_design_engine_fades_only_logical_synthesis_boundaries -q --no-cov
```

Expected: FAIL，`first[0]` 仍约为 `16383`，证明生产生成循环没有 fade-in。

- [x] **Step 4: 写空块与单块失败测试**

追加两个 fake 和测试：

```python
class EmptyThenSequencedFakeMlxModel:
    config = SimpleNamespace(tts_model_type="voice_design")

    def generate(self, **kwargs: object):
        del kwargs
        yield SimpleNamespace(
            sample_rate=24_000,
            audio=np.array([], dtype=np.float32),
            is_final_chunk=False,
        )
        yield SimpleNamespace(
            sample_rate=24_000,
            audio=np.full(2_400, 0.5, dtype=np.float32),
            is_final_chunk=False,
        )
        yield SimpleNamespace(
            sample_rate=24_000,
            audio=np.full(2_400, 0.5, dtype=np.float32),
            is_final_chunk=True,
        )


class SingleFinalFakeMlxModel:
    config = SimpleNamespace(tts_model_type="voice_design")

    def generate(self, **kwargs: object):
        del kwargs
        yield SimpleNamespace(
            sample_rate=24_000,
            audio=np.full(2_400, 0.5, dtype=np.float32),
            is_final_chunk=True,
        )


def test_mlx_voice_design_engine_ignores_empty_chunk_before_fade_in(tmp_path: Path) -> None:
    engine = MlxVoiceDesignEngine(
        tmp_path,
        device="mps",
        load_fn=lambda _: EmptyThenSequencedFakeMlxModel(),
        numpy_module=np,
        warmup=False,
    )
    first = np.frombuffer(
        list(engine.synthesize("空块测试", voice="default", speed=1.0, language="zh"))[0],
        dtype="<i2",
    )
    assert abs(int(first[0])) < 100


def test_mlx_voice_design_engine_fades_both_ends_of_single_final_chunk(
    tmp_path: Path,
) -> None:
    engine = MlxVoiceDesignEngine(
        tmp_path,
        device="mps",
        load_fn=lambda _: SingleFinalFakeMlxModel(),
        numpy_module=np,
        warmup=False,
    )
    samples = np.frombuffer(
        list(engine.synthesize("单块测试", voice="default", speed=1.0, language="zh"))[0],
        dtype="<i2",
    )
    assert abs(int(samples[0])) < 100
    assert abs(int(samples[1_200]) - 16_383) < 100
    assert abs(int(samples[-1])) < 100
```

- [x] **Step 5: 运行两项测试并确认失败**

Run:

```bash
uv run --extra dev pytest \
  tests/test_qwen3_tts_voice_design.py::test_mlx_voice_design_engine_ignores_empty_chunk_before_fade_in \
  tests/test_qwen3_tts_voice_design.py::test_mlx_voice_design_engine_fades_both_ends_of_single_final_chunk \
  -q --no-cov
```

Expected: 两项均 FAIL，首个非空块仍以非零样本开始。

- [x] **Step 6: 最小接入 `apply_crossfade`**

在 worker 的 domain import 中加入 `apply_crossfade`。保留当前 `_generate()` 中已有的 profile、seed、
temperature 与 model 参数，仅把结果循环改成以下状态机：

```python
first_chunk = True
for result in self._model.generate(
    text=text,
    voice=None,
    instruct=profile.instruction,
    speed=speed,
    lang_code=language,
    max_tokens=generation_token_budget(text),
    repetition_penalty=self._repetition_penalty,
    temperature=used_temperature,
    top_p=self._top_p,
    stream=True,
    streaming_interval=self._chunk_ms / 1000,
):
    pcm = self._to_pcm(result)
    if not pcm:
        continue
    if first_chunk:
        pcm = apply_crossfade(
            pcm,
            sample_rate=self._sample_rate,
            fade_ms=5,
            fade_in=True,
            fade_out=False,
        )
        first_chunk = False
    yield pcm
```

不要修改 `_to_pcm()` 的最终块静音裁剪和 fade-out。

- [x] **Step 7: 运行 TTS 边界回归**

Run:

```bash
uv run --extra dev pytest \
  tests/test_qwen3_tts_voice_design.py \
  tests/test_qwen3_tts_worker.py \
  tests/test_tts_streaming_splitter.py \
  -q --no-cov
```

Expected: 全部 PASS；首块、中间块、空块和最终块语义都被锁定。

- [x] **Step 8: 运行完整门禁并提交行为修复**

Run:

```bash
uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
git diff --check
git add src/speechrail/backends/qwen3_tts_worker.py tests/test_qwen3_tts_voice_design.py
git diff --staged
git commit -m "fix(tts): 补齐合成片段首块淡入"
```

Expected: 完整门禁先通过，staged diff 只包含本 Task 两个文件且不改写 `d4a7c9f` 已收口的逻辑。

---

### Task 2: SpeechRail 1.6.9 发布制品

**Files:**
- Modify: `pyproject.toml`
- Modify: `uv.lock`
- Modify: `src/speechrail/__init__.py`
- Modify: `src/speechrail/config/__init__.py`
- Modify: `tests/test_app_contract.py`
- Modify: `tests/test_release_verification.py`
- Modify: `tests/test_installer.py`
- Modify: `CHANGELOG.md`
- Add: `docs/superpowers/specs/2026-09-05-tts-segment-boundary-stability-design.md`
- Add: `docs/superpowers/plans/2026-09-05-tts-segment-boundary-stability.md`

**Interfaces:**
- Consumes: Task 1 已提交的首块淡入行为。
- Produces: `dist/speechrail-1.6.9-py3-none-any.whl`。

- [x] **Step 1: 将版本事实统一提升到 1.6.9**

把以下 `1.6.8` 改为 `1.6.9`：

```text
pyproject.toml                         version = "1.6.9"
src/speechrail/__init__.py            __version__ = "1.6.9"
src/speechrail/config/__init__.py     version: str = "1.6.9"
tests/test_app_contract.py            两处期望版本 1.6.9
tests/test_release_verification.py    speechrail-1.6.9.dist-info/METADATA
tests/test_installer.py               speechrail-1.6.9-py3-none-any.whl
```

- [x] **Step 2: 更新 lock 与 changelog**

Run:

```bash
uv lock
```

Expected: `uv.lock` 的本地 package 版本为 `1.6.9`，无无关依赖升级。

在空的 `[Unreleased]` 后新增：

```markdown
## [1.6.9] - 2026-09-05

### Fixed

- **TTS 独立合成片段首块淡入补齐**：Qwen3-TTS worker 现在只对每次合成的首个非空
  PCM 块应用一次 5 ms fade-in，并保留最终块 fade-out；中间流式块不做逐块音量处理，
  避免实时分句在静音到非零首样本之间产生 click，同时保持 REST/Realtime 契约不变。
```

- [x] **Step 3: 运行版本与发布测试**

Run:

```bash
uv run --extra dev pytest \
  tests/test_version_consistency.py \
  tests/test_app_contract.py \
  tests/test_release_verification.py \
  tests/test_installer.py \
  -q --no-cov
```

Expected: 全部 PASS，所有版本事实源一致。

- [x] **Step 4: 运行完整门禁并构建 wheel**

Run:

```bash
uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
git diff --check
uv build --no-sources --wheel
python3 -m zipfile -l dist/speechrail-1.6.9-py3-none-any.whl | rg 'qwen3_tts_worker|METADATA'
```

Expected: 所有 gate 通过；wheel 包含 `speechrail/backends/qwen3_tts_worker.py` 和
`speechrail-1.6.9.dist-info/METADATA`。

- [x] **Step 5: 提交发布元数据与迁移后的 SpeechRail 文档**

Run:

```bash
git add \
  pyproject.toml uv.lock CHANGELOG.md \
  src/speechrail/__init__.py src/speechrail/config/__init__.py \
  tests/test_app_contract.py tests/test_release_verification.py tests/test_installer.py \
  docs/superpowers/specs/2026-09-05-tts-segment-boundary-stability-design.md \
  docs/superpowers/plans/2026-09-05-tts-segment-boundary-stability.md
git diff --staged
git commit -m "chore: 发布 SpeechRail 1.6.9"
```

Expected: staged diff 不包含工作区既有的 voice registry、HTTP route、ADR 或 archive 文档改动。

---

### Task 3: 版本化部署、真实 PCM 验收与回退

**Files/State:**
- Deploy: `dist/speechrail-1.6.9-py3-none-any.whl`
- Preserve: 私有配置、外部模型、上一版 `runtime/current`、`runtime/releases/`
- Runtime change: 重启 `com.speechrail`

**Interfaces:**
- Consumes: Task 2 wheel。
- Produces: SpeechRail 1.6.9 服务身份与真实 PCM 验收记录。

- [x] **Step 1: 记录精确回退目标和部署前健康状态**

Run:

```bash
SPEECHRAIL_APP_HOME_PATH="$HOME/Library/Application Support/SpeechRail"
SPEECHRAIL_PREVIOUS_RELEASE_PATH="$(readlink "$SPEECHRAIL_APP_HOME_PATH/runtime/current")"
test -n "$SPEECHRAIL_PREVIOUS_RELEASE_PATH"
test -x "$SPEECHRAIL_PREVIOUS_RELEASE_PATH/.venv/bin/python"
printf '%s\n' "$SPEECHRAIL_PREVIOUS_RELEASE_PATH"
uv run speechrail service status --app-home "$SPEECHRAIL_APP_HOME_PATH"
curl -s http://127.0.0.1:8201/health
curl -s http://127.0.0.1:8201/readyz
curl -s http://127.0.0.1:8201/v1/models
curl -s http://127.0.0.1:8201/v1/voices
```

Expected: release 路径为非空绝对路径，四个端点成功；不得输出私有 `.env`。

- [x] **Step 2: 执行版本化安装**

此步骤改变真实运行态，只有获得当前用户明确授权后执行：

```bash
uv run speechrail service disable --app-home "$SPEECHRAIL_APP_HOME_PATH"
python3 tools/install_macos.py \
  --wheel dist/speechrail-1.6.9-py3-none-any.whl \
  --env-file "$SPEECHRAIL_APP_HOME_PATH/config/.env" \
  --app-home "$SPEECHRAIL_APP_HOME_PATH" \
  --enable
```

Expected: `runtime/current` 原子切换到 1.6.9，只运行一个服务实例，私有配置未被覆盖。

- [x] **Step 3: 验证部署身份与真实 PCM**

Run:

```bash
uv run speechrail service status --app-home "$SPEECHRAIL_APP_HOME_PATH"
curl -s http://127.0.0.1:8201/health
curl -s http://127.0.0.1:8201/readyz
curl -s http://127.0.0.1:8201/v1/models
curl -s http://127.0.0.1:8201/v1/voices
```

执行不会落盘 PCM、也不会输出 API key 的 REST smoke：

```bash
SPEECHRAIL_APP_HOME_PATH="$HOME/Library/Application Support/SpeechRail" \
uv run python - <<'PY'
from array import array
import os
from pathlib import Path

import httpx

from speechrail.config import Settings

app_home = Path(os.environ["SPEECHRAIL_APP_HOME_PATH"])
settings = Settings(_env_file=app_home / "config/.env")
headers = {"Authorization": f"Bearer {settings.api_key}"} if settings.api_key else {}
texts = (
    "这是短句边界测试。",
    "第一句用于检查开始边界。第二句用于检查多句连续合成。",
)
for text in texts:
    response = httpx.post(
        "http://127.0.0.1:8201/v1/audio/speech",
        headers=headers,
        json={
            "model": "speechrail/qwen3-tts",
            "input": text,
            "voice": "default",
            "response_format": "pcm",
            "speed": 1.0,
        },
        timeout=120.0,
    )
    response.raise_for_status()
    assert response.content and len(response.content) % 2 == 0
    samples = array("h")
    samples.frombytes(response.content)
    assert abs(samples[0]) < 100
    assert abs(samples[-1]) < 100
    assert max(abs(value) for value in samples) < 32760
    print({"bytes": len(response.content), "peak": max(abs(value) for value in samples)})
PY
```

Expected: 两次请求均成功，断言全部通过；输出只含字节数和峰值，不含文本、PCM 或 API key。
Realtime 事件顺序与 chunk index 由 Task 1 的 worker/streaming tests 和完整 gate 验证；人工试听两次
REST 结果时不得出现句首 click。

- [ ] **Step 4: 失败时恢复上一 release**

Run:

```bash
test -n "$SPEECHRAIL_PREVIOUS_RELEASE_PATH"
test -x "$SPEECHRAIL_PREVIOUS_RELEASE_PATH/.venv/bin/python"
uv run speechrail service disable --app-home "$SPEECHRAIL_APP_HOME_PATH"
ln -sfn "$SPEECHRAIL_PREVIOUS_RELEASE_PATH" "$SPEECHRAIL_APP_HOME_PATH/runtime/current"
"$SPEECHRAIL_APP_HOME_PATH/runtime/current/.venv/bin/python" \
  -m speechrail service install --app-home "$SPEECHRAIL_APP_HOME_PATH"
"$SPEECHRAIL_APP_HOME_PATH/runtime/current/.venv/bin/python" \
  -m speechrail service enable --app-home "$SPEECHRAIL_APP_HOME_PATH"
curl -s http://127.0.0.1:8201/health
curl -s http://127.0.0.1:8201/readyz
curl -s http://127.0.0.1:8201/v1/models
curl -s http://127.0.0.1:8201/v1/voices
```

Expected: `runtime/current` 恢复为 Step 1 的精确路径，服务定义来自上一 release，四个端点成功。
不得删除 releases、外部模型或私有配置。
