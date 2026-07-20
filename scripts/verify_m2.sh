#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"

swift test
zsh scripts/build_app.sh

app_path="$project_dir/dist/kongshan.app"
app_binary="$app_path/Contents/MacOS/kongshan"
core_binary="$app_path/Contents/Resources/sing-box"

file "$app_binary" | grep -q 'arm64'
file "$core_binary" | grep -q 'arm64'
codesign --verify --deep --strict --verbose=2 "$app_path"
plutil -lint "$app_path/Contents/Info.plist"
"$core_binary" version | grep -q 'sing-box version 1.13.14'

verification_dir=$(mktemp -d /tmp/kongshan-m2-verify.XXXXXX)
geosite_cn="$verification_dir/geosite-cn.srs"
geoip_cn="$verification_dir/geoip-cn.srs"
ads="$verification_dir/geosite-category-ads-all.srs"
fixture="$verification_dir/routing.json"

cleanup() {
    unlink "$fixture" 2>/dev/null || true
    unlink "$geosite_cn" 2>/dev/null || true
    unlink "$geoip_cn" 2>/dev/null || true
    unlink "$ads" 2>/dev/null || true
    rmdir "$verification_dir" 2>/dev/null || true
}
trap cleanup EXIT

curl --fail --location --retry 2 --connect-timeout 15 --silent --show-error \
    'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs' \
    --output "$geosite_cn"
curl --fail --location --retry 2 --connect-timeout 15 --silent --show-error \
    'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs' \
    --output "$geoip_cn"
curl --fail --location --retry 2 --connect-timeout 15 --silent --show-error \
    'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs' \
    --output "$ads"

for rule_set in "$geosite_cn" "$geoip_cn" "$ads"; do
    [[ -s "$rule_set" ]]
    "$core_binary" rule-set decompile "$rule_set" -o /dev/null
done

print -r -- "{
  \"log\": {\"disabled\": true},
  \"inbounds\": [],
  \"outbounds\": [
    {\"type\": \"direct\", \"tag\": \"direct\"},
    {\"type\": \"block\", \"tag\": \"reject\"},
    {\"type\": \"selector\", \"tag\": \"手动选择\", \"outbounds\": [\"direct\"]},
    {\"type\": \"selector\", \"tag\": \"自动选择\", \"outbounds\": [\"direct\"]}
  ],
  \"route\": {
    \"rules\": [
      {\"domain_suffix\": [\"custom.example\"], \"action\": \"route\", \"outbound\": \"手动选择\"},
      {\"domain\": [\"localhost\"], \"domain_suffix\": [\"local\"], \"ip_cidr\": [\"192.168.0.0/16\"], \"action\": \"route\", \"outbound\": \"direct\"},
      {\"ip_is_private\": true, \"action\": \"route\", \"outbound\": \"direct\"},
      {\"rule_set\": \"geosite-category-ads-all\", \"action\": \"route\", \"outbound\": \"reject\"},
      {\"rule_set\": [\"geosite-cn\", \"geoip-cn\"], \"action\": \"route\", \"outbound\": \"direct\"}
    ],
    \"rule_set\": [
      {\"type\": \"local\", \"tag\": \"geosite-cn\", \"format\": \"binary\", \"path\": \"$geosite_cn\"},
      {\"type\": \"local\", \"tag\": \"geoip-cn\", \"format\": \"binary\", \"path\": \"$geoip_cn\"},
      {\"type\": \"local\", \"tag\": \"geosite-category-ads-all\", \"format\": \"binary\", \"path\": \"$ads\"}
    ],
    \"final\": \"自动选择\"
  }
}" > "$fixture"

"$core_binary" check -c "$fixture"

print 'M2 automated verification passed'
