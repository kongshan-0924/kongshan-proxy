#!/bin/zsh
set -euo pipefail

version=1.13.14
archive="sing-box-${version}-darwin-arm64.tar.gz"
expected=73e8967b0fc08e17bce4263ca56ebc394822401a16497a1c4e02316c888202ab
url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${archive}"
target=Vendor/sing-box/sing-box
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

tar -xOf "$archive_path" "sing-box-${version}-darwin-arm64/sing-box" > "$binary_path"
install -m 755 "$binary_path" "$target"
print "Installed sing-box $version to $target"
