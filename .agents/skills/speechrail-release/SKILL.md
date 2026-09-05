---
name: speechrail-release
description: >-
  SpeechRail 本机版本发布 SOP。用于判定 SemVer、更新版本与 CHANGELOG、执行代码门、
  构建 wheel、原子替换 managed/explicit-env LaunchAgent 服务、按版本类型选择性能基准、
  验证与回滚。触发词：发布、release、版本号、bump、构建 wheel、安装新版本、tag。
---

# SpeechRail 版本发布 SOP

目标是交付一个可验证、可回退的本机 wheel release。发布流程不得下载未在 catalog 中锁定的模型，不覆盖用户配置，不同时运行两个服务实例。

## 1. 确定版本与验收范围

以 `pyproject.toml` 的 `[project].version` 为版本事实来源。先比较上一 tag 到 `HEAD` 的用户可见变化，再选择：

| 类型 | 条件 | 性能基准 |
|---|---|---|
| PATCH | 兼容 bug、安全、稳定性或性能修复；不增加公共能力，不改变档位组合 | 只测当前部署档位 |
| MINOR | 新增兼容 API、模型档位、音色能力、运行时能力或明显改变默认行为 | 串行测 `quality`、`balanced`、`light`，结束恢复原档 |
| MAJOR | 破坏公共契约或迁移要求 | 三档完整基准，并验证迁移与兼容期；必须有 ADR/迁移文档 |

纯文档修改通常不单独发版。无法确定类型时取更高一级，避免漏测。

## 2. 前置快照

```bash
git status --short
git log -5 --oneline
git describe --tags --abbrev=0
speechrail profile status --app-home "$HOME/Library/Application Support/SpeechRail"
speechrail service status --app-home "$HOME/Library/Application Support/SpeechRail"
```

记录当前 commit、tag、active profile、selection generation、`runtime/current` 目标和服务 PID。确认 label 为 `com.speechrail`、端口为 `8201`，保留上一 release、selection 和私有配置作为回退点。

## 3. 更新发布材料

以下位置必须与新版本一致；以字段定位，不依赖行号：

| 文件 | 字段 |
|---|---|
| `pyproject.toml` | `[project].version` |
| `src/speechrail/__init__.py` | `__version__` |
| `src/speechrail/config/__init__.py` | `Settings.version` 默认值 |
| `contracts/openapi.yaml` | `info.version` 与 `/health` example |
| `configs/speechrail.example.env` | `SPEECHRAIL_VERSION` |
| `configs/speechrail.example.yaml` | `service.version` |
| `tests/test_app_contract.py` | 两处 `/health` 断言 |
| `tests/test_installer.py` | wheel fixture 名 |
| `tests/test_release_verification.py` | dist-info fixture 名 |
| `uv.lock` | 项目包版本，由 `uv lock` 生成 |
| `CHANGELOG.md` | 新版本条目，并保留空的 `[Unreleased]` |

不要改 worker 帧协议的整数 `version: 1`、历史 CHANGELOG 标题或归档报告中的旧版本。正式文档 front matter 只在正文实质变化时更新。

```bash
uv lock
uv run python scripts/check_version_consistency.py
uv run --extra dev python -c "from speechrail.config import Settings; print(Settings().version)"
```

第二条必须 exit 0，第三条必须输出新版本。检查私有 managed 配置是否含 `SPEECHRAIL_VERSION`；该键会覆盖 wheel 默认版本。若存在，先在仓库外创建权限为 `0600` 的备份，再原子删除该单行，使后续版本来自已安装 wheel。不得输出配置全文。

## 4. 发布门

```bash
uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
plutil -lint deploy/macos/com.speechrail.plist.example
git diff --check
```

检查结果内容与测试数量，不以退出码摘要替代证据。构建前按逻辑主题提交代码、文档和版本材料；不要提交 `.env`、模型、音频、原始 benchmark 数据、日志或 `dist/`。

## 5. 构建并校验 wheel

```bash
uv build --no-sources --wheel
python3 -m zipfile -l dist/speechrail-<version>-py3-none-any.whl
```

确认文件名、包 metadata、worker 模块、assets 和版本一致。保存 wheel SHA-256 供本机审计；构建产物不提交 Git。

## 6. 替换本机服务

### 6.1 Managed 三档安装（默认）

先停旧服务，再用当前 profile 安装新 wheel。`install_managed` 会复用已校验模型和 lock-keyed vendor runtime，在新 release 中 preflight，原子切换 `runtime/current`，重新安装并启用 LaunchAgent。

```bash
APP_HOME="$HOME/Library/Application Support/SpeechRail"
uv run speechrail service disable --app-home "$APP_HOME"
APP_HOME="$APP_HOME" WHEEL="dist/speechrail-<version>-py3-none-any.whl" uv run python - <<'PY'
import os
from pathlib import Path

import httpx

from speechrail.service.modelscope import ModelScopeDownloader
from speechrail.service.profile_commands import profile_status
from tools.install_macos import install_managed

app_home = Path(os.environ["APP_HOME"])
wheel = Path(os.environ["WHEEL"])
status = profile_status(app_home)
if status.preset not in {"quality", "balanced", "light"}:
    raise SystemExit("managed profile is unavailable")
with httpx.Client(timeout=httpx.Timeout(connect=30, read=300, write=30, pool=30)) as client:
    result = install_managed(
        wheel,
        app_home=app_home,
        preset_id=status.preset,
        downloader=ModelScopeDownloader(client=client),
        env_file=app_home / "config" / ".env",
        enable=True,
    )
print(result.runtime_python)
PY
```

这一步允许短暂停服。不要在 wheel 替换时顺便改变 profile；模型档位切换用 `speechrail profile apply` 独立执行。

### 6.2 Explicit-env 安装（仅非 managed 部署）

```bash
APP_HOME="$HOME/Library/Application Support/SpeechRail"
uv run speechrail service disable --app-home "$APP_HOME"
python3 tools/install_macos.py \
  --wheel "dist/speechrail-<version>-py3-none-any.whl" \
  --env-file "$APP_HOME/config/.env" \
  --app-home "$APP_HOME" \
  --enable
```

不要对已有 managed selection 使用 legacy installer。

## 7. 运行态验证

模型加载期间使用有界轮询，不固定假设 30 秒：

```bash
APP_HOME="$HOME/Library/Application Support/SpeechRail"
uv run speechrail service status --app-home "$APP_HOME"
curl --fail http://127.0.0.1:8201/health
curl --fail http://127.0.0.1:8201/readyz
curl --fail http://127.0.0.1:8201/v1/models
curl --fail http://127.0.0.1:8201/v1/voices
readlink "$APP_HOME/runtime/current"
uv run python scripts/verify_release.py \
  --wheel "dist/speechrail-<version>-py3-none-any.whl" \
  --app-home "$APP_HOME"
```

必须确认：

- `state=running`，PID 使用 `runtime/current/.venv/bin/python`；
- `/health.version` 是新版本，`asr_ready=true`、`tts_ready=true`；
- `/readyz` 为 200；
- `/v1/models` 声明实际 profile、artifact、variant 与 quantization；
- `/v1/voices` 返回九个 canonical system roles，且能力与当前权重一致；
- 公共 ASR 与 TTS 使用真实、非敏感 fixture 返回 200、非空结果和 request ID。

## 8. 发布性能基准

调用 `.agents/skills/speechrail-perf-benchmark/SKILL.md`：

- PATCH：只测步骤 2 记录的 active profile；
- MINOR：按 active → 其余两档 → active 串行测三档；
- MAJOR：三档完整测量并增加迁移/兼容验证。

报告写入 `docs/archive/performance/YYYY-MM-DD-v<version>-performance-benchmark.md`，更新性能归档索引。README 只保留面向用户的少量稳定指标，不复制完整报告。

## 9. 提交与 tag

重新运行版本一致性和 `git diff --check`，确认 benchmark 报告记录的是已安装 wheel。然后：

```bash
git tag v<version>
```

创建 tag 前确认工作树干净、tag 指向包含发布报告的目标 commit、同名 tag 不存在。只有当前任务明确授权远端发布时才执行 `git push origin <branch>` 与 `git push origin v<version>`；禁止 force-push。

## 10. 回滚

1. 停用 `com.speechrail`。
2. 将 `runtime/current` 恢复为前置快照记录的旧 release。
3. 恢复旧 LaunchAgent 定义；managed 部署同时保留/恢复旧 selection 与 vendor `current`。
4. 启用旧服务并重新验证 `/health`、`/readyz`、`/v1/models`、`/v1/voices` 和真实 smoke。
5. 不删除旧 release、模型、私有配置或日志。

## 完成清单

- [ ] SemVer 与 benchmark scope 已判定
- [ ] 版本一致性、pytest、ruff、mypy、OpenAPI、plist、diff gate 全部通过
- [ ] wheel 已验证并原子替换服务
- [ ] 新版本、profile、模型、音色和真实 ASR/TTS smoke 已核对
- [ ] PATCH 当前档或 MINOR/MAJOR 三档基准已归档
- [ ] active profile 已恢复，回退点仍存在
- [ ] 发布 commit 与本地 tag 已创建；远端操作符合当前授权
