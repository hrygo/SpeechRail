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
  不能作为第二个 Applications/DerivedData 可执行副本。

## 平台基线

遵循仓库 `AGENTS.md` 的平台目标，并核对本次交付物的 package/target、Python 约束和构建设置。
发现旧脚本或 target 仍声明更低版本时，报告与项目目标的差异；不以旧检查放行证明当前基线已满足，
也不因发布任务擅自修改无关平台代码。

## 1. 确定范围、版本与快照

以 `pyproject.toml` 的 `[project].version` 为服务版本事实来源；App 同时必须有可审计的
`CFBundleShortVersionString` 和单调递增的 `CFBundleVersion`。按用户可见变化选择：

| 类型 | 条件 |
|---|---|
| PATCH | 兼容 bug、安全、稳定性或性能修复，不增加公共能力 |
| MINOR | 新增兼容 API 或能力；默认行为变化须先判断是否破坏公共契约 |
| MAJOR | 破坏公共契约或需要迁移 |

证据不足时列出待确认的公共影响，不仅凭不确定性提高版本；纯文档通常不单独发版。明确 `service-only`、`app-only` 或 `combined`，不要因
“配套”扩大 scope。

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
uvx --python 3.12 --from dist/speechrail-<version>-py3-none-any.whl speechrail install --help
```

测试清除环境中的 `SPEECHRAIL_API_KEY`，但不把任何凭据写入命令或输出。构建后核对文件名、dist-info、worker
模块、assets 和版本，并确认 wheel 能独立提供安装入口（`speechrail install --help` 在仓库外成功执行，
macOS 打包阶段的 CI 也执行同一步）；`dist/`、模型、音频、日志和原始 benchmark 不提交 Git。

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

scope 包含 App 构建时读取 [macOS App 分发与签名](../../../docs/developers/macos-app-release.md)，并执行：

```bash
scripts/macos_app_build.sh --configuration Debug
plutil -lint macos/SpeechRailApp/Resources/LaunchAgents/com.speechrail.desktop.control.plist
# XCUITest 属 UI 自动化，会接管前台窗口与焦点：默认不运行，仅在当前用户明确要求时执行（见 AGENTS.md 硬约束）
# scripts/macos_app_test.sh
```

本机门禁使用 fake transport，不注册生产 helper，不启动/停止生产服务，不访问真实模型。`macos_app_test.sh`
属 UI 自动化，会接管前台窗口与焦点，默认不运行，只有当前用户明确要求时才执行；未运行不构成发布失败，
但必须在报告中列为未执行项。没有 Developer ID
时只能交付本地 Debug/Release 测试包，不能称为可分发版本；Distribution 还需逐项验证 nested code、
Hardened Runtime、notarization、staple、Gatekeeper 和最终 ZIP，不能用 `codesign --deep` 掩盖问题。

安装时退出旧 App，将最终 ZIP 解出的唯一 bundle 放到 `~/Applications/SpeechRail.app`，确认显示名、bundle
identifier、版本/build 和 control-agent 状态。验收后只清理本次精确 staging、DerivedData、未交付 archive/export
和旧测试 bundle；用 Finder/废纸篓处理，不做全局 LaunchServices 重置，不删除服务 app home、runtime、模型、
配置或日志。最后检查：

```bash
mdfind 'kMDItemCFBundleIdentifier == "com.speechrail.desktop"'
mdfind 'kMDItemFSName == "SpeechRailApp.app"'
```

第一查询应只保留唯一安装路径；测试/归档副本应在构建或临时目录清理后消失。若仍有多个
`SpeechRail.app`，先列出真实路径并逐一判断，不盲删。

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
