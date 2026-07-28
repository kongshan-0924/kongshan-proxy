# kongshan

kongshan 是一款面向 Apple Silicon Mac 的原生 sing-box 图形客户端。它使用 SwiftUI/AppKit 构建菜单栏与主窗口，打包官方 sing-box 1.13.14，不自研代理协议或加密实现。

以「配置」为中心：一个订阅即一个配置文件，同一时刻只有一个生效、可随时切换。支持 Shadowsocks（含 `simple-obfs` 混淆插件）、Trojan、VMess、**VLESS（含 Reality / uTLS / xtls-rprx-vision）**、Hysteria2、AnyTLS 六种协议，直接沿用机场自带的策略组做分流——在机场主组里挑一个节点即贯穿所有需代理的流量。系统代理与 TUN 可单独或同时开启，覆盖节点切换/测速、出口 IP 与 DNS 自测、节点地区旗帜与倍率、规则分流与分应用代理、连接监控、配置备份/恢复、双 DoH、Dashboard、实时日志、订阅定时更新、开机自启与内核崩溃自愈。TUN 可选安装**免密码特权助手**，授权一次后启停零弹窗（见下文）。

## 安装

从 [Releases](https://github.com/kongshan-0924/kongshan-proxy/releases) 下载最新 `kongshan-<版本>.dmg`，打开后把 `kongshan.app` 拖进 `Applications`。

产物为 **ad-hoc 签名**（无 Developer ID / 公证），首次打开需在 App 上**右键 → 打开**以绕过 Gatekeeper；请从 `/Applications` 启动，不要直接双击 `dist/` 里的构建产物。

## 系统要求

- Apple Silicon Mac（arm64）
- macOS 14 或更高版本
- 构建：Xcode Command Line Tools / Swift 6 工具链；构建时可访问 GitHub，用于下载固定版本 sing-box 与当前官方规则集

## 构建与打包

```bash
cd /Users/kaysen/workspace/mac/代理软件
zsh scripts/build_app.sh    # 产出 dist/kongshan.app，自增补丁版本号
zsh scripts/make_dmg.sh     # 打成拖拽安装式 dist/kongshan-<版本>.dmg
```

`build_app.sh` 会把 `dist/` 标记为 Spotlight 不索引（`.metadata_never_index`）并注销该副本的启动服务登记，避免构建产物冒充成第二个程序出现在启动台。正式运行副本应放在 `/Applications`。

完整自动验收：

```bash
zsh scripts/verify_m4.sh
```

成功时最后一行为 `M4 automated verification passed`。脚本运行全量测试、构建并校验 arm64 App/签名/内核/规则集，再在隔离的临时数据目录启动无节点 App，检查 CPU、RSS、TCP socket、子进程和恢复残留。脚本不会设置真实系统代理、注册登录项、请求 TUN 管理员授权或发送真实通知。

产物 `dist/kongshan.app` 使用 ad-hoc 签名，未做 Developer ID 签名、公证或自动更新（安装方式见上文「安装」）。若 macOS 阻止运行，请在“系统设置 → 隐私与安全性”中按系统提示确认，不要绕过系统安全机制。

## 使用说明

1. 「配置」页导入 Clash YAML 订阅链接（或手动添加节点），每个订阅下载为一个配置文件；单选其中之一设为生效。
2. 「代理」页按机场自带的策略分流：在主组里挑一个出站节点（可先「测速全部」），需代理的策略会跟随它；也可为单个策略单独指定节点。切换节点后会自动断开旧连接，出口 IP 立即生效。
3. 从菜单栏或「代理」页开启接管方式。系统代理管理当前活动网络服务的 HTTP/HTTPS/SOCKS 设置，无需密码；TUN 需 root。默认每次启动/停止/改配置弹一次管理员授权；也可在「设置 → 隧道」安装**免密码特权助手**（授权一次），之后 TUN 启停零弹窗（见「免密码 TUN 助手」）。两者可单独或同时开启。
4. 「规则」页只读展示当前配置生效的分流规则；自定义绕过域名/CIDR、跳过 TUN 的网段在「设置 → 隧道」维护。
5. 「连接」页实时列出活跃连接（主机/进程、规则链路、上下行流量），可单条或一键全部关闭。Dashboard、日志、连接三页仅在可见且代理运行时才建立 Clash API 连接，离开即断开。
6. 订阅自动更新默认 24 小时，可设为 1–168 小时。App 未运行期间不会后台唤醒；下次启动时，已到期订阅会立即安排更新。
7. 「登录时启动 kongshan」只在用户主动切换时调用 `SMAppService.mainApp`。若显示“等待系统批准”，请打开系统登录项设置批准后返回刷新状态。

## TUN 的工作方式

TUN 模式下的三个关键选择（都是踩过真机坑之后定下来的，改动前请先读 `docs/design/`）：

- **固定 gVisor 用户态栈**。`system`/`mixed` 栈的 TCP 转发在部分网络（多默认网关、企业网）会失效——只有 UDP/ICMP 通、网页全打不开。界面上不再提供协议栈选项。
- **Fake-IP（`240.0.0.0/4`）**。真实 IP 方案下的 DNS-over-TUN 在多网关网络会失效；Class E 段避开了物理网关与订阅规则常用的 `198.18/15`。映射经 `cache_file` 持久化，内核重启后仍然有效。
- **系统 DNS 指向 TUN 接口自身的地址**（如 `172.19.0.1`，不是下一跳）。macOS 只为该地址建本地路由，指到同网段的下一跳会绕回物理网关、无法被 `hijack-dns` 接管。关闭或退出时自动还原。

## 免密码 TUN 助手（可选）

TUN 每次启停都需要 root 授权。若想省去反复输密码，可在「设置 → 隧道 → 安装免密码助手」授权**一次**，安装一个由 launchd 以 root 运行的特权助手；之后 TUN 启停零弹窗。助手职责单一——只起停内置 sing-box，不接受任何来自客户端的路径/命令/参数。

安全设计（ad-hoc 自用、无 Developer ID）：

- **只跑固定内核**：helper 与 sing-box 安装时都拷到 root-only 目录（`/Library/Application Support/kongshan/helper/`，root:wheel），路径钉死进 root:0600 的 `trust.json`；exec 前校验签名 + cdhash，配置只经只读管道 fd（`-c /dev/stdin`）送入，不落盘、不进命令行。
- **只认正版调用方**：每个连接按内核 audit token 取对端签名，校验 identifier + **App bundle 路径** + **cdhash 钉死**；App 启用 **hardened runtime**（内核忽略 `DYLD_INSERT_LIBRARIES`、禁同用户调试注入）。二者合起来，使同一账户下其它进程既不能替换、也不能注入正版 App 来冒充它驱动 root 助手。
- **配置内容白名单**：助手 exec 前对配置做 schema 校验，封死 root 写文件（`log.output`、`cache_file.path`）与远程无鉴权控制（`clash_api` 只允许带 secret 的回环高位端口），校验通过的字节重新序列化后经助手自建管道投喂。
- **只杀自己起的内核**（按可执行路径核对，信号 SIGINT→SIGTERM→SIGKILL 逐级升级并确认退出）、拒绝优先、绝不自动安装（仅用户点按钮或首次开 TUN 时触发一次授权）。助手重启后会认领上一实例遗留的内核，避免出现 App 清理不掉的 root 进程；助手不可达时自动回退到每次授权的 osascript 兜底，功能不受影响。

卸载：「设置 → 隧道 → 卸载助手」一次授权即完成 bootout 并删除助手、socket 与 trust.json。**重新构建 App（cdhash 会变）后需重装助手一次**。

## 权限与恢复

- 系统代理：开启前保存每个活动网络服务的原始代理快照；正常关闭时精确恢复。App 异常结束后重新打开，会先尝试恢复遗留快照。
- TUN：配置以只读文件描述符传给经授权启动的 root sing-box（osascript 兜底走 0600 FIFO；免密码助手走 Unix socket 的 SCM_RIGHTS 只读管道），不落盘；磁盘恢复记录只含 PID、内核路径和启动时间。重启 App 时会核对进程身份，再执行恢复。
- 崩溃自愈：普通/TUN 内核都按精确 PID 监听退出事件；10 秒滚动窗口内最多自动重启 3 次，第 4 次停止接管并尝试发送本地通知。未装助手时 TUN 自动重启仍会显示管理员授权。
- 睡眠唤醒：内核可能"进程还在但隧道已死"（macOS 会拆掉 utun 设备，而 Clash API 照常应答）。唤醒后除健康检查外还会核对 TUN 地址是否仍挂在网卡上，没了就自动重建隧道。
- 换网/唤醒：补挂系统代理与 DNS；**物理网络身份真的变化时**才重置内核里的全部连接（旧连接已死但客户端不知道，会卡在死 socket 上重试十几分钟）。Wi-Fi 信号抖动、IPv6 续租不会触发重置。
- 如果自动恢复失败，不要盲删恢复文件或按不明 PID 杀进程。先退出 kongshan，在“系统设置 → 网络 → 当前网络 → 详细信息 → 代理”核对代理开关；TUN 问题先用活动监视器或 `ps` 核对进程命令确为 App 内置 sing-box，再按界面提示重试恢复。

## 数据与日志

默认数据目录为 `~/Library/Application Support/kongshan/`：

- `subscriptions.json`、`subscriptions/*.yaml`：订阅元数据与成功缓存
- `manual-nodes.json`、`settings.json`、`rules.json`：本地节点与设置
- `rule-sets/*.srs`：验证后的官方规则集缓存
- `config.json`：去除 Clash controller/secret 的诊断快照
- `logs/sing-box*.log`：普通内核日志，单文件上限 5 MiB（免密码助手模式下 TUN 内核日志在 `/Library/Application Support/kongshan/helper/sing-box-tun.log`）
- `fakeip-cache-v2.db`：Fake-IP 映射持久化，供内核重启后复用
- `proxy-recovery.json`、`tun-recovery.json`：仅在接管期间存在的恢复记录

Clash API 的随机端口与 secret 只保存在内存，不写入设置、日志或诊断配置。日志导出只读取已知日志文件，不导出订阅 URL、配置或凭据。

## 已知限制与人工验收

- 系统代理模式只影响进入本地 mixed 代理的请求解析，不等同于接管 macOS 全局 DNS；真实 DNS 泄漏需在 TUN/真实网络下人工验证。
- TUN 模式固定使用 gVisor 栈与 Fake-IP（见「TUN 的工作方式」）；strict_route 可能影响局域网、虚拟机、容器或其他 VPN。
- **所在网络若有透明代理，任何代理客户端的节点都会连不上**（表现为 Reality 校验失败、Hysteria2 无网络活动）。判据与排查步骤见 `docs/design/tun-real-machine-debug.md`。
- 同时运行多个 TUN 客户端（如本应用与 Stash/Surge）会互抢默认路由，务必只开其中一个。
- ad-hoc 构建下的登录项批准、通知权限与 TUN 授权行为受 macOS 系统策略影响，需要在最终安装路径人工确认。
- 自动测试不能代替真实机场订阅、节点可用性、Google/国内站点、出口 IP、DNS leak、强杀 App 恢复、24 小时 Instruments Leaks/Allocations 与 Activity Monitor Energy Impact 验收。

四阶段自动/人工边界分别记录在 `docs/acceptance/M1.md`、`M2.md`、`M3.md` 和 `M4.md`。

## 排障文档

- `docs/design/tun-authorization-approaches.md`：macOS 各家 TUN 授权方式对比（NetworkExtension / SMJobBless 助手 / osascript），本项目为何只能钉 cdhash，以及助手链路上踩过的四个坑及其回归测试。
- `docs/design/tun-real-machine-debug.md`：真机 TUN 排查记录，含"所在网络是否有透明代理"的判据。
- `docs/HANDOFF.md` / `docs/PROGRESS.md` / `docs/NEXT_STEPS.md` / `docs/progress/SESSION_LOG.md`：交接、进度与逐次会话记录。
