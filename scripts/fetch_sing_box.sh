#!/bin/zsh
set -euo pipefail

version=1.13.21
archive="sing-box-${version}-darwin-arm64.tar.gz"
expected=62bca85bf08b9145288729cf010c98ea9877b8086f7369cde9e127012d509424
expected_binary=c71877673f3f444a11b3197b5f4c8e3954afb1341ddcf7ea8068f3bf6b187e12
url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${archive}"
target=Vendor/sing-box/sing-box

if [[ -x "$target" ]] \
    && file "$target" | grep -q 'arm64' \
    && [[ "$(shasum -a 256 "$target" | awk '{print $1}')" == "$expected_binary" ]]; then
    print "Using verified sing-box $version at $target"
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

tar -xOf "$archive_path" "sing-box-${version}-darwin-arm64/sing-box" > "$binary_path"
install -m 755 "$binary_path" "$target"
print "Installed sing-box $version to $target"
