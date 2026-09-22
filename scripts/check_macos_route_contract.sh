#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_ROUTE="$ROOT_DIR/macos/SpeechRailApp/SpeechRailApp/AppRoute.swift"
APP="$ROOT_DIR/macos/SpeechRailApp/SpeechRailApp/App.swift"
CONTROL_CENTER="$ROOT_DIR/macos/SpeechRailApp/SpeechRailApp/ControlCenterView.swift"
UI_TESTS="$ROOT_DIR/macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift"
MATRIX="$ROOT_DIR/docs/design/2026-09-15-macos-uiux-redesign/UIUX-AUDIT-MATRIX.md"

fail() {
  echo "route contract check failed: $1" >&2
  exit 1
}

rg -q 'public var shortcutSpec: AppRouteShortcutSpec\?' "$APP_ROUTE" \
  || fail "AppRoute.shortcutSpec is missing"
rg -q 'public static func routes\(in group: AppRouteGroup\)' "$APP_ROUTE" \
  || fail "AppRoute.routes(in:) is missing"

for spec in \
  'case \.dubbing:\s+\.init\(key: "1", modifiers: \.command\)' \
  'case \.voiceDesign:\s+\.init\(key: "2", modifiers: \.command\)' \
  'case \.voiceClone:\s+\.init\(key: "3", modifiers: \.command\)' \
  'case \.voiceLibrary:\s+\.init\(key: "4", modifiers: \.command\)' \
  'case \.works:\s+\.init\(key: "5", modifiers: \.command\)' \
  'case \.assistant:\s+\.init\(key: "6", modifiers: \.command\)' \
  'case \.meeting:\s+\.init\(key: "7", modifiers: \.command\)' \
  'case \.captions:\s+\.init\(key: "8", modifiers: \.command\)' \
  'case \.teleprompter:\s+\.init\(key: "t", modifiers: \.commandShift\)' \
  'case \.overview:\s+\.init\(key: "9", modifiers: \.command\)' \
  'case \.monitoring:\s+\.init\(key: "0", modifiers: \.command\)' \
  'case \.models:\s+\.init\(key: "m", modifiers: \.commandShift\)' \
  'case \.diagnostics:\s+\.init\(key: "d", modifiers: \.commandShift\)' \
  'case \.developerDocs:\s+\.init\(key: "h", modifiers: \.commandShift\)'
do
  rg -U -q "$spec" "$APP_ROUTE" || fail "missing shortcut spec: $spec"
done

for route in \
  dubbing voiceDesign voiceClone voiceLibrary works \
  assistant meeting captions teleprompter \
  overview monitoring models diagnostics developerDocs
do
  rg -q "^    case $route$" "$APP_ROUTE" \
    || fail "AppRoute enum is missing: $route"
done

for title in \
  '配音台' '音色创作' '音色克隆' '音色库' '我的作品' \
  '语音助手' '会议助手' '实时字幕' 'AI 提词器' \
  '服务状态' '运行监控' '模型' '诊断' '开发者文档'
do
  rg -q "\"$title\"" "$UI_TESTS" \
    || fail "UI test route list is missing: $title"
done

for route in \
  dubbing voiceDesign voiceClone voiceLibrary works \
  assistant meeting captions teleprompter \
  overview monitoring models diagnostics developerDocs
do
  rg -q "\| $route \|" "$MATRIX" \
    || fail "audit matrix is missing route: $route"
done

if rg -q 'routeShortcuts|route == \.teleprompter' "$APP"; then
  fail "SpeechRailCommands still owns a duplicate shortcut map or teleprompter exception"
fi

for group in creator session service
do
  rg -q "AppRoute\\.routes\\(in: \\.$group\\)" "$CONTROL_CENTER" \
    || fail "ControlCenterView does not derive the $group group from AppRoute"
done

echo "macOS route contract: 14 enum cases, 14 shortcut specs, 14 UI test entries, 14 matrix entries, one registry"
