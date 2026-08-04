#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"

swift test
zsh scripts/build_app.sh

app_path=${KONGSHAN_APP_PATH:-"$project_dir/.build/kongshan.app"}
app_binary="$app_path/Contents/MacOS/kongshan"
core_binary="$app_path/Contents/Resources/sing-box"

file "$app_binary" | grep -q 'arm64'
file "$core_binary" | grep -q 'arm64'
codesign --verify --deep --strict --verbose=2 "$app_path"
plutil -lint "$app_path/Contents/Info.plist"
"$core_binary" version | grep -q 'sing-box version 1.13.14'
print -r -- '{"log":{"disabled":true},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}' \
    | "$core_binary" check -c /dev/stdin

print 'M1 automated verification passed'
