# SpeechRail 生命周期控制器

wheel 替换时使用 `speechrail service stop`；`service disable` 只是兼容别名。controller 会在 `launchctl bootout` 后确认 per-port lock，不能把单独的 `launchctl` 成功返回当成旧进程已退出。

## 安全 stop/start

优先使用 `speechrail service stop/start --app-home ...` 的受管入口。下面的 Python 片段会实际改变服务状态，
仅用于已授权维护且需要定位 controller 的场景；它读取私有配置但不打印内容。
当前 release 缺少 `LaunchAgentServiceController` 时停止并报告所需升级，不自动升级，也不能退回模糊 kill。

单独 start 按 [operator contract](operator-contract.md) 的启动分支处理，不执行下方 stop 片段。
以下示例分别说明停止与启动机制，不是一套必须连续执行的命令；profile 事务使用其 CLI 入口。

```bash
APP_HOME="${SPEECHRAIL_APP_HOME:-$HOME/Library/Application Support/SpeechRail}"
CURRENT_PYTHON="$APP_HOME/runtime/current/.venv/bin/python"
test -x "$CURRENT_PYTHON"
APP_HOME="$APP_HOME" "$CURRENT_PYTHON" - <<'PY'
import os
from pathlib import Path

from speechrail.config import Settings
from speechrail.service.launchd import create_launch_agent_manager
from speechrail.service.profile_switch import LaunchAgentServiceController

app_home = Path(os.environ["APP_HOME"]).resolve()
settings = Settings.from_env_file(app_home / "config" / ".env")
manager = create_launch_agent_manager(working_directory=app_home)
LaunchAgentServiceController(manager, port=settings.port).stop()
PY
```

`stop()` 的固定边界是：先 `bootout`，最多等待 2 秒获取同一 per-port lock；仍占用时只对 `launchctl print` 或 lock owner metadata、并经过 PID/命令行校验的精确进程组发送 `SIGKILL`，再最多等待 10 秒确认 lock 释放。PID 缺失、owner 无法验证或 lock 仍未释放都会失败并阻止候选启动。

## stop 前的外部连接检查

controller 只负责 SpeechRail LaunchAgent 和其 worker；它不会替外部 Sona、浏览器或其它 `/v1/realtime` 客户端关闭 WebSocket。执行 `stop()` 或 profile 事务前，先运行 `lsof -nP -iTCP:<port>`，只把 `ESTABLISHED` 连接视为客户端占用，并用已配置鉴权读取 `/metrics`：

- `speechrail_realtime_active_sessions` 必须为 0；
- `speechrail_governor_active_requests{class="batch"}` 和 `{class="realtime"}` 必须为 0；
- streaming worker 不应有活动 session。

发现外部连接时暂停事务并报告阻塞，等待客户端自行断开；不得自动关闭 Sona、浏览器或其它客户端。只有用户明确授权关闭指定客户端时，才在精确核对 PID、命令行和 owner 后按精确 PID/进程组结束它。若短 ASR smoke 仍为 `429 backend_busy`，保留证据并停止事务；不要以重启循环掩盖连接未释放。

切换 `runtime/current`、安装 plist 后，用新 runtime 执行 `start()`，它会在 `bootstrap`/`kickstart` 前再次确认没有旧进程持锁：

```bash
APP_HOME="$APP_HOME" CURRENT_PYTHON="$APP_HOME/runtime/current/.venv/bin/python" \
  "$APP_HOME/runtime/current/.venv/bin/python" - <<'PY'
import os
from pathlib import Path

from speechrail.config import Settings
from speechrail.service.launchd import create_launch_agent_manager
from speechrail.service.profile_switch import LaunchAgentServiceController

app_home = Path(os.environ["APP_HOME"]).resolve()
settings = Settings.from_env_file(app_home / "config" / ".env")
manager = create_launch_agent_manager(working_directory=app_home)
LaunchAgentServiceController(manager, port=settings.port).start()
PY
```

`CURRENT_PYTHON` 只用于说明当前 runtime；实际启动命令必须由 `runtime/current/.venv/bin/python` 执行。若 start 前 lock 仍被占用，controller 会失败，不应循环 kickstart。

## profile apply 的生命周期

`speechrail profile apply <preset> --yes` 和 `profile rollback --yes` 已经在应用层使用同一 controller，并且额外执行：

1. 写入候选和一次性 startup permit；
2. 启动后先检查 `/health.profile` 是否等于候选；
3. 再检查 `/readyz`、模型/音色 catalog 和真实公共 smoke；
4. 失败只回滚一次，事务已自动回滚且已恢复时不得再次回滚；回滚也失败则标记 `not_ready`，不做重启重试。

这条事务路径用于模型档位切换；普通重启可以用 controller-backed `service restart`，但不能用它代替 profile 事务。

## managed installer 的前置条件

`install_managed` 在准备阶段和切换 `runtime/current` 前都会检查配置端口的 singleton lock。lock 被占用时立即失败并保留旧 release；必须先完成 `service stop`，不能在运行态直接替换 managed runtime。

## 安全边界

- 只使用精确 PID/进程组；禁止 `pkill`、`killall`、`grep | kill` 和按名称杀进程。
- 不删除旧 release、模型、selection、vendor runtime 或日志来“解决”停止问题。
- 强杀后先证明目标退出与 lock/listener 释放；只有请求包含再次启动时才继续核对单 listener、health/profile identity 和已授权 smoke。命令返回 0、进程存在或端口曾经打开都不够。
