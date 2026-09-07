---
name: speechrail-release
description: >-
  SpeechRail 本机版本发布 SOP。用于判定 SemVer、更新版本与 CHANGELOG、执行代码门、构建并安装 wheel、
  安全替换 managed LaunchAgent、验证启停与 profile 切换、回滚和留存发布证据。
  只读版本判断、仅构建 wheel、本机安装发布是三个不同入口；命中的具体入口按用户请求范围选择，
  不因单个触发词自动执行完整发布。
---

# SpeechRail 版本发布 SOP

目标是交付一个可验证、可回退的本机 wheel release。发布允许停服和数分钟的启动真空，但任何候选版本都不得与旧实例并存，也不得在模型制品、配置或回退点未确认时切换运行态。

发布、安装和回滚必须遵守 [本机 operator contract](../speechrail-local-deploy/references/operator-contract.md)；本 SOP 只补充版本材料、代码门和交付证据。

## 入口分级

本 SOP 覆盖三种不同范围的入口，命中后按用户请求选择，不因单个词自动升级：

| 入口 | 范围 | 是否改动运行态 |
|---|---|---|
| 只读版本判断 | 读取 `pyproject.toml`/`__version__`、比较上一 tag 到 HEAD，输出建议 SemVer | 否 |
| 仅构建 wheel | 更新版本材料、执行代码门、从干净源快照构建 wheel 并记录 SHA-256 | 否 |
| 本机安装发布 | 完整替换 managed 服务并做运行态验收（本 SOP 默认主题） | 是 |

`版本号`、`bump`、`构建 wheel` 等词默认进入只读或仅构建入口；只有用户明确要求安装/替换本机服务时才进入完整发布。

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

记录当前 commit、active profile、generation、runtime target、服务 PID、listener 数量、模型身份、旧 wheel hash 和可回退 selection/vendor runtime。必须确认只有一个 8201 listener，且 PID 属于 `runtime/current/.venv/bin/python`。发布必须从明确的 release 源快照构建，不能从含未归属改动的工作树直接构建；记录 commit、工作树摘要、构建输入文件集合、wheel metadata 和 SHA-256，最终 tag 必须与构建输入一致。

发布、切档和性能 smoke 前还必须隔离外部 realtime 客户端：用 `lsof -nP -iTCP:8201` 查找 `ESTABLISHED` 连接，用已配置鉴权读取 `/metrics` 确认 `speechrail_realtime_active_sessions=0`、batch/realtime governor active requests 均为 0。Sona、浏览器或其它客户端的连接不会随 SpeechRail `bootout` 自动释放；发现活动客户端时暂停发布并报告阻塞，等待客户端自行断开，只有用户明确授权才按已核验的精确 PID 关闭指定客户端。若公共 ASR 仍返回 `429 backend_busy`，停止发布并保留证据，不循环重试。

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

构建必须绑定精确源快照：先确认 `git status --short` 只有本次 release 文件，记录 `git rev-parse HEAD` 与构建输入文件集合；从该快照构建，记录 wheel metadata 与 SHA-256，最终 tag 与构建输入一致。

```bash
env -u SPEECHRAIL_API_KEY uv run --extra dev pytest
uv run --extra dev ruff check src tests tools
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
plutil -lint deploy/macos/com.speechrail.plist.example
git diff --check
uv build --no-sources --wheel
python3 -m zipfile -l dist/speechrail-<version>-py3-none-any.whl
shasum -a 256 dist/speechrail-<version>-py3-none-any.whl
```

测试时清除环境中的 `SPEECHRAIL_API_KEY`，避免私有配置污染匿名/契约测试；不要把 key 写入命令、报告或日志。`--extra dev` 已包含 `mcp`（默认启用），因此 `tests/mcp/` 无需再单独 `--extra mcp`。本地功能门禁用 `--no-cov` 运行以验证正确性，覆盖率 80% 上限由 CI 的 `pytest --cov=src` 承担；`ruff check src tests tools` 与 CI 同口径，避免只查 `src tests` 漏掉 `tools/` 的遗留 lint。构建后核对 wheel 文件名、metadata、worker 模块、assets 和版本；`dist/`、模型、音频、日志和原始 benchmark 不提交 Git。

## 5. 安全替换 managed 服务

`tools.install_macos.install_managed(...)` 负责 staging、新 release preflight、共享 runtime 准备和原子切换 `runtime/current`，并会在切换前确认配置端口的 lock 已释放，但不会替旧服务完成进程退出确认。替换前后都必须使用 [本机生命周期 controller](../speechrail-local-deploy/references/lifecycle.md)：

1. 记录 active profile，确认新 wheel 与旧 selection/model lock 相容；不要在 wheel 发布事务中改变 profile。
2. 用 `speechrail service stop` 或当前 managed Python 执行安全 stop：`bootout` 后最多等 2 秒；lock 仍被占用时重新核对当前 owner/PID/命令行后才对精确进程组 `SIGKILL`；再最多等 10 秒。PID 缺失、身份不一致、不安全或 lock 未释放时中止，不启动候选。
3. 调用 `install_managed(wheel, app_home=..., preset_id=<active profile>, ..., enable=False)`；preflight 失败时恢复 `runtime/current` 和 runtime snapshot，保留旧服务回退点。
4. 使用新 `runtime/current/.venv/bin/python` 安装/更新 LaunchAgent，确认 plist 指向新 runtime；随后用 controller `start()`，它会在 `bootstrap`/`kickstart` 前再次确认 lock 已释放。
5. 只允许一个新父进程和一个 listener。模型加载期间不连续 restart，使用有界轮询等待；启动上限按实际设备和模型确定，可达数分钟。

安装器的安全边界是强制的：managed 首次安装若 `service enable` 或注入的 post-enable verifier 失败，会尝试停止候选、清理新 selection、恢复旧 current/runtime。安装器只负责组合这些端口，PID/进程组识别和短等待后精确 `SIGKILL` 仍由 lifecycle controller 单一实现。

`speechrail service stop` 会执行 bounded stop、精确强杀和 lock 验证；`service disable` 仅作为兼容别名。不要用底层 `launchctl`、`pkill`、`killall` 或手工 plist 绕过 controller。

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
- 真实、非敏感 fixture 的 ASR/TTS 都返回 200、非空结果和 request ID（私有 `.env` 配置 API key 时，须用该 key 鉴权，从 `.env` 读取且**不回显**）；
- 没有外部 established realtime connection，`realtime_active_sessions=0`，batch/realtime active requests 均为 0；
- 通过一次“第二实例应失败”的检查（启动同一端口的 `speechrail serve` 得到 `server_already_running`），然后不留下第二进程。macOS 无 GNU `timeout`，用 `python -c 'import subprocess,os; subprocess.run([...], timeout=30)'` 实现有界等待；`speechrail serve --app-home ...` 可用作显式 app home。

仅有进程存在、plist 存在、配置存在或 `/health` 200 都不能证明新 release 生效；profile identity mismatch 说明 smoke 可能打到了旧 listener，必须重新安全 stop。

## 7. profile 与性能验收

读取 `.agents/skills/speechrail-perf-benchmark/SKILL.md` 执行基准：

- PATCH：只测快照记录的 active profile；
- MINOR：`active → 其余两档 → active`，逐档停服、确认 lock、启动、等真实 ready、核对 `/health.profile`、做 smoke；
- MAJOR：三档完整套件，再做迁移/兼容和回退验证。

profile 切换失败时停止后续采集，记录失败档、operation 状态、PID、stderr 尾部和错误码。先读取 operation 状态与回滚结果：事务已自动回滚且已恢复时不得再次回滚；仅在确认未恢复且回退目标明确时执行一次 `profile rollback --yes`。回滚也失败时保持 `not_ready`，不要用旧数据补齐或连续重启。

基准报告必须记录实际安装 wheel hash、commit、profile、generation、模型身份、硬件、资源采样完整性、外部客户端隔离证据和 gate；缺少真实质量或完整物理采样时写 `unset`/`fail`，不能写“通过”。原始 JSON、音频、embedding 和日志放仓库外。

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

远端 push 只有在当前任务明确授权时执行；禁止 force-push。若工作树含其他用户改动，不得声称“干净”或擅自打 tag。macOS（Apple Git）向受保护分支推送时若遇 `LibreSSL SSL_connect: SSL_ERROR_SYSCALL to github.com:443` 而 `curl` 同一地址正常，通常是 HTTP/2 连接被 reset；用 `git -c http.version=HTTP/1.1 push ...` 绕过（单命令注入，不要持久改动全局 config）。

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
