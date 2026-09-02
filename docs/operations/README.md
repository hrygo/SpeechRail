---
title: "SpeechRail 运维与 SRE 文档中心"
status: active
audience: "运维工程师、SRE、系统管理员"
version: "1.4.0"
date: 2026-09-02
---

# 📦 SpeechRail 运维与 SRE 文档

欢迎查阅 SpeechRail 运维文档。本目录面向负责 macOS 本机部署、LaunchAgent 常驻服务生命周期管理、版本升级与回滚、监控诊断以及故障排查的 SRE 与运维人员。

---

## 📑 推荐阅读路径

```mermaid
graph TD
    A[🚀 1. 运行时与环境部署<br/>runtime-deployment.md] --> B[📖 2. 运维操作手册 (Runbook)<br/>operations-runbook.md]
    B --> C[🔒 3. 安全防护与可观测性<br/>security-observability.md]
    C --> D[🔄 4. 客户端迁移与平滑回滚<br/>migration-runbook.md]
```

1. **[🚀 运行时与环境部署 (runtime-deployment.md)](runtime-deployment.md)**：外部模型 Snapshot 目录规范、隔离 Python 虚拟环境配置与端口规划。
2. **[📖 运维操作手册 (operations-runbook.md)](operations-runbook.md)**：macOS `launchd` 用户级服务管理、原子化升级/回滚流程与故障排查决策树。
3. **[🔒 安全防护与可观测性 (security-observability.md)](security-observability.md)**：网络访问控制、日志脱敏规范、内存配额与健康探针标准。
4. **[🔄 客户端迁移与平滑回滚 (migration-runbook.md)](migration-runbook.md)**：QwenPaw 与 Sona 的平滑切换、影子流量验证与旧端点退役流程。

---

## 🛠️ macOS 服务常用操作速查

```bash
# 1. 安装当前用户的 LaunchAgent 配置文件
uv run speechrail service install

# 2. 启用常驻后台服务
uv run speechrail service enable

# 3. 实时查看服务运行状态与 PID
uv run speechrail service status

# 4. 重启服务（重新加载模型）
uv run speechrail service restart

# 5. 停用服务 / 完全卸载
uv run speechrail service disable
uv run speechrail service uninstall
```

---

> [!IMPORTANT]
> - SpeechRail 专为 **macOS (Apple Silicon)** 设计，默认绑定 `127.0.0.1:8201`。
> - 禁止以 `root` 权限或作为系统级 `LaunchDaemon` 运行，必须作为当前登录用户的 `LaunchAgent` 托管。
