#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"

zsh scripts/fetch_sing_box.sh
swift build -c release --arch arm64

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
stage_dir=$(mktemp -d "$dist_dir/.kongshan-build.XXXXXX")
stage_app="$stage_dir/kongshan.app"

cleanup() {
    rm -rf "$stage_dir"
}
trap cleanup EXIT

mkdir -p "$stage_app/Contents/MacOS" "$stage_app/Contents/Resources"
install -m 755 .build/arm64-apple-macosx/release/kongshan "$stage_app/Contents/MacOS/kongshan"
install -m 755 Vendor/sing-box/sing-box "$stage_app/Contents/Resources/sing-box"
install -m 644 Resources/Info.plist "$stage_app/Contents/Info.plist"
install -m 644 Resources/THIRD_PARTY_NOTICES.md "$stage_app/Contents/Resources/THIRD_PARTY_NOTICES.md"
install -m 644 Resources/AppIcon.icns "$stage_app/Contents/Resources/AppIcon.icns"
# 把本次版本号写进 App 的 Info.plist（模板 Resources/Info.plist 保持不变，避免 git 抖动）。
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" "$stage_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$stage_app/Contents/Info.plist"
codesign --force --deep --sign - --timestamp=none "$stage_app"

if [[ -e "$app_path" ]]; then
    rm -rf "$app_path"
fi
mv "$stage_app" "$app_path"
print "Built $app_path  (版本 $app_version / build $build_number)"
