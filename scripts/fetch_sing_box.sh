#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"
source "$project_dir/scripts/arch_lib.sh"

# 内置内核不再直接用官方发布包：官方没有 XHTTP，改为官方源码 + 移植的 XHTTP 自己编译
# （scripts/build_sing_box.sh，见 Kernel/xhttp/README.md）。构建可复现，SHA-256 按架构钉死在 arch_lib.sh。
target=$(kongshan_singbox_vendor_path)
expected=$(kongshan_singbox_binary_sha256)

verified() {
    [[ -x "$target" ]] \
        && file "$target" | grep -q "$(kongshan_host_arch)" \
        && [[ "$(shasum -a 256 "$target" | awk '{print $1}')" == "$expected" ]]
}

# 已存在且是**本机架构**的已验证副本就直接用。架构不符时必须重编：
# Intel 上跑 arm64 内核只会得到 `bad CPU type in executable`。
if verified; then
    print "Using verified sing-box ($(kongshan_singbox_platform)) at $target"
    exit 0
fi

zsh scripts/build_sing_box.sh "$(kongshan_singbox_platform)" "$target"
verified || {
    print -u2 "编出的 sing-box 与钉住的 SHA-256 不一致（期望 $expected）：Go 版本、源码或补丁变了？"
    exit 1
}
