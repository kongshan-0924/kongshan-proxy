# kongshan 空山

面向 Apple Silicon Mac 的原生 sing-box 图形客户端。SwiftUI + AppKit 构建，打包官方 sing-box 1.13.14，不自研任何代理协议或加密实现。

以「配置」为中心：一个订阅即一个配置文件，同一时刻只有一个生效、可随时切换。支持 **Shadowsocks**（含 SIP003 插件）、**Trojan**、**VMess**、**VLESS**（Reality / uTLS / xtls-rprx-vision）、**Hysteria2**、**AnyTLS** 六种协议，直接沿用机场自带的策略组做分流。系统代理与 TUN 可单独或同时开启。

## 安装

从 [Releases](https://github.com/kongshan-0924/kongshan-proxy/releases) 下载最新 `kongshan-<版本>.dmg`，打开后把 `kongshan.app` 拖进 `Applications`。

产物为 **ad-hoc 签名**（无 Developer ID、未公证），首次打开需在 App 上**右键 → 打开**以绕过 Gatekeeper。请从 `/Applications` 启动，不要直接双击 `dist/` 里的构建产物——那是同一个 App 的另一份副本。

## 系统要求

- Apple Silicon Mac（arm64）
- macOS 14 或更高版本
- 构建：Xcode Command Line Tools / Swift 6 工具链；构建时需访问 GitHub 以下载固定版本 sing-box 与官方规则集

## 界面

侧栏八页，各自回答一个问题：

| 页 | 回答什么 |
|---|---|
| **仪表盘** | 现在通不通、走哪个节点、出口在哪、这次用了多少流量 |
| **配置** | 我有哪些订阅 / 自建节点，哪个生效 |
| **代理** | 每个策略走哪个节点，哪个节点快 |
| **规则** | 流量是怎么分的 |
| **连接** | 此刻谁在联网，走了哪条链路 |
| **内核日志** | 某个域名为什么连不上 |
| **消息** | 出过什么问题 |
| **设置** | 通用 / 隧道 / 网络 / 资源 / 更多 |

### 仪表盘

顶部胶囊直接开关系统代理与 TUN，两者可同时生效。指标区给出接管方式、当前节点、出口 IP 与 DNS 泄漏检测、活跃连接数、内核内存与运行时长。

「网络流量」除实时速率曲线外，还显示**本次会话累计**——数据取自内核的权威累计计数器，**跨内核重启连续**（改设置、崩溃自愈都会重启内核，计数器归零时会自动结转基线）。

### 配置

粘贴 Clash YAML 订阅链接导入，每个订阅下载为一个配置文件。

「+ 自建节点」有两种方式：

- **粘贴链接**：支持 `ss` / `trojan` / `vmess` / `vless` / `hysteria2`(`hy2`) / `anytls`，可一次粘贴多行，解析结果带协议标签预览后再添加，解析不了的行安静跳过。
- **手动填写**：Hysteria2 表单。

### 代理

按机场自带的策略分流：左侧用流媒体、AI、通讯、游戏等语义图标区分策略组；在主组里挑一个出站节点
（可先「测速全部」），需代理的策略会跟随它，也可为单个策略单独指定。批量测速使用有界并发并分批
更新界面，“测速并选最快”只测试当前策略的候选节点。延迟显示在节点卡片右上角，选中项有底色。
切换节点后自动断开旧连接，出口 IP 立即生效。

### 规则

只读展示当前配置生效的分流规则，**按目标策略分组折叠**——一屏就能看清流量怎么分（哪些直连、哪些被拦、哪些走哪个组），点开某组才铺开明细。搜索时切回扁平结果。自定义绕过域名/CIDR、跳过 TUN 的网段在「设置 → 隧道」维护。

### 连接

实时列出活跃连接（主机、进程、命中的规则、出站链路、上下行速率与累计量），顶部给出筛选范围内的累计合计。出站链路显示节点名而非内部 tag。可单条或一键全部关闭。

### 内核日志

排障用。除级别筛选与关键字搜索外：

- **只看问题**：只显示警告与错误。几千行里真正有信息量的通常只有几十行。
- **按连接聚合**：把同一条连接的多行日志（入站 → 进程匹配 → 出站 → 失败原因）折成一组，标出目标主机与行数，有错整组标红，可一次复制整条链路。
- 搜索同时匹配解析出的目标主机名。

Dashboard、日志、连接三页仅在可见且代理运行时才建立 Clash API 连接，离开即断开。

## 菜单栏

菜单栏使用原生 AppKit 状态项，显示代理状态图标和整机实时上下行速度。

- **图标有三种样式**（山脊 / 山谷 / 盾峰），在「设置 → 通用 → 外观」切换。菜单栏会把图标染成单色，所以状态靠**形状**区分：关闭是线稿、开启填实、TUN 额外加一个点。
- 速度每 2 秒读取一次物理 `en*` 网卡，不统计 `utun`，避免 TUN 流量重复计数；代理关闭时也能显示整机网速。
- 状态栏按钮与持久化 `NSMenu` 相互独立：速度刷新不替换菜单对象，节点子菜单和面板入口不会被 SwiftUI Scene 重建打断。

## TUN 的工作方式

TUN 模式下的三个关键选择（都是踩过真机坑之后定下来的，改动前先读 `docs/design/`）：

- **固定 gVisor 用户态栈**。`system`/`mixed` 栈的 TCP 转发在部分网络（多默认网关、企业网）会失效——只有 UDP/ICMP 通、网页全打不开。界面上不提供协议栈选项。
- **Fake-IP（`240.0.0.0/4`）**。真实 IP 方案下的 DNS-over-TUN 在多网关网络会失效；Class E 段避开了物理网关与订阅规则常用的 `198.18/15`。映射经 `cache_file` 持久化。
- **系统 DNS 指向 TUN 接口自身的地址**（如 `172.19.0.1`，不是下一跳）。macOS 只为该地址建本地路由，指到同网段的下一跳会绕回物理网关、无法被 `hijack-dns` 接管。关闭或退出时自动还原。

## 内网 DNS 分流

TUN 模式下系统 DNS 被指向 TUN 接口自身，所有查询交给内核。而 Fake-IP **不校验域名是否真实存在**——任何名字都给一个 `240.0.0.0/4` 的假 IP，假 IP 段又整段被路由进代理出口。结果是**内网设备一直加载**：流量被送去国外节点，让它连你办公室的机器。企业网的 AD 域常常是个 `.com`，正好落在这条路上。

所以启动时（**接管系统 DNS 之前**）会探测内网 DNS 与内网域名，把内网域名交给内网 DNS 解析并直连；系统代理模式下同时加进 bypass 表。域名来源依次是：

1. DHCP 下发的搜索域；
2. 没有搜索域时，用内网 DNS 自身的 PTR 反解推断 AD 域——`PTR(内网DNS)` → `AD1.<域>` → 候选域，再要求**该域在同一台服务器上解析到私有 IP** 才接受（这一步防误判：公共 DNS 的反解也有父域，但它会解析到公网地址）。

可在「设置 → 隧道 → 内网 DNS 分流」关闭或手动指定服务器与域名后缀。

**已知边界**：只在启动时探测。TUN 运行中换网络不会重新探测，关掉再开即可。

## 免密码 TUN 助手（可选）

TUN 每次启停都需要 root 授权。在「设置 → 隧道 → 安装免密码助手」授权**一次**，安装一个由 launchd 以 root 运行的特权助手，之后 TUN 启停零弹窗。助手职责单一——只起停内置 sing-box，不接受任何来自客户端的路径/命令/参数。

安全设计（ad-hoc 自用、无 Developer ID）：

- **只跑固定内核**：helper 与 sing-box 安装时都拷到 root-only 目录（`/Library/Application Support/kongshan/helper/`，root:wheel），路径钉死进 root:0600 的 `trust.json`；exec 前校验签名 + cdhash，配置只经只读管道 fd（`-c /dev/stdin`）送入，不落盘、不进命令行。
- **只认正版调用方**：每个连接按内核 audit token 取对端签名，校验 identifier + **App bundle 路径** + **cdhash 钉死**；App 启用 **hardened runtime**（内核忽略 `DYLD_INSERT_LIBRARIES`、禁同用户调试注入）。二者合起来，使同一账户下其它进程既不能替换、也不能注入正版 App 来冒充它驱动 root 助手。
- **配置内容白名单**：助手 exec 前对配置做 schema 校验，封死 root 写文件（`log.output`、`cache_file.path`）与远程无鉴权控制（`clash_api` 只允许带 secret 的回环高位端口）。
- **只杀自己起的内核**（按可执行路径核对，信号 SIGINT→SIGTERM→SIGKILL 逐级升级并确认退出）、拒绝优先、绝不自动安装。助手重启后会认领上一实例遗留的内核；助手不可达时自动回退到每次授权的 osascript 兜底。

卸载：「设置 → 隧道 → 卸载助手」一次授权即完成。**重新构建 App（cdhash 会变）后需重装助手一次**——这是 ad-hoc 签名的固有代价，不要为省这一次弹窗放宽 cdhash 校验。

## 权限与恢复

- **单实例**：启动时检查是否已有同一个 App 在运行，有就把已有窗口带到前台、自己安静退出。两个实例同时跑会各自持有一份系统代理快照，后退出的那个会拿被对方改过的快照去"还原"，把设置永久写坏。
- **本地端口固定**：mixed inbound 的端口首次分配后写入 `settings.json` 跨启动复用，只有被占用才另选（并给出提示）。Chromium 内核的客户端会缓存解析到的系统代理地址，端口每次都变会让它们持续去打已经关掉的旧端口，表现为反复「正在重新连接」。
- **节点域名解析走无连接 UDP**。DoH 是长连接，被路由器 NAT 悄悄回收后内核察觉不到，后续查询会写进死 socket 卡满 10 秒；而这条链路负责解析**出站节点自己的域名**，它一卡整个代理就停摆。国内网站的解析仍走 DoH，隐私与抗投毒不受影响。
- **系统代理**：开启前保存每个活动网络服务的原始快照，正常关闭时精确恢复。App 异常结束后重新打开会先尝试恢复遗留快照。
- **崩溃自愈**：普通/TUN 内核都按精确 PID 监听退出事件；10 秒滚动窗口内最多自动重启 3 次，第 4 次停止接管并**还原系统代理**（不留指向死端口的设置）。
- **睡眠唤醒**：内核可能"进程还在但隧道已死"（macOS 会拆掉 utun 设备，而 Clash API 照常应答）。唤醒后除健康检查外还会核对 TUN 地址是否仍挂在网卡上，没了就自动重建隧道。
- **换网**：补挂系统代理与 DNS；**物理网络身份真的变化时**才重置内核里的全部连接。Wi-Fi 信号抖动、IPv6 续租不会触发。
- 若自动恢复失败，不要盲删恢复文件或按不明 PID 杀进程。先退出 kongshan，在「系统设置 → 网络 → 详细信息 → 代理」核对开关；TUN 问题先用活动监视器核对进程命令确为 App 内置 sing-box，再按界面提示重试。

## 数据与日志

默认数据目录 `~/Library/Application Support/kongshan/`：

- `subscriptions.json`、`subscriptions/*.yaml`：订阅元数据与成功缓存
- `manual-nodes.json`、`settings.json`、`rules.json`：本地节点与设置
- `rule-sets/*.srs`：验证后的官方规则集缓存
- `config.json`：**去除凭据与 Clash controller/secret** 的诊断快照
- `logs/sing-box*.log`：普通内核日志，单文件上限 5 MiB（助手模式下 TUN 内核日志在 `/Library/Application Support/kongshan/helper/sing-box-tun.log`）
- `fakeip-cache-v2.db`：Fake-IP 映射持久化
- `proxy-recovery.json`、`tun-recovery.json`：仅在接管期间存在的恢复记录

Clash API 的随机端口与 secret 只保存在内存，不写入设置、日志或诊断配置。日志导出只读取已知日志文件，不导出订阅 URL、配置或凭据。

## 构建与打包

```bash
zsh scripts/build_app.sh    # 产出 .build/kongshan.app，自增补丁版本号
zsh scripts/make_dmg.sh     # 打成拖拽安装式 dist/kongshan-<版本>.dmg
zsh scripts/make_icons.sh   # 重新生成 Resources/AppIcon.icns
zsh scripts/verify_m4.sh    # 完整自动验收，成功时最后一行 M4 automated verification passed
```

App 图标是**可重生成的产物**：形状、配色、留白全在 `scripts/make_icons.swift` 里，改个数字重跑即可，不必在十个尺寸之间手工对齐。

`verify_m4.sh` 运行全量测试，构建并校验 arm64 App / 签名 / 内核 / 规则集，再在隔离的临时数据目录启动无节点 App，检查 CPU、RSS、TCP socket、子进程和恢复残留。可运行构建只放在已忽略的 `.build`，`dist` 只保留最新 DMG，正式运行副本只安装到 `/Applications`。脚本不会设置真实系统代理、注册登录项、请求 TUN 授权或发送真实通知。

## 已知限制

- 系统代理模式只影响进入本地 mixed 代理的请求解析，不等同于接管 macOS 全局 DNS；真实 DNS 泄漏需在 TUN 下人工验证。
- TUN 固定使用 gVisor 栈与 Fake-IP；`strict_route` 可能影响局域网、虚拟机、容器或其他 VPN。
- **所在网络若有透明代理，任何代理客户端的节点都会连不上**（表现为 Reality 校验失败、Hysteria2 无网络活动）。判据与排查步骤见 `docs/design/tun-real-machine-debug.md`。
- 同时运行多个 TUN 客户端（如本应用与 Stash/Surge）会互抢默认路由，务必只开其中一个。
- ad-hoc 构建下的登录项批准、通知权限与 TUN 授权行为受 macOS 系统策略影响，需在最终安装路径人工确认。
- 自动测试不能代替真实机场订阅、节点可用性、出口 IP、DNS leak、强杀恢复与长时间内存/能耗验收。

## 文档

- `docs/design/tun-authorization-approaches.md`：macOS 各家 TUN 授权方式对比（NetworkExtension / SMJobBless 助手 / osascript），本项目为何只能钉 cdhash，以及助手链路上踩过的四个坑及其回归测试。
- `docs/design/tun-real-machine-debug.md`：真机 TUN 排查记录，含「所在网络是否有透明代理」的判据。
- `docs/HANDOFF.md` / `docs/PROGRESS.md` / `docs/NEXT_STEPS.md` / `docs/progress/SESSION_LOG.md`：交接、进度与逐次会话记录。
- `docs/acceptance/M1.md`~`M4.md`：四阶段自动/人工验收边界。
