#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/macos/SpeechRailApp/SpeechRailApp.xcodeproj"
CONFIGURATION="Debug"
ACTION="build"
EXPORT_OPTIONS=""
EXPORT_PATH=""
ARCHIVE_PATH=""
CI_DERIVED_DATA=""
TIMEOUT_SECONDS="1800"
PASSTHROUGH=()
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

while (($# > 0)); do
  case "$1" in
    --ci-derived-data)
      [[ $# -ge 2 ]] || { echo "--ci-derived-data requires a value" >&2; exit 2; }
      CI_DERIVED_DATA="$2"
      shift 2
      ;;
    --configuration)
      [[ $# -ge 2 ]] || { echo "--configuration requires a value" >&2; exit 2; }
      CONFIGURATION="$2"
      shift 2
      ;;
    --archive)
      ACTION="archive"
      shift
      ;;
    --test-unit)
      ACTION="test-unit"
      shift
      ;;
    --timeout)
      [[ $# -ge 2 ]] || { echo "--timeout requires a value" >&2; exit 2; }
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --)
      shift
      PASSTHROUGH=("$@")
      break
      ;;
    --export-options)
      [[ $# -ge 2 ]] || { echo "--export-options requires a value" >&2; exit 2; }
      EXPORT_OPTIONS="$2"
      shift 2
      ;;
    --export-path)
      [[ $# -ge 2 ]] || { echo "--export-path requires a value" >&2; exit 2; }
      EXPORT_PATH="$2"
      shift 2
      ;;
    --archive-path)
      [[ $# -ge 2 ]] || { echo "--archive-path requires a value" >&2; exit 2; }
      ARCHIVE_PATH="$2"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# 把可能还不存在的路径解析成绝对路径：取最近的既存祖先做 `pwd -P`，再接上剩余段。
# 这样比较前缀时不会因为 /tmp -> /private/tmp 之类的符号链接而误判。
absolute_path() {
  local target="$1" suffix="" probe
  probe="$target"
  while [[ ! -e "$probe" ]]; do
    suffix="$(basename "$probe")${suffix:+/$suffix}"
    probe="$(dirname "$probe")"
  done
  printf '%s%s\n' "$(cd "$probe" && pwd -P)" "${suffix:+/$suffix}"
}

if [[ -n "$CI_DERIVED_DATA" ]]; then
  [[ "${GITHUB_ACTIONS:-}" == "true" && "${CI:-}" == "true" && -n "${RUNNER_TEMP:-}" ]] || {
    echo "--ci-derived-data is only supported on a GitHub Actions runner" >&2
    exit 2
  }
  [[ "$ACTION" == "build" && -z "$EXPORT_PATH" ]] || {
    echo "--ci-derived-data supports build without export only" >&2
    exit 2
  }
  CI_DERIVED_DATA="$(absolute_path "$CI_DERIVED_DATA")"
  CI_TEMP_ROOT="$(absolute_path "$RUNNER_TEMP")"
  case "$CI_DERIVED_DATA" in
    "$CI_TEMP_ROOT"/*) ;;
    *) echo "--ci-derived-data must be inside RUNNER_TEMP" >&2; exit 2 ;;
  esac
fi

# A successful App build does not compile the unit-test target. Check the
# hand-maintained test manifest before building so local validation cannot
# miss a test file that GitHub's Quality Gates would reject.
python3 "$ROOT_DIR/scripts/check_macos_test_target_coverage.py"

if [[ "$ACTION" == "archive" ]]; then
  ARCHIVE_PATH="${ARCHIVE_PATH:-$ROOT_DIR/build/SpeechRail.xcarchive}"
  if [[ -n "$EXPORT_PATH" ]]; then
    EXPORT_PATH="$(absolute_path "$EXPORT_PATH")"
    case "$EXPORT_PATH" in
      "$ROOT_DIR"|"$ROOT_DIR"/*)
        echo "--export-path must be outside the repository: $EXPORT_PATH" >&2
        exit 2
        ;;
    esac
    case "$EXPORT_PATH" in
      *.app)
        echo "--export-path is a directory that will receive SpeechRail.app, not a bundle path: $EXPORT_PATH" >&2
        exit 2
        ;;
    esac
  fi
  mkdir -p "$(dirname "$ARCHIVE_PATH")"
  xcodebuild \
    -project "$PROJECT" \
    -scheme SpeechRailApp \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    archive
  # archive 里的 Products/Applications/SpeechRail.app 不是交付物，只是中间产物。
  # xcodebuild archive 会登记它，Finder/LaunchServices 随后就能把它当成第二个已安装
  # App（本机就这么多出一个 3.2.1）。这里直接注销，交付物只有 --export-path 那份。
  "$LSREGISTER" -u "$ARCHIVE_PATH/Products/Applications/SpeechRail.app" >/dev/null 2>&1 || true
  echo "archive: $ARCHIVE_PATH"
  if [[ -n "$EXPORT_OPTIONS" ]]; then
    [[ -n "$EXPORT_PATH" ]] || { echo "--export-path is required with --export-options" >&2; exit 2; }
    xcodebuild \
      -exportArchive \
      -archivePath "$ARCHIVE_PATH" \
      -exportOptionsPlist "$EXPORT_OPTIONS" \
      -exportPath "$EXPORT_PATH"
    echo "exported distribution: $EXPORT_PATH"
  fi
elif [[ "$ACTION" == "test-unit" ]]; then
  # 单测入口走 SwiftPM，不走 `xcodebuild test`：
  # * SwiftPM 编译 `SpeechRailMacControlTests` 下的每个 `.swift`，Xcode 的
  #   `Unit Test Sources` 只列其中一部分，所以 SwiftPM 是超集（CI 同此结论）；
  # * `xcodebuild test` 进入测试前要先解析 test bundle。bundle 无法解析的主机
  #   （例如 CoreSimulator 与 Xcode 版本不匹配）会直接报
  #   "No test bundle product for testingSpecifier"，一条单测都跑不到——这正是
  #   这个入口在 2026-10-27 那台机器上失败的原因；
  # * 该入口不产出 `.app`，因此不需要 DerivedData 隔离与 LaunchServices 注销。
  # App target 的编译链接证明由默认 build 动作负责。
  [[ -z "$ARCHIVE_PATH" ]] || { echo "--archive-path is not supported with --test-unit" >&2; exit 2; }
  [[ -z "$EXPORT_OPTIONS" ]] || { echo "--export-options is not supported with --test-unit" >&2; exit 2; }
  [[ -z "$EXPORT_PATH" ]] || { echo "--export-path is not supported with --test-unit" >&2; exit 2; }
  [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] && (( TIMEOUT_SECONDS > 0 )) || {
    echo "--timeout must be a positive integer number of seconds" >&2
    exit 2
  }

  cd "$ROOT_DIR"
  swift test --package-path macos/SpeechRailApp ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"} &
  TEST_PID=$!

  # 挂死兜底：SwiftPM 极少挂，但一旦挂住，脚本不能永远等下去。
  waited=0
  while kill -0 "$TEST_PID" 2>/dev/null; do
    if ((waited >= TIMEOUT_SECONDS)); then
      echo "test-unit: timed out after ${TIMEOUT_SECONDS}s, stopping swift test" >&2
      kill -TERM "$TEST_PID" 2>/dev/null || true
      sleep 5
      kill -KILL "$TEST_PID" 2>/dev/null || true
      exit 124
    fi
    sleep 1
    waited=$((waited + 1))
  done

  set +e
  wait "$TEST_PID"
  status=$?
  set -e
  if ((status != 0)); then
    echo "test-unit: FAILED (swift test exit $status)" >&2
    exit "$status"
  fi
  echo "test-unit: passed"
else
  if [[ -n "$ARCHIVE_PATH" ]]; then
    echo "--archive-path requires --archive" >&2
    exit 2
  fi
  if [[ -n "$EXPORT_OPTIONS" ]]; then
    echo "--export-options requires --archive" >&2
    exit 2
  fi
  if [[ -n "$EXPORT_PATH" ]]; then
    EXPORT_PATH="$(absolute_path "$EXPORT_PATH")"
    case "$EXPORT_PATH" in
      "$ROOT_DIR"|"$ROOT_DIR"/*)
        echo "--export-path must be outside the repository: $EXPORT_PATH" >&2
        exit 2
        ;;
    esac
    case "$EXPORT_PATH" in
      *.app)
        echo "--export-path is a directory that will receive SpeechRail.app, not a bundle path: $EXPORT_PATH" >&2
        exit 2
        ;;
    esac
    if [[ -e "$EXPORT_PATH/SpeechRail.app" ]]; then
      echo "refusing to overwrite an existing bundle: $EXPORT_PATH/SpeechRail.app" >&2
      exit 2
    fi
  fi
  if [[ -n "$CI_DERIVED_DATA" ]]; then
    DERIVED_DATA="$CI_DERIVED_DATA"
    mkdir -p "$DERIVED_DATA"
  else
    DERIVED_DATA="$(mktemp -d "${TMPDIR:-/tmp}/speechrail-macos-build.XXXXXX")"
  fi
  PRODUCT="$DERIVED_DATA/Build/Products/$CONFIGURATION/SpeechRail.app"

  cleanup_build_artifacts() {
    "$LSREGISTER" -u "$PRODUCT" >/dev/null 2>&1 || true
    # 导出的副本同样注销：它是待安装的**来源**，正式路径由安装那一步登记。
    # 不注销的话，任何一次误开都会在 LaunchServices 里多出一条 com.speechrail.desktop。
    if [[ -n "$EXPORT_PATH" && -d "$EXPORT_PATH/SpeechRail.app" ]]; then
      "$LSREGISTER" -u "$EXPORT_PATH/SpeechRail.app" >/dev/null 2>&1 || true
    fi
    if [[ -n "$CI_DERIVED_DATA" ]]; then
      # Keep compiler intermediates for CI, never keep a launchable App bundle.
      /bin/rm -rf "$PRODUCT"
    else
      /bin/rm -rf "$DERIVED_DATA"
    fi
  }

  trap cleanup_build_artifacts EXIT

  xcodebuild \
    -project "$PROJECT" \
    -scheme SpeechRailApp \
    -configuration "$CONFIGURATION" \
    -sdk macosx \
    -derivedDataPath "$DERIVED_DATA" \
    build \
    ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}

  if [[ -n "$EXPORT_PATH" ]]; then
    /bin/mkdir -p "$EXPORT_PATH"
    /usr/bin/ditto "$PRODUCT" "$EXPORT_PATH/SpeechRail.app"
    # 本地 Debug/Release 档位嵌的是 local-control XPC，导出件必须过同一个门禁，
    # 否则安装那一步拿到的只是一个「能双击但控制通道不可用」的壳。
    if [[ "$CONFIGURATION" != "Distribution" ]]; then
      "$ROOT_DIR/scripts/macos_app_verify_local_xpc.sh" "$EXPORT_PATH/SpeechRail.app"
    fi
    echo "exported app bundle: $EXPORT_PATH/SpeechRail.app"
    echo "install it with: ditto \"$EXPORT_PATH/SpeechRail.app\" \"\$HOME/Applications/SpeechRail.app\""
  fi
fi
