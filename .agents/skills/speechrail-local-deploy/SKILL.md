---
name: speechrail-local-deploy
description: >-
  SpeechRail macOS 本机部署、wheel 替换、managed profile 切换、LaunchAgent 验证和回滚 SOP。
  用于安装、升级、启停、排障或核对本机服务。
---

# SpeechRail 本机部署 SOP

SpeechRail 只部署为当前用户的 `LaunchAgent`。默认 app home 为 `$HOME/Library/Application Support/SpeechRail`，label 为 `com.speechrail`，端口为 `127.0.0.1:8201`。

## 原则

- 始终保持单实例；替换 release 前先停旧服务。
- 私有配置权限为 `0600`，不得输出、覆盖或提交。
- app wheel、共享 vendor runtime、模型 snapshot 和 selection 分开管理；profile 只改变权重组合。
- preflight 通过后才切 `runtime/current`；失败恢复旧指针并保持模型与配置不变。
- 不用 root、`LaunchDaemon`、`pkill`、模糊 PID 或手工 plist 修改。

## 操作前快照

```bash
APP_HOME="$HOME/Library/Application Support/SpeechRail"
speechrail service status --app-home "$APP_HOME"
speechrail profile status --app-home "$APP_HOME"
readlink "$APP_HOME/runtime/current"
curl --fail http://127.0.0.1:8201/health
```

记录 PID、版本、active profile、generation、runtime target 和模型身份。任何路径或 label 不符都先停止操作并定位实际部署。

## 首次安装

源码开发环境使用 `uv sync --extra dev` 与私有 `.env`。面向用户的 managed 首装应通过受审查的 installer/双击入口，选择 `quality`、`balanced` 或 `light`，下载 catalog 锁定的 ModelScope 制品并逐文件校验，再创建共享 runtime、安装 wheel、preflight 和启用服务。

`SpeechRail 设置.command` 与以下命令使用同一切档事务：

```bash
speechrail setup --app-home "$APP_HOME"
speechrail profile list
speechrail profile apply light --app-home "$APP_HOME" --yes
```

自动化切档必须显式 `--yes`。切换允许短暂停服，公共 ASR/TTS smoke 失败时只回退一次。

## wheel 替换

完整发布使用 `.agents/skills/speechrail-release/SKILL.md`。顺序固定为：

1. 完整代码 gate 与 wheel 校验；
2. 记录当前 managed profile 和回退点；
3. `service disable`；
4. 以同一 profile 调用 `tools.install_macos.install_managed(...)`；
5. 新 release preflight；
6. 原子切换 app `runtime/current`，保留 vendor runtime/model current；
7. 安装并启用 LaunchAgent；
8. 验证端点和真实 ASR/TTS。

不要用 `tools/install_macos.py` 的 legacy CLI 替换已有 managed deployment；该入口只用于显式 `.env`、没有 managed selection 的安装。

## 验证

使用有界轮询等待模型加载，然后检查：

```bash
speechrail service status --app-home "$APP_HOME"
curl --fail http://127.0.0.1:8201/health
curl --fail http://127.0.0.1:8201/readyz
curl --fail http://127.0.0.1:8201/v1/models
curl --fail http://127.0.0.1:8201/v1/voices
curl --fail http://127.0.0.1:8201/metrics
```

通过条件：

- PID 指向 `runtime/current/.venv/bin/python`；
- `/health.version` 与 wheel 一致，ASR/TTS ready；
- `/v1/models` 的 profile、artifact、variant 和 quantization 与 selection 一致；
- `/v1/voices` 有九个 canonical system roles，availability/capabilities 与当前 TTS variant 一致；
- 一段真实非敏感音频的 ASR 与 `serena` TTS 均返回 200、非空结果和 request ID。

## 回滚

### profile 回滚

```bash
speechrail profile rollback --app-home "$APP_HOME" --yes
```

### wheel 回滚

1. 停用当前服务。
2. 恢复操作前记录的 app `runtime/current`。
3. managed 安装同时核对旧 selection 与 vendor runtime current；不要凭目录名猜测。
4. 用旧 runtime 执行 `speechrail service install` 和 `enable`。
5. 重做全部端点与真实 smoke。

`disable` 只停服务，`uninstall` 删除 plist；二者都不是版本回滚。不要删除旧 release、模型、配置或日志。

## 常见故障

| 现象 | 先查 | 处理 |
|---|---|---|
| 端口拒绝 | service status、PID、stderr | 确认单实例和 LaunchAgent domain |
| `/health` 仍是旧版本 | app current、wheel metadata、私有 `SPEECHRAIL_VERSION` | managed 配置不应长期覆盖 wheel 版本 |
| `/readyz` 503 | selection、snapshot hash、共享 runtime、preflight | 修复配置/制品，不用测试开关掩盖 |
| 音色数量或能力错误 | active TTS variant、selection generation、是否运行新 wheel | 重启当前 release 并核对 `/v1/voices` |
| profile apply 失败 | prepared set、启动许可、public smoke | 使用一次 rollback，保留失败证据 |
| `launchctl` exit 5 | 旧任务是否完成 bootout | 使用服务 CLI 的 settle 逻辑，不连续 restart |

交付时报告版本、profile、generation、端点状态、真实 smoke、未验证项和精确回滚目标，不含凭据或私人绝对路径。
