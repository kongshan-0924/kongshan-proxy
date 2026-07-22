#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"

zsh scripts/fetch_sing_box.sh
# 本机环境沙盒被禁用（sandbox-exec: Operation not permitted），必须显式 --disable-sandbox。
SWIFTPM_ENABLE_SANDBOX=NO swift build -c release --arch arm64 --disable-sandbox

# 版本号：VERSION 文件是唯一来源，每次构建自增修订号（x.y.Z）。
# 用 KONGSHAN_KEEP_VERSION=1 可跳过自增（重出同一版时用）。
version_file="$project_dir/VERSION"
[[ -f "$version_file" ]] || print "0.1.0" > "$version_file"
current=$(tr -d '[:space:]' < "$version_file")
major=${current%%.*}
rest=${current#*.}
minor=${rest%%.*}
patch=${rest#*.}
if [[ "${KONGSHAN_KEEP_VERSION:-0}" != "1" ]]; then
    patch=$((patch + 1))
fi
app_version="$major.$minor.$patch"
# CFBundleVersion 需单调递增的数字，用 major*10000+minor*100+patch 生成。
build_number=$((major * 10000 + minor * 100 + patch))
print "$app_version" > "$version_file"

dist_dir="$project_dir/dist"
app_path="$dist_dir/kongshan.app"
mkdir -p "$dist_dir"
# 让 Spotlight/启动服务永久忽略 dist：否则这里的 kongshan.app 会被自动索引、
# 冒充成"第二个程序"出现在启动台/程序坞（用户根本没点开过它）。标准机制：
# 目录内放 .metadata_never_index。运行的正式副本在 /Applications，dist 只是构建产物。
touch "$dist_dir/.metadata_never_index"
stage_dir=$(mktemp -d "$dist_dir/.kongshan-build.XXXXXX")
stage_app="$stage_dir/kongshan.app"

cleanup() {
    rm -rf "$stage_dir"
}
trap cleanup EXIT

mkdir -p "$stage_app/Contents/MacOS" "$stage_app/Contents/Resources"
install -m 755 .build/arm64-apple-macosx/release/kongshan "$stage_app/Contents/MacOS/kongshan"
install -m 755 .build/arm64-apple-macosx/release/KongshanHelper "$stage_app/Contents/MacOS/KongshanHelper"
install -m 755 Vendor/sing-box/sing-box "$stage_app/Contents/Resources/sing-box"
install -m 644 Resources/Info.plist "$stage_app/Contents/Info.plist"
install -m 644 Resources/THIRD_PARTY_NOTICES.md "$stage_app/Contents/Resources/THIRD_PARTY_NOTICES.md"
install -m 644 Resources/AppIcon.icns "$stage_app/Contents/Resources/AppIcon.icns"
# 把本次版本号写进 App 的 Info.plist（模板 Resources/Info.plist 保持不变，避免 git 抖动）。
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" "$stage_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$stage_app/Contents/Info.plist"
# 加固（堵 §5.1）：--options runtime 开启 hardened runtime。它让内核忽略 DYLD_INSERT_LIBRARIES
# （无 allow-dyld-environment-variables 权限），挡住"同用户把库注入正版进程冒充 App 连 helper"。
# 与安装时钉客户端 cdhash（挡替换重签）合起来，才完整堵住免密码助手的同用户提权面。
# ad-hoc 也会被内核强制 hardened runtime（无需 Developer ID）；App 不捆第三方 dylib，library
# validation 不会挡自带库。改动后务必确认 App 仍能正常启动。
codesign --force --deep --options runtime --sign - --timestamp=none "$stage_app"

if [[ -e "$app_path" ]]; then
    rm -rf "$app_path"
fi
mv "$stage_app" "$app_path"
# 再保险：注销 dist 副本的启动服务登记，避免它出现在启动台/程序坞。
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[[ -x "$lsregister" ]] && "$lsregister" -u "$app_path" 2>/dev/null || true
print "Built $app_path  (版本 $app_version / build $build_number)"
