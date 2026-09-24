---
name: speechrail-release
description: >-
  SpeechRail 服务/App 发布、版本判断、构建验收、App 安装路径整理和回滚。按用户明确范围选择
  只读、构建或安装入口；不因“版本/bump/构建”自动改运行态，不用于性能基准、远程部署或全新首装。
---

# SpeechRail 发布与回滚

本 skill 处理明确授权的 service-only、app-only 或 combined release。它把版本材料、构建门禁、
安装边界和回滚点串起来；生命周期细节统一由
[operator contract](../speechrail-local-deploy/references/operator-contract.md) 管理。

## 入口分级

| 用户请求 | 入口 | 是否改运行态 |
|---|---|---|
| 查询版本、评估 bump | 读取代码/标签并给出 SemVer 建议 | 否 |
| 明确要求更新版本 | 修改对应版本材料并检查一致性 | 否 |
| 只构建 wheel/App | 对应构建和产物校验；不自动 bump | 否 |
| 从 GitHub 制品安装（默认全套） | 制品入口：同一发布的服务 wheel + App，先服务后 App | 服务与 App |
| 本机 App 替换，用户自行验收 | 第 4 节快路径：备份、替换、静态验证后交还用户 | 仅 App |
| App 本机验证 | 按请求做静态或非 UI 检查；接管窗口的测试需当前消息明确要求 | 依检查方式而定 |
| 安装/替换或 bundle 整理 | 仅对指定单元安装、验收或清理，保留回退点 | 是 |

以下章节按入口选用，不是必须顺序执行的完整流水线。用户已有授权持续有效；构建不包含安装、
清理、真实签名、公证、创建 tag 或远端发布。安装验收中的真实推理须已被请求覆盖，否则记录未验证项。

全新 Mac 首装、下载模型和首次注册服务读
[speechrail-zero-setup](../speechrail-zero-setup/SKILL.md)；性能/质量/内存 benchmark 读
[speechrail-perf-benchmark](../speechrail-perf-benchmark/SKILL.md)。

## 发布单元与硬边界

- 服务交付物是 wheel、managed `runtime/current` 和 selection，由唯一
  `com.speechrail` user `LaunchAgent` 拥有 8201。
- App 是按需打开的 `SpeechRail.app` 与可选 `com.speechrail.desktop.control` helper；App 不加载模型、
  不拥有 8201、不替代服务。服务与 App 可独立回滚，combined 必须先验收服务再验收 App。
- 一次只允许一个服务父进程、一个 ASGI worker 和一个 listener；不要在同一 app home 上并行发布、切档或
  benchmark。默认 loopback；不在仓库、命令、日志或 evidence 中写入 key、`.env`、音频、完整转写或模型路径。
- App 实际安装只保留一个 bundle，默认路径为 `~/Applications/SpeechRail.app`。上一版本保留为 ZIP/归档回退点，
  不能作为第二个 Applications/DerivedData 可执行副本；Xcode build/test 临时 bundle 不得残留或进入 LaunchServices。
- 会产出 App/test bundle 的构建必须通过仓库包装脚本：普通 build 用 `scripts/macos_app_build.sh`，UI test 仅在当次获准后用 `scripts/macos_app_test.sh`，archive/export 用对应发布脚本；禁止裸跑 `xcodebuild` 将 `.app` 留在长期 DerivedData 或临时目录。只读 `-showBuildSettings` 等查询除外。包装脚本使用隔离 DerivedData，在退出时注销本次 bundle 并直接清理，不把副本移入废纸篓。

## 平台基线

遵循仓库 `AGENTS.md` 的平台目标，并核对本次交付物的 package/target、Python 约束和构建设置。
发现旧脚本或 target 仍声明更低版本时，报告与项目目标的差异；不以旧检查放行证明当前基线已满足，
也不因发布任务擅自修改无关平台代码。

## 1. 确定范围、版本与快照

以 `pyproject.toml` 的 `[project].version` 为服务版本事实来源；App 同时必须有可审计的
`CFBundleShortVersionString` 和单调递增的 `CFBundleVersion`。按用户可见变化选择：

| 类型 | 条件 |
|---|---|
| PATCH | bug、安全、稳定性或性能修复，不增加公共能力 |
| MINOR | 新增兼容 API 或能力；默认行为变化仍须核对公共契约 |
| MAJOR | 有意改变公共契约；当前项目不为旧数据或旧协议自动保留迁移层 |

证据不足时列出待确认的公共影响，不仅凭不确定性提高版本；纯文档通常不单独发版。明确 `service-only`、`app-only` 或 `combined`，不要因
“配套”扩大已明确的单项 scope；“从制品安装”按本项目约定默认 combined，见下方制品入口。

版本材料按字段核对：

`pyproject.toml`、`src/speechrail/__init__.py`、`src/speechrail/config/__init__.py`、
`contracts/openapi.yaml`、`configs/speechrail.example.env`、`configs/speechrail.example.yaml`、
对应测试 fixture、`uv.lock`、`CHANGELOG.md`，以及 scope 包含 App 时的 build settings / `.xcconfig`。
不要修改 worker frame `version: 1`、历史 changelog 标题或旧归档报告版本。

版本与构建只需源码快照；以下运行态快照仅用于已授权的服务安装、替换或回滚：

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

带 `--app-home` 的 service/profile/setup 状态变更应由 managed runtime 执行；先读
`speechrail service preflight --app-home "$APP_HOME"`，不要用源码 `.venv` 推断安装态。
停服、切档和真实 smoke 前按 operator contract 隔离外部 realtime 客户端；发现活动连接就暂停，不自动
关闭其他客户端。

## 2. 代码门与 wheel

从明确、无未归属改动的源快照构建，记录 commit、相关未提交 diff、wheel metadata 和 SHA-256。
普通构建只运行对应构建、制品检查和受影响的必要验证。下列完整代码门仅在用户明确要求完整验收时执行；
文档更新、App-only 构建不运行整套 Python 检查：

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
uvx --python 3.14.7 --from dist/speechrail-<version>-py3-none-any.whl speechrail install --help
```

测试清除环境中的 `SPEECHRAIL_API_KEY`，但不把任何凭据写入命令或输出。构建后核对文件名、dist-info、worker
模块、assets 和版本，并确认 wheel 能独立提供安装入口（`speechrail install --help` 在仓库外成功执行，
macOS 打包阶段的 CI 也执行同一步）；`dist/`、模型、音频、日志和原始 benchmark 不提交 Git。

## GitHub 制品安装（默认全套）

本项目中“从制品安装”“使用 GitHub 制品安装”“安装某个 release/tag/run”默认指 **combined：服务 wheel + macOS App**，
已有安装授权覆盖这两个单元，不重复询问是否安装服务。只有用户明确说“只装 App”或“只装服务”才缩小范围；
给出单个资产链接只定位来源，不自动把全套降为单项，缺少另一项时先补齐同一发布的制品，无法补齐则报告阻碍。

按 [GitHub 制品安装 SOP](../../../docs/developers/macos-app-release.md#github-制品安装) 锁定同一发布来源、下载并校验两个制品；
不转成本地构建，不要求制品与当前工作区版本一致。要求“最新”时在实际安装时查询远端并固定具体版本；
制品不包含未发布的本地修改，存在这种预期冲突时先澄清。缺失、过期或校验失败时保持原安装，不擅自换版本/run 或触发 CI。

两个制品准备好后，按第 3 节替换并验证 managed 服务，再按第 4 节安装 App；保留服务和 App 两套独立回退点。
“我来验收”只把交互体验验收交还用户，不免除服务安装后的启动、ready 与身份检查，也不允许只装 App 就报告全套完成。
服务失败则不进入 App 替换；服务成功、App 失败时只回退 App，并明确报告两者实际状态，不宣称全套成功。
全套安装不自动切换 profile、下载模型或进行性能/质量基准；缺少必要模型/配置时说明阻碍，不静默扩展操作。

## 3. 安全替换 managed 服务

用户已要求安装或替换服务时，先读 local-deploy 的
[lifecycle controller](../speechrail-local-deploy/references/lifecycle.md) 和 operator contract：

1. 保存 active profile、旧 selection、runtime/vendor 回退点，并确认外部连接和 active request 已清零。
2. 通过 controller 安全 stop；bootout 返回、旧 PID 或 lock 未经复核都不能证明服务已退出。
3. 通过 wheel 自带的 `speechrail install` 入口，按当前 `--help` 和运维手册选择参数，
   做 staging、preflight 和原子切换；不直接编排内部 Python 安装函数。失败时恢复旧
   `runtime/current`/selection，不删除旧 release、模型、配置或日志。
4. 用新 managed runtime 通过 controller start；等待真实 ready，核对 profile/model/voice identity 和
   必要公共 smoke。任何 PID、身份、lock 或 listener 不一致都 fail closed，不循环 restart。

生命周期遵守共享 operator contract：默认最多等待 `2 秒`；仅在重新核对身份后允许对精确进程组发送
`SIGKILL`，并在强杀后最多等待 `10 秒` 确认 lock 释放。

wheel 替换和 profile 切换分开执行；不要直接使用底层 `launchctl`、`pkill`、`killall` 或手工 plist。

## 4. macOS App 构建、安装与清理

### 本机 App 替换快路径

已明确为本机 App-only，且用户说“替换安装，我来验收”或同义请求时，目标是**安装完成、等待用户验收**，不是完整发布验收。
只读取 [App 安装快路径](../../../docs/developers/macos-app-release.md#本机替换用户自行验收)；已读且未变的材料直接复用，
不展开服务运维、Developer ID、公证或基准流程，也不重新确认已有安装授权。

- 有与最后一次源码改动对应的成功构建证据和现存产物时直接复用；路径或时间戳只能帮助定位，不能独立证明来源。缺少可信产物才构建一次，不因安装重复跑测试或 bump 版本。
- 只做必要的候选包检查、旧版归档、正常退出、同文件系统替换及安装后静态校验；具体事务与失败回退见快路径。
- 不启动新 App、不做 UI/控制链路验收或查服务运行态。静态校验后必须运行 `scripts/macos_app_verify_single_install.sh <安装路径>`，确认 LaunchServices 只登记该安装 bundle，且没有 UI test runner 登记。
- 若唯一登记检查发现重复项：仅当本次授权范围包含清理副本时，按 App 安装 SOP 核实来源、版本、进程占用后清理 SpeechRail 自有生成物；精确注销 LaunchServices 记录并删除生成副本，不移入废纸篓、不触碰无关 App、不清空整个废纸篓。范围未覆盖清理时停止并报告路径。静态校验与唯一登记通过后，报告安装路径、版本和回退点，注明“未启动，待用户验收”，然后停止。

### 构建与其他发布入口

scope 包含 App 构建时读取 [macOS App 分发与签名](../../../docs/developers/macos-app-release.md)，并执行：

```bash
scripts/macos_app_build.sh --configuration Debug
plutil -lint macos/SpeechRailApp/Resources/LaunchAgents/com.speechrail.desktop.control.plist
# XCUITest 属 UI 自动化，会接管前台窗口与焦点：默认不运行，仅在当前用户明确要求时执行（见 AGENTS.md 硬约束）
# scripts/macos_app_test.sh
```

构建与测试的临时 `.app` 产物必须由包装脚本在 `EXIT` 收尾时先按精确路径注销、再直接删除；不要使用 `trash` 保留可被系统再次发现的副本。

本机门禁使用 fake transport，不注册生产 helper，不启动/停止生产服务，不访问真实模型。`macos_app_test.sh`
属 UI 自动化，会接管前台窗口与焦点，默认不运行，只有当前用户明确要求时才执行；未运行不构成发布失败，
但必须在报告中列为未执行项。没有 Developer ID
时只能交付本地 Debug/Release 测试包，不能称为可分发版本；Distribution 还需逐项验证 nested code、
Hardened Runtime、notarization、staple、Gatekeeper 和最终 ZIP，不能用 `codesign --deep` 掩盖问题。

安装与清理按 [App 安装 SOP](../../../docs/developers/macos-app-release.md#安装验收与清理) 的对应分支执行；
App-only 用户自行验收走上面的快路径；combined 先完成服务安装验证，再复用 App 替换步骤。正式发布保留签名、公证与制品验证要求。只清理本次可确认归属的临时产物，
既有构建副本的整理需单独覆盖该范围，不把 Spotlight 缓存结果当作安装失败或删除授权。

## 5. 运行验收、benchmark 与回滚

服务验收必须同时满足：PID/executable 来自 `runtime/current/.venv/bin/python`、8201 只有一个 listener、
`/health`/`/readyz`/`/v1/models`/`/v1/voices` identity 与 selection 一致、必要的真实 ASR/TTS smoke 返回
非空结果和 request ID，且外部 realtime session/active requests 为零。只看到进程、plist、配置或 `/health`
200 不算发布成功。

只有明确要求性能或质量基准时才读取 [speechrail-perf-benchmark](../speechrail-perf-benchmark/SKILL.md)，不要在 release skill
中重复基准模板。服务回滚读取 local-deploy 的 rollback/controller 规则；App-only 失败只恢复上一份已验证
ZIP 到同一路径，不删除服务数据；combined 先判断失败单元再独立回滚。

## 6. 证据与 tag

最终 evidence 仅填写本次适用的 scope、SemVer、commit、wheel/App hash、runtime target、profile/generation、
PID/listener、health/ready、preflight、models/voices、smoke、App 签名/公证状态、回退点和未验证项；原始
JSON、音频、embedding、日志和绝对私有路径留在仓库外。创建 commit/tag 需用户明确授权；只有发布 commit 包含全部所需材料、工作树无未归属改动且
同名 tag 不存在时才创建 tag；远端 push 需用户明确授权，禁止 force-push。
