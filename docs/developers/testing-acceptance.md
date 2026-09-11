---
title: "SpeechRail 测试与验收"
status: active
date: 2026-09-11
---

# SpeechRail 测试与验收

## 自动化门禁

提交前运行：

```bash
cd <path-to-SpeechRail>
uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
git diff --check
```

官方 Node SDK 的分人 multipart wire contract 单独锁定在 `tests/openai-sdk-node/`，不参与服务的
运行时依赖：

```bash
npm ci --prefix tests/openai-sdk-node --ignore-scripts --no-audit --no-fund
npm test --prefix tests/openai-sdk-node
```

测试使用 fake backend 和合成/脱敏数据，不加载模型、不访问网络，也不提交真实音频。
至少覆盖：模型 aliases、ASR/TTS 错误 envelope、上传限制、队列、REST 响应格式、voice
registry、worker frame 协议、snapshot preflight、Realtime v1 的 update/append/flush/commit/
cancel 顺序、TTS chunk 顺序与背压，以及 legacy config/EOF 行为。

## 真实 worker smoke

在完整外部 snapshot 和 runtime 配置下：

```bash
curl http://127.0.0.1:8201/health
curl http://127.0.0.1:8201/readyz
curl http://127.0.0.1:8201/v1/models
curl http://127.0.0.1:8201/v1/voices
curl -X POST http://127.0.0.1:8201/v1/audio/transcriptions \
  -F 'file=@sample.wav' \
  -F 'model=speechrail/qwen3-asr-1.7b' \
  -F 'language=zh' \
  -F 'response_format=verbose_json'
curl -X POST http://127.0.0.1:8201/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{"model":"speechrail/qwen3-tts","input":"SpeechRail smoke test.","voice":"default","response_format":"pcm"}' \
  -o /tmp/speechrail-smoke.pcm
```

验收 HTTP 状态、非空文本/偶数字节音频、`X-Request-ID`、模型设备/dtype 与预期 profile。
测试音频和 `/tmp/speechrail-smoke.pcm` 由操作者本地保存，结束后删除；提交/报告只保留最小
结果摘要而非文本、音频或 PCM。

## 档位与分人供给测试清单

catalog v2（按档位精度策略、aligner 作为分人制品、diarization 按档门控）由以下确定性测试文件覆盖：

| 关注点 | 测试文件与代表用例 |
|---|---|
| v2 catalog 契约：`precision_policy`、preset `aligner`/`diarization`、schema v2、aligner 身份 | `tests/test_model_presets.py`（`test_load_catalog_matches_tier_precision_policy`、`test_light_tier_uses_q8_quantization_under_schema_v2`）、`tests/test_model_identity.py`（`test_aligner_artifact_*`）、`tests/test_model_catalog_builder.py`（`test_legal_metadata_produces_schema_v2_with_precision_policy`）|
| selection 依档覆盖 aligner 目录、`light` 清空分人、aligner snapshot 缺失 fail closed | `tests/test_profile_selection.py`（`test_selection_overlays_aligner_dir_by_preset`、`test_light_selection_clears_aligner_and_diarization`、`test_missing_aligner_directory_raises`）|
| `diarization_assets` 按档供给：`light` 不产物、`balanced`=`aligner-q8`、`quality`=`aligner-bf16`、复用/损坏/未知档 | `tests/test_installer.py`（`test_prepare_diarization_assets_*`）|
| preflight aligner 门控：未设置时跳过、缺 CoreML 时仍校验、不完整 snapshot 拒绝 | `tests/test_service_preflight.py`（`test_preflight_skips_aligner_snapshot_when_aligner_dir_unset`、`test_preflight_checks_aligner_snapshot_without_coreml_bundle`、`test_preflight_rejects_incomplete_aligner_snapshot`）|
| `profile apply` 写/删分人键、三档互切、供给失败显式报错 | `tests/test_profile_commands.py`（`test_apply_light_removes_diarization_env`、`test_apply_balanced_writes_diarization_env`、`test_diarization_prepare_failure_is_explicit`）|
| installer / zero-setup 按档门控分人供给与 smoke | `tests/test_installer.py`（`test_managed_install_*diarization*`）、`tests/test_video_podcast_skill_install.py`（`test_zero_setup_light_skips_diarization_smoke`、`test_zero_setup_balanced_runs_diarization_smoke`）|

这些测试使用 fake backend 与脱敏 fixture，不加载真实模型、不下载 aligner。

## 集成验收矩阵

| 客户端/接口 | 当前状态 | 通过条件 |
|---|---|---|
| REST curl | 已完成本机 smoke | health / readyz / models 正常，短音频得到结果 |
| REST TTS | 契约与 fake backend 已覆盖 | `/v1/voices` 有登记 preset，短文本返回 24 kHz PCM/WAV；真实 runtime 需另验收 |
| QwenPaw `whisper_api` | 已完成本机 smoke | provider 指向 `8201/v1`、应用完整重启、短中文音频有文本 |
| OpenAI SDK | 可按兼容契约接入 | multipart 调用和错误处理符合 OpenAPI |
| Hermes Agent | 待验收 | STT 专用 base URL/model 生效且不改变聊天 endpoint |
| `/v1/realtime` | 协议测试 | update → append → commit → 一次 completed；不要求 delta |
| `/v1/realtime` ASR/TTS | fake backend 协议测试 | OpenAI 事件顺序、取消、背压、terminal event 和 diarization 边界；真实 worker 需另验收 |
| `sona` adapter | 确定性边界已覆盖 | ASR/TTS 真实音频、播放和回滚 smoke 通过；不以 legacy `/asr` 作为替换结论 |

每次发布保存命令、时间、版本/commit、测试摘要、OpenAPI lint、设备/dtype、request ID 与
未验证风险。命令退出码不能单独替代 API 响应或客户端行为证据。
