#!/bin/zsh
# 把 .build/kongshan.app 打包成拖拽安装式 DMG（含 /Applications 快捷方式）。
# dist 保留历史 DMG，只清理可运行 App 副本与索引垃圾文件。
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"

app_path=${KONGSHAN_APP_PATH:-"$project_dir/.build/kongshan.app"}
if [[ ! -d "$app_path" ]]; then
    print "错误：$app_path 不存在，请先运行 scripts/build_app.sh" >&2
    exit 1
fi

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app_path/Contents/Info.plist")
mkdir -p "$project_dir/dist"
dmg_path="dist/kongshan-$version.dmg"

staging=$(mktemp -d)
cleanup() { rm -rf "$staging"; }
trap cleanup EXIT

# 拖拽安装布局：App + 指向 /Applications 的软链
cp -R "$app_path" "$staging/kongshan.app"
ln -s /Applications "$staging/Applications"

rm -f "$dmg_path"
hdiutil create \
    -volname "kongshan $version" \
    -srcfolder "$staging" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$dmg_path" >/dev/null

if [[ -n "${KONGSHAN_CODESIGN_IDENTITY:-}" && "$KONGSHAN_CODESIGN_IDENTITY" != "-" ]]; then
    codesign --force --sign "$KONGSHAN_CODESIGN_IDENTITY" --timestamp "$dmg_path"
fi

# 公证是可选发布步骤；只使用本机 Keychain 中已配好的 profile，脚本不接收也不保存账号密钥。
if [[ -n "${KONGSHAN_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$dmg_path" --keychain-profile "$KONGSHAN_NOTARY_PROFILE" --wait
    xcrun stapler staple "$dmg_path"
fi

size=$(du -h "$dmg_path" | cut -f1)
# **不删历史 DMG**：发布只做加法，旧版本产物是回滚点与追溯依据（用户 2026-08-23 明确要求）。
# 仍要清掉 dist 里的可运行 App 副本——它会被 Launch Services 记住，导致误启动第二个实例。
rm -rf "$project_dir/dist/kongshan.app"
rm -f "$project_dir/dist/.metadata_never_index" "$project_dir/dist/.DS_Store"
print "Built $dmg_path  ($size)"
