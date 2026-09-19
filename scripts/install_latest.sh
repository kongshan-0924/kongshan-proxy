#!/bin/zsh
# 一键替换安装 kongshan 最新版：从 GitHub Release 下载 → 校验 → 正常退出旧版 → 替换 → 启动。
#
# 用法：
#   zsh scripts/install_latest.sh            安装最新版（已是最新则什么都不做）
#   zsh scripts/install_latest.sh --check    只下载并校验，不碰已安装的 App
#   zsh scripts/install_latest.sh --force    已是最新也重装
#   curl -fsSL https://raw.githubusercontent.com/kongshan-0924/kongshan-proxy/main/scripts/install_latest.sh | zsh
#
# 安全闸门与 `scripts/release.sh install` 一致：只请求旧版正常退出（绝不 TERM/KILL），
# 确认系统代理、DNS、TUN 都已还原、直连可用才替换；替换前备份配置，旧版移入废纸篓作回滚点。
# 区别只在来源：这里装的是 GitHub 上已发布的那一份，并用 Release 给出的 SHA-256 校验下载内容。
set -euo pipefail

readonly repo="kongshan-0924/kongshan-proxy"
readonly bundle_id="com.kaysen.kongshan"
readonly target_app="/Applications/kongshan.app"
readonly support="$HOME/Library/Application Support/kongshan"

fail() {
    print -u2 -- "安装中止：$*"
    exit 1
}

usage() {
    print -- "用法：zsh install_latest.sh [--check] [--force]"
    print -- "  --check  只下载并校验最新版，不碰已安装的 App"
    print -- "  --force  已是最新也重新安装"
}

mode=install
force=0
for arg in "$@"; do
    case $arg in
        --check) mode=check ;;
        --force) force=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; fail "未知参数：$arg" ;;
    esac
done

app_version() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null
}

# **awk 里不许 exit**（开了 pipefail）：提前退出会让上游吃 SIGPIPE、整条管道返回 141。
# 见 release.sh 同名函数的说明。
any_app_pid() {
    ps -axo pid=,command= | awk '$2 ~ /\/kongshan\.app\/Contents\/MacOS\/kongshan$/ && !pid { pid = $1 } END { if (pid) print pid }'
}

installed_app_pid() {
    ps -axo pid=,command= | awk -v app="$target_app/Contents/MacOS/kongshan" '$2 == app && !pid { pid = $1 } END { if (pid) print pid }'
}

wait_until() {
    local deadline=$1; shift
    local elapsed=0
    while (( elapsed < deadline )); do
        if "$@"; then return 0; fi
        sleep 0.2
        (( elapsed += 1 ))
    done
    "$@"
}

system_proxy_is_off() {
    scutil --proxy | awk '/Enable :/ && $3 != 0 { bad=1 } END { exit bad }'
}

dns_not_on_tun() {
    # 不经管道：这是安全闸门，吃到 SIGPIPE 会被误判成"没有指向 TUN"而放行。
    ! [[ "$(scutil --dns)" =~ 'nameserver\[[0-9]+\] : (172\.19\.0\.1|fdfe:dcba:9876::1)' ]]
}

direct_network_is_reachable() {
    curl --fail --silent --show-error --max-time 10 --noproxy '*' \
        https://www.apple.com/library/test/success.html >/dev/null 2>&1
}

# 与 release.sh 一致：代理 / DNS 快照里只剩「当前不存在的网络服务」时是待还原保留，不算没收干净。
recovery_snapshots_are_gone() {
    [[ ! -e "$support/tun-recovery.json" ]] || return 1
    local current
    current=$(/usr/sbin/networksetup -listallnetworkservices 2>/dev/null) || return 1
    local residue snapshot
    for residue in proxy-recovery.json dns-recovery.json; do
        snapshot="$support/$residue"
        [[ -e "$snapshot" ]] || continue
        KONGSHAN_CURRENT_SERVICES="$current" /usr/bin/python3 -c '
import json, os, sys
current = {line.lstrip("*").strip() for line in os.environ.get("KONGSHAN_CURRENT_SERVICES", "").splitlines()
           if line.strip() and not line.startswith("An asterisk")}
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
names = {s.get("name") for s in data.get("services", []) if isinstance(s, dict)}
sys.exit(1 if (names & current) else 0)
' "$snapshot" || return 1
    done
    return 0
}

backup_configuration() {
    local version=$1
    [[ -d "$support" ]] || return 0
    typeset -a candidates existing
    candidates=(settings.json rules.json subscriptions.json manual-nodes.json runtime-events.json subscriptions)
    local item
    for item in "${candidates[@]}"; do
        [[ -e "$support/$item" ]] && existing+=("$item")
    done
    (( ${#existing[@]} > 0 )) || return 0
    local backup_dir="$HOME/Library/Application Support/kongshan-backups"
    local archive="$backup_dir/kongshan-config-$version-$(date +%Y%m%d-%H%M%S).tar.gz"
    mkdir -p "$backup_dir"
    COPYFILE_DISABLE=1 tar -czf "$archive" -C "$support" -- "${existing[@]}"
    chmod 600 "$archive"
    tar -tzf "$archive" >/dev/null
    print -- "配置已备份：$archive"
}

# ---------------------------------------------------------------- 取最新版信息

# curl 不读系统代理设置：国内直连 GitHub 可能很慢甚至不通，系统代理开着就借用它。
typeset -a proxy_args
proxy=$(scutil --proxy | awk '/HTTPSEnable : 1/ { e = 1 } /HTTPSProxy :/ { h = $3 } /HTTPSPort :/ { p = $3 } END { if (e && h != "" && p != "") print h ":" p }')
if [[ -n "$proxy" ]]; then
    proxy_args=(--proxy "http://$proxy")
    print -- "下载走系统代理 $proxy"
fi

release_json=$(curl -fsSL --max-time 30 "${proxy_args[@]}" \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$repo/releases/latest") \
    || fail "取不到最新版本信息（api.github.com）"

release_fields=$(print -r -- "$release_json" | /usr/bin/python3 -c '
import json, sys
release = json.load(sys.stdin)
assets = [a for a in release.get("assets", []) if a.get("name", "").endswith(".dmg")]
if len(assets) != 1:
    sys.exit(2)
asset = assets[0]
digest = asset.get("digest") or ""
print(release["tag_name"], asset["name"], asset["browser_download_url"], asset["size"],
      digest.removeprefix("sha256:") or "-")
') || fail "最新 Release 里没有唯一的 DMG 安装包"
read -r tag dmg_name dmg_url dmg_size dmg_digest <<< "$release_fields"
version=${tag#v}
[[ "$dmg_digest" != "-" ]] || fail "Release 没有提供 SHA-256 摘要，无法校验下载内容，拒绝安装"

installed_version="none"
[[ -d "$target_app" ]] && installed_version=$(app_version "$target_app" || print -- unknown)
print -- "最新版本 $tag（$dmg_name，$dmg_size 字节）；已安装 $installed_version"
if [[ "$mode" == install && "$installed_version" == "$version" && $force == 0 ]]; then
    print -- "已是最新版，无需安装（要重装请加 --force）"
    exit 0
fi

# ---------------------------------------------------------------- 下载与校验

work=$(mktemp -d /tmp/kongshan-install.XXXXXX)
mount_point=""
stage=""
cleanup() {
    [[ -n "$mount_point" ]] && hdiutil detach "$mount_point" -quiet >/dev/null 2>&1 || true
    [[ -n "$stage" && -d "$stage" ]] && rm -rf "$stage"
    [[ "$work" == /tmp/kongshan-install.* ]] && rm -rf "$work"
}
trap cleanup EXIT

dmg="$work/$dmg_name"
curl -fL --max-time 900 --retry 2 --progress-bar "${proxy_args[@]}" -o "$dmg" "$dmg_url" \
    || fail "下载失败：$dmg_url"
[[ $(stat -f%z "$dmg") == "$dmg_size" ]] || fail "下载大小与 Release 不符"
actual_digest=$(shasum -a 256 "$dmg" | awk '{ print $1 }')
[[ "$actual_digest" == "$dmg_digest" ]] || fail "SHA-256 与 Release 不符（下载内容被篡改或损坏）"
print -- "SHA-256 校验通过：$actual_digest"

mount_point="$work/mnt"
mkdir -p "$mount_point"
# macOS 27 起 `hdiutil attach -mountpoint` 已弃用（仍可用但会警告），有新命令就用新的。
if diskutil image attach --help >/dev/null 2>&1; then
    diskutil image attach --readOnly --nobrowse --mountPoint "$mount_point" "$dmg" >/dev/null \
        || fail "无法挂载 $dmg_name"
else
    hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mount_point" "$dmg" >/dev/null \
        || fail "无法挂载 $dmg_name"
fi
source_app="$mount_point/kongshan.app"
[[ -d "$source_app" ]] || fail "安装包里没有 kongshan.app"
codesign --verify --deep --strict "$source_app" >/dev/null 2>&1 || fail "安装包内 App 签名校验失败"
[[ $(app_version "$source_app") == "$version" ]] || fail "安装包内 App 版本与 Release 不一致"
[[ "$(file "$source_app/Contents/MacOS/kongshan")" == *arm64* ]] || fail "安装包内 App 不是 arm64"
print -- "安装包校验通过：kongshan $version（签名完整、arm64）"

if [[ "$mode" == check ]]; then
    print -- "--check：只做了下载与校验，未改动已安装的 App"
    exit 0
fi

# ---------------------------------------------------------------- 替换

# 先在 /Applications 同卷暂存一份：之后的替换只是一次 mv，失败也能原样退回。
stage="/Applications/.kongshan-stage-$$.app"
ditto "$source_app" "$stage"
codesign --verify --deep --strict "$stage" >/dev/null 2>&1 || fail "暂存副本签名校验失败"

was_running=0
pid=$(any_app_pid)
if [[ -n "$pid" ]]; then
    was_running=1
    print -- "正在请求旧版正常退出（PID $pid），它会先还原系统代理与 DNS……"
    osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 \
        || fail "无法请求旧版正常退出"
    for _ in {1..200}; do
        [[ -z $(any_app_pid) ]] && break
        sleep 0.1
    done
    [[ -z $(any_app_pid) ]] || fail "旧版未在 20 秒内正常退出；未发送 TERM/KILL，也未替换"
fi

# 替换前的检查不通过：不替换，并把旧版重新打开，不让用户停在没有代理的状态。
abort_before_replace() {
    local suffix=""
    if (( was_running )) && [[ -d "$target_app" ]]; then
        open "$target_app" || true
        suffix="，已重新打开旧版"
    fi
    fail "$1；未替换$suffix"
}

pgrep -f '/kongshan.*/sing-box' >/dev/null 2>&1 && abort_before_replace "仍有 kongshan 的 sing-box 进程"
wait_until 25 recovery_snapshots_are_gone || abort_before_replace "系统恢复快照 5 秒内仍未清除"
wait_until 25 system_proxy_is_off || abort_before_replace "系统代理 5 秒内仍处于启用状态"
wait_until 25 dns_not_on_tun || abort_before_replace "系统 DNS 仍指向 kongshan TUN"
wait_until 60 direct_network_is_reachable || abort_before_replace "直连网络检查失败"

backup_configuration "$version"

timestamp=$(date +%Y%m%d-%H%M%S)
backup="$HOME/.Trash/kongshan-$installed_version-before-$version-$timestamp.app"
rejected="$HOME/.Trash/kongshan-$version-failed-$timestamp.app"
[[ -d "$target_app" ]] && mv "$target_app" "$backup"
if ! mv "$stage" "$target_app" \
    || ! codesign --verify --deep --strict "$target_app" >/dev/null 2>&1 \
    || [[ $(app_version "$target_app") != "$version" ]]; then
    [[ ! -d "$target_app" ]] || mv "$target_app" "$rejected"
    [[ ! -d "$target_app" && -d "$backup" ]] && mv "$backup" "$target_app"
    (( was_running )) && open "$target_app" || true
    fail "安装失败，已恢复旧版"
fi
stage=""

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$target_app" >/dev/null 2>&1 || true
open "$target_app"
# 只等「进程出现」不够：单实例保护下新进程可能一闪即退。要同一个 PID 连续存活满 3 秒。
pid_after=""
for _ in {1..100}; do
    pid_after=$(installed_app_pid)
    [[ -n "$pid_after" ]] && break
    sleep 0.1
done
[[ -n "$pid_after" ]] || fail "新版未在 10 秒内启动；旧版备份在 $backup"
for _ in {1..15}; do
    sleep 0.2
    [[ $(installed_app_pid) == "$pid_after" ]] || fail "新版启动后未能稳定运行；旧版备份在 $backup"
done

print -- ""
print -- "已安装并打开 kongshan $version（PID $pid_after）"
[[ -d "$backup" ]] && print -- "旧版备份（可拖回「应用程序」回滚）：$backup"
print -- "提示：新版签名已变，下次开启 TUN 时会要求重装一次特权助手（输入一次密码），属正常现象。"
