# SpeechRail 本机部署故障排查

先读取主 SOP 和 [生命周期 controller](lifecycle.md)。所有服务故障先确认“单实例、单 listener、lock 是否释放”，再判断模型或依赖；不要把旧 listener 的响应当成候选版本的结果。

## 1. 端口冲突或 server_already_running

~~~bash
APP_HOME="${SPEECHRAIL_APP_HOME:-$HOME/Library/Application Support/SpeechRail}"
speechrail service status --app-home "$APP_HOME"
lsof -nP -iTCP:8201 -sTCP:LISTEN
~~~

若不是唯一的 managed PID，停止发布/切换操作。使用生命周期 controller 完成 bootout、2 秒 lock 等待、精确进程组 SIGKILL 和最多 10 秒的二次 lock 等待；禁止 pkill、killall、kill -TERM 猜 PID 或连续 restart。

## 2. worker_load_error

按以下顺序排查：

1. listener 是否只有一个；
2. launchctl print gui/$(id -u)/com.speechrail 的 PID 是否属于 runtime/current/.venv/bin/python；
3. 旧父进程或 vendor worker 是否仍持有 per-port lock；
4. speechrail service preflight 是否从 managed runtime 执行；
5. 单实例清理后再重试一次。

只有在单实例、runtime identity 和 preflight 都正确后，才检查模型 snapshot/hash 或 vendor stderr；不能先删除模型或打开下载开关。

## 3. launchctl exit 5 或启动后仍是旧版本/profile

bootout 返回早于旧进程退出，或 smoke 打到了旧 listener。停止重试，读取 /health.profile、runtime/current、PID executable 和 lock；重新走生命周期 controller。候选启动前 lock 未释放时必须失败，不得继续 kickstart。

## 4. /readyz 503 或 preflight 失败

~~~bash
APP_HOME="${SPEECHRAIL_APP_HOME:-$HOME/Library/Application Support/SpeechRail}"
speechrail service preflight --app-home "$APP_HOME"
readlink "$APP_HOME/runtime/current"
speechrail profile status --app-home "$APP_HOME"
~~~

确认 selection、snapshot hash、共享 vendor runtime、配置权限和 managed Python。preflight 失败时保持停服，修复后重新执行；不要用源码 checkout 的依赖结果替代 managed runtime。

## 5. this wheel is already staged

这通常表示上次安装在创建 release 后中断。先核对该 wheel 的 SHA-256、release 目录是否完整、runtime/current 是否仍指向旧 release，以及旧回退点是否存在。优先复用完整 release 或运行受审查的 installer 回滚；不要直接 rm -rf、删除整个 runtime/releases 或覆盖未知目录。

## 6. plist 或配置问题

~~~bash
plutil -lint "$HOME/Library/LaunchAgents/com.speechrail.plist"
stat -f '%Sp %N' "$HOME/Library/Application Support/SpeechRail/config/.env"
~~~

私有配置必须为 0600 且不能是 symlink。重新安装 plist 使用当前 managed runtime 的 speechrail service install；不要手工编辑 plist 或复制 .env 全文到报告。

若只需修复权限，可执行 `chmod 0600` 后重新运行 managed preflight；不要替换配置内容：

~~~bash
chmod 0600 "$HOME/Library/Application Support/SpeechRail/config/.env"
~~~

## 7. 日志证据

只截取与失败时间窗口对应的脱敏尾部，避免输出 key、音频、完整转写、完整 prompt 或完整配置：

~~~bash
tail -n 80 "$HOME/Library/Logs/SpeechRail/stderr.log"
tail -n 80 "$HOME/Library/Logs/SpeechRail/stdout.log"
~~~

交付记录版本、wheel hash、runtime target、profile/generation、PID/listener、错误码、controller stop 结果和回退目标；原始日志保留在 app home，不提交 Git。
