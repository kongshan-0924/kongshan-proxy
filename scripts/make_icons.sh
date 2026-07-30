#!/bin/zsh
# 重新生成 Resources/AppIcon.icns。
# 形状与配色全在 scripts/make_icons.swift 里，改完跑一次这个脚本即可。
set -euo pipefail
cd "$(dirname "$0")/.."

staging="$(mktemp -d)/AppIcon.iconset"
trap 'rm -rf "$(dirname "$staging")"' EXIT

swift scripts/make_icons.swift "$staging"
iconutil -c icns "$staging" -o Resources/AppIcon.icns
echo "已更新 Resources/AppIcon.icns（$(du -h Resources/AppIcon.icns | cut -f1)）"
