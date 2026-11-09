#!/bin/zsh
# 从官方源码编译 kongshan 内置的 sing-box：官方版本 + 移植自 sing-box-lx 的 XHTTP 传输（见 Kernel/xhttp/README.md）。
#
# 用法：zsh scripts/build_sing_box.sh [arm64|amd64|all] [输出路径]
#   arm64 / amd64：编一个架构，缺省输出到该架构在 Vendor 里的位置（缺省架构跟本机）。
#   all：升级内核用。两个架构都编进 Vendor，并把新的 SHA-256 写进 arch_lib.sh。
#
# 在哪编（KONGSHAN_BUILD_HOST）：
#   不设：有 ~/sdk/go 的机器（构建机自己）在本机编；其余机器（MacBook）转到 imac 编，产物取回。
#   local：强制本机编，需要 Go 与 Xcode 命令行工具（官方 macOS 版同样 CGO_ENABLED=1）。
#   <ssh 主机>：转到那台 Mac 编。跳板连不上时自动局域网直连（scripts/remote_lib.sh）。
# 内核只在构建机上编：Go 工具链与缓存约 5 GB 留在那边；同一台机器编出的产物逐字节一致，
# 换机器（或构建机升级 Xcode / SDK）SHA-256 会变，这时用 all 重编并提交新的钉住值。
#
# 升级内核时改 version 与 upstream_commit，再跑 all（内核 cdhash 会变，装新版后要重装一次免密码助手）。
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"
source "$project_dir/scripts/arch_lib.sh"

version=1.14.4
upstream_commit=c005f35300ce76427dc285481ec5695f5b179cd2
# 与官方该版本 macOS 构建同一个 Go（.github/workflows/build.yml 的 go-version）；本机版本不同时 Go 会自动下载这一版工具链。
go_toolchain=go1.26.10
arch=${1:-$(kongshan_singbox_platform)}
[[ $arch == arm64 || $arch == amd64 || $arch == all ]] || { print -u2 "架构只能是 arm64、amd64 或 all：$arch"; exit 1 }

vendor_path() { [[ $1 == arm64 ]] && print Vendor/sing-box/sing-box || print Vendor/sing-box/sing-box-amd64 }

build_host=${KONGSHAN_BUILD_HOST:-}
if [[ -z $build_host ]]; then
    [[ -x ~/sdk/go/bin/go ]] && build_host=local || build_host=imac
fi

if [[ $arch == all ]]; then
    for a in arm64 amd64; do
        KONGSHAN_BUILD_HOST=$build_host zsh "$0" "$a" "$(vendor_path $a)"
        sha=$(shasum -a 256 "$(vendor_path $a)" | awk '{print $1}')
        sed -E -i '' "s/^( *$a\) print )[0-9a-f]{64}( ;;)$/\\1$sha\\2/" scripts/arch_lib.sh
        grep -q "$a) print $sha ;;" scripts/arch_lib.sh || { print -u2 "没能更新 arch_lib.sh 里 $a 的 SHA-256"; exit 1 }
    done
    print "已更新 scripts/arch_lib.sh 的钉住值；提交 Vendor/sing-box/sing-box 与 arch_lib.sh。"
    print "提醒：内核 cdhash 变了，装上新版后要在 设置 → 接管 重装一次免密码助手。"
    exit 0
fi

output=${2:-$(vendor_path $arch)}

if [[ $build_host != local ]]; then
    source "$project_dir/scripts/remote_lib.sh"
    kongshan_remote_setup "$build_host"
    "${kongshan_ssh[@]}" "$build_host" 'mkdir -p ~/build/kongshan ~/build/out'
    rsync -e "$kongshan_rsh" -a --delete scripts Kernel "$build_host:build/kongshan/"
    "${kongshan_ssh[@]}" "$build_host" "cd ~/build/kongshan && KONGSHAN_BUILD_HOST=local KONGSHAN_SINGBOX_TEST=${KONGSHAN_SINGBOX_TEST:-0} zsh scripts/build_sing_box.sh $arch ~/build/out/sing-box-$arch"
    mkdir -p "${output:h}"
    rsync -e "$kongshan_rsh" -a "$build_host:build/out/sing-box-$arch" "$output"
    print "已取回 $output（在 $build_host 上编译）"
    print "SHA-256 $(shasum -a 256 "$output" | awk '{print $1}')"
    exit 0
fi

# 构建机上 Go 只装在 ~/sdk（不动系统）；非交互 ssh 的 PATH 里没有它。
[[ -d ~/sdk/go/bin ]] && path=(~/sdk/go/bin $path)
export GOPROXY=${GOPROXY:-https://goproxy.cn,direct}
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
