#!/bin/zsh
# 主机架构相关的常量。build_app / release 的门禁与内核下载共用。
#
# 每次发布两个包：arm64 与 x86_64（release.sh prepare-remote 在 Intel 测试机上一起出）。

# 目标架构默认是本机；KONGSHAN_TARGET_ARCH=arm64|x86_64 可交叉构建另一个架构
# （iMac 上同时出 x86_64 自用与 arm64 给 MacBook，见 release.sh prepare-remote）。
# SwiftPM / Mach-O 里认的架构名（`lipo -archs`、`file` 的输出）。
kongshan_host_arch() {
    case ${KONGSHAN_TARGET_ARCH:-$(uname -m)} in
        arm64) print arm64 ;;
        x86_64) print x86_64 ;;
        *) return 1 ;;
    esac
}

# sing-box 官方发布包的平台名（`darwin-arm64` / `darwin-amd64`）。
kongshan_singbox_platform() {
    case ${KONGSHAN_TARGET_ARCH:-$(uname -m)} in
        arm64) print arm64 ;;
        x86_64) print amd64 ;;
        *) return 1 ;;
    esac
}

# 各架构内核在 Vendor 里的位置：arm64 入库（发布用），amd64 只在本地（.gitignore）。
kongshan_singbox_vendor_path() {
    case $(kongshan_singbox_platform) in
        arm64) print Vendor/sing-box/sing-box ;;
        amd64) print Vendor/sing-box/sing-box-amd64 ;;
        *) return 1 ;;
    esac
}

# 内置内核（官方源码 + XHTTP，`scripts/build_sing_box.sh` 编出）的 SHA-256，按平台钉死；
# 构建可复现（-trimpath、-buildid= 与固定的 Go 版本），换版本或改补丁后重编并更新这里。
kongshan_singbox_binary_sha256() {
    case $(kongshan_singbox_platform) in
        arm64) print 232905956e0662cb8da7f7d68f19ef53369fb657071d939f002f00e313f13cf6 ;;
        amd64) print 1c1329a836969e9e37d1a61013c47cc5e056ee27397538f17503188e74101202 ;;
        *) return 1 ;;
    esac
}
