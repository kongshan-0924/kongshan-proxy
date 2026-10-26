#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"
source "$project_dir/scripts/arch_lib.sh"

version=1.14.4
platform=$(kongshan_singbox_platform)
archive="sing-box-${version}-darwin-${platform}.tar.gz"
expected=$(kongshan_singbox_archive_sha256)
expected_binary=$(kongshan_singbox_binary_sha256)
url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${archive}"
target=Vendor/sing-box/sing-box

# 已存在且是**本机架构**的已验证副本就直接用。架构不符时必须重下：
# Intel 上跑 arm64 内核只会得到 `bad CPU type in executable`。
if [[ -x "$target" ]] \
    && file "$target" | grep -q "$(kongshan_host_arch)" \
    && [[ "$(shasum -a 256 "$target" | awk '{print $1}')" == "$expected_binary" ]]; then
    print "Using verified sing-box $version ($platform) at $target"
    exit 0
fi

temp_dir=$(mktemp -d /tmp/kongshan-fetch.XXXXXX)
archive_path="$temp_dir/$archive"
binary_path="$temp_dir/sing-box"

cleanup() {
    unlink "$archive_path" 2>/dev/null || true
    unlink "$binary_path" 2>/dev/null || true
    rmdir "$temp_dir" 2>/dev/null || true
}
trap cleanup EXIT

curl -fL --retry 2 --connect-timeout 15 "$url" -o "$archive_path"
actual=$(shasum -a 256 "$archive_path" | awk '{print $1}')
if [[ "$actual" != "$expected" ]]; then
    print -u2 "sing-box archive SHA-256 mismatch: expected $expected, got $actual"
    exit 1
fi

tar -xOf "$archive_path" "sing-box-${version}-darwin-${platform}/sing-box" > "$binary_path"
# 新机器上 Vendor/ 可能还不存在（例如只同步了源码、没带二进制）。
mkdir -p "${target:h}"
install -m 755 "$binary_path" "$target"
print "Installed sing-box $version ($platform) to $target"
