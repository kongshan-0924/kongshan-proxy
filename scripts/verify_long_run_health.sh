#!/bin/zsh
set -euo pipefail

app_path=${KONGSHAN_HEALTH_APP_PATH:-/Applications/kongshan.app}
app_binary="$app_path/Contents/MacOS/kongshan"
core_binary="$app_path/Contents/Resources/sing-box"
sample_count=${KONGSHAN_HEALTH_SAMPLE_COUNT:-60}
interval_seconds=${KONGSHAN_HEALTH_INTERVAL_SECONDS:-10}
max_app_average_cpu=${KONGSHAN_HEALTH_MAX_APP_AVERAGE_CPU:-10.0}
max_app_sample_cpu=${KONGSHAN_HEALTH_MAX_APP_SAMPLE_CPU:-20.0}
max_app_rss_kb=${KONGSHAN_HEALTH_MAX_APP_RSS_KB:-262144}
max_app_fd=${KONGSHAN_HEALTH_MAX_APP_FD:-256}
max_core_fd=${KONGSHAN_HEALTH_MAX_CORE_FD:-512}
artifact_dir=${KONGSHAN_HEALTH_ARTIFACT_DIR:-/private/tmp/kongshan-long-run-health-$(date +%Y%m%d-%H%M%S)}

fail() {
    print -u2 -- "Long-run health verification failed: $*"
    capture_diagnostics
    exit 1
}

find_exact_pid() {
    ps -axo pid=,command= | awk -v binary="$1" '$2 == binary { print $1 }'
}

fd_count() {
    local lines
    lines=$( (lsof -nP -p "$1" 2>/dev/null || true) | wc -l | tr -d ' ')
    (( lines > 0 )) && print $((lines - 1)) || print 0
}

tcp_count() {
    (lsof -nP -a -p "$1" -iTCP -sTCP:"$2" 2>/dev/null || true) \
        | awk 'NR > 1 { count++ } END { print count + 0 }'
}

capture_diagnostics() {
    mkdir -p "$artifact_dir"
    ps -axo pid=,ppid=,etime=,%cpu=,rss=,command= > "$artifact_dir/processes.txt" || true
    [[ -z "${app_pid:-}" ]] || /usr/bin/sample "$app_pid" 5 1 -file "$artifact_dir/app-sample.txt" >/dev/null 2>&1 || true
    [[ -z "${app_pid:-}" ]] || lsof -nP -p "$app_pid" > "$artifact_dir/app-lsof.txt" 2>&1 || true
    [[ -z "${core_pid:-}" ]] || lsof -nP -p "$core_pid" > "$artifact_dir/core-lsof.txt" 2>&1 || true
    print -u2 -- "诊断证据：$artifact_dir"
}

(( sample_count > 0 )) || fail "采样次数必须大于 0"
(( interval_seconds >= 0 )) || fail "采样间隔不能为负数"
[[ -x "$app_binary" ]] || fail "App 可执行文件不存在：$app_binary"

app_candidates=$(find_exact_pid "$app_binary")
typeset -a app_pids
app_pids=(${(f)app_candidates})
(( ${#app_pids[@]} == 1 )) || fail "需要且只能有一个运行中 App，当前 ${#app_pids[@]} 个"
app_pid=${app_pids[1]}

typeset -a app_cpu_samples app_rss_samples app_fd_samples core_fd_samples established_samples close_wait_samples
for (( index = 1; index <= sample_count; index++ )); do
    kill -0 "$app_pid" 2>/dev/null || fail "第 $index 次采样前 App 已退出"
    read -r app_cpu app_rss <<< "$(ps -p "$app_pid" -o %cpu=,rss=)"
    app_fd=$(fd_count "$app_pid")
    core_candidates=$(find_exact_pid "$core_binary")
    typeset -a core_pids
    core_pids=(${(f)core_candidates})
    (( ${#core_pids[@]} <= 1 )) || fail "检测到 ${#core_pids[@]} 个 sing-box 内核，无法确定采样对象"
    core_pid=${core_pids[1]:-}
    if [[ -n "$core_pid" ]]; then
        core_fd=$(fd_count "$core_pid")
        established=$(tcp_count "$core_pid" ESTABLISHED)
        close_wait=$(tcp_count "$core_pid" CLOSE_WAIT)
    else
        core_fd=0
        established=0
        close_wait=0
    fi

    app_cpu_samples+=("$app_cpu")
    app_rss_samples+=("$app_rss")
    app_fd_samples+=("$app_fd")
    core_fd_samples+=("$core_fd")
    established_samples+=("$established")
    close_wait_samples+=("$close_wait")
    print -- "Sample $index/$sample_count: app CPU ${app_cpu}% RSS ${app_rss}KB FD $app_fd; core PID ${core_pid:-无} FD $core_fd ESTABLISHED $established CLOSE_WAIT $close_wait"
    (( index == sample_count )) || sleep "$interval_seconds"
done

average_cpu=$(print -l -- "${app_cpu_samples[@]}" | awk '{ total += $1 } END { printf "%.3f", total / NR }')
max_cpu=$(print -l -- "${app_cpu_samples[@]}" | sort -nr | head -1)
max_rss=$(print -l -- "${app_rss_samples[@]}" | sort -nr | head -1)
max_app_fd_observed=$(print -l -- "${app_fd_samples[@]}" | sort -nr | head -1)
max_core_fd_observed=$(print -l -- "${core_fd_samples[@]}" | sort -nr | head -1)
max_established=$(print -l -- "${established_samples[@]}" | sort -nr | head -1)
max_close_wait=$(print -l -- "${close_wait_samples[@]}" | sort -nr | head -1)

awk -v value="$average_cpu" -v limit="$max_app_average_cpu" 'BEGIN { exit !(value <= limit) }' || fail "App 平均 CPU ${average_cpu}% 超过 ${max_app_average_cpu}%"
awk -v value="$max_cpu" -v limit="$max_app_sample_cpu" 'BEGIN { exit !(value <= limit) }' || fail "App 单次 CPU ${max_cpu}% 超过 ${max_app_sample_cpu}%"
(( max_rss <= max_app_rss_kb )) || fail "App RSS ${max_rss}KB 超过 ${max_app_rss_kb}KB"
(( max_app_fd_observed <= max_app_fd )) || fail "App FD $max_app_fd_observed 超过 $max_app_fd"
(( max_core_fd_observed <= max_core_fd )) || fail "Core FD $max_core_fd_observed 超过 $max_core_fd"
(( max_close_wait == 0 )) || fail "检测到 $max_close_wait 个 CLOSE_WAIT"

print -- "Summary: app average/max CPU ${average_cpu}%/${max_cpu}%, max RSS ${max_rss}KB, app/core max FD ${max_app_fd_observed}/${max_core_fd_observed}, max ESTABLISHED $max_established, CLOSE_WAIT $max_close_wait"
print -- "Long-run health verification passed"
