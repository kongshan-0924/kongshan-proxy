#!/bin/zsh
# 远程构建机（App 默认 m5，内核默认 iMac）的连接方式。build_sing_box.sh 与 release.sh prepare-remote 共用。
#
# ~/.ssh/config 里构建机经跳板（ProxyJump）连；跳板连不上说明人和构建机在同一局域网，改为直连。
# 调用 kongshan_remote_setup <主机> 后用：
#   "${kongshan_ssh[@]}" <主机> <命令>
#   rsync -e "$kongshan_rsh" ...

kongshan_remote_setup() {
    local host=$1
    local jump=$(ssh -G "$host" 2>/dev/null | awk '$1 == "proxyjump" { print $2 }')
    kongshan_ssh=(ssh -o ServerAliveInterval=30)
    if [[ -n $jump && $jump != none ]] \
        && ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$jump" true 2>/dev/null; then
        print -u2 "跳板 $jump 连不上，按局域网直连 $host"
        kongshan_ssh+=(-o ProxyJump=none)
    fi
    kongshan_rsh=${(j: :)kongshan_ssh}
    "${kongshan_ssh[@]}" -o BatchMode=yes -o ConnectTimeout=8 "$host" true \
        || { print -u2 "连不上构建机 $host"; return 1 }
}
