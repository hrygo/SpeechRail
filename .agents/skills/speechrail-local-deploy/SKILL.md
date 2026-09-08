---
name: speechrail-local-deploy
description: >-
  SpeechRail macOS 本机部署、wheel 替换、LaunchAgent 启停、managed profile 切换、故障排查和回滚 SOP。
  用于安装、升级、停服、强制清理旧进程、切档或核对本机服务；不用于远程或多实例部署。
---

# SpeechRail 本机部署、启停与切换 SOP

SpeechRail 是单机、单用户服务：只允许一个 `com.speechrail` LaunchAgent、一个 ASGI 父进程和一个 `127.0.0.1:8201` listener。模型加载和切档期间允许完全停服，停服真空可持续数分钟；正确性优先于保持端口连续可用。

跨发布、安装、停启、切档和基准的共同终态契约见 [references/operator-contract.md](references/operator-contract.md)；本文件补充本机命令和排障细节。

## 终态不变量

- app home 默认是 `$HOME/Library/Application Support/SpeechRail`；服务 label 是 `com.speechrail`；只使用用户级 `LaunchAgent`，不使用 root、`LaunchDaemon` 或手工改 plist。
- `speechrail serve` 进入 per-user/per-port `flock`。第二个进程必须失败为 `server_already_running`；看到 `worker_load_error` 之前，先排除重复父进程、遗留 vendor worker 和端口锁竞争。
- `runtime/current`、selection、共享 vendor runtime、模型 snapshot 和 wheel release 分开管理。切换只改变已校验的 selection；替换 wheel 只原子切 `runtime/current`，不覆盖配置、模型或 vendor `current`。
- `service stop`/`start`/`restart` 使用生命周期 controller；`enable`/`disable` 只保留为兼容别名。`launchctl bootout` 返回不等于 ASGI 父进程和 vendor worker 已退出，详见 [references/lifecycle.md](references/lifecycle.md)。
- 不使用 `pkill`、`killall`、模糊名称匹配或未经确认的 PID。强杀前必须重新核对当前 lock owner、命令行和 executable；只有仍一致的精确 PID/进程组才允许强杀，且不得是当前 Codex/终端进程。
- 不输出 API key、`.env` 全文、Authorization、音频、完整转写、完整日志或私有绝对路径；诊断只保留状态、版本、profile、generation、错误码和脱敏 stderr 尾部。

## 操作前快照

```bash
APP_HOME="${SPEECHRAIL_APP_HOME:-$HOME/Library/Application Support/SpeechRail}"
speechrail service status --app-home "$APP_HOME"
speechrail profile status --app-home "$APP_HOME"
readlink "$APP_HOME/runtime/current"
lsof -nP -iTCP:8201 -sTCP:LISTEN
curl --fail http://127.0.0.1:8201/health
```

记录当前 commit、wheel SHA-256、runtime target、服务 PID、active profile、generation、`/health` 的模型身份和 listener 数量。必须确认只有一个 listener；路径、label、端口或 PID 不符时先停用并定位，不能继续安装。

发布前执行 `speechrail service preflight --app-home "$APP_HOME"`。CLI 检测到当前进程不是 active managed runtime 时会自动转交给 `runtime/current/.venv/bin/python`；managed runtime 不存在或不可执行时应直接失败，不得用源码 checkout 的 `.venv` 代替安装态判断。

## 外部 realtime 客户端隔离

`service stop`、`profile apply` 和 benchmark 只管理 SpeechRail 的 LaunchAgent，不会替仍在运行的 Sona、浏览器标签页或其它 WebSocket 客户端关闭连接。诊断默认只读；停服、切档或基准前做一次外部连接快照，发现活动客户端时暂停并报告阻塞，不自动结束其他应用：

1. 用 `lsof -nP -iTCP:<port>` 区分唯一 listener 与 `ESTABLISHED` 客户端连接，记录连接所属的精确 PID；不要把 `CLOSED` 条目当成活动会话。
2. 用已配置的鉴权方式读取 `/metrics`，只检查 `speechrail_realtime_active_sessions`、`speechrail_governor_active_requests{class="batch|realtime"}` 和 streaming worker state；不把 API key 写入命令或日志。
3. 只要存在外部 established connection、active realtime session 或 active governor request，就暂停依赖静默环境的停服、切档或基准操作，报告持有连接的客户端 PID、session/active request 计数和阻塞原因，等待客户端自行断开。服务自身 stop 不等于客户端 stop。
4. 只有用户明确授权关闭指定客户端时，才在核对 PID 的命令行与 owner 后按精确 PID/进程组结束该客户端；不得使用 `pkill`、`killall` 或模糊名称匹配。维护 SpeechRail 的授权不自动包含关闭浏览器、Sona 或其它客户端。
5. 连接清零后重新做一次短公共 ASR smoke；若仍返回 `429 backend_busy`，停止切档/发布并保留连接、metrics 和 operation 状态证据，不循环重试或用旧结果补齐。

外部客户端未隔离时，`worker_load_error`、`not_ready` 或 `backend_busy` 不能直接归因于模型制品或候选 runtime。

## 首次安装

managed 首装由受审查的 installer/设置入口完成：先选择 `quality`、`balanced` 或 `light`，只准备 catalog 锁定并逐文件校验的制品，再创建共享 runtime、写入 `0600` 私有配置、执行 managed-runtime preflight、安装 LaunchAgent，最后启用并做公共 smoke。自动化切档或首装必须显式 `--yes`。

```bash
APP_HOME="${SPEECHRAIL_APP_HOME:-$HOME/Library/Application Support/SpeechRail}"
speechrail setup --app-home "$APP_HOME" --yes
speechrail profile status --app-home "$APP_HOME"
```

不为诊断临时打开模型下载、不直接运行 vendor worker 作为服务；安装和回滚统一走 managed selection。

## 启停协议

所有需要替换进程的操作都遵循以下顺序；不要用连续 `restart` 代替它：

1. 读取 `launchctl print gui/$(id -u)/com.speechrail` 的 PID；没有已加载任务时保留 PID 为空。
2. `bootout` 旧 LaunchAgent。
3. 最多等待 2 秒，反复尝试获取同一个 per-port singleton lock。
4. 仍被占用且当前 owner/PID 身份重新确认时，对该 PID 的精确进程组发送 `SIGKILL`；不递归杀其他进程，不杀当前进程。
5. 最多再等待 10 秒确认 lock 释放。仍未释放则中止，不得启动候选服务；保留旧 runtime/selection 并报告 `previous service instance did not stop`。
6. 只有 lock 已释放后才 `bootstrap`/`kickstart` 候选服务。
7. 启动真空期间不要反复重启。模型加载可能超过 30 秒，应按实际启动上限有界轮询；端口出现后仍必须验证 profile、ready 和公共 API。

profile 切换直接使用事务命令；它会准备制品、停止旧服务、写入一次性 startup permit、启动候选、检查 `/health.profile`，再做 `/readyz`、catalog 和真实 smoke：

```bash
APP_HOME="${SPEECHRAIL_APP_HOME:-$HOME/Library/Application Support/SpeechRail}"
speechrail profile apply balanced --app-home "$APP_HOME" --yes
```

`service restart` 只适合不改变 selection 的普通重启；它不替代上面的停止确认。wheel 替换的安全 stop/start 入口见 [references/lifecycle.md](references/lifecycle.md)。

## wheel 替换

1. 先完成版本、代码 gate、wheel preflight 和当前快照；确认回退 release、selection、vendor runtime 和私有配置都存在。
2. 使用 `service stop` 或当前 managed Python 执行安全 stop；status 不可用时只有经过 owner metadata、PID 和命令行校验的旧进程才允许被精确强杀。
3. 用 `tools.install_macos.install_managed(...)` 准备新 release、共享 runtime 和同一 active profile；安装器会在切换前再次确认端口 lock 已释放。失败时恢复旧指针和 runtime snapshot。
4. 使用新 `runtime/current/.venv/bin/python` 安装/启用 LaunchAgent，再按启停协议确认 lock 已释放后启动。
5. 以有界轮询检查 `/health`、`/readyz`、`/v1/models`、`/v1/voices`，再以非敏感短 fixture 做真实 ASR/TTS smoke。只看到进程、配置或 `/health` 200 不算发布成功。

不要在 wheel 替换事务中顺便改变 profile；模型档位切换单独执行并记录 generation。

## 验证清单

```bash
APP_HOME="${SPEECHRAIL_APP_HOME:-$HOME/Library/Application Support/SpeechRail}"
.agents/skills/speechrail-local-deploy/scripts/verify_service.sh
speechrail service status --app-home "$APP_HOME"
speechrail profile status --app-home "$APP_HOME"
speechrail service preflight --app-home "$APP_HOME"
```

通过条件：

- `lsof` 对 8201 只有一个 listener，PID 属于 `runtime/current/.venv/bin/python`；
- `/health.version`、wheel metadata 和 release 记录一致，ASR/TTS ready；
- `/health.profile` 与目标 selection 一致；`/readyz` 为 200；
- `/v1/models` 的 profile、artifact、variant、quantization 与 selection 一致；
- `/v1/voices` 返回当前 TTS variant 实际支持的九个 canonical roles；
- 真实 ASR/TTS 均返回 200、非空结果和 request ID；
- 没有外部 `ESTABLISHED` realtime 客户端连接，`realtime_active_sessions=0`，batch/realtime active requests 均为 0；
- 不存在第二个服务、遗留 listener 或仍持有 per-port lock 的旧进程。

## profile 切换与回滚

切换只允许一次事务和一次回滚，不做无限重试：

1. 记录 active profile、generation 和旧 prepared selection。
2. `profile apply <target> --yes`；准备阶段失败时不碰服务。
3. 停止旧服务并确认 lock 释放后启动候选；先核对 `/health.profile`，再做 ready/catalog/真实 smoke。
4. 成功才 commit generation；失败先读取 operation 状态、回滚结果和当前 selection。事务已自动回滚且已恢复时不得再次回滚；仅在确认未恢复、回退目标明确且 operation 允许时执行一次 `profile rollback --yes` 人工恢复，再走同样 stop/start/smoke。
5. 回滚也失败时标记 `not_ready`，停止继续采集或重启，保留 operation 状态、stderr 尾部、PID 和 runtime/selection 指针供人工处理。

MINOR/MAJOR 验收按 `quality → balanced → light → quality` 串行执行；每档都等待真实 ready 和 smoke，结束必须恢复开始的档位。PATCH 只测当前档，性能口径见 `speechrail-perf-benchmark`。

## 回滚

### profile

```bash
APP_HOME="${SPEECHRAIL_APP_HOME:-$HOME/Library/Application Support/SpeechRail}"
speechrail profile rollback --app-home "$APP_HOME" --yes
```

### wheel

1. 用同一安全停止协议停用当前服务。
2. 恢复快照记录的 `runtime/current`，同时核对旧 selection 与 vendor `current`；不要凭目录名猜版本。
3. 用旧 runtime 安装/启用 LaunchAgent，完成同一组 endpoint 和真实 smoke。
4. 不删除旧 release、模型、配置或日志；`disable`/`uninstall` 都不是版本回滚。

## 故障定位顺序

| 现象 | 首先确认 | 处理 |
|---|---|---|
| `worker_load_error` | listener 数量、LaunchAgent PID、per-port lock、vendor worker 是否属于同一 runtime | 先按安全 stop 清理旧进程，再用 managed runtime preflight；单进程重试仍失败才检查模型制品 |
| `server_already_running` | `lsof` 与 `launchctl print` 是否已有唯一服务 | 不启动第二实例；确认调用方使用目标 app home 和 runtime |
| `/health` 是旧 profile/版本 | `/health.profile`、`runtime/current`、PID 的实际 executable | 停止并确认 lock 释放；禁止把旧 listener 当作候选 smoke 结果 |
| `/readyz` 503 | selection、snapshot hash、共享 runtime、preflight 输出 | 保持停服，修复配置/制品后再启动；不打开下载开关掩盖问题 |
| `429 backend_busy` 或切档 smoke 不 ready | 外部 established WebSocket、`realtime_active_sessions`、governor active requests、streaming worker state | 报告活动客户端并暂停，等待客户端自行断开或用户明确授权关闭，连接与 session 清零后再重做一次短 smoke；不要循环重试或先换模型 |
| `launchctl` exit 5 | bootout 后旧父进程/worker 是否还持锁 | 等待 2 秒，按精确 PID 进程组强杀，再等最多 10 秒；不要连续 restart |
| `service preflight` 可疑失败 | CLI 是否发现并转交到 `runtime/current/.venv/bin/python` | 保留 runtime 身份和具体 FAIL 项；managed runtime 不存在时先修复 release，不要回退到源码依赖 |

交付时报告版本、wheel hash、runtime target、profile、generation、PID/listener、endpoint、真实 smoke、回退目标和未验证项，不含凭据、音频或完整日志。
