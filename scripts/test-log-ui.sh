#!/bin/bash
# 纯组件回归：不接触主 App 数据或真实项目，仅创建不可见的测试窗口。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/log-ui-regression
if [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
# SwiftUI 27 的 State 使用平台宏插件，独立编译组件时显式加载。
plugin="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
xcrun swiftc -load-plugin-library "$plugin" -parse-as-library \
  App/Main/StageStrip.swift App/Main/NativeLogText.swift App/Main/LogTextStyler.swift App/Main/ResultBanner.swift \
  scripts/test-log-ui.swift -o build/log-ui-regression/tests
build/log-ui-regression/tests
