---
title: "SpeechRail macOS App 分发与签名"
status: active
version: "0.1.1"
date: 2026-09-13
---

# SpeechRail macOS App 分发与签名

## 当前状态

当前开发机按无 Apple Developer ID 模式运行：Debug/Release 使用 ad hoc 本地签名构建并关闭 Hardened Runtime，测试脚本默认保留该本地签名，以便 Xcode UI test runner 正常加载 `Testing.framework` 运行库；不会生成可分发的 archive，不会上传 notarization，也不会修改钥匙串或用户的登录项。只有显式设置 `SPEECHRAIL_MACOS_SIGNED_TESTS=0` 才会请求 unsigned test bundle；Distribution 配置才启用 Hardened Runtime。

这不等同于可交付给其他 Mac 的发布包。站外直接分发仍保留 Developer ID Application + notarization 路径，待用户准备 Apple Developer 账号、证书和 notarization credential 后再启用。

## 本地无证书开发

```bash
scripts/macos_app_build.sh --configuration Debug
scripts/macos_app_test.sh
```

本地测试不需要 Developer ID。测试使用 `--ui-test` fake transport，不注册生产 helper、不启动 `com.speechrail`、不下载模型。测试生成的 DerivedData、`.xcresult` 和构建产物留在本机忽略目录。

## Developer ID 发布前置

发布机需要具备：

- Apple Developer 账号及目标 App 的 Team ID；
- `Developer ID Application` 证书及对应私钥；
- 可被 `notarytool` 使用的 Keychain profile；
- 与 `com.speechrail.desktop`、`com.speechrail.desktop.control` 对应的签名配置。

Team ID、证书名称、Apple ID、app-specific password、API key 和 Keychain profile 名称都只通过用户本机环境或钥匙串传入，不写入仓库。不要把真实 `ExportOptions.plist` 提交到仓库；以 `macos/SpeechRailApp/ExportOptions.plist.example` 为模板，在仓库外复制并替换占位值。

## Archive / export / verify

准备好签名身份后，在仓库根目录执行：

```bash
export SPEECHRAIL_TEAM_ID="<your-team-id>"
scripts/macos_app_archive.sh \
  --export-options "/path/outside/repository/ExportOptions.plist" \
  --export-path "build/macos-export"
scripts/macos_app_verify_distribution.sh "build/macos-export/SpeechRail.app"
```

`macos_app_verify_distribution.sh` 会逐项验证 App、嵌套 framework、Agent executable 以及 LaunchAgent plist，不使用 `codesign --deep` 掩盖嵌套代码签名问题。验证项包括：

- Hardened Runtime 和签名完整性；
- App bundle 内 `SpeechRailControlAgent` 存在且可执行；
- helper plist 位于 `Contents/Library/LaunchAgents/`；
- helper plist 使用 `BundleProgram`，而不是旧式 `Program`；
- Distribution 构建不会保留本地 `SPEECHRAIL_ALLOW_UNSIGNED_XPC` 开发开关；
- 构建时若有 Team ID，会把它注入 helper 环境，供 Agent 生成 same-team XPC requirement。

## Notarization

压缩导出的 App 后，通过 Keychain profile 调用 `notarytool` 上传；成功后 staple，再用 `spctl --assess` 和 `codesign --verify --strict` 验证。命令中的 credential 只引用 Keychain profile，不把秘密放在命令参数、日志或仓库文件中。

当前无 Apple Developer ID 时，以上步骤属于未执行项；ad hoc 本地签名不能替代 Developer ID，不能把本地 build 说明为 Developer ID 已签名或已公证的分发包。

## 回滚

若新 App 已注册 control helper，先在 App 中注销 helper，再移除新 App bundle，恢复上一版本 App。回滚不删除 SpeechRail app home、模型、私有配置、运行时或现有 `com.speechrail` LaunchAgent；App/Agent 退出也不应自动停止现有服务。
