---
title: "SpeechRail 运维与 SRE 文档中心"
status: active
audience: "运维工程师、SRE、系统管理员"
version: "2.0.4"
date: 2026-09-09
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
5. **[📊 会议分人端到端验收报告 (speaker-diarization-e2e-acceptance-2026-09-06.md)](speaker-diarization-e2e-acceptance-2026-09-06.md)**：SPK-E2E-1 的 2026-09-06 历史验收快照；不替代当前 runtime 能力状态，也不等同于连续 Realtime 已发布。
6. **[🧪 能力诊断与质量验收](capability-quality-acceptance.md)**：读取当前能力、运行外部语料 benchmark，并以 fail-closed 方式管理 CoreML 连续分人验收；当前状态与内存证据以此页为准。
7. **[🤝 Speaker Diarization 质量验收交接](diarization-quality-evaluation-handoff.md)**：准备受权 RTTM/UEM、两小时运行窗口与脱敏报告的最小输入。

---

## 🛠️ macOS 服务常用操作速查

```bash
# 1. 安装当前用户的 LaunchAgent 配置文件
uv run speechrail service install

# 2. 安全启动常驻后台服务
uv run speechrail service start

# 3. 实时查看服务运行状态与 PID
uv run speechrail service status

# 4. 安全重启服务（短等待后必要时精确强杀）
uv run speechrail service restart

# 5. 安全停用服务 / 完全卸载
uv run speechrail service stop
uv run speechrail service uninstall
```

`service enable` / `service disable` 保留为兼容别名，但已经经过同一套
controller-backed stop/start 流程。发布和切档不得直接调用底层 `launchctl`。

---

> [!IMPORTANT]
> - SpeechRail 专为 **macOS (Apple Silicon)** 设计，默认绑定 `127.0.0.1:8201`。
> - 禁止以 `root` 权限或作为系统级 `LaunchDaemon` 运行，必须作为当前登录用户的 `LaunchAgent` 托管。
