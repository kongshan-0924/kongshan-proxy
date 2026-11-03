#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"

fail() {
    print -u2 -- "发布中止：$*"
    exit 1
}

version() {
    tr -d '[:space:]' < VERSION
}

app_version() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist"
}

app_cdhash() {
    codesign -d --verbose=4 "$1" 2>&1 | awk -F= '/^CDHash=/ && !h { h = $2 } END { if (h) print h }'
}

verify_artifacts() {
    local expected=$(version)
    local app="$project_dir/.build/kongshan.app"
    local dmg="$project_dir/dist/kongshan-$expected.dmg"
    [[ -d "$app" ]] || fail "缺少 $app"
    [[ -f "$dmg" ]] || fail "缺少 $dmg"
    [[ $(app_version "$app") == "$expected" ]] || fail "App 与 VERSION 不一致"
    codesign --verify --deep --strict --verbose=2 "$app"
    file "$app/Contents/MacOS/kongshan" | grep -q arm64 || fail "App 不是 arm64"
    file "$app/Contents/Resources/sing-box" | grep -q arm64 || fail "sing-box 不是 arm64"
    hdiutil verify "$dmg" >/dev/null
    # Intel 包（prepare-remote 才有）：有就一并核对，发布时必须有。
    local intel_app="$project_dir/.build/x86_64/kongshan.app" intel_dmg="$project_dir/dist/kongshan-$expected-x86_64.dmg"
    if [[ -d "$intel_app" || -f "$intel_dmg" ]]; then
        [[ -d "$intel_app" && -f "$intel_dmg" ]] || fail "Intel 包不完整：App 与 DMG 要同时在"
        [[ $(app_version "$intel_app") == "$expected" ]] || fail "Intel App 与 VERSION 不一致"
        codesign --verify --deep --strict "$intel_app" || fail "Intel App 签名校验失败"
        file "$intel_app/Contents/MacOS/kongshan" | grep -q x86_64 || fail "Intel App 不是 x86_64"
        file "$intel_app/Contents/Resources/sing-box" | grep -q x86_64 || fail "Intel 包的 sing-box 不是 x86_64"
        hdiutil verify "$intel_dmg" >/dev/null
    fi
}

# 工具链前置检查：缺 xctest 或 swift 时，verify_m4 会先编译几十分钟，再在测试阶段
# 报一句看不懂的错误。这里提前拦住，把原因和修法直接说清楚。
require_toolchain() {
    xcrun --find xctest >/dev/null 2>&1 \
        || fail "找不到 xctest：请安装完整的 Xcode（仅 Command Line Tools 不够），并在“Xcode → Settings → Locations”选中它"
    command -v swift >/dev/null 2>&1 || fail "找不到 swift：请安装 Xcode 或 Swift 工具链"
    xcode-select -p >/dev/null 2>&1 || fail "xcode-select 未指向可用的开发者目录"
}

prepare() {
    [[ -z $(git status --porcelain) ]] \
        || fail "prepare 前工作区必须完全干净；验证戳必须绑定一个确定提交"
    require_toolchain
    KONGSHAN_KEEP_VERSION=1 zsh scripts/verify_m4.sh
    zsh scripts/make_dmg.sh
    verify_artifacts
    write_stamp
}

# 在另一台 Mac（默认 ssh 主机 imac，Intel）上构建，本机不跑 swift build：
# 那边跑全量测试与 x86_64 门禁（M1–M4，产物留给测试机），再交叉构建 arm64；取回 arm64 的 App 与 DMG，
# 本机做发布产物检查并写验证戳，之后照常 install / publish。arm64 产物没在真机上跑过 M1–M4，
# install 装完会打开它，有问题当场能看到。
prepare_remote() {
    [[ -z $(git status --porcelain) ]] \
        || fail "prepare 前工作区必须完全干净；验证戳必须绑定一个确定提交"
    local host=${1:-${KONGSHAN_BUILD_HOST:-imac}}
    local remote=kongshan-test/src
    local expected=$(version)
    print -- "同步代码到 $host:$remote"
    rsync -a --delete --exclude .git --exclude .build --exclude dist --exclude .vscode \
        --exclude Vendor/sing-box/sing-box-amd64 ./ "$host:$remote/"
    ssh -o ServerAliveInterval=30 "$host" "cd $remote && export KONGSHAN_KEEP_VERSION=1 \
        && zsh scripts/verify_m4.sh && zsh scripts/make_dmg.sh \
        && export KONGSHAN_TARGET_ARCH=arm64 KONGSHAN_APP_PATH=.build/arm64/kongshan.app \
        && zsh scripts/build_app.sh && zsh scripts/make_dmg.sh" \
        || fail "$host 上的测试或构建失败"
    mkdir -p "$project_dir/.build" "$project_dir/dist"
    rsync -a --delete "$host:$remote/.build/arm64/kongshan.app/" "$project_dir/.build/kongshan.app/"
    rsync -a "$host:$remote/dist/kongshan-$expected.dmg" "$project_dir/dist/"
    # Intel 包：发布时与 arm64 一起上传。
    mkdir -p "$project_dir/.build/x86_64"
    rsync -a --delete "$host:$remote/.build/kongshan.app/" "$project_dir/.build/x86_64/kongshan.app/"
    rsync -a "$host:$remote/dist/kongshan-$expected-x86_64.dmg" "$project_dir/dist/"
    # 本地 dist 只留最新（与 make_dmg.sh 同规则）。
    local -a stale
    stale=("$project_dir"/dist/kongshan-*.dmg(N))
    stale=(${stale:#*/kongshan-$expected.dmg})
    stale=(${stale:#*/kongshan-$expected-x86_64.dmg})
    (( ${#stale} == 0 )) || trash "${stale[@]}"
    verify_artifacts
    write_stamp
}

write_stamp() {
    local expected=$(version)
    local dmg="$project_dir/dist/kongshan-$expected.dmg"
    local digest=$(shasum -a 256 "$dmg" | awk '{print $1}')
    local cdhash=$(app_cdhash "$project_dir/.build/kongshan.app")
    [[ -n "$cdhash" ]] || fail "无法读取 App CDHash"
    local intel_dmg="$project_dir/dist/kongshan-$expected-x86_64.dmg" intel_digest=-
    [[ -f "$intel_dmg" ]] && intel_digest=$(shasum -a 256 "$intel_dmg" | awk '{print $1}')
    local commit=$(git rev-parse HEAD)
    mkdir -p "$project_dir/.build"
    print -r -- "$commit $expected $digest $cdhash $intel_digest" > "$project_dir/.build/release-verified.txt"
    # 构建出的 App 版本通常高于已安装的那份；若就此重启，登录项会拉起它。见 `unregister_build_app`。
    unregister_build_app
    print -- "发布候选已验证：v$expected"
    print -- "SHA-256 $digest"
    print -- "App CDHash $cdhash"
    [[ $intel_digest == - ]] || print -- "Intel DMG SHA-256 $intel_digest"
}

# 验证戳绑定的提交与 HEAD 之间**只差文档**时放行。
#
# 本项目的固定节奏是「prepare 跑完 → 把门禁数值（CPU、SHA-256、CDHash）补进 SESSION_LOG
# → 再 publish」。那条记录必须等 prepare 出结果才写得出来，于是 HEAD 必然比戳多一个
# 纯文档提交，而严格相等的判据每次都会卡死——v0.1.107 就是因此绕过脚本手工发布的，
# 绕过意味着这一整套门禁当次全部失效，比放宽危险得多。
#
# 放宽只针对 `docs/`：构建产物由代码决定，docs 改动不可能改变它。
# 只要差异里出现任何一个非 docs 路径（含 scripts/ 自己），就说明产物已不对应 HEAD 的代码，
# 照旧拒绝。HEAD 还必须是戳提交的后代，防止切了分支却拿着旧戳发布。
stamp_commit_covers_head() {
    local stamped=$1
    local head=$(git rev-parse HEAD)
    [[ "$stamped" == "$head" ]] && return 0
    git merge-base --is-ancestor "$stamped" "$head" 2>/dev/null || return 1
    local -a changed
    changed=(${(f)"$(git diff --name-only "$stamped..$head")"})
    (( ${#changed} )) || return 1
    local f
    for f in $changed; do
        [[ "$f" == docs/* ]] || return 1
    done
    return 0
}

require_verification_stamp() {
    local stamp="$project_dir/.build/release-verified.txt"
    [[ -f "$stamp" ]] || fail "缺少验证戳，请先运行 scripts/release.sh prepare"
    read -r stamped_commit stamped_version stamped_digest stamped_cdhash stamped_intel_digest < "$stamp"
    stamp_commit_covers_head "$stamped_commit" \
        || fail "提交在验证后发生变化（非文档改动），请重新 prepare"
    if [[ "$stamped_commit" != $(git rev-parse HEAD) ]]; then
        print -- "注意：HEAD 比验证戳多出纯文档提交；产物构建自 $stamped_commit，代码与 HEAD 一致"
    fi
    [[ "$stamped_version" == $(version) ]] || fail "版本在验证后发生变化，请重新 prepare"
    local dmg="$project_dir/dist/kongshan-$stamped_version.dmg"
    [[ "$stamped_digest" == $(shasum -a 256 "$dmg" | awk '{print $1}') ]] \
        || fail "DMG 在验证后发生变化，请重新 prepare"
    [[ -n "$stamped_cdhash" && "$stamped_cdhash" == $(app_cdhash "$project_dir/.build/kongshan.app") ]] \
        || fail "App 在验证后发生变化，请重新 prepare"
    if [[ -n "${stamped_intel_digest:-}" && "$stamped_intel_digest" != - ]]; then
        [[ "$stamped_intel_digest" == $(shasum -a 256 "$project_dir/dist/kongshan-$stamped_version-x86_64.dmg" | awk '{print $1}') ]] \
            || fail "Intel DMG 在验证后发生变化，请重新 prepare"
    fi
    verify_artifacts
}

# 反复取样直到条件成立，超时才判失败。
#
# **两处安装检查都因为「点采样当成稳态判据」而误报过**，所以统一走这里：
# 旧版退出与系统状态还原之间有时间差（进程消失 ≠ scutil 已经反映还原结果，
# SystemConfiguration 的动态存储是异步传播的），2026-08-25 就是这样把一次
# 成功的还原判成了「系统代理仍处于启用状态」。
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

direct_network_is_reachable() {
    curl --fail --silent --show-error --max-time 10 --noproxy '*' \
        https://www.apple.com/library/test/success.html >/dev/null 2>&1
}

system_proxy_is_off() {
    scutil --proxy | awk '/Enable :/ && $3 != 0 { bad=1 } END { exit bad }'
}

# 代理 / DNS 快照里**只剩当前不存在的网络服务**时，这不是"旧版没释放干净"，
# 而是 v0.1.99 起的待还原保留：服务（拔掉的 USB 网卡、退出的 VPN 虚拟服务）不在列表里就写不回去，
# 快照必须留着等它回来。旧实现一律要求文件消失，于是只要有一个服务暂时不在，就**永远装不上新版**
# ——真机 2026-09-04：网络服务里 `LAN` 消失、`Shadowrocket` 出现，安装被卡在这里。
#
# `tun-recovery.json` 不在放宽之列：它存的是内核运行记录、没有服务列表，
# 存在就意味着 TUN 真的没收干净，必须照旧要求消失。
recovery_snapshots_are_gone() {
    local support="$HOME/Library/Application Support/kongshan"
    [[ ! -e "$support/tun-recovery.json" ]] || return 1

    local current
    current=$(/usr/sbin/networksetup -listallnetworkservices 2>/dev/null) || return 1

    local residue
    for residue in proxy-recovery.json dns-recovery.json; do
        # 变量名不能叫 path：zsh 里 $path 是绑定 PATH 的特殊数组，赋标量会报
        # `inconsistent type for assignment`，真机 2026-09-04 安装时就栽在这。
        local snapshot="$support/$residue"
        [[ -e "$snapshot" ]] || continue
        KONGSHAN_CURRENT_SERVICES="$current" /usr/bin/python3 -c '
import json, os, sys

current = {
    line.lstrip("*").strip()
    for line in os.environ.get("KONGSHAN_CURRENT_SERVICES", "").splitlines()
    if line.strip() and not line.startswith("An asterisk")
}
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    # 读不动就当没释放干净，按老规矩拦下。
    sys.exit(1)
# 属于其他网络位置的项（v0.2.12 起快照按位置记）此刻本就还原不了，等切回那个位置时还原，不算没收干净。
import plistlib
try:
    prefs = plistlib.load(open("/Library/Preferences/SystemConfiguration/preferences.plist", "rb"))
    current_set = str(prefs.get("CurrentSet", "")).split("/")[-1] or None
except Exception:
    current_set = None
names = {
    s.get("name") for s in data.get("services", [])
    if isinstance(s, dict) and (current_set is None or s.get("locationID") in (None, current_set))
}
# 快照里还留着「当前就在列表里」的服务 = 确实没还原干净，拦下。
sys.exit(1 if (names & current) else 0)
' "$snapshot" || return 1
    done
    return 0
}

# **awk 里不许 exit**（本文件开了 pipefail）。
#
# awk 找到第一个匹配就 exit 会关掉管道读端，而 `ps` 还在往里写——`ps` 收到 SIGPIPE，
# pipefail 让整条管道返回 141，`pid=$(installed_app_pid)` 在 set -e 下直接中止整个脚本。
# `ps -axo` 在本机约 174 KB，远超 64 KB 管道缓冲。它按 PID 排序：空山 PID 大时那行在末尾，
# awk 退出时 ps 早已写完，所以长期没出事；2026-09-18 PID 回绕到 24225 后那行排到了前面，
# 实测旧写法 **200 次失败 195 次**，安装在「新版已启动」之后被腰斩（退出码 141）。
# 改为读完全部输入、在 END 里输出首个匹配：ps 永远写得完，同样 200 次 0 失败。
no_kongshan_kernel() {
    ! pgrep -f '/kongshan.*/sing-box' >/dev/null 2>&1
}

installed_app_pid() {
    ps -axo pid=,command= | awk '$2 == "/Applications/kongshan.app/Contents/MacOS/kongshan" && !pid { pid = $1 } END { if (pid) print pid }'
}

# **任意位置**的 kongshan 实例。退出旧版时必须用它，而不是只认 /Applications 的 `installed_app_pid`。
#
# 真机 2026-09-14：跑着的是 `.build/kongshan.app`（原因见 `unregister_build_app`）。
# 旧逻辑看不见它 → 以为没有旧版在跑、不去退出 → 替换 /Applications 成功 →
# 但 `open /Applications/kongshan.app` 遇到同 bundle ID 的实例已在运行，只是**激活**它、
# 不会从新路径起进程 → 等 10 秒等不到 /Applications 路径的进程 → 报「新版未在 10 秒内启动」。
# 文件其实已经换好了，只是跑的仍是构建目录那份。
any_app_pid() {
    # 同 installed_app_pid：不许在 awk 里 exit。
    ps -axo pid=,command= | awk '$2 ~ /\/kongshan\.app\/Contents\/MacOS\/kongshan$/ && !pid { pid = $1 } END { if (pid) print pid }'
}

# 把构建目录里的 App 从 LaunchServices 摘掉。
#
# 它与 /Applications 里的同 bundle ID。登录项是**按 bundle ID** 拉起的，LaunchServices
# 在多份登记里挑版本更高的——于是「构建了新版却还没安装、然后重启」时，开机拉起的是
# `.build` 那份（真机 2026-09-14：/Applications 仍是 0.1.108、.build 是 0.1.109，
# `lsregister -dump` 显示 .build 恰在开机时刻 07:45 被登记，开机进程 PID 632 正是它）。
#
# 构建产物只给门禁（M4 直接执行二进制，不经 LaunchServices）与发布（codesign/摘要校验）用，
# 从来不该是启动目标。摘掉登记不影响这两者。
unregister_build_app() {
    local lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    [[ -d "$project_dir/.build/kongshan.app" ]] || return 0
    "$lsregister" -u "$project_dir/.build/kongshan.app" >/dev/null 2>&1 || true
}

backup_configuration() {
    local expected=$1
    local support="$HOME/Library/Application Support/kongshan"
    [[ -d "$support" ]] || return 0

    typeset -a candidates existing
    candidates=(settings.json rules.json subscriptions.json manual-nodes.json runtime-events.json subscriptions)
    for item in "${candidates[@]}"; do
        [[ -e "$support/$item" ]] && existing+=("$item")
    done
    (( ${#existing[@]} > 0 )) || return 0

    local backup_dir="$HOME/Library/Application Support/kongshan-backups"
    local archive="$backup_dir/kongshan-config-$expected-$(date +%Y%m%d-%H%M%S).tar.gz"
    mkdir -p "$backup_dir"
    COPYFILE_DISABLE=1 tar -czf "$archive" -C "$support" -- "${existing[@]}"
    chmod 600 "$archive"
    tar -tzf "$archive" >/dev/null
    print -- "配置备份：$archive"
    print -- "配置备份 SHA-256：$(shasum -a 256 "$archive" | awk '{print $1}')"

    # 只留最近 5 份：每份都含完整订阅与节点凭据，攒着既占地方也扩大泄露面。
    # 更早的移进废纸篓（可拖回），不直接删；系统没有 trash 命令时宁可不清理。
    local -a all_backups stale_backups
    all_backups=("$backup_dir"/kongshan-config-*.tar.gz(N.om))
    stale_backups=("${(@)all_backups[6,-1]}")
    if (( ${#stale_backups[@]} > 0 )) && command -v trash >/dev/null 2>&1; then
        trash "${stale_backups[@]}" && print -- "已把 ${#stale_backups[@]} 份更早的配置备份移进废纸篓（只保留最近 5 份）"
    fi
}

install_verified() {
    require_verification_stamp
    local expected=$(version)
    local source_app="$project_dir/.build/kongshan.app"
    local target_app="/Applications/kongshan.app"
    local pid=$(any_app_pid)

    if [[ -n "$pid" ]]; then
        osascript -e 'tell application id "com.kaysen.kongshan" to quit' >/dev/null 2>&1 \
            || fail "无法请求旧版正常退出"
        for _ in {1..200}; do
            [[ -z $(any_app_pid) ]] && break
            sleep 0.1
        done
        [[ -z $(any_app_pid) ]] || fail "旧版未在 20 秒内正常退出；未发送 TERM/KILL，也未替换"
    fi

    # 内核（含测速内核）是 App 的子进程，会比 App 晚一点退出：2026-11-02 进程消失后立刻查，误拦过一次。
    wait_until 50 no_kongshan_kernel || fail "旧版退出 10 秒后仍有 kongshan sing-box 进程；未替换"
    # 还原写入发生在退出流程末尾，晚于进程消失；给它 5 秒落地再判。
    wait_until 25 recovery_snapshots_are_gone \
        || fail "系统恢复快照在 5 秒内仍未清除；未替换"
    wait_until 25 system_proxy_is_off \
        || fail "系统代理在 5 秒内仍处于启用状态；未替换"
    # 不用管道：这是**安全闸门**，而它在 if 里——pipefail 下若 scutil 吃到 SIGPIPE，
    # 管道返回 141，if 会把它当成"没有指向 TUN"而**放行安装**，等于静默绕过检查。
    # 输出只有几 KB 实际触发不了，但闸门不该靠运气。改用 zsh 正则，整段不经管道。
    if [[ "$(scutil --dns)" =~ 'nameserver\[[0-9]+\] : (172\.19\.0\.1|fdfe:dcba:9876::1)' ]]; then
        fail "系统 DNS 仍指向 kongshan TUN；未替换"
    fi
    # 拆掉 TUN 之后解析器要几秒才切回来，单次探测会误判：真机 2026-09-07 09:2x
    # 这里报 `Resolving timed out after 10002 ms` 中止了安装，而十几秒后同一条探测 200 且解析只要 35ms。
    # 与上面几项检查一致，改成反复取样直到成立、超时才判失败。
    wait_until 60 direct_network_is_reachable \
        || fail "直连网络检查失败；未替换"
    backup_configuration "$expected"

    local stage="/Applications/.kongshan-stage-$$.app"
    local installed_version="none"
    [[ ! -d "$target_app" ]] || installed_version=$(app_version "$target_app")
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup="$HOME/.Trash/kongshan-$installed_version-before-$expected-$timestamp.app"
    local rejected="$HOME/.Trash/kongshan-$expected-failed-$timestamp.app"
    ditto "$source_app" "$stage"
    codesign --verify --deep --strict --verbose=2 "$stage"
    [[ $(app_version "$stage") == "$expected" ]] || fail "暂存 App 版本不符"
    if [[ -d "$target_app" ]]; then
        mv "$target_app" "$backup"
    fi
    if ! mv "$stage" "$target_app" \
        || ! codesign --verify --deep --strict --verbose=2 "$target_app" \
        || [[ $(app_version "$target_app") != "$expected" ]]; then
        [[ ! -d "$target_app" ]] || mv "$target_app" "$rejected"
        [[ ! -d "$target_app" && -d "$backup" ]] && mv "$backup" "$target_app"
        fail "安装失败，已尝试恢复旧版"
    fi
    # 先摘掉构建目录那份、再强制登记新装的这份，`open` 与日后开机拉起都只会解析到 /Applications。
    unregister_build_app
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "$target_app" >/dev/null 2>&1 || true
    open "$target_app"
    # 只等"进程出现"是不够的：单实例保护下新实例可能瞬间出现又退出，
    # 那一瞬的 PID 会被当成安装成功（2026-08-23 真机踩过）。
    # 改为等到出现，再确认**同一个 PID**连续存活满 3 秒。
    local pid_after=""
    for _ in {1..100}; do
        pid_after=$(installed_app_pid)
        [[ -n "$pid_after" ]] && break
        sleep 0.1
    done
    [[ -n "$pid_after" ]] || fail "新版未在 10 秒内启动；旧版备份仍在 $backup"
    for _ in {1..15}; do
        sleep 0.2
        [[ $(installed_app_pid) == "$pid_after" ]] \
            || fail "新版启动后未能稳定运行（PID $pid_after 已消失）；旧版备份仍在 $backup"
    done
    print -- "已安装并打开 v$expected；旧版可恢复备份：$backup"
}

# ── 公开发布 ───────────────────────────────────────────────────────────────
#
# 开发仓库（origin）是私有的：完整历史、内部文档、真机排查记录都在那里。
# 公开仓库只接收**导出的快照**：HEAD 去掉 scripts/public-export-exclude.txt 列出的路径，
# 作者统一为 GitHub noreply 身份，提交说明只写版本号；推送前必须通过私有信息闸门。
# 开发历史绝不整段推上公开仓库——一旦公开就撤不回来（2026-09-19 的整改就是为此）。
public_repo=kongshan-0924/kongshan-proxy
public_remote=public
public_name=kongshan-0924
public_email=48129787+kongshan-0924@users.noreply.github.com
denylist="$project_dir/docs/private/leak-denylist.txt"

# 公开仓库的远端：只拉分支；标签放进独立命名空间 refs/public-tags/，
# 否则与开发仓库的同名标签（两边的 v0.2.6 指向不同提交）互相冲突。
ensure_public_remote() {
    if ! git remote get-url "$public_remote" >/dev/null 2>&1; then
        git remote add "$public_remote" "git@github.com:$public_repo.git"
    fi
    git config "remote.$public_remote.tagOpt" --no-tags
    git config --replace-all "remote.$public_remote.fetch" "+refs/heads/*:refs/remotes/$public_remote/*"
    git config --add "remote.$public_remote.fetch" "+refs/tags/*:refs/public-tags/*"
    # 推送钩子兜底：绕过本脚本手动推公开仓库会被拦下，见 scripts/hooks/pre-push。
    local hook="$(git rev-parse --git-common-dir)/hooks/pre-push"
    if [[ ! -L "$hook" || $(readlink "$hook") != "$project_dir/scripts/hooks/pre-push" ]]; then
        [[ ! -e "$hook" ]] || fail "$hook 已存在且不是本项目的推送钩子，请人工确认后再发布"
        ln -s "$project_dir/scripts/hooks/pre-push" "$hook"
    fi
}

export_excludes() {
    local line
    while IFS= read -r line; do
        line=${line%%\#*}
        line=${line//[[:space:]]/}
        [[ -n "$line" ]] && print -r -- "${line%/}"
    done < "$project_dir/scripts/public-export-exclude.txt"
}

# HEAD 去掉排除路径后的 tree。用临时索引，不碰工作区与真实索引。
export_tree() {
    local scratch=$(mktemp -d -t kongshan-export)
    local item
    {
        GIT_INDEX_FILE="$scratch/index" git read-tree HEAD
        for item in $(export_excludes); do
            GIT_INDEX_FILE="$scratch/index" git rm -r -q --cached --ignore-unmatch -- "$item" >/dev/null
        done
        GIT_INDEX_FILE="$scratch/index" git write-tree
    } always {
        rm -rf "$scratch"
    }
}

# CHANGELOG 里有本版段落就用它，否则只写版本号；末尾附 DMG 的 SHA-256。
release_notes() {
    local expected=$1 digest=$2 intel_digest=$3
    local section=$(awk -v head="## v$expected " 'index($0, head) == 1 { on = 1; next } on && /^## / { on = 0 } on' CHANGELOG.md)
    if [[ -n "${section//[[:space:]]/}" ]]; then
        print -r -- "$section"
    else
        print -r -- "kongshan $expected"
    fi
    print
    print -r -- "Apple Silicon（arm64）安装包 \`kongshan-$expected.dmg\` SHA-256：\`$digest\`"
    print
    print -r -- "Intel（x86_64）安装包 \`kongshan-$expected-x86_64.dmg\` SHA-256：\`$intel_digest\`"
}

publish() {
    require_verification_stamp
    [[ -z $(git status --porcelain) ]] || fail "发布前工作区必须干净"
    [[ $(git branch --show-current) == main ]] || fail "只允许从 main 发布"
    [[ -s "$denylist" ]] || fail "缺少私有黑名单 $denylist；没有它闸门查不出个人域名与姓名"
    gh auth status >/dev/null
    [[ $(gh repo view "$(git remote get-url origin | sed -E 's#^.*github\.com[:/]##; s#\.git$##')" --json visibility --jq .visibility) == PRIVATE ]] \
        || fail "origin 不是私有仓库；开发历史只能推到私有仓库"
    ensure_public_remote
    local expected=$(version)
    local tag="v$expected"
    local dmg="$project_dir/dist/kongshan-$expected.dmg"
    local digest=$(shasum -a 256 "$dmg" | awk '{print $1}')
    # 每次都发两个包：Apple Silicon 与 Intel（prepare-remote 产出）。
    local intel_dmg="$project_dir/dist/kongshan-$expected-x86_64.dmg"
    local intel_app="$project_dir/.build/x86_64/kongshan.app"
    [[ -f "$intel_dmg" && -d "$intel_app" ]] || fail "缺少 Intel 包；用 scripts/release.sh prepare-remote 构建两个架构"
    local intel_digest=$(shasum -a 256 "$intel_dmg" | awk '{print $1}')

    # 1. 开发仓库（私有）：打标签、推送。
    if git rev-parse "$tag" >/dev/null 2>&1; then
        [[ $(git rev-list -n 1 "$tag") == $(git rev-parse HEAD) ]] \
            || fail "标签 $tag 已存在但不指向当前提交"
    else
        git tag -a "$tag" -m "kongshan $expected"
    fi
    git push origin main
    git push origin "$tag"

    # 2. 公开快照：导出 → 闸门 → 提交 → 推送。
    git fetch -q "$public_remote"
    local tree=$(export_tree)
    local message="kongshan $expected"
    local notes=$(release_notes "$expected" "$digest" "$intel_digest")
    local app="$project_dir/.build/kongshan.app"
    python3 scripts/leak_guard.py --tree "$tree" --message "$message"$'\n'"$notes" \
        --binary "$app/Contents/MacOS/kongshan" "$app/Contents/MacOS/KongshanHelper" \
            "$intel_app/Contents/MacOS/kongshan" "$intel_app/Contents/MacOS/KongshanHelper" \
        || fail "私有信息闸门未通过，未推送公开仓库"

    local commit
    if commit=$(git rev-parse -q --verify "refs/public-tags/$tag^{commit}"); then
        # 上次发布推完快照后中断：标签已在公开仓库，内容必须与这次导出一致。
        [[ $(git rev-parse "$commit^{tree}") == "$tree" ]] \
            || fail "公开仓库已有 $tag，但内容与本次导出不同"
    else
        local parent=$(git rev-parse -q --verify "refs/remotes/$public_remote/main" || true)
        if [[ -n "$parent" && $(git rev-parse "$parent^{tree}") == "$tree" ]]; then
            # 上次推完 main、没推完标签就中断了：沿用那个提交，不重复造一个同内容的。
            commit=$parent
        else
            commit=$(GIT_AUTHOR_NAME=$public_name GIT_AUTHOR_EMAIL=$public_email \
                     GIT_COMMITTER_NAME=$public_name GIT_COMMITTER_EMAIL=$public_email \
                     git commit-tree "$tree" ${parent:+-p} ${parent:+$parent} -m "$message")
        fi
        KONGSHAN_PUBLIC_EXPORT=1 git push "$public_remote" "${commit}:refs/heads/main"
        KONGSHAN_PUBLIC_EXPORT=1 git push "$public_remote" "${commit}:refs/tags/${tag}"
        git fetch -q "$public_remote"
    fi

    # 3. 公开 Release：一键安装脚本从这里取最新版（scripts/install_latest.sh）。
    gh release view "$tag" -R "$public_repo" >/dev/null 2>&1 && fail "Release $tag 已存在"
    gh release create "$tag" "$dmg#kongshan-$expected.dmg（Apple Silicon）" \
        "$intel_dmg#kongshan-$expected-x86_64.dmg（Intel）" -R "$public_repo" \
        --verify-tag \
        --title "kongshan $expected" \
        --notes "$notes" \
        --latest
    print -- "已发布 $tag：开发仓库已推送，公开仓库快照 ${commit[1,12]}"
}

# 公开仓库 main 跟上 HEAD，不发版、不打标签：修一键安装脚本、README 这类不进 App 的改动。
# 与 publish 同一套导出、闸门与 noreply 身份；差异里有 App 代码就拒绝，那要走 prepare + publish。
# 2026-11-03：给已发布的版本补 Intel 包后，公开仓库里的旧一键安装脚本（要求只有一个 DMG）随即失效，
# 当时只能手工拼快照、被推送钩子拦下——这条命令就是那种修补的正规路径。
sync_public() {
    local message=${1:-}
    [[ -n "$message" ]] || fail "用法：scripts/release.sh sync-public \"<提交说明>\""
    [[ -z $(git status --porcelain) ]] || fail "工作区必须干净"
    [[ $(git branch --show-current) == main ]] || fail "只允许从 main 推送"
    [[ -s "$denylist" ]] || fail "缺少私有黑名单 $denylist；没有它闸门查不出个人域名与姓名"
    ensure_public_remote
    git fetch -q "$public_remote"
    local parent=$(git rev-parse "refs/remotes/$public_remote/main")
    local tree=$(export_tree)
    if [[ $(git rev-parse "$parent^{tree}") == "$tree" ]]; then
        print -- "公开仓库已与 HEAD 一致，无需推送"
        return 0
    fi
    local -a changed
    changed=(${(f)"$(git diff --name-only "$parent" "$tree")"})
    local f
    for f in $changed; do
        case $f in
            Sources/*|Resources/*|Vendor/*|Kernel/*|Package.swift|Package.resolved)
                fail "公开仓库与 HEAD 的差异含 App 代码（$f），要走 prepare-remote + publish 发新版" ;;
        esac
    done
    print -- "将更新到公开仓库的文件：${(j:、:)changed}"
    python3 scripts/leak_guard.py --tree "$tree" --message "$message" \
        || fail "私有信息闸门未通过，未推送公开仓库"
    local commit=$(GIT_AUTHOR_NAME=$public_name GIT_AUTHOR_EMAIL=$public_email \
                   GIT_COMMITTER_NAME=$public_name GIT_COMMITTER_EMAIL=$public_email \
                   git commit-tree "$tree" -p "$parent" -m "$message")
    git push origin main
    KONGSHAN_PUBLIC_EXPORT=1 git push "$public_remote" "${commit}:refs/heads/main"
    git fetch -q "$public_remote"
    print -- "公开仓库 main 已更新：${commit[1,12]}"
}

case ${1:-} in
    prepare) prepare ;;
    prepare-remote) prepare_remote "${2:-}" ;;
    sync-public) sync_public "${2:-}" ;;
    install) install_verified ;;
    publish) publish ;;
    *)
        print -u2 -- "用法：scripts/release.sh prepare|prepare-remote [ssh 主机]|install|publish|sync-public "<说明>""
        exit 64
        ;;
esac
