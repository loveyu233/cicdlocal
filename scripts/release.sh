#!/bin/bash
# 默认复用本地开发身份；正式签名和上传公证必须显式选择。
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:---local}"
if [ "$#" -gt 1 ]; then
    echo "用法：scripts/release.sh [--local|--signed|--notarize|--help]" >&2
    exit 2
fi
if [ "$mode" = "--help" ]; then
    cat <<'HELP'
用法：scripts/release.sh [--local|--signed|--notarize]
  --local     默认。复用界面测试的开发签名生成 Release 归档和 ZIP，供本机使用。
  --signed    使用已有 Developer ID 证书归档、导出并检查签名，不上传。
  --notarize  在正式签名后上传 Apple 公证，成功后附加票据并生成分发 ZIP。
正式模式需要环境变量 LOCALCICD_SIGNING_IDENTITY、LOCALCICD_TEAM_ID。
公证还需要 LOCALCICD_NOTARY_PROFILE，指向已在钥匙串中登记的 notarytool profile。
脚本不创建证书、不更改系统签名设置、不自动更新 provisioning。
本地模式使用 LOCALCICD_UI_SIGNING_IDENTITY 或已记住的开发证书；仅显式设为 - 才使用临时签名。
HELP
    exit 0
fi
case "$mode" in --local|--signed|--notarize) ;; *) echo "未知打包模式。" >&2; exit 2 ;; esac
identity="-"
team=""
if [ "$mode" = "--local" ]; then
    identity="$(python3 scripts/ui_signing.py)"
else
    identity="${LOCALCICD_SIGNING_IDENTITY:?请设置已有 Developer ID Application 证书名称}"
    team="${LOCALCICD_TEAM_ID:?请设置开发团队标识}"
    if [[ "$identity" != "Developer ID Application:"* ]] || [[ ! "$team" =~ ^[A-Z0-9]{10}$ ]]; then
        echo "正式签名身份或团队标识格式不正确。" >&2
        exit 2
    fi
fi
if [ "$mode" = "--notarize" ]; then
    : "${LOCALCICD_NOTARY_PROFILE:?请设置已有 notarytool 钥匙串 profile 名称}"
fi
if [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcodegen generate --quiet
mkdir -p build/releases
output="$(pwd)/$(mktemp -d build/releases/localcicd-XXXXXXXX)"
archive="$output/LocalCICD.xcarchive"
if ! xcodebuild -project LocalCICD.xcodeproj -scheme LocalCICD -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$archive" \
    -derivedDataPath build/ReleaseDerivedData \
    CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$identity" "DEVELOPMENT_TEAM=$team" \
    archive >"$output/archive.log" 2>&1; then
    echo "归档失败，完整日志：$output/archive.log" >&2
    tail -n 20 "$output/archive.log" >&2
    exit 1
fi
if [ "$mode" = "--local" ]; then
    app="$output/LocalCICD.app"
    /usr/bin/ditto "$archive/Products/Applications/LocalCICD.app" "$app"
    scripts/verify-app.sh "$app"
else
    options="$output/ExportOptions.plist"
    /usr/bin/plutil -create xml1 "$options"
    /usr/bin/plutil -insert method -string developer-id "$options"
    /usr/bin/plutil -insert signingStyle -string manual "$options"
    /usr/bin/plutil -insert signingCertificate -string "$identity" "$options"
    /usr/bin/plutil -insert teamID -string "$team" "$options"
    /usr/bin/plutil -insert stripSwiftSymbols -bool YES "$options"
    if ! xcodebuild -exportArchive -archivePath "$archive" -exportPath "$output/export" \
        -exportOptionsPlist "$options" >"$output/export.log" 2>&1; then
        echo "导出失败，完整日志：$output/export.log" >&2
        exit 1
    fi
    app="$output/export/LocalCICD.app"
    scripts/verify-app.sh "$app" --require-runtime
fi
zip="$output/LocalCICD.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
if [ "$mode" = "--notarize" ]; then
    xcrun notarytool submit "$zip" --keychain-profile "$LOCALCICD_NOTARY_PROFILE" --wait \
        --output-format json >"$output/notarization.json"
    if [ "$(/usr/bin/plutil -extract status raw "$output/notarization.json")" != "Accepted" ]; then
        echo "Apple 未接受此公证请求，请检查 $output/notarization.json。" >&2
        exit 1
    fi
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    scripts/verify-app.sh "$app" --require-runtime
    /usr/sbin/spctl --assess --type execute --verbose=2 "$app"
    zip="$output/LocalCICD-notarized.zip"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
fi
echo "打包模式：$mode"
echo "App：$app"
echo "ZIP：$zip"
if [ "$mode" = "--local" ]; then
    echo "这是本机使用的签名包；未执行 Developer ID 签名或 Apple 公证。"
fi
