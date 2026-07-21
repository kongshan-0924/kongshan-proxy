#!/bin/zsh
# 把 dist/kongshan.app 打包成拖拽安装式 DMG（含 /Applications 快捷方式）。
# 先运行 build_app.sh 产出 dist/kongshan.app，再运行本脚本。
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"

app_path="dist/kongshan.app"
if [[ ! -d "$app_path" ]]; then
    print "错误：$app_path 不存在，请先运行 scripts/build_app.sh" >&2
    exit 1
fi

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app_path/Contents/Info.plist")
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

size=$(du -h "$dmg_path" | cut -f1)
print "Built $dmg_path  ($size)"
