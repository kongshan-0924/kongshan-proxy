#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"

fail() {
    print -u2 -- "M4 verification failed: $*"
    exit 1
}

if [[ ${KONGSHAN_VERIFY_SKIP_BUILD:-0} != 1 ]]; then
    zsh scripts/verify_m3.sh
fi

app_path=${KONGSHAN_VERIFY_APP_PATH:-${KONGSHAN_APP_PATH:-"$project_dir/.build/kongshan.app"}}
app_binary="$app_path/Contents/MacOS/kongshan"
core_binary="$app_path/Contents/Resources/sing-box"

[[ -d "$app_path" ]] || fail "app bundle is missing: $app_path"
[[ -x "$app_binary" ]] || fail "app executable is missing"
[[ -x "$core_binary" ]] || fail "bundled sing-box is missing"
[[ -f "$app_path/Contents/Info.plist" ]] || fail "Info.plist is missing"
[[ -f "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md" ]] || fail "third-party notices are missing"

file "$app_binary" | grep -q 'arm64' || fail "app executable is not arm64"
file "$core_binary" | grep -q 'arm64' || fail "sing-box is not arm64"
codesign --verify --deep --strict --verbose=2 "$app_path"
plutil -lint "$app_path/Contents/Info.plist"
"$core_binary" version | grep -q 'sing-box version 1.13.14' || fail "unexpected sing-box version"

if [[ ${KONGSHAN_VERIFY_SKIP_TESTS:-0} != 1 ]]; then
    swift test --skip-build --filter DNSConfigTests/testSystemAndTUNDefaultAndCustomDNSPassBundledCoreCheck
    swift test --skip-build --filter ClashStreamingTests/testConsumerCancellationClosesUnderlyingDataStream
    swift test --skip-build --filter CrashRestartTests
    swift test --skip-build --filter AppStateTests/testDashboardMonitoringKeepsSixtyPointsAndIsIdempotent
    swift test --skip-build --filter AppStateTests/testLogMonitoringKeepsTwoThousandEntriesAndIsIdempotent
    swift test --skip-build --filter AppStateTests/testInitializeOnlyReadsLoginItemStatusWithoutRegistering
fi

max_rss_kb=${KONGSHAN_VERIFY_MAX_RSS_KB:-153600}
max_average_cpu=${KONGSHAN_VERIFY_MAX_AVERAGE_CPU:-1.0}
max_sample_cpu=${KONGSHAN_VERIFY_MAX_SAMPLE_CPU:-5.0}
verification_root=$(mktemp -d /tmp/kongshan-m4-verify.XXXXXX)
verification_home="$verification_root/home"
app_stdout="$verification_root/app.stdout"
app_stderr="$verification_root/app.stderr"
app_pid=""

terminate_app() {
    [[ -n "$app_pid" ]] || return 0
    local pid=$app_pid
    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        for _ in {1..50}; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
    fi
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        app_pid=""
        return 1
    fi
    wait "$pid" 2>/dev/null || true
    app_pid=""
}

cleanup() {
    terminate_app >/dev/null 2>&1 || true
    if [[ "$verification_root" == /tmp/kongshan-m4-verify.* ]]; then
        rm -rf "$verification_root"
    fi
}
trap cleanup EXIT

mkdir -p "$verification_home"
CFFIXED_USER_HOME="$verification_home" "$app_binary" >"$app_stdout" 2>"$app_stderr" &
app_pid=$!

for _ in {1..50}; do
    kill -0 "$app_pid" 2>/dev/null && break
    sleep 0.1
done
kill -0 "$app_pid" 2>/dev/null || fail "release app exited during launch"
# `ps %cpu` 是衰减平均值。应用启动要建主窗口并首次渲染仪表盘，
# 只等 2 秒会把这段启动开销算进读数。红线针对的是空闲稳态，因此先让它稳定下来。
sleep ${KONGSHAN_VERIFY_SETTLE_SECONDS:-15}

support_dir="$verification_home/Library/Application Support/kongshan"
[[ -d "$support_dir" ]] || fail "app did not use the isolated support directory"

if [[ ${KONGSHAN_VERIFY_INJECT_RECOVERY:-0} == 1 ]]; then
    touch "$support_dir/proxy-recovery.json"
fi

typeset -a cpu_samples
max_rss_observed=0
for index in {1..5}; do
    sample=$(ps -p "$app_pid" -o %cpu=,rss=)
    [[ -n "$sample" ]] || fail "release app exited before sample $index"
    read -r cpu rss <<< "$sample"
    cpu_samples+=("$cpu")
    (( rss > max_rss_observed )) && max_rss_observed=$rss
    (( rss < max_rss_kb )) || fail "RSS ${rss} KB exceeds ${max_rss_kb} KB"
    awk -v value="$cpu" -v limit="$max_sample_cpu" 'BEGIN { exit !(value <= limit) }' \
        || fail "CPU sample ${cpu}% exceeds ${max_sample_cpu}%"
    print -- "M4 idle sample $index: CPU ${cpu}% RSS ${rss} KB"
    sleep 1
done

average_cpu=$(print -l -- "${cpu_samples[@]}" | awk '{ total += $1 } END { printf "%.3f", total / NR }')
awk -v value="$average_cpu" -v limit="$max_average_cpu" 'BEGIN { exit !(value <= limit) }' \
    || fail "average CPU ${average_cpu}% exceeds ${max_average_cpu}%"

tcp_sockets=$(lsof -nP -a -p "$app_pid" -iTCP 2>/dev/null || true)
[[ -z "$tcp_sockets" ]] || fail "no-node app retained TCP sockets"
child_pids=$(pgrep -P "$app_pid" || true)
[[ -z "$child_pids" ]] || fail "no-node app retained child processes: $child_pids"
[[ ! -e "$support_dir/proxy-recovery.json" ]] || fail "proxy recovery residue exists"
[[ ! -e "$support_dir/tun-recovery.json" ]] || fail "TUN recovery residue exists"
fifo_path=$(find "$verification_home" -type p -print -quit)
[[ -z "$fifo_path" ]] || fail "FIFO residue exists: $fifo_path"

terminate_app || fail "release app did not exit after TERM"
print -- "M4 idle summary: average CPU ${average_cpu}% max RSS ${max_rss_observed} KB"
print 'M4 automated verification passed'
