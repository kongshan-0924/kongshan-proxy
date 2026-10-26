#!/bin/zsh
# 主机架构相关的常量。build_app / release 的门禁与内核下载共用。
#
# 发布包仍然是 Apple Silicon 专用（README 写明），但开发机上允许按主机架构出本地构建：
# Intel Mac 上出 x86_64，用来跑测试、试功能；不会拿去公开发布。

# SwiftPM / Mach-O 里认的架构名（`lipo -archs`、`file` 的输出）。
kongshan_host_arch() {
    case $(uname -m) in
        arm64) print arm64 ;;
        x86_64) print x86_64 ;;
        *) return 1 ;;
    esac
}

# sing-box 官方发布包的平台名（`darwin-arm64` / `darwin-amd64`）。
kongshan_singbox_platform() {
    case $(uname -m) in
        arm64) print arm64 ;;
        x86_64) print amd64 ;;
        *) return 1 ;;
    esac
}

# 内核压缩包与解包后二进制的 SHA-256，按平台分开钉死；版本变更时两处都要更新。
kongshan_singbox_archive_sha256() {
    case $(kongshan_singbox_platform) in
        arm64) print 0d8c7f5ed5d587b0f1a5e9772a708ec3bfa4ac4c9329604b01d8d9c2ba406838 ;;
        amd64) print eae86b9b033bba50b7c44ab719e4bfac0aca05efd28483390ed3aa510f32db25 ;;
        *) return 1 ;;
    esac
}

kongshan_singbox_binary_sha256() {
    case $(kongshan_singbox_platform) in
        arm64) print 6546126c1759683fe85798da92409215d53c50e0f2b346b4f74a61babc8dbec2 ;;
        amd64) print affe521a424d217e013e7c4c84278ecfdf7e9e4108f253a41562272afd5f527e ;;
        *) return 1 ;;
    esac
}
