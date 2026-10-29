#!/bin/bash
# 生成工程、构建 App，并逐包测试。
# 用法：scripts/build.sh [--skip-tests]
set -euo pipefail
cd "$(dirname "$0")/.."

# xcode-select 仍指向 Command Line Tools 时，只对本脚本改用 Xcode，不改系统设置。
if [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

identity="$(python3 scripts/ui_signing.py)"
xcodegen generate --quiet
mkdir -p build
build_log="build/xcodebuild.log"
# 与原生测试和本地 Release 使用同一身份，保留已有系统授权。
if ! xcodebuild \
    -project LocalCICD.xcodeproj \
    -scheme LocalCICD \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build/DerivedData \
    CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$identity" DEVELOPMENT_TEAM= \
    build >"$build_log" 2>&1; then
    grep -E "error:|BUILD FAILED" "$build_log" | tail -n 30 || true
    echo "构建失败，完整日志：${build_log}" >&2
    exit 1
fi
grep -E "warning: .*\.swift|BUILD SUCCEEDED" "$build_log" || true

app="build/DerivedData/Build/Products/Debug/LocalCICD.app"
if [ ! -x "$app/Contents/MacOS/LocalCICD" ]; then
    echo "构建失败：没有生成 ${app}" >&2
    exit 1
fi
echo "App：${app}"

if [ "${1:-}" != "--skip-tests" ]; then
    # 包测试沿用 Command Line Tools，与单独运行 scripts/test-packages.sh 一致。
    env -u DEVELOPER_DIR scripts/test-packages.sh
fi
