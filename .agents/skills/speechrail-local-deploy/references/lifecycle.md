# SpeechRail 生命周期控制器

wheel 替换时使用 `speechrail service stop`；`service disable` 只是兼容别名。controller 会在 `launchctl bootout` 后确认 per-port lock，不能把单独的 `launchctl` 成功返回当成旧进程已退出。

## 安全 stop/start

下面的 Python 片段只读取 app home 的私有配置，不打印配置内容。它要求当前 release 已包含 `LaunchAgentServiceController`；缺失时应中止发布并先升级到支持该 controller 的 release，不能退回到模糊 kill。

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
4. 失败只回滚一次；回滚也失败则标记 `not_ready`，不做重启重试。

这条事务路径用于模型档位切换；普通重启可以用 controller-backed `service restart`，但不能用它代替 profile 事务。

## managed installer 的前置条件

`install_managed` 在准备阶段和切换 `runtime/current` 前都会检查配置端口的 singleton lock。lock 被占用时立即失败并保留旧 release；必须先完成 `service stop`，不能在运行态直接替换 managed runtime。

## 安全边界

- 只使用精确 PID/进程组；禁止 `pkill`、`killall`、`grep | kill` 和按名称杀进程。
- 不删除旧 release、模型、selection、vendor runtime 或日志来“解决”停止问题。
- 强杀后必须以 lock 释放、单 listener、health/profile identity 和真实 smoke 为证据；命令返回 0、进程存在或端口曾经打开都不够。
