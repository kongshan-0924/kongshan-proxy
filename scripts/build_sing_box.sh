#!/bin/zsh
# 从官方源码编译 kongshan 内置的 sing-box：官方版本 + 移植自 sing-box-lx 的 XHTTP 传输（见 Kernel/xhttp/README.md）。
#
# 用法：zsh scripts/build_sing_box.sh [arm64|amd64] [输出路径]
#   缺省按本机架构、输出到 Vendor/sing-box/sing-box。需要 Go 与 Xcode 命令行工具（官方 macOS 版同样 CGO_ENABLED=1）。
#
# 升级内核时改 version 与 upstream_commit，重跑后把 arch_lib.sh 里的二进制 SHA-256 换成新输出的值。
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"
source "$project_dir/scripts/arch_lib.sh"

version=1.14.4
upstream_commit=c005f35300ce76427dc285481ec5695f5b179cd2
# 与官方该版本 macOS 构建同一个 Go（.github/workflows/build.yml 的 go-version）；本机版本不同时 Go 会自动下载这一版工具链。
go_toolchain=go1.26.10
arch=${1:-$(kongshan_singbox_platform)}
output=${2:-Vendor/sing-box/sing-box}
[[ $arch == arm64 || $arch == amd64 ]] || { print -u2 "架构只能是 arm64 或 amd64：$arch"; exit 1 }
command -v go >/dev/null || { print -u2 "需要 Go（brew install go）"; exit 1 }

work=$(mktemp -d /tmp/kongshan-singbox.XXXXXX)
cleanup() {
    # 源码树几千个文件；按 CLAUDE.md 不用 rm，移进废纸篓，没有 trash 命令就留在 /tmp 由系统清理。
    command -v trash >/dev/null 2>&1 && trash "$work" 2>/dev/null || true
}
trap cleanup EXIT

git -c advice.detachedHead=false clone -q --depth 1 --branch "v$version" https://github.com/SagerNet/sing-box.git "$work/src"
actual=$(git -C "$work/src" rev-parse HEAD)
[[ $actual == "$upstream_commit" ]] || { print -u2 "官方 v$version 的提交对不上：期望 $upstream_commit，实际 $actual"; exit 1 }

cp -R Kernel/xhttp/overlay/. "$work/src/"
patch -s -d "$work/src" -p1 < Kernel/xhttp/core.patch

cd "$work/src"
tags="$(tr -d '[:space:]' < release/DEFAULT_BUILD_TAGS_OTHERS),with_xhttp"
export GOTOOLCHAIN=$go_toolchain
if [[ ${KONGSHAN_SINGBOX_TEST:-0} == 1 ]]; then
    # 移植进来的 XHTTP 单测 + 被补丁改过的 v2ray 传输与选项解码。
    CGO_ENABLED=1 go test -count=1 -tags "$tags" ./transport/v2rayxhttp/ ./common/badh2/ ./transport/v2ray/ ./option/
fi
ldflags="-X 'github.com/sagernet/sing-box/constant.Version=$version-xhttp' $(< release/LDFLAGS) -s -w -buildid="
CGO_ENABLED=1 GOOS=darwin GOARCH=$arch \
    go build -trimpath -o "$work/sing-box" -tags "$tags" -ldflags "$ldflags" ./cmd/sing-box
cd "$project_dir"

mkdir -p "${output:h}"
install -m 755 "$work/sing-box" "$output"
print "已编译 sing-box $version-xhttp（darwin-$arch，$(go env GOVERSION)）到 $output"
print "SHA-256 $(shasum -a 256 "$output" | awk '{print $1}')"
