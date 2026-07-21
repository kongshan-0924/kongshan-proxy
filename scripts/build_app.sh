#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"

zsh scripts/fetch_sing_box.sh
swift build -c release --arch arm64

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
codesign --force --deep --sign - --timestamp=none "$stage_app"

if [[ -e "$app_path" ]]; then
    rm -rf "$app_path"
fi
mv "$stage_app" "$app_path"
print "Built $app_path"
