#!/bin/bash
# 逐包运行 swift test。用法：scripts/test-packages.sh [包名 ...]
set -euo pipefail
cd "$(dirname "$0")/.."

packages=("$@")
if [ ${#packages[@]} -eq 0 ]; then
    packages=(Models Platform Storage GitKit LogKit PushWatch Runner ApplicationKit)
fi

# Command Line Tools 6.4 的 swiftbuild 约一半概率不给测试目标加载 TestingMacros 插件，
# 报 "plugin for module 'TestingMacros' not found"。显式加载插件后稳定（§17 2026-10-20）。
EXTRA=()
TESTING_PLUGIN="$(xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$TESTING_PLUGIN" ]; then
    EXTRA=(-Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN")
fi

failed=()
for p in "${packages[@]}"; do
    echo "==> $p"
    log="$(mktemp)"
    test_exit=0
    swift test --package-path "Packages/$p" ${EXTRA[@]+"${EXTRA[@]}"} >"$log" 2>&1 || test_exit=$?
    if [ "$test_exit" -eq 0 ] && grep -qE "^✔ Test run" "$log" && ! grep -qE "^✘" "$log"; then
        grep -E "^✔ Test run" "$log" || tail -n 1 "$log"
    else
        # 失败时只打印错误行，完整输出留在临时文件里
        grep -E "error:|✘" "$log" | grep -v "^/Library" | head -n 20 || true
        echo "完整输出：$log"
        failed+=("$p")
    fi
done

if [ ${#failed[@]} -gt 0 ]; then
    echo "失败的包：${failed[*]}" >&2
    exit 1
fi
echo "全部 ${#packages[@]} 个包测试通过"
