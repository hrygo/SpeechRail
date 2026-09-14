# SpeechRail GitHub Actions 未签名 DMG 发布设计

## 状态与范围

- 状态：已实现（GitHub 首次 tag runner 执行待验证）
- 日期：2026-09-14
- 范围：`.github/workflows/`、DMG 打包脚本、发布校验测试和相关开发者文档
- 不修改：应用功能、服务运行态、模型制品、用户配置，以及工作树中已有的 UI/文档并行改动

本设计在 `docs/superpowers/specs/2026-09-06-github-actions-modernization-design.md` 的可复用 CI、版本门禁和 wheel 发布基础上，补充 macOS App 的 unsigned DMG 发布路径。

## 目标

1. PR、`main` push 和 tag release 使用同一套锁定依赖与质量门禁。
2. `vX.Y.Z` tag 自动生成与版本一致的 arm64 `SpeechRail.app` 和 DMG，并作为 GitHub Release 资产发布。
3. 不要求 Developer ID、Apple 账号或公证凭据即可产出可下载的测试/早期分发包。
4. 对 App、DMG、平台相关 wheel 和 SHA-256 清单做发布前校验，失败时不执行 Release 写操作。

## 非目标

- 本阶段不签名、不 notarize、不 staple，也不新增 Apple Secrets。
- 不把真实模型、音频、私有配置或本机 LaunchAgent 带入 GitHub Actions。
- 不把 GitHub-hosted runner 当作 Apple Silicon 性能或音质验收环境。
- 不改变服务公共 API、App 功能或本机安装路径。

## 方案

### Runner 与架构

- Python 服务测试矩阵保留 `ubuntu-latest` 与 `macos-15`，覆盖当前服务支持的确定性测试。
- App UI 测试与 DMG 构建使用 `macos-26`，与 `SpeechRailApp` 的 `MACOSX_DEPLOYMENT_TARGET=26.0` 对齐。
- App Release 构建显式限定 `ARCHS=arm64`、`CODE_SIGNING_ALLOWED=NO` 和 `CODE_SIGNING_REQUIRED=NO`。

### CI

`.github/workflows/ci.yml` 同时支持普通触发和 `workflow_call`：

- `quality`：锁定 `uv.lock`，运行 Ruff、Mypy、版本一致性、OpenAPI lint、分人契约回归和差异空白检查。
- `test`：保留 Ubuntu/macOS Python 3.12 矩阵，构建 wheel 后运行完整 pytest。
- `macos-app`：在 `macos-26` 上运行 Swift package、Xcode UI test 和 plist/entitlements 检查。
- `package`：在 quality 与 test 全部成功后构建并检查唯一带版本前缀的 wheel，上传带有限保留期的 workflow artifact。普通 CI 默认使用 Ubuntu；Release 通过 `workflow_call` 的 `package-runner: macos-26` 构建并检查 Darwin 专用 CoreML worker，避免发布 wheel 丢失 native worker。

所有 Action 使用已存在的不可变 SHA 引用；普通 CI 始终只有 `contents: read`。

### Release

Release 仅由 `v*` tag push 触发：

1. `verify-tag` 读取 `pyproject.toml`，要求 tag 等于 `v` + 项目版本。
2. `ci` 调用同一份 reusable CI；失败时跳过发布。
3. `build-app` 与 `ci` 并行执行。它在 `macos-26` 上构建 unsigned Release App，调用专用脚本生成 DMG，校验 bundle/version/DMG 内容后上传 artifact。
4. `publish` 等待 `ci` 与 `build-app`，下载本次 run 的 wheel/DMG，重新核对带版本前缀的 wheel 文件名和版本，生成合并的 `SHA256SUMS`，再由唯一的 `contents: write` job 用 `gh` 幂等创建或更新 Release。

### DMG 内容

DMG 使用显式临时 staging 目录，包含：

- `SpeechRail.app`
- 指向 `/Applications` 的 `Applications` 符号链接

脚本通过 `hdiutil create` 生成压缩 UDZO 镜像，并以只读方式重新挂载，确认 App 与 Applications 链接确实存在。输出路径必须显式指定，已存在文件拒绝覆盖。

## 安全与失败边界

- 未签名 App 通过 Release 资产发布，但 Release 文案必须说明首次打开可能被 Gatekeeper 拦截，需要用户在“隐私与安全性”中手动允许；不能描述为已签名或已公证版本。
- `verify-tag`、版本检查、App 构建、DMG 校验或 checksum 任一失败，都不会执行 `contents: write` 发布步骤。
- workflow 不写入 `.env`、模型、音频、完整日志、token 或绝对私有路径。
- 重跑同一 tag 只覆盖该 tag 的同名 Release 资产，不移动 tag、不创建第二个 Release。

## 验收标准

- workflow YAML 通过 actionlint 或等价语法校验，job 依赖和 `workflow_call` 可解析。
- 新增发布校验脚本有失败与通过测试；DMG 脚本参数和 bundle/version 边界有测试。
- 本地可执行版本一致性、Ruff、Mypy、pytest、OpenAPI lint、wheel 内容和 `git diff --check` 门禁。
- GitHub tag release 的预期资产为当前构建平台生成的 wheel、arm64 unsigned DMG 和 `SHA256SUMS`。

## 回退

回退只需恢复本次 workflow/脚本/文档变更；已有 tag、Release、服务 runtime 和本机 App 不受影响。若发布 job 失败，保留 workflow artifact，修复后可对同一 tag 幂等重跑。
