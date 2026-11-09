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
zsh scripts/build_sing_box.sh all        # 升级内核：两个架构都编进 Vendor，并更新 arch_lib.sh 的 SHA-256
zsh scripts/build_sing_box.sh arm64 /tmp/sing-box-arm64   # 只编一个架构到指定位置
KONGSHAN_SINGBOX_TEST=1 zsh scripts/build_sing_box.sh amd64 /tmp/sing-box-amd64   # 先跑移植进来的单测
```

内核固定在一台构建机上编（`KONGSHAN_BUILD_HOST`，缺省见脚本开头）：在别的机器上运行会同步脚本与补丁过去编译、取回产物；
构建机经跳板连不上时自动直连。需要 Go 与 Xcode 命令行工具（与官方 macOS 构建一样 `CGO_ENABLED=1`），Go 钉在官方该版本用的 1.26.10，
构建机版本不同会自动下载。构建可复现：**同一台机器**重编得到同一个 SHA-256，钉在 `scripts/arch_lib.sh`；
换机器或构建机升级 Xcode / SDK 后 SHA-256 会变（CGO 链接系统 SDK），用 `all` 重编后提交新的钉住值。

编译选项是官方的 `release/DEFAULT_BUILD_TAGS_OTHERS` 加 `with_xhttp`，比官方 macOS 包少 `with_naive_outbound`
（naive 协议，kongshan 不用）。

## 升级内核

1. 改 `build_sing_box.sh` 的 `version`、`upstream_commit`、`go_toolchain`（看官方 `.github/workflows/build.yml`）。
2. 对照 lx 对应版本更新 `overlay/` 与 `core.patch`（`diff -u 官方 lx` 三个核心文件）；补丁打不上时编译会直接失败。
3. `KONGSHAN_SINGBOX_TEST=1 zsh scripts/build_sing_box.sh all`：跑单测、编两个架构、写新的 SHA-256；提交 `Vendor/sing-box/sing-box`
   与 `arch_lib.sh`，再走分流改动的验证流程。内核 cdhash 变了，装新版后要重装一次免密码助手。
4. **升到 1.15 及以上时**：1.15 废弃了 TUN 的 `stack`（1.17 删除），改用 sing-tun 自带协议栈。要删掉 `ConfigGenerator` 里 TUN 入站的 `stack`，
   同步改助手的配置白名单与 README「TUN 固定使用 gVisor」一句；2026-11-03 用 1.15.0-alpha.13 检查真实配置结构，这是唯一的废弃告警。
