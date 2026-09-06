---
name: speechrail-release
description: >-
  SpeechRail 本机版本发布 SOP。用于判定 SemVer、更新版本与 CHANGELOG、执行代码门、构建并安装 wheel、
  安全替换 managed/explicit-env LaunchAgent、验证启停与 profile 切换、回滚和留存发布证据。
  触发词：发布、release、版本号、bump、构建 wheel、安装新版本、tag。
---

# SpeechRail 版本发布 SOP

目标是交付一个可验证、可回退的本机 wheel release。发布允许停服和数分钟的启动真空，但任何候选版本都不得与旧实例并存，也不得在模型制品、配置或回退点未确认时切换运行态。

## 1. 先确定范围与发布锁

以 `pyproject.toml` 的 `[project].version` 为版本事实来源。先比较上一 tag 到 `HEAD` 的用户可见变化，再选择验收范围：

| 类型 | 条件 | 必测 profile |
|---|---|---|
| PATCH | 兼容 bug、安全、稳定性或性能修复；不增加公共能力和档位组合 | 当前 active profile |
| MINOR | 新增兼容 API、模型档位、音色/运行时能力或明显改变默认行为 | `quality`、`balanced`、`light`，结束恢复原档 |
| MAJOR | 破坏公共契约或迁移要求 | 三档完整套件，加迁移和兼容验证 |

无法确定时取更高一级。纯文档修改通常不单独发版；若改动影响共同 runtime、切换器或基准工具，至少按三档评估。

发布、`profile apply`、`profile rollback` 和 benchmark 切档必须串行；不要在同一 app home 上并行运行两个 operator、两个 installer 或两个 benchmark。

## 2. 前置快照与运行态边界

```bash
APP_HOME="${SPEECHRAIL_APP_HOME:-$HOME/Library/Application Support/SpeechRail}"
git status --short
git log -5 --oneline
git describe --tags --abbrev=0
speechrail profile status --app-home "$APP_HOME"
speechrail service status --app-home "$APP_HOME"
readlink "$APP_HOME/runtime/current"
lsof -nP -iTCP:8201 -sTCP:LISTEN
curl --fail http://127.0.0.1:8201/health
```

记录当前 commit、active profile、generation、runtime target、服务 PID、listener 数量、模型身份、旧 wheel hash 和可回退 selection/vendor runtime。必须确认只有一个 8201 listener，且 PID 属于 `runtime/current/.venv/bin/python`。工作树可以有与本发布无关的用户改动，但发布 commit、报告和 tag 只能包含明确归属本次 release 的文件。

执行 `speechrail service preflight --app-home "$APP_HOME"`，确认它通过 managed runtime 的 Python；不要从源码 `.venv` 推断已安装 wheel 的依赖。

## 3. 更新版本材料

以下位置必须与新版本一致；按字段定位，不依赖行号：

| 文件 | 字段 |
|---|---|
| `pyproject.toml` | `[project].version` |
| `src/speechrail/__init__.py` | `__version__` |
| `src/speechrail/config/__init__.py` | `Settings.version` 默认值 |
| `contracts/openapi.yaml` | `info.version` 与 `/health` example |
| `configs/speechrail.example.env` | `SPEECHRAIL_VERSION` |
| `configs/speechrail.example.yaml` | `service.version` |
| `tests/test_app_contract.py` | `/health` 断言 |
| `tests/test_installer.py` | wheel fixture 名 |
| `tests/test_release_verification.py` | dist-info fixture 名 |
| `uv.lock` | 项目包版本，由 `uv lock` 生成 |
| `CHANGELOG.md` | 新版本条目，并保留空的 `[Unreleased]` |
| `README.md` | 用户可见版本和本轮可信 benchmark 摘要 |

不要改 worker 帧协议的整数 `version: 1`、历史 CHANGELOG 标题或归档报告中的旧版本。正式文档 front matter 的 `version`/`date` 只在正文实质变化时更新。

README 顶部必须保留动态 GitHub Release badge：

```html
<a href="https://github.com/hrygo/SpeechRail/releases"><img src="https://img.shields.io/github/v/release/hrygo/SpeechRail?color=3776AB&label=release" alt="Release" /></a>
```

```bash
uv lock
uv run python scripts/check_version_consistency.py
uv run python -c "from speechrail.config import Settings; print(Settings().version)"
rg -F -n 'href="https://github.com/hrygo/SpeechRail/releases"' README.md
rg -F -n 'src="https://img.shields.io/github/v/release/hrygo/SpeechRail?color=3776AB&label=release"' README.md
```

若私有 managed 配置含 `SPEECHRAIL_VERSION`，先在仓库外创建 `0600` 备份，再原子删除该单行，使版本来自 wheel；不得输出配置全文或提交 `.env`。

## 4. 代码门与 wheel

```bash
env -u SPEECHRAIL_API_KEY uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
plutil -lint deploy/macos/com.speechrail.plist.example
git diff --check
uv build --no-sources --wheel
python3 -m zipfile -l dist/speechrail-<version>-py3-none-any.whl
shasum -a 256 dist/speechrail-<version>-py3-none-any.whl
```

测试时清除环境中的 `SPEECHRAIL_API_KEY`，避免私有配置污染匿名/契约测试；不要把 key 写入命令、报告或日志。构建后核对 wheel 文件名、metadata、worker 模块、assets 和版本；`dist/`、模型、音频、日志和原始 benchmark 不提交 Git。

## 5. 安全替换 managed 服务

`tools.install_macos.install_managed(...)` 负责 staging、新 release preflight、共享 runtime 准备和原子切换 `runtime/current`，并会在切换前确认配置端口的 lock 已释放，但不会替旧服务完成进程退出确认。替换前后都必须使用 [本机生命周期 controller](../speechrail-local-deploy/references/lifecycle.md)：

1. 记录 active profile，确认新 wheel 与旧 selection/model lock 相容；不要在 wheel 发布事务中改变 profile。
2. 用 `speechrail service stop` 或当前 managed Python 执行安全 stop：`bootout` 后最多等 2 秒；lock 仍被占用时对经过 owner/PID 校验的精确进程组 `SIGKILL`；再最多等 10 秒。PID 缺失、不安全或 lock 未释放时中止，不启动候选。
3. 调用 `install_managed(wheel, app_home=..., preset_id=<active profile>, ..., enable=False)`；preflight 失败时恢复 `runtime/current` 和 runtime snapshot，保留旧服务回退点。
4. 使用新 `runtime/current/.venv/bin/python` 安装/更新 LaunchAgent，确认 plist 指向新 runtime；随后用 controller `start()`，它会在 `bootstrap`/`kickstart` 前再次确认 lock 已释放。
5. 只允许一个新父进程和一个 listener。模型加载期间不连续 restart，使用有界轮询等待；启动上限按实际设备和模型确定，可达数分钟。

`speechrail service stop` 会执行 bounded stop、精确强杀和 lock 验证；`service disable` 仅作为兼容别名。不要用底层 `launchctl`、`pkill`、`killall` 或手工 plist 绕过 controller。

### explicit-env（仅无 managed selection 时）

确认 app home 没有 managed `selection.json`，仍使用同一安全 stop 协议。然后用受审查的 legacy installer 安装显式 `.env`，最后再做整套运行态验收：

```bash
APP_HOME="${SPEECHRAIL_APP_HOME:-$HOME/Library/Application Support/SpeechRail}"
python3 tools/install_macos.py \
  --wheel "dist/speechrail-<version>-py3-none-any.whl" \
  --env-file "$APP_HOME/config/.env" \
  --app-home "$APP_HOME" \
  --enable
```

不要用 legacy installer 覆盖已有 managed selection；发现 selection 存在时停止并改走 managed 流程。

## 6. 运行态验收

```bash
APP_HOME="${SPEECHRAIL_APP_HOME:-$HOME/Library/Application Support/SpeechRail}"
speechrail service status --app-home "$APP_HOME"
speechrail profile status --app-home "$APP_HOME"
speechrail service preflight --app-home "$APP_HOME"
curl --fail http://127.0.0.1:8201/health
curl --fail http://127.0.0.1:8201/readyz
curl --fail http://127.0.0.1:8201/v1/models
curl --fail http://127.0.0.1:8201/v1/voices
readlink "$APP_HOME/runtime/current"
uv run python scripts/verify_release.py \
  --wheel "dist/speechrail-<version>-py3-none-any.whl" \
  --app-home "$APP_HOME"
lsof -nP -iTCP:8201 -sTCP:LISTEN
```

必须同时满足：

- PID 的实际 executable 来自 `runtime/current/.venv/bin/python`，且 8201 只有一个 listener；
- `/health.version`、wheel metadata、`runtime/current` release 和发布记录一致；ASR/TTS ready；
- `/health.profile`、`/v1/models` 的 profile/artifact/variant/quantization 与 selection 一致；
- `/readyz` 为 200，`/v1/voices` 的 availability/capabilities 与当前 TTS variant 一致；
- 真实、非敏感 fixture 的 ASR/TTS 都返回 200、非空结果和 request ID；
- 通过一次“第二实例应失败”的检查（启动同一端口的 `speechrail serve` 得到 `server_already_running`），然后不留下第二进程。

仅有进程存在、plist 存在、配置存在或 `/health` 200 都不能证明新 release 生效；profile identity mismatch 说明 smoke 可能打到了旧 listener，必须重新安全 stop。

## 7. profile 与性能验收

读取 `.agents/skills/speechrail-perf-benchmark/SKILL.md` 执行基准：

- PATCH：只测快照记录的 active profile；
- MINOR：`active → 其余两档 → active`，逐档停服、确认 lock、启动、等真实 ready、核对 `/health.profile`、做 smoke；
- MAJOR：三档完整套件，再做迁移/兼容和回退验证。

profile 切换失败时停止后续采集，记录失败档、operation 状态、PID、stderr 尾部和错误码；使用 `profile rollback --yes` 只回滚一次。回滚也失败时保持 `not_ready`，不要用旧数据补齐或连续重启。

基准报告必须记录实际安装 wheel hash、commit、profile、generation、模型身份、硬件、资源采样完整性和 gate；缺少真实质量或完整物理采样时写 `unset`/`fail`，不能写“通过”。原始 JSON、音频、embedding 和日志放仓库外。

## 8. 回滚与恢复

1. 用同一安全 stop 协议停止当前服务。
2. 恢复前置快照的 `runtime/current`，同时核对旧 selection、共享 vendor `current` 和私有配置；不要凭目录名猜版本。
3. 用旧 runtime 安装/更新 LaunchAgent，启用并用 controller start。
4. 重做 `/health`、`/readyz`、`/v1/models`、`/v1/voices` 和真实 ASR/TTS smoke；若回滚也失败，停止操作并报告 `not_ready` 证据。
5. 保留旧 release、模型、配置、日志和失败证据。`disable`/`uninstall` 不等于版本回滚。

## 9. 发布证据与 tag

完成前保存一条脱敏 evidence ledger：版本、commit、wheel SHA-256、runtime target、PID/listener、profile/generation、health/ready、preflight、models/voices、真实 smoke、性能报告链接、回退目标和未验证项。绝对路径只保留必要的仓库相对路径或通用 `$HOME` 变量。

```bash
uv run python scripts/check_version_consistency.py
git diff --check
git diff --staged --check
git status --short
```

只有发布 commit 已包含本次所需代码、文档和报告、工作树没有未归属改动、同名 tag 不存在时才创建：

```bash
git tag v<version>
```

远端 push 只有在当前任务明确授权时执行；禁止 force-push。若工作树含其他用户改动，不得声称“干净”或擅自打 tag。

## 完成清单

- [ ] SemVer、active profile 和 benchmark scope 已判定
- [ ] 版本一致性、pytest、ruff、mypy、OpenAPI、plist、diff gate 全部通过
- [ ] wheel metadata 和 SHA-256 已记录，managed preflight 使用新 wheel
- [ ] 旧服务按 2 秒等待 + 精确进程组强杀 + 10 秒 lock 确认停止
- [ ] 只有一个 listener，PID/executable、version、profile、generation 与 selection 一致
- [ ] `/health`、`/readyz`、`/v1/models`、`/v1/voices` 和真实 ASR/TTS smoke 通过
- [ ] PATCH 当前档或 MINOR/MAJOR 三档基准已归档，gate 和限制如实记录
- [ ] 性能归档索引、README 摘要和动态 Release badge 已同步
- [ ] active profile 已恢复，旧 release、selection、vendor runtime 和回退点仍存在
- [ ] tag/远端操作符合当前授权，发布证据不含秘密或原始音频
