# 运维文档

本目录面向部署、启动、排障、升级和回滚 SpeechRail 的操作者。首发运行模型是 macOS 本机单服务进程、单 ASGI worker、每个已配置 profile 一个隔离 worker；服务不会下载或搬运模型。

## 推荐阅读顺序

1. [运行时与部署](runtime-deployment.md)：确认外部 snapshot/runtime、配置键、端口和进程拓扑。
2. [运维 Runbook](operations-runbook.md)：按上线、启动、健康检查、`launchd`、故障处理和回滚执行。
3. [安全与可观测性](security-observability.md)：确认网络、敏感数据、日志和容量边界。
4. [迁移 Runbook](migration-runbook.md)：执行客户端切换、影子验证、回滚和旧路径退役。
5. [当前边界与剩余风险](../architecture/current-boundaries.md)：发布前核对验收门。

## 运行入口

- 环境模板：[configs/speechrail.example.env](../../configs/speechrail.example.env)
- macOS 模板：[LaunchAgent plist](../../deploy/macos/com.speechrail.plist.example)
- 健康端点：`/health`、`/readyz`、`/v1/models`、`/v1/voices`
- 默认服务地址：`http://127.0.0.1:8201`

健康端点返回 200 表示推理入口就绪；音频质量、并发、峰值内存与客户端迁移的验收以对应
smoke、性能基准和回滚演练为准。
