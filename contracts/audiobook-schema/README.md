# 有声书作品库结构快照

本目录保存 `AudiobookStore` 的 SQLite DDL 快照，供建库结构一致性与历史升级回归使用。版本由 `AudiobookStoreSchema.currentUserVersion` 声明，快照对应 `createTablesSQL` 并以 `PRAGMA user_version` 标识版本。

## 快照与升级规则

- 已合入基线的 `v<N>.sql` 冻结，不修改、覆盖或删除。
- 建库结构变化时递增 `currentUserVersion`，新增对应快照，并同步实现迁移和历史库升级测试；不复用旧版本。
- 快照只包含受校验器允许的结构语句和 PRAGMA，不包含业务数据。
- `scripts/check_audiobook_schema.py --base-ref <ref>` 对照 Git 基线核对版本递增与历史快照不变，并核对当前 Swift 建库 SQL 与快照的结构一致性。该检查不能代替迁移代码的执行测试。

## 快照导航

| 文件 | 版本 | 内容 |
|---|---|---|
| [v6.sql](v6.sql) | 6 | 加工文本修订字段引入前的冻结作品库结构 |
| [v7.sql](v7.sql) | 7 | `sources` 增加加工文本身份、参考来源、准备版本、来源映射与工作流快照字段，`characters` 增加 `source_id` |

## 校验入口

在仓库根目录执行，Python 开发依赖须已准备：

```bash
uv run --no-sync --extra dev python scripts/check_audiobook_schema.py --base-ref origin/main
uv run --no-sync --extra dev pytest --no-cov tests/test_audiobook_schema_contract.py
swift test --package-path macos/SpeechRailApp --filter AudiobookStoreTests
```

历史 DDL 建库、数据保留、失败回滚与结构漂移的验收要求见[数据库结构与升级门禁](../../docs/developers/testing-acceptance.md#数据库结构与升级门禁)。
