#!/bin/zsh
# 在构建机（默认 m5）上编译并跑测试，带卡死看门狗：日志连续 STALL 秒（默认 180）没有新输出，
# 就打印最后几行与正在跑的用例、结束测试进程并以非零退出——不再出现「后台空等半小时」（2026-11-09）。
#
# 用法：scripts/remote_test.sh [主机] [--filter 正则] [--snapshots 远程目录]
#   结果日志在构建机 ~/ks-test.log；快照目录给了就设 KONGSHAN_SNAPSHOT_DIR。
set -euo pipefail
project_dir=${0:A:h:h}
cd "$project_dir"

host=m5 filter="" snapdir=""
[[ ${1:-} != --* && -n ${1:-} ]] && { host=$1; shift }
while (( $# )); do
    case $1 in
        --filter) filter=$2; shift 2 ;;
        --snapshots) snapdir=$2; shift 2 ;;
        *) print -u2 "未知参数：$1"; exit 2 ;;
    esac
done
stall=${STALL:-180}
remote=kongshan-test/src

source scripts/remote_lib.sh
kongshan_remote_setup "$host"
# 与 release.sh prepare-remote 同规则：amd64 内核不入库，--delete 时必须排除，否则会删掉构建机上钉住的那份
# （2026-11-09 从工作区同步到 iMac 时删过一次，127 例测试因此失败）。本机有就单独带过去。
rsync -e "$kongshan_rsh" -a --delete --exclude .git --exclude .build --exclude dist --exclude .vscode \
    --exclude .worktrees --exclude .DS_Store --exclude Vendor/sing-box/sing-box-amd64 ./ "$host:$remote/"
amd64=Vendor/sing-box/sing-box-amd64
[[ -f $amd64 ]] || amd64=${KONGSHAN_MAIN_REPO:-$HOME/workspace/mac/代理软件}/Vendor/sing-box/sing-box-amd64
[[ -f $amd64 ]] && rsync -e "$kongshan_rsh" -a "$amd64" "$host:$remote/Vendor/sing-box/sing-box-amd64"

# ssh 会把参数拼成一行命令，空字符串会丢；用 (qq) 加引号保住位置。
"${kongshan_ssh[@]}" "$host" zsh -s -- ${(qq)remote} ${(qq)stall} ${(qq)filter} ${(qq)snapdir} <<'REMOTE'
set -u
remote=$1 stall=$2 filter=${3:-} snapdir=${4:-}
cd ~/$remote || exit 2
# 上一轮残留的测试进程会占住 .build 锁，新一轮只能空等：先清掉。
# swift-test 的命令行不带项目路径，按工作目录认人，只杀本项目的，不碰构建机上别的项目（2026-11-09 审计）。
for p in $(pgrep -f "swift-test --skip-build" 2>/dev/null); do
    [[ $(lsof -a -p $p -d cwd -Fn 2>/dev/null | sed -n 's/^n//p') == $HOME/$remote ]] && kill $p 2>/dev/null
done
pkill -f "xctest $HOME/$remote" 2>/dev/null; sleep 1
print "== 编译"
swift build --build-tests 2>&1 | grep -E "error:|Compiling|Build complete" | grep -v Compiling | tail -5
(( ${pipestatus[1]} == 0 )) || { print "编译失败"; exit 1 }
log=~/ks-test.log
[[ -f $log ]] && trash $log
args=(--skip-build)
[[ -n $filter ]] && args+=(--filter "$filter")
if [[ -n $snapdir ]]; then
    [[ -d $snapdir ]] && trash $snapdir
    mkdir -p $snapdir
    export KONGSHAN_SNAPSHOT_DIR=$snapdir
fi
print "== 测试（看门狗 ${stall}s）"
swift test $args > $log 2>&1 &
pid=$!
last_size=-1 idle=0
while kill -0 $pid 2>/dev/null; do
    sleep 10
    size=$(stat -f %z $log)
    if (( size == last_size )); then
        (( idle += 10 ))
        if (( idle >= stall )); then
            print "!! 日志 ${stall}s 无新输出，判定卡死。最后几行："
            tail -4 $log
            print "!! 正在跑的子进程："
            ps -axo pid,ppid,etime,command | grep -E "xctest|tail -f|sing-box|safe-test-core" | grep -v grep
            pkill -P $pid 2>/dev/null; kill $pid 2>/dev/null
            pkill -f "xctest $HOME/$remote" 2>/dev/null
            exit 3
        fi
    else
        idle=0 last_size=$size
    fi
done
wait $pid; code=$?
grep -E ": error:|Executed [0-9]+ tests, with|✘ Test" $log | sort -u | tail -15
exit $code
REMOTE
