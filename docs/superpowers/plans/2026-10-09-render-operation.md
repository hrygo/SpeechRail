# 渲染准备与执行所有权 Implementation Plan

> **For agentic workers:** 使用 `executing-plans` 在当前会话逐项实施。用户已要求逐个处理短时可验证 Issue；本计划不授权提交、推送、合并或运行态操作。

**Goal:** 按 #226 拆出纯准备、单次渲染执行与交付收尾，保持现有 HTTP 合同。

**Architecture:** `render_preparation.py` 从已验证请求、音色和发音规则构造不可变准备结果；`render_operation.py` 持有单次执行依赖、deadline、reservation 与 receipt/timing。HTTP adapter 保留鉴权、前置错误顺序、媒体编码及 ASGI send/disconnect，并报告交付结果。

**Tech Stack:** Python 3.14、现有 SpeechRequest/RenderRecipe、ResourceGovernor、pytest fake。

**Spec:** GitHub #226 验收矩阵及当前 `audio.py`、`tts_delivery.py` 清理合同。

## Global Constraints

- 保留 #223 的唯一音色存储与 typed execution port。
- 不改变公开协议、用户数据、模型策略或编码缓冲上限。
- 后端 iterator 关闭前不退出 reservation；重复取消保留清理 task。
- HTTP Request/Response 不进入应用用例；不注入完整 AppServices。
- 不运行模型、UI、长稳或完整套件。

## Review Focus

- 首块已预取但 body 未开始时，关闭仍回收 backend。
- ASGI send 失败与 backend 回收事实分别处理。
- close 失败维持隔离，不能产生完成回执。
- timing 的声学/显示坐标和 unknown 保持现有定义。
- 每个请求有独立 operation，旧清理不能操作新 receipt。

### Task 1: 纯准备

**Files:** 新增 `application/render_preparation.py`、`tests/test_render_operation.py`；修改 `http/routes/audio.py`。

**Interfaces:** `prepare_render(request, *, profile, artifact, output_format, sample_rate, pronunciation=None, integrity=False) -> RenderPreparation`，结果包含 SpeechRequest、可选 RenderRecipe、摘要和可选 timing 坐标。

- [ ] 用纯系统音色、SpeechRequest 直接验证不依赖 HTTP、不虚构 runtime/seed、归一化导致显示坐标未知。
- [ ] 运行 `uv run --no-sync pytest --no-cov tests/test_render_operation.py`，先确认新入口缺失。
- [ ] 将现有准备计算迁入纯函数，路由保留发音 registry 查询和 begin 错误映射。
- [ ] 执行新测试和 receipt/timing/发音路由回归。

### Task 2: 执行与交付 owner

**Files:** 新增 `application/render_operation.py`；修改 `http/routes/audio.py`。

**Interfaces:** `RenderOperation.pcm(counter=None)`、`deliver(source, first, counter)`、`close_delivery()`；明确依赖 batch port、execution ports、voice directory、Governor、receipt/timing registry 与 metrics。

- [ ] 小型 fake 验证正常 PCM、首块预取后关闭、清理失败隔离、取消与同一 deadline。
- [ ] 按现有 audio_stream 顺序迁移 reserve、strict prepare、validated PCM、身份/计量及 timing。
- [ ] 两种流交付共享有限 owner；媒体编码及 ASGI 包装留在 adapter。
- [ ] 跑 `test_speech_api.py`、`test_render_receipts.py`、`test_render_receipt_routes.py`、`test_tts_delivery.py`、`test_tts_timing_routes.py`、`test_interface_parity.py`。

### Task 3: 验证与记录

**Files:** 更新 `docs/architecture/voice-validation-usecases.md` 与短时 Issue 交付记录。

- [ ] 定向 Mypy、Ruff、diff check；核对首块/body/send/取消/失败/cleanup 回归。
- [ ] 记录实测命令、数量、时间与剩余风险。只在对应证据存在时报告完成。
