# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.3.x   | :white_check_mark: |
| 1.2.x   | :x:                |
| < 1.2.0 | :x:                |

## Reporting a Vulnerability

SpeechRail 是一个本地优先（Local-First）且设计上默认仅绑定本地 Loopback (`127.0.0.1`) 的语音运行时服务。

如果您发现了安全漏洞（例如认证绕过、本地命令注入、不安全的反序列化或未经授权的网络外呼），我们非常感激您遵循负责任的漏洞披露原则：

1. **请勿通过公开 Issue 报告安全漏洞**。
2. 请直接发送加密邮件至项目维护者邮箱：**aaronwong1989@gmail.com**。
3. 请在报告中包含：
   - 漏洞类型与影响范围
   - 复现步骤或 PoC (Proof of Concept)
   - 建议的缓解或修复方案（如有）
4. 我们将在 **48 小时内** 确认收到您的报告并展开评估，并在修复完成且发布安全补丁版本后公开致谢。
