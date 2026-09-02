## 📝 变更说明

<!-- 请清晰描述本次 PR 解决的问题、新增的特性或优化的动机。 -->

### 变更类型 (Type of Change)
- [ ] 🐛 Bugfix (修复缺陷)
- [ ] ✨ Feature (新功能或新能力)
- [ ] ⚡ Performance (性能优化与显存/内存治理)
- [ ] 📚 Documentation (文档改进)
- [ ] ♻️ Refactoring (代码重构，无功能或契约变化)
- [ ] 🧪 Tests (测试用例补充)
- [ ] 🔧 Chore (工程化与构建系统维护)

---

## 🔍 核心实现细节

<!-- 简要列举核心修改点与设计考量。 -->
1. 
2. 

---

## 🧪 验证与自测结果

<!-- 请列出本地运行的验证命令与实测结果。 -->
- [ ] 单元与契约测试全绿：`uv run --extra dev pytest -q --no-cov`
- [ ] 测试覆盖率达标 (>= 80.0%)：`uv run --extra dev pytest --cov=src`
- [ ] 代码规范与 Lint 通过：`uv run --extra dev ruff check src tests`
- [ ] 严格静态类型检查通过：`uv run --extra dev mypy src`

---

## 🛡️ 契约与安全检查清单

- [ ] 本次改动 **未破坏对外 OpenAI 兼容契约**（REST/WebSocket 字段与事件模型一致）
- [ ] 绝不向外暴露或自动下载云端模型，严格保持 **本地优先与绝对隐私**
- [ ] 提交中 **未包含任何包含私有路径、凭据或未脱敏音频的敏感文件**
