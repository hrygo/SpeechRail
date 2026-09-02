# SpeechRail Application Composition Refactor Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task-by-task, with a review checkpoint after each commit.

**Goal:** 在不改变 `create_app(...)` 调用签名、HTTP/WebSocket 契约、错误 envelope 或运行时所有权的前提下，把 `src/speechrail/app.py` 拆成可独立测试的组合根、生命周期对象和窄路由模块。

**Architecture:** `app.py` 只解析 overrides、创建 `AppServices`、安装 middleware/exception handler、注册 routers 与 FastAPI lifespan。`application/` 组合具体 backend、队列、Resource Governor、jobs 和进程生命周期；`http/routes/` 只处理 FastAPI 输入输出；domain port 与 backend adapter 保持现有依赖方向。

**Tech Stack:** Python 3.12、FastAPI lifespan、Pydantic v2、asyncio、pytest、Ruff、mypy、OpenAPI。

---

## 执行边界

- 工作目录：`<path-to-SpeechRail>`
- 先执行：无；这是 SpeechRail DRY/SOLID 总控计划的第一阶段。
- 后续依赖：`2026-09-01-speechrail-tts-delivery-refactor.md` 依赖本计划创建的 `http/routes/audio.py` 与 `http/routes/realtime_v2.py`。
- 公共入口必须保持以下签名兼容：

```python
def create_app(
    settings: Settings | None = None,
    *,
    transcribe: Transcribe | None = None,
    v2_transcriber: BatchTranscriber | None = None,
    realtime_asr_factory: RealtimeAsrFactory | None = None,
    diarization_engine: DiarizationEngine | None = None,
    tts_synthesizer: SpeechSynthesizer | None = None,
    job_repository: JobRepository | None = None,
    job_processor: JobProcessor | None = None,
) -> FastAPI:
    ...
```

- 保持公开路径：`/health`、`/readyz`、`/v1/models`、`/v1/voices`、`/v1/audio/transcriptions`、`/v1/audio/speech`、`/v1/jobs`、`/v1/realtime`、`/v2/realtime`、`/asr`。
- 保持当前安全差异：健康/模型/voice 清单仍可直接读取；受保护的 HTTP/WS 路径继续使用既有 Bearer 规则；`/asr` 仍是仅限 loopback 的 legacy 骨架，不借重构扩权。
- 执行前若工作树已包含 `_resolve_ffmpeg()`，必须保留 `PATH → /opt/homebrew/bin/ffmpeg → /usr/local/bin/ffmpeg` 的解析顺序和 `audio_decode_failed` 语义；route 拆分只移动 helper，不退回硬编码 `"ffmpeg"`。
- 用 FastAPI lifespan 取代当前 `@app.on_event("startup")` / `@app.on_event("shutdown")`，但启动顺序必须保持 `repository recovery → ASR worker → TTS worker → JobRunner`，关闭顺序保持反向且幂等。
- 不修改 `contracts/`、模型配置、数据库格式或真实 runtime；发现契约行为缺口时停止本计划并另立行为变更任务。

## 目标文件

- Create: `src/speechrail/application/__init__.py`
- Create: `src/speechrail/application/services.py`
- Create: `src/speechrail/application/lifecycle.py`
- Create: `src/speechrail/http/auth.py`
- Create: `src/speechrail/http/errors.py`
- Create: `src/speechrail/http/routes/__init__.py`
- Create: `src/speechrail/http/routes/system.py`
- Create: `src/speechrail/http/routes/audio.py`
- Create: `src/speechrail/http/routes/jobs.py`
- Create: `src/speechrail/http/routes/realtime_v1.py`
- Create: `src/speechrail/http/routes/realtime_v2.py`
- Create: `src/speechrail/http/routes/legacy.py`
- Modify: `src/speechrail/app.py`
- Create: `tests/test_application_composition.py`
- Modify: `tests/test_app_contract.py`
- Modify: `tests/test_transcription_api.py`
- Modify: `tests/test_speech_api.py`
- Modify: `tests/test_jobs_api.py`
- Modify: `tests/test_websocket_contract.py`
- Modify: `tests/test_realtime_v2_websocket.py`
- Modify: `tests/test_wlk_compatibility.py`
- Modify: `tests/test_tts_voices_api.py`
- Modify: `tests/test_security_boundaries.py`

## Task 1: 固化完整路由与生命周期基线

**Files:**

- Create: `tests/test_application_composition.py`
- Modify: 上述现有 HTTP/WS 契约测试，仅补缺失断言，不改生产代码

- [ ] **Step 1: 增加生命周期回滚测试**

使用 fake worker、fake repository 和 fake JobRunner 记录调用顺序。测试必须覆盖：部分启动失败时已启动资源被关闭；正常退出只关闭一次；纯 fake override 不创建真实 Qwen worker。

```python
async def test_lifespan_rolls_back_started_components() -> None:
    calls: list[str] = []
    lifecycle = FakeLifecycle(calls=calls, fail_on="tts.start")

    with pytest.raises(RuntimeError, match="tts.start"):
        async with lifecycle.run():
            pass

    assert calls == ["repository.recover", "asr.start", "tts.start", "asr.close"]
```

- [ ] **Step 2: 补齐路由保护断言**

至少锁定 `X-Request-ID`、`Cache-Control: no-store`、HTTP 401 envelope、WS close code `1008/1013`、v1 commit 后 batch、v2 terminal event、legacy config/EOF、jobs owner scope 和 `/v1/voices` 投影。

- [ ] **Step 3: 运行基线**

```bash
uv run --extra dev pytest \
  tests/test_app_contract.py \
  tests/test_transcription_api.py \
  tests/test_speech_api.py \
  tests/test_jobs_api.py \
  tests/test_websocket_contract.py \
  tests/test_realtime_v2_websocket.py \
  tests/test_wlk_compatibility.py \
  tests/test_tts_voices_api.py \
  tests/test_security_boundaries.py \
  -q --no-cov
```

预期：现有测试通过；新增生命周期测试因目标接口尚不存在而失败。若既有测试先失败，记录并先处理基线，不把失败归因于重构。

- [ ] **Step 4: 提交基线测试**

```bash
git add tests/test_application_composition.py tests/test_app_contract.py \
  tests/test_transcription_api.py tests/test_speech_api.py tests/test_jobs_api.py \
  tests/test_websocket_contract.py tests/test_realtime_v2_websocket.py \
  tests/test_wlk_compatibility.py tests/test_tts_voices_api.py \
  tests/test_security_boundaries.py
git commit -m "test: freeze speechrail application behavior"
```

## Task 2: 提取组合对象与 FastAPI lifespan

**Files:**

- Create: `src/speechrail/application/services.py`
- Create: `src/speechrail/application/lifecycle.py`
- Create: `src/speechrail/application/__init__.py`
- Modify: `src/speechrail/app.py`
- Modify: `tests/test_application_composition.py`

- [ ] **Step 1: 定义不可变依赖快照与显式 override**

实现下列形状；字段使用仓库已有 port 类型，不把 `Request`、`UploadFile` 或 `WebSocket` 放入 application 层。

```python
Transcribe = Callable[[bytes, str | None, str], Awaitable[TranscriptResult]]


@dataclass(frozen=True, slots=True)
class AppOverrides:
    transcribe: Transcribe | None = None
    v2_transcriber: BatchTranscriber | None = None
    realtime_asr_factory: RealtimeAsrFactory | None = None
    diarization_engine: DiarizationEngine | None = None
    tts_synthesizer: SpeechSynthesizer | None = None
    job_repository: JobRepository | None = None
    job_processor: JobProcessor | None = None


@dataclass(frozen=True, slots=True)
class AppServices:
    settings: Settings
    transcribe: Transcribe | None
    v2_transcriber: BatchTranscriber | None
    realtime_asr_factory: RealtimeAsrFactory | None
    diarization_engine: DiarizationEngine | None
    tts_synthesizer: SpeechSynthesizer | None
    job_repository: JobRepository | None
    admission: AdmissionQueue
    governor: ResourceGovernor
    lifecycle: RuntimeLifecycle

    @property
    def asr_ready(self) -> bool: ...

    @property
    def tts_ready(self) -> bool: ...
```

把当前 `_CallableBatchTranscriber` 与 `Transcribe` alias 一并移到 `application/services.py`，由 `app.py` import 后继续用于兼容签名，避免 application 反向导入组合根。`asr_ready`/`tts_ready` 保持当前“injected component 无 `ready` 属性即视为 ready”的规则。

`build_app_services(settings, overrides) -> AppServices` 继续执行当前 Qwen/WLK/NeMo/job 的显式组合；请求路径不得触发模型下载或新建 worker。

- [ ] **Step 2: 实现单一生命周期所有者**

`RuntimeLifecycle.start()` 和 `RuntimeLifecycle.close()` 拥有 repository recovery、worker start/close 与 JobRunner task。失败时只清理已启动资源，重复 `close()` 不抛错、不重复终止新资源。

- [ ] **Step 3: 迁移到 FastAPI lifespan**

```python
@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    await services.lifecycle.start()
    try:
        yield
    finally:
        await services.lifecycle.close()
```

删除 `@app.on_event` 注册，保持没有 runtime 资源时 lifespan 仍可进入/退出。

- [ ] **Step 4: 运行红绿验证**

```bash
uv run --extra dev pytest tests/test_application_composition.py tests/test_app_contract.py -q --no-cov
uv run --extra dev ruff check src/speechrail/application src/speechrail/app.py tests/test_application_composition.py
uv run --extra dev mypy src
```

- [ ] **Step 5: 提交组合与生命周期**

```bash
git add src/speechrail/application src/speechrail/app.py tests/test_application_composition.py tests/test_app_contract.py
git commit -m "refactor: isolate speechrail application lifecycle"
```

## Task 3: 提取错误、认证、system 与 audio 路由

**Files:**

- Create: `src/speechrail/http/auth.py`
- Create: `src/speechrail/http/errors.py`
- Create: `src/speechrail/http/routes/__init__.py`
- Create: `src/speechrail/http/routes/system.py`
- Create: `src/speechrail/http/routes/audio.py`
- Modify: `src/speechrail/app.py`
- Modify: `tests/test_app_contract.py`
- Modify: `tests/test_transcription_api.py`
- Modify: `tests/test_speech_api.py`
- Modify: `tests/test_tts_voices_api.py`
- Modify: `tests/test_security_boundaries.py`

- [ ] **Step 1: 先为 route factory 写失败测试**

```python
def test_audio_router_can_be_built_from_fake_services(fake_services: AppServices) -> None:
    router = create_audio_router(fake_services)
    assert {route.path for route in router.routes} == {
        "/v1/audio/transcriptions",
        "/v1/audio/speech",
    }
```

- [ ] **Step 2: 提取公共 HTTP 边界 primitive**

`http/errors.py` 承载现有 error envelope、request-ID middleware 和 validation handler；`http/auth.py` 提供 `http_auth_error(request, settings) -> JSONResponse | None` 与 `websocket_is_authorized(websocket, settings) -> bool`。调用者仍决定哪些路径需要认证，禁止给健康或 legacy 路径追加新策略。

- [ ] **Step 3: 移动 system 与 audio 路由**

`create_system_router(services) -> APIRouter` 拥有四个只读端点；`create_audio_router(services) -> APIRouter` 拥有上传有界读取、固定 `ffmpeg` argv 解码、batch transcription、REST TTS 与 WAV 封装。将 `_resolve_ffmpeg()` 与 `_FFMPEG_FALLBACKS` 一并移动到该 transport 模块，更新 `tests/test_transcription_api.py` 的 monkeypatch import；保留 PATH/absolute fallback 顺序。只移动代码并改依赖引用，不改 status、media type 或错误 code。

- [ ] **Step 4: 运行聚焦回归并提交**

```bash
uv run --extra dev pytest tests/test_app_contract.py tests/test_transcription_api.py \
  tests/test_speech_api.py tests/test_tts_voices_api.py tests/test_security_boundaries.py \
  -q --no-cov
uv run --extra dev ruff check src/speechrail/http src/speechrail/app.py
uv run --extra dev mypy src
git add src/speechrail/http src/speechrail/app.py tests/test_app_contract.py \
  tests/test_transcription_api.py tests/test_speech_api.py tests/test_tts_voices_api.py \
  tests/test_security_boundaries.py
git commit -m "refactor: extract speechrail http routes"
```

## Task 4: 提取 jobs 与三类 WebSocket 路由

**Files:**

- Create: `src/speechrail/http/routes/jobs.py`
- Create: `src/speechrail/http/routes/realtime_v1.py`
- Create: `src/speechrail/http/routes/realtime_v2.py`
- Create: `src/speechrail/http/routes/legacy.py`
- Modify: `src/speechrail/app.py`
- Modify: `tests/test_jobs_api.py`
- Modify: `tests/test_websocket_contract.py`
- Modify: `tests/test_realtime_v2_websocket.py`
- Modify: `tests/test_wlk_compatibility.py`
- Modify: `tests/test_security_boundaries.py`

- [ ] **Step 1: 提取 jobs router**

`create_jobs_router(services) -> APIRouter` 保持 owner hash、repository readiness、202/404/503 和 cancel 语义；JobRunner 生命周期仍只在 `RuntimeLifecycle`，router 不创建 background task。

- [ ] **Step 2: 分版本提取 WebSocket router**

分别实现 `create_realtime_v1_router`、`create_realtime_v2_router` 与 `create_legacy_router`。v1/v2 不共享状态机；只复用认证和 error primitive。v2 内部的 ASR、TTS、diarization、backpressure、cancel 与 cleanup 顺序原样迁移。

- [ ] **Step 3: 将 `app.py` 收敛为组合根**

最终 `create_app` 只应完成：解析 settings/overrides、`build_app_services`、创建 FastAPI、安装 middleware/handlers、`include_router`、返回 app。保留 `app.state.settings` 兼容读取，但路由不从 `app.state` 猜测依赖。

- [ ] **Step 4: 运行完整路由回归**

```bash
uv run --extra dev pytest \
  tests/test_application_composition.py tests/test_app_contract.py \
  tests/test_transcription_api.py tests/test_speech_api.py tests/test_jobs_api.py \
  tests/test_websocket_contract.py tests/test_realtime_v2_websocket.py \
  tests/test_wlk_compatibility.py tests/test_tts_voices_api.py \
  tests/test_security_boundaries.py -q --no-cov
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
git diff --check
```

- [ ] **Step 5: 提交路由收口**

```bash
git add src/speechrail/app.py src/speechrail/http/routes \
  tests/test_jobs_api.py tests/test_websocket_contract.py \
  tests/test_realtime_v2_websocket.py tests/test_wlk_compatibility.py \
  tests/test_security_boundaries.py
git commit -m "refactor: separate speechrail websocket routes"
```

## Task 5: 项目门禁与人工审查

- [ ] **Step 1: 验证没有跨层倒置**

确认 `domain/` 不导入 FastAPI/backend，`application/` 不导入 route，backend 不导入 `app.py`，route 不直接实例化 Qwen/WLK/NeMo。

- [ ] **Step 2: 运行项目门禁**

```bash
uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
git diff --check
```

- [ ] **Step 3: 核对公开行为**

比较重构前后的路由集合、OpenAPI paths、错误 code、WS close code 与 terminal event fixture。没有真实外部 runtime 授权时，本计划只声明 fake/contract gate 通过，不声明真实 ASR/TTS 已验收。

## 完成标准

- [ ] `create_app(...)` 签名和所有公开路径不变。
- [ ] `@app.on_event` 已消失，lifespan 启停/回滚/幂等测试通过。
- [ ] `app.py` 不再含 endpoint 业务分支或具体 worker lifecycle。
- [ ] v1、v2、legacy 路由仍是三个显式协议边界。
- [ ] 全量 pytest、Ruff、mypy、OpenAPI lint 与 `git diff --check` 通过。
- [ ] 未修改 `contracts/`、外部模型、`.env`、运行服务或另一个仓库。
