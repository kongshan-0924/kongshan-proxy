# 内置内核的 XHTTP 移植

官方 sing-box 不支持 Xray 的 XHTTP 传输。kongshan 的内置内核 = 官方源码 + 从
[sing-box-lx](https://github.com/Leadaxe/sing-box-lx) 移植的 XHTTP 客户端，由 `scripts/build_sing_box.sh` 编译。
除 XHTTP 外都是官方代码；版本号显示为 `1.14.4-xhttp`。

| 来源 | 版本 | 提交 |
|---|---|---|
| SagerNet/sing-box | v1.14.4 | `c005f35300ce76427dc285481ec5695f5b179cd2` |
| Leadaxe/sing-box-lx | v1.14.4-lx.25 | `d0e2a15ee71f53469dd98f3c63b1e0ba7c3b678c` |

## 内容

- `overlay/`：原样复制到官方源码树。
  - `transport/v2rayxhttp/`：lx 的 XHTTP 实现与单测。改动两处：
    - `conntest_lx.go` 换成 `conntest_kongshan.go`：去掉 lx 自己的连接测试追踪（`common/lxtrace`，官方没有），行为同 lx 无追踪时；
    - `http3.go` 没带，`http3_stub.go` 改为总是生效：HTTP/3 版 XHTTP 依赖 lx 改过的 TLS，没移植，`alpn` 写 `h3` 的节点会被拒（App 导入时就拦下）。
  - `transport/v2ray/registry.go`、`common/badh2/`、`option/v2ray_xhttp*.go`、`include/v2rayxhttp.go`：lx 原文件。
- `core.patch`：对官方三个文件的改动（传输类型常量、传输选项解码、客户端传输改走注册表），共约 80 行，取自 lx 同版本。
- `LICENSE.sing-box-lx`：lx 的许可证（GPL-3.0，与官方相同）。

## 编译

```bash
zsh scripts/build_sing_box.sh            # 按本机架构，输出到 Vendor/sing-box/sing-box
KONGSHAN_SINGBOX_TEST=1 zsh scripts/build_sing_box.sh amd64 /tmp/sing-box-amd64   # 先跑移植进来的单测
```

需要 Go 与 Xcode 命令行工具（与官方 macOS 构建一样 `CGO_ENABLED=1`）。Go 钉在官方该版本用的 1.26.10，
本机版本不同会自动下载。构建可复现：同一版 Go 重编得到同一个 SHA-256，钉在 `scripts/arch_lib.sh`。

编译选项是官方的 `release/DEFAULT_BUILD_TAGS_OTHERS` 加 `with_xhttp`，比官方 macOS 包少 `with_naive_outbound`
（naive 协议，kongshan 不用）。

## 升级内核

1. 改 `build_sing_box.sh` 的 `version`、`upstream_commit`、`go_toolchain`（看官方 `.github/workflows/build.yml`）。
2. 对照 lx 对应版本更新 `overlay/` 与 `core.patch`（`diff -u 官方 lx` 三个核心文件）；补丁打不上时编译会直接失败。
3. `KONGSHAN_SINGBOX_TEST=1` 编两个架构，把新的 SHA-256 写进 `arch_lib.sh`，再走分流改动的验证流程。
