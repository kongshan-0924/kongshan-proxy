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
    codesign -d --verbose=4 "$1" 2>&1 | awk -F= '/^CDHash=/{print $2; exit}'
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
}

prepare() {
    [[ -z $(git status --porcelain) ]] \
        || fail "prepare 前工作区必须完全干净；验证戳必须绑定一个确定提交"
    KONGSHAN_KEEP_VERSION=1 zsh scripts/verify_m4.sh
    zsh scripts/make_dmg.sh
    verify_artifacts

    local expected=$(version)
    local dmg="$project_dir/dist/kongshan-$expected.dmg"
    local digest=$(shasum -a 256 "$dmg" | awk '{print $1}')
    local cdhash=$(app_cdhash "$project_dir/.build/kongshan.app")
    [[ -n "$cdhash" ]] || fail "无法读取 App CDHash"
    local commit=$(git rev-parse HEAD)
    mkdir -p "$project_dir/.build"
    print -r -- "$commit $expected $digest $cdhash" > "$project_dir/.build/release-verified.txt"
    print -- "发布候选已验证：v$expected"
    print -- "SHA-256 $digest"
    print -- "App CDHash $cdhash"
}

require_verification_stamp() {
    local stamp="$project_dir/.build/release-verified.txt"
    [[ -f "$stamp" ]] || fail "缺少验证戳，请先运行 scripts/release.sh prepare"
    read -r stamped_commit stamped_version stamped_digest stamped_cdhash < "$stamp"
    [[ "$stamped_commit" == $(git rev-parse HEAD) ]] || fail "提交在验证后发生变化，请重新 prepare"
    [[ "$stamped_version" == $(version) ]] || fail "版本在验证后发生变化，请重新 prepare"
    local dmg="$project_dir/dist/kongshan-$stamped_version.dmg"
    [[ "$stamped_digest" == $(shasum -a 256 "$dmg" | awk '{print $1}') ]] \
        || fail "DMG 在验证后发生变化，请重新 prepare"
    [[ -n "$stamped_cdhash" && "$stamped_cdhash" == $(app_cdhash "$project_dir/.build/kongshan.app") ]] \
        || fail "App 在验证后发生变化，请重新 prepare"
    verify_artifacts
}

installed_app_pid() {
    ps -axo pid=,command= | awk '$2 == "/Applications/kongshan.app/Contents/MacOS/kongshan" { print $1; exit }'
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
}

install_verified() {
    require_verification_stamp
    local expected=$(version)
    local source_app="$project_dir/.build/kongshan.app"
    local target_app="/Applications/kongshan.app"
    local pid=$(installed_app_pid)

    if [[ -n "$pid" ]]; then
        osascript -e 'tell application id "com.kaysen.kongshan" to quit' >/dev/null 2>&1 \
            || fail "无法请求旧版正常退出"
        for _ in {1..200}; do
            [[ -z $(installed_app_pid) ]] && break
            sleep 0.1
        done
        [[ -z $(installed_app_pid) ]] || fail "旧版未在 20 秒内正常退出；未发送 TERM/KILL，也未替换"
    fi

    pgrep -f '/kongshan.*/sing-box' >/dev/null 2>&1 && fail "仍有 kongshan sing-box 进程；未替换"
    local support="$HOME/Library/Application Support/kongshan"
    for residue in proxy-recovery.json dns-recovery.json tun-recovery.json; do
        [[ ! -e "$support/$residue" ]] || fail "系统恢复快照仍存在：$residue；未替换"
    done
    scutil --proxy | awk '/Enable :/ && $3 != 0 { bad=1 } END { exit bad }' \
        || fail "系统代理仍处于启用状态；未替换"
    if scutil --dns | grep -Eq 'nameserver\[[0-9]+\] : (172\.19\.0\.1|fdfe:dcba:9876::1)'; then
        fail "系统 DNS 仍指向 kongshan TUN；未替换"
    fi
    curl --fail --silent --show-error --max-time 10 --noproxy '*' https://www.apple.com/library/test/success.html >/dev/null \
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
    open "$target_app"
    for _ in {1..100}; do
        [[ -n $(installed_app_pid) ]] && break
        sleep 0.1
    done
    [[ -n $(installed_app_pid) ]] || fail "新版未在 10 秒内保持运行；旧版备份仍在 $backup"
    print -- "已安装并打开 v$expected；旧版可恢复备份：$backup"
}

publish() {
    require_verification_stamp
    [[ -z $(git status --porcelain) ]] || fail "发布前工作区必须干净"
    [[ $(git branch --show-current) == main ]] || fail "只允许从 main 发布"
    gh auth status >/dev/null
    local expected=$(version)
    local tag="v$expected"
    local dmg="$project_dir/dist/kongshan-$expected.dmg"
    if git rev-parse "$tag" >/dev/null 2>&1; then
        [[ $(git rev-list -n 1 "$tag") == $(git rev-parse HEAD) ]] \
            || fail "标签 $tag 已存在但不指向当前提交"
    else
        git tag -a "$tag" -m "kongshan $expected"
    fi
    git push origin main
    git push origin "$tag"
    gh release view "$tag" >/dev/null 2>&1 && fail "Release $tag 已存在"
    gh release create "$tag" "$dmg#kongshan-$expected.dmg" \
        --title "kongshan $expected" \
        --generate-notes \
        --latest
    print -- "已发布 $tag"
}

case ${1:-} in
    prepare) prepare ;;
    install) install_verified ;;
    publish) publish ;;
    *)
        print -u2 -- "用法：scripts/release.sh prepare|install|publish"
        exit 64
        ;;
esac
