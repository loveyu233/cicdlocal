#!/bin/bash
# 只检查本项目的 App 包，不启动应用或改变 Gatekeeper 设置。
set -euo pipefail
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "用法：scripts/verify-app.sh /绝对路径/LocalCICD.app [--require-runtime]" >&2
    exit 2
fi
app="$1"
require_runtime="${2:-}"
if [[ "$app" != /* ]] || [[ "$app" != *.app ]] || { [ -n "$require_runtime" ] && [ "$require_runtime" != "--require-runtime" ]; }; then
    echo "请提供本项目 App 的绝对路径和有效选项。" >&2
    exit 2
fi
identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
if [ "$identifier" != "io.github.loveyu233.cicdlocal" ]; then
    echo "拒绝检查其他项目的应用包。" >&2
    exit 1
fi
for executable in "$app/Contents/MacOS/LocalCICD" "$app/Contents/MacOS/localcicd-hook"; do
    test -x "$executable"
    /usr/bin/lipo -verify_arch arm64 "$executable"
    /usr/bin/codesign --verify --strict --verbose=2 "$executable"
    # 绝对动态库依赖只能来自系统；不能依赖开发目录中的 SwiftPM 构建结果。
    while IFS= read -r dependency; do
        case "$dependency" in
            /System/Library/*|/usr/lib/*|@rpath/*|@loader_path/*|@executable_path/*) ;;
            *) echo "发现无法用于分发的动态库依赖：$dependency" >&2; exit 1 ;;
        esac
    done < <(/usr/bin/otool -L "$executable" | /usr/bin/awk 'NR > 1 {print $1}')
    if [ "$require_runtime" = "--require-runtime" ]; then
        signature=$(/usr/bin/codesign -dv --verbose=4 "$executable" 2>&1)
        if [[ "$signature" != *"runtime"* ]] || [[ "$signature" != *"Authority=Developer ID Application:"* ]]; then
            echo "正式分发需要 Developer ID 签名和 Hardened Runtime：$executable" >&2
            exit 1
        fi
    fi
done
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
echo "App 包结构、arm64、主程序与辅助程序签名及动态库依赖检查通过。"
