---
name: speechrail-release
description: >-
  SpeechRail 本机版本发布 SOP。用于判定 SemVer、更新版本与 CHANGELOG、执行代码门、构建并安装 wheel、
  发布 macOS App、安全替换 managed LaunchAgent、验证启停与 profile 切换、回滚和留存发布证据。
  只读版本判断、构建 wheel/App、本机安装发布是不同入口；命中的具体入口按用户请求范围选择，
  不因单个触发词自动执行完整发布。
---

# SpeechRail 版本发布 SOP

目标是交付一个可验证、可回退的本机 release。release 可以只包含服务 wheel、只包含 macOS App，或同时包含两者；允许服务停服和数分钟的启动真空，但任何候选服务版本都不得与旧实例并存，也不得在模型制品、配置或回退点未确认时切换运行态。

发布、安装和回滚必须遵守 [本机 operator contract](../speechrail-local-deploy/references/operator-contract.md)；本 SOP 只补充版本材料、App 分发、代码门和交付证据。App 的签名、归档和公证细节见 [macOS App 分发与签名](../../../docs/developers/macos-app-release.md)。

## 发布单元与所有权

| 发布单元 | 交付物 | 实际 owner | 登录启动 | 可否替换另一单元 |
|---|---|---|---|---|
| 服务 | wheel + managed `runtime/current` + selection | `com.speechrail` user `LaunchAgent` | **是** | 否；不读写 App bundle |
| App | `SpeechRail.app` + bundled `SpeechRailControlAgent` | App 控制面与 `com.speechrail.desktop.control` helper | App **否**；helper 仅按需由 `SMAppService` 管理 | 否；不加载模型、不创建第二个服务 |
| 联合发布 | 上述两套制品及同一 release evidence | 两套 owner 各自独立 | 以服务为准 | 先服务、后 App 验收 |

`SpeechRail.app` 退出、升级或 helper 注销都不得停止 `com.speechrail`。App 发布必须只保留一个实际安装 bundle；测试和归档副本不应长期留在 Applications/DerivedData，否则 Finder/LaunchServices 会显示重复 App。

## 入口分级

本 SOP 覆盖多种不同范围的入口，命中后按用户请求选择，不因单个词自动升级：

| 入口 | 范围 | 是否改动运行态 |
|---|---|---|
| 只读版本判断 | 读取 `pyproject.toml`/`__version__`、比较上一 tag 到 HEAD，输出建议 SemVer | 否 |
| 仅构建 wheel | 更新版本材料、执行代码门、从干净源快照构建 wheel 并记录 SHA-256 | 否 |
| App 本机验证 | 构建 App、跑 XCTest/UI test、检查 helper plist 与签名；不安装生产 helper | 否 |
| App 分发包 | Distribution archive/export、逐项签名验证、公证/staple、生成 ZIP | 否；安装另有明确授权 |
| 本机安装发布 | 完整替换 managed 服务并做运行态验收（本 SOP 默认主题） | 是 |
| 联合发布 | 先完成服务发布，再安装并验收兼容的 App | 是 |

`版本号`、`bump`、`构建 wheel` 或 `构建 App` 等词默认进入只读/构建入口；只有用户明确要求安装/替换本机服务或安装 App 时才进入对应的运行态发布。

## 1. 先确定范围与发布锁

以 `pyproject.toml` 的 `[project].version` 为版本事实来源。先比较上一 tag 到 `HEAD` 的用户可见变化，再选择验收范围：

| 类型 | 条件 | 必测 profile |
|---|---|---|
| PATCH | 兼容 bug、安全、稳定性或性能修复；不增加公共能力和档位组合 | 当前 active profile |
| MINOR | 新增兼容 API、模型档位、音色/运行时能力或明显改变默认行为 | `quality`、`balanced`、`light`，结束恢复原档 |
| MAJOR | 破坏公共契约或迁移要求 | 三档完整套件，加迁移和兼容验证 |

无法确定时取更高一级。纯文档修改通常不单独发版；若改动影响共同 runtime、切换器或基准工具，至少按三档评估。

先明确本次 release scope：`service-only`、`app-only` 或 `combined`。服务和 App 的 rollback point 必须分别记录；App-only 修复不应触发 wheel 替换，service-only PATCH 也不应为了“配套”重建 App。只有两套制品都变更且兼容性已验证时，才使用 `combined` release。

App 版本必须在构建产物中可审计：`CFBundleShortVersionString`（用户可见版本）和 `CFBundleVersion`（单调递增 build）。二者缺失、仍为工具默认值或无法和 release evidence 关联时，App 分发门禁失败；不能用文件修改时间或 Finder 显示名代替版本。App 的 XPC `schema_version`、固定命令集合和 managed runtime machine-output 字段也必须保持兼容，不能把 App 直接绑定到源码 checkout。

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

执行 `speechrail service preflight --app-home "$APP_HOME"`。CLI 会在当前进程不是 active managed runtime 时，自动把 service 以及 profile/setup 状态变更转交给 `runtime/current/.venv/bin/python`；不要从源码 `.venv` 推断已安装 wheel 的依赖，也不要手工拼接另一套 preflight 或切档命令。

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
| App 工程的 build settings / `.xcconfig`（若 scope 包含 App） | `MARKETING_VERSION`、`CURRENT_PROJECT_VERSION`、`PRODUCT_NAME=SpeechRail`、bundle identifier |
| `README.md` | 仅在用户明确要求同步 README 时，更新用户可见版本和本轮可信 benchmark 摘要 |

不要改 worker 帧协议的整数 `version: 1`、历史 CHANGELOG 标题或归档报告中的旧版本。正式文档 front matter 的 `version`/`date` 只在正文实质变化时更新。

只有本次获用户明确授权修改 README 时，才确认顶部动态 GitHub Release badge 仍保留：

```html
<a href="https://github.com/hrygo/SpeechRail/releases"><img src="https://img.shields.io/github/v/release/hrygo/SpeechRail?color=3776AB&label=release" alt="Release" /></a>
```

```bash
uv lock
uv run python scripts/check_version_consistency.py
uv run python -c "from speechrail.config import Settings; print(Settings().version)"
```

本次修改 README 时，再执行：

```bash
rg -F -n 'href="https://github.com/hrygo/SpeechRail/releases"' README.md
rg -F -n 'src="https://img.shields.io/github/v/release/hrygo/SpeechRail?color=3776AB&label=release"' README.md
```

若私有 managed 配置含 `SPEECHRAIL_VERSION`，先在仓库外创建 `0600` 备份，再原子删除该单行，使版本来自 wheel；不得输出配置全文或提交 `.env`。

## 4. 代码门与 wheel

构建必须绑定精确源快照：先确认 `git status --short` 只有本次 release 文件，记录 `git rev-parse HEAD` 与构建输入文件集合；从该快照构建，记录 wheel metadata 与 SHA-256，最终 tag 与构建输入一致。

```bash
env -u SPEECHRAIL_API_KEY uv run --extra dev pytest
uv run --extra dev ruff check src tests tools examples/perf .agents/skills/speechrail-perf-benchmark/scripts/prepare_fixtures.py
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

## 6. macOS App 发布

只有 scope 包含 App 时执行本节；服务-only release 不安装或注册 App。完整的签名、归档、公证和产物命名细节见 [macOS App 分发与签名](../../../docs/developers/macos-app-release.md)。App 永远是按需打开的控制面；`com.speechrail` 仍由服务发布流程负责登录常驻。

### 6.1 本机构建与测试

```bash
scripts/macos_app_build.sh --configuration Debug
scripts/macos_app_test.sh
plutil -lint macos/SpeechRailApp/Resources/LaunchAgents/com.speechrail.desktop.control.plist
```

本机门禁使用 fake transport，不注册生产 `com.speechrail.desktop.control`，不启动/停止生产 `com.speechrail`，不访问真实模型。构建前还要确认 App 产物含有显式的 `CFBundleShortVersionString` 和 `CFBundleVersion`；缺失或仍为默认值时停止发布并先补齐工程版本设置：

```bash
xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj \
  -scheme SpeechRailApp -configuration Distribution -showBuildSettings \
  | rg 'MARKETING_VERSION|CURRENT_PROJECT_VERSION'
```

### 6.2 Distribution 归档、公证与产物

没有 Developer ID identity 时，只能交付本地 Debug/Release 测试包，不能称为可分发版本；不要用 ad hoc 签名绕过本节。具备证书和 Keychain notarization profile 后：

```bash
export SPEECHRAIL_TEAM_ID="<your-team-id>"
scripts/macos_app_archive.sh \
  --export-options "/path/outside/repository/ExportOptions.plist" \
  --export-path "/path/outside/repository/macos-export"
scripts/macos_app_verify_distribution.sh "/path/outside/repository/macos-export/SpeechRail.app"
```

`macos_app_verify_distribution.sh` 必须逐项通过 App、ControlAgent、nested framework、`BundleProgram`、Hardened Runtime 和签名检查；禁止使用 `codesign --deep` 掩盖嵌套代码问题。将导出的 App 压缩为提交包，通过 Keychain profile 使用 `notarytool` 提交并等待结果；成功后 staple、validate、Gatekeeper 检查，再重新生成最终 ZIP：

```bash
ditto -c -k --keepParent \
  "/path/outside/repository/macos-export/SpeechRail.app" \
  "/path/outside/repository/SpeechRail-<version>-submit.zip"
xcrun notarytool submit "/path/outside/repository/SpeechRail-<version>-submit.zip" \
  --keychain-profile "$SPEECHRAIL_NOTARY_PROFILE" --wait
xcrun stapler staple "/path/outside/repository/macos-export/SpeechRail.app"
xcrun stapler validate "/path/outside/repository/macos-export/SpeechRail.app"
spctl --assess --type execute --verbose=2 \
  "/path/outside/repository/macos-export/SpeechRail.app"
ditto -c -k --keepParent \
  "/path/outside/repository/macos-export/SpeechRail.app" \
  "/path/outside/repository/SpeechRail-<version>.zip"
shasum -a 256 "/path/outside/repository/SpeechRail-<version>.zip"
```

`SPEECHRAIL_TEAM_ID`、Keychain profile 和签名身份只能来自本机安全配置；不写入仓库、命令日志或 evidence。联合发布时，最终 ZIP 与服务 wheel 放在同一个 GitHub Release，但 App bundle 不携带 Python runtime、模型、`.env`、日志或 API key。

### 6.3 安装、控制链路验收与清理

1. 先完成服务发布和 `/health`、`/readyz`、`/v1/models`、`/v1/voices` 验收；App 不能替代服务验收。
2. 退出旧 `SpeechRail.app`，把最终 ZIP 解出的唯一 bundle 安装到用户路径 `~/Applications/SpeechRail.app`；若使用其他安装路径，必须在 evidence 中明确记录。不要在 Applications 中并排保留旧 `.app`；上一版本保留为 ZIP/归档制品，不作为第二个可执行 bundle。
3. 打开同一路径的 App，先确认显示名、bundle identifier、App version/build 和 control-agent 状态；再用 UI 执行一次 `status`/`preflight` 只读控制，必要时再按授权执行 mutation。App 通过 `SMAppService` 管理 `com.speechrail.desktop.control`，不得手工写 LaunchAgent plist 或直接调用 `launchctl`。
4. 关闭 App 后再次检查服务 `/health`、`/readyz`、唯一 8201 listener 和服务 PID；App/Agent 退出不能导致 `com.speechrail` 停止。
5. 验收完成后清理本次精确的 staging、DerivedData、`build/macos-derived-data`、未交付 archive/export 和旧测试 bundle；可保留最终 ZIP、哈希和脱敏 evidence。用 Finder/废纸篓处理精确路径，不做全局 LaunchServices 重置，不删除服务 app home、`runtime/releases`、模型、配置或日志。
6. 最后确认：

```bash
mdfind 'kMDItemCFBundleIdentifier == "com.speechrail.desktop"'
mdfind 'kMDItemFSName == "SpeechRailApp.app"'
```

前一查询在清理后只应保留唯一安装路径（默认 `~/Applications/SpeechRail.app`）；后一查询应为空。若仍有多个 `SpeechRail.app`，先列出实际路径并逐一判断是安装包、构建产物还是测试副本，再清理精确副本，不能盲删。

### 6.4 App 回滚

- App-only 失败：退出新 App，恢复上一份已验证的 ZIP 到同一安装路径；按 `SMAppService`/System Settings 核对 control-agent 状态，服务 `runtime/current`、selection、模型和 `com.speechrail` 不变。
- 联合发布失败：若服务验收通过而 App/XPC 失败，只回滚 App；若服务失败，先按本 SOP 的服务回滚恢复 `com.speechrail`，再按需恢复兼容的 App。不能用 App 回滚替代服务回滚，也不能因 App 安装失败删除服务数据。
- 回滚后重新执行 App version/build、helper 状态、App 退出不影响服务、唯一安装路径和最终服务 health/ready 检查。

## 7. 运行态验收

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
- 真实、非敏感 fixture 的 ASR/TTS 都返回 200、非空结果和 request ID（私有 `.env` 配置 API key 时，benchmark/CLI 会自动读取且**不回显**；只有显式 `SPEECHRAIL_API_KEY` 才覆盖文件值）；
- 没有外部 established realtime connection，`realtime_active_sessions=0`，batch/realtime active requests 均为 0；
- 通过一次“第二实例应失败”的检查（启动同一端口的 `speechrail serve` 得到 `server_already_running`），然后不留下第二进程。macOS 无 GNU `timeout`，用 `python -c 'import subprocess,os; subprocess.run([...], timeout=30)'` 实现有界等待；`speechrail serve --app-home ...` 可用作显式 app home。

仅有进程存在、plist 存在、配置存在或 `/health` 200 都不能证明新 release 生效；profile identity mismatch 说明 smoke 可能打到了旧 listener，必须重新安全 stop。

## 8. profile 与性能验收

读取 `.agents/skills/speechrail-perf-benchmark/SKILL.md` 执行基准：

- PATCH：只测快照记录的 active profile；
- MINOR：`active → 其余两档 → active`，逐档停服、确认 lock、启动、等真实 ready、核对 `/health.profile`、做 smoke；
- MAJOR：三档完整套件，再做迁移/兼容和回退验证。

profile 切换失败时停止后续采集，记录失败档、operation 状态、PID、stderr 尾部和错误码。先读取 operation 状态与回滚结果：事务已自动回滚且已恢复时不得再次回滚；仅在确认未恢复且回退目标明确时执行一次 `profile rollback --yes`。回滚也失败时保持 `not_ready`，不要用旧数据补齐或连续重启。

基准报告必须记录实际安装 wheel hash、commit、profile、generation、模型身份、硬件、资源采样完整性、外部客户端隔离证据和 gate；缺少真实质量或完整物理采样时写 `unset`/`fail`，不能写“通过”。原始 JSON、音频、embedding 和日志放仓库外。

## 9. 回滚与恢复

1. 用同一安全 stop 协议停止当前服务。
2. 恢复前置快照的 `runtime/current`，同时核对旧 selection、共享 vendor `current` 和私有配置；不要凭目录名猜版本。
3. 用旧 runtime 安装/更新 LaunchAgent，启用并用 controller start。
4. 重做 `/health`、`/readyz`、`/v1/models`、`/v1/voices` 和真实 ASR/TTS smoke；若回滚也失败，停止操作并报告 `not_ready` 证据。
5. 保留旧 release、模型、配置、日志和失败证据。`disable`/`uninstall` 不等于版本回滚。

## 10. 发布证据与 tag

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

- [ ] release scope（`service-only` / `app-only` / `combined`）、SemVer、active profile 和 benchmark scope 已判定
- [ ] 服务版本一致性、pytest、ruff、mypy、OpenAPI、服务 plist、diff gate 全部通过
- [ ] wheel metadata 和 SHA-256 已记录，managed preflight 使用新 wheel
- [ ] 旧服务按 2 秒等待 + 精确进程组强杀 + 10 秒 lock 确认停止
- [ ] 只有一个 listener，PID/executable、version、profile、generation 与 selection 一致
- [ ] `/health`、`/readyz`、`/v1/models`、`/v1/voices` 和真实 ASR/TTS smoke 通过
- [ ] 若包含 App：`CFBundleShortVersionString`/`CFBundleVersion`、bundle identifier、Debug/UI test、helper plist 和 App 签名门禁通过
- [ ] 若为 Distribution：Developer ID、Hardened Runtime、nested code、notarization、staple、`spctl` 和最终 ZIP SHA-256 已记录
- [ ] 若安装 App：唯一安装路径、control-agent 状态和 App 退出后服务仍 healthy 已核对；无 `SpeechRailApp` 遗留 bundle
- [ ] PATCH 当前档或 MINOR/MAJOR 三档基准已归档，gate 和限制如实记录
- [ ] 性能归档索引已同步；只有用户明确要求 README 同步时，README 摘要和动态 Release badge 已核对
- [ ] active profile 已恢复，旧 release、selection、vendor runtime 和回退点仍存在
- [ ] 服务/App 回退点均可用；tag/远端操作符合当前授权，发布证据不含秘密或原始音频
