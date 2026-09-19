#!/bin/zsh
set -euo pipefail

app_path=${KONGSHAN_DASHBOARD_APP_PATH:-/Applications/kongshan.app}
app_binary="$app_path/Contents/MacOS/kongshan"
bundle_id=${KONGSHAN_DASHBOARD_BUNDLE_ID:-com.kaysen.kongshan}
sample_count=${KONGSHAN_DASHBOARD_SAMPLE_COUNT:-10}
settle_seconds=${KONGSHAN_DASHBOARD_SETTLE_SECONDS:-15}
max_average_cpu=${KONGSHAN_DASHBOARD_MAX_AVERAGE_CPU:-10.0}
max_sample_cpu=${KONGSHAN_DASHBOARD_MAX_SAMPLE_CPU:-20.0}
max_rss_kb=${KONGSHAN_DASHBOARD_MAX_RSS_KB:-262144}
artifact_dir=${KONGSHAN_DASHBOARD_ARTIFACT_DIR:-/private/tmp/kongshan-dashboard-performance-$(date +%Y%m%d-%H%M%S)}
app_pid=""
did_capture=0

capture_diagnostics() {
    (( did_capture == 0 )) || return 0
    did_capture=1
    [[ -n "$app_pid" ]] || return 0
    kill -0 "$app_pid" 2>/dev/null || return 0
    mkdir -p "$artifact_dir"
    /usr/bin/sample "$app_pid" 5 1 -file "$artifact_dir/sample.txt" >/dev/null 2>&1 || true
    ps -p "$app_pid" -o pid=,etime=,%cpu=,rss=,command= > "$artifact_dir/process.txt" || true
    print -u2 -- "诊断证据：$artifact_dir"
}

fail() {
    print -u2 -- "Dashboard performance verification failed: $*"
    capture_diagnostics
    exit 1
}

[[ -d "$app_path" ]] || fail "App 不存在：$app_path"
[[ -x "$app_binary" ]] || fail "可执行文件不存在：$app_binary"
(( sample_count > 0 )) || fail "采样次数必须大于 0"

candidate_output=$(ps -axo pid=,command= | awk -v binary="$app_binary" '$2 == binary { print $1 }')
[[ -n "$candidate_output" ]] || fail "目标 App 未运行；本门禁不会自行启动代理"
typeset -a candidates
candidates=(${(f)candidate_output})
(( ${#candidates[@]} == 1 )) || fail "找到 ${#candidates[@]} 个目标 App 进程，无法确定采样对象"
app_pid=${candidates[1]}

# 只请求现有实例显示窗口。脚本不发送退出、TERM 或 KILL，也不改代理配置。
open -b "$bundle_id"
sleep "$settle_seconds"
kill -0 "$app_pid" 2>/dev/null || fail "显示窗口后原 App 进程已退出"

current_pid=$(ps -axo pid=,command= | awk -v binary="$app_binary" '$2 == binary { print $1 }')
[[ "$current_pid" == "$app_pid" ]] || fail "显示窗口前后进程发生变化（原 $app_pid，现 ${current_pid:-无}）"

typeset -a cpu_samples
max_rss_observed=0
for (( index = 1; index <= sample_count; index++ )); do
    sample=$(ps -p "$app_pid" -o %cpu=,rss=)
    [[ -n "$sample" ]] || fail "第 $index 次采样前 App 已退出"
    read -r cpu rss <<< "$sample"
    cpu_samples+=("$cpu")
    (( rss > max_rss_observed )) && max_rss_observed=$rss
    (( rss <= max_rss_kb )) || fail "RSS ${rss} KB 超过 ${max_rss_kb} KB"
    awk -v value="$cpu" -v limit="$max_sample_cpu" 'BEGIN { exit !(value <= limit) }' \
        || fail "CPU 单次 ${cpu}% 超过 ${max_sample_cpu}%"
    print -- "Dashboard sample $index: CPU ${cpu}% RSS ${rss} KB"
    sleep 1
done

average_cpu=$(print -l -- "${cpu_samples[@]}" | awk '{ total += $1 } END { printf "%.3f", total / NR }')
awk -v value="$average_cpu" -v limit="$max_average_cpu" 'BEGIN { exit !(value <= limit) }' \
    || fail "CPU 平均 ${average_cpu}% 超过 ${max_average_cpu}%"

print -- "Dashboard summary: average CPU ${average_cpu}% max RSS ${max_rss_observed} KB PID ${app_pid}"
print -- "Dashboard visible-window performance verification passed"
