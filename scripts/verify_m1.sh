#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"

# 本机环境沙盒被禁用（sandbox-exec: Operation not permitted），必须显式 --disable-sandbox。
SWIFTPM_ENABLE_SANDBOX=NO swift test --disable-sandbox
zsh scripts/build_app.sh

app_path=${KONGSHAN_APP_PATH:-"$project_dir/.build/kongshan.app"}
app_binary="$app_path/Contents/MacOS/kongshan"
core_binary="$app_path/Contents/Resources/sing-box"

source "$project_dir/scripts/arch_lib.sh"
host_arch=$(kongshan_host_arch)
file "$app_binary" | grep -q "$host_arch"
file "$core_binary" | grep -q "$host_arch"
codesign --verify --deep --strict --verbose=2 "$app_path"
plutil -lint "$app_path/Contents/Info.plist"
"$core_binary" version | grep -q 'sing-box version 1.14.4'
# 免密码助手安装时要算内置内核的 cdhash，没签名就按设计拒绝安装（官方 amd64 包不带签名，见 build_app.sh）。
codesign -dv --verbose=4 "$core_binary" 2>&1 | grep '^CDHash=' >/dev/null || { print -u2 -- "内置 sing-box 没有签名，免密码助手将无法安装"; exit 1; }
print -r -- '{"log":{"disabled":true},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}' \
    | "$core_binary" check -c /dev/stdin

print 'M1 automated verification passed'
