#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"

source "$project_dir/scripts/arch_lib.sh"
host_arch=$(kongshan_host_arch) || {
    print -u2 -- "不支持的 CPU 架构：$(uname -m)（只支持 arm64 / x86_64）"
    exit 1
}

zsh scripts/fetch_sing_box.sh
# 本机环境沙盒被禁用（sandbox-exec: Operation not permitted），必须显式 --disable-sandbox。
# 按主机架构构建：Apple Silicon 出 arm64（发布用），Intel 出 x86_64（只供本机调试）。
SWIFTPM_ENABLE_SANDBOX=NO swift build -c release --arch "$host_arch" --disable-sandbox

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

app_path=${KONGSHAN_APP_PATH:-"$project_dir/.build/kongshan.app"}
app_dir=${app_path:h}
mkdir -p "$app_dir"
stage_dir=$(mktemp -d "$app_dir/.kongshan-build.XXXXXX")
stage_app="$stage_dir/kongshan.app"

cleanup() {
    [[ ! -e "$stage_dir" ]] || trash "$stage_dir"
}
trap cleanup EXIT

# release 产物目录。Xcode 27 起 SwiftPM 默认换成 swiftbuild 后端，位置从
#   .build/<triple>/release/            （native 后端）
# 变成
#   .build/out/Products/Release/        （swiftbuild）
# 两种都认下来，换工具链不至于让打包整个失效（2026-09-18 踩过：报
# `install: .build/arm64-apple-macosx/release/kongshan: No such file or directory`）。
# 优先取宿主架构那一份：同一工作区里可能同时留着上次交叉构建的别的架构产物。
typeset -a release_dirs
release_dirs=("$project_dir"/.build/${host_arch}-apple-macosx/release(N/))
if (( ${#release_dirs[@]} == 0 )) || [[ ! -x "$release_dirs[1]/kongshan" ]]; then
    release_dirs=("$project_dir"/.build/*/release(N/))
fi
if (( ${#release_dirs[@]} == 0 )) || [[ ! -x "$release_dirs[1]/kongshan" ]]; then
    release_dirs=("$project_dir"/.build/out/Products/Release(N/))
fi
(( ${#release_dirs[@]} >= 1 )) || {
    print -u2 -- "找不到 release 产物目录（两种布局都没命中）"
    exit 1
}
release_dir=$release_dirs[1]
for required in kongshan KongshanHelper; do
    [[ -x "$release_dir/$required" ]] || {
        print -u2 -- "release 产物缺少可执行文件：$required（在 $release_dir）"
        exit 1
    }
done

mkdir -p "$stage_app/Contents/MacOS" "$stage_app/Contents/Resources"
install -m 755 "$release_dir/kongshan" "$stage_app/Contents/MacOS/kongshan"
install -m 755 "$release_dir/KongshanHelper" "$stage_app/Contents/MacOS/KongshanHelper"
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
sign_identity=${KONGSHAN_CODESIGN_IDENTITY:--}
typeset -a codesign_args
codesign_args=(--force --deep --options runtime --sign "$sign_identity")
if [[ "$sign_identity" == "-" ]]; then
    codesign_args+=(--timestamp=none)
else
    codesign_args+=(--timestamp)
    [[ -z "${KONGSHAN_CODESIGN_KEYCHAIN:-}" ]] || codesign_args+=(--keychain "$KONGSHAN_CODESIGN_KEYCHAIN")
fi
# 内置内核单独签：`--deep` 不会去签 Contents/Resources 里的可执行文件。官方 arm64 包自带链接器
# ad-hoc 签名，amd64 包完全不签——不签就算不出 cdhash，免密码助手安装时按设计拒绝
# （Intel 上表现为「安装助手没反应」，2026-10-26 iMac 实测）。必须在签 App 之前签，App 的资源封印
# 才包含签好的这份。不加 --options runtime：与官方 arm64 包同一形态，不改内核的运行约束。
typeset -a kernel_codesign_args
kernel_codesign_args=(--force --sign "$sign_identity")
if [[ "$sign_identity" == "-" ]]; then
    kernel_codesign_args+=(--timestamp=none)
else
    kernel_codesign_args+=(--timestamp)
    [[ -z "${KONGSHAN_CODESIGN_KEYCHAIN:-}" ]] || kernel_codesign_args+=(--keychain "$KONGSHAN_CODESIGN_KEYCHAIN")
fi
codesign "${kernel_codesign_args[@]}" "$stage_app/Contents/Resources/sing-box"
codesign "${codesign_args[@]}" "$stage_app"

if [[ -e "$app_path" ]]; then
    trash "$app_path"
fi
mv "$stage_app" "$app_path"
# 构建副本只放在隐藏的 .build 中，并注销启动服务登记；正式运行副本只有 /Applications 中的一份。
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[[ -x "$lsregister" ]] && "$lsregister" -u "$app_path" 2>/dev/null || true
print "Built $app_path  (版本 $app_version / build $build_number)"
