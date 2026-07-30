# 项目交接

## 2026-07-30 v0.1.54 成品化打磨 + 全流程走查（当前版本）

上一轮（0.1.52）改完只跑了自动化测试。本轮补做**自审 + 真机逐页走查**，
发现 11 处问题并全部修完（5 处是上一轮自己引入的），明细见 SESSION_LOG
「全流程真机走查 + 自审」条。要点：

- 文案：仪表盘版本号前缀加错（真机上 coreVersion 已含 `sing-box`）；
  「关于 → 内核」有既有的重复前缀 bug。
- 位置：「外观」段插进了「隧道」页，应在「通用」。
- 性能：日志行每次渲染重新解析、规则分组算两遍、连接列表 filter+sort 算四遍，均已提取。
- 噪音：规则组内重复显示目标策略；连接链路显示原始 `node-<uuid>` 而非节点名。
- 测试：我写的一条断言是偶发失败的（ISO8601 往返丢精度），已改容差。
- 环境：System Events 点不动 SwiftUI 侧栏 List 行，要用方向键；本机 AX 树对本应用恒为空。

真机验证通过：会话流量实时累加、3479 条规则归 9 组、16 行日志聚 4 组、
连接累计与速率一致、菜单栏图标清晰、外观段就位。

## 2026-07-30 v0.1.52 成品化打磨

用户提的 11 项打磨要求：**8 项完成，2 项部分完成**。完整机理与取舍见
`docs/progress/SESSION_LOG.md` 2026-07-30「成品化打磨」条。

| 项 | 状态 |
|---|---|
| App 图标（空山） | ✅ `scripts/make_icons.swift` 可重生成 |
| 菜单栏图标 3 样式 × 3 状态 | ✅ 设置 → 外观 可切换 |
| 本次会话流量统计 | ✅ 仪表盘「网络流量」格内 |
| 自建节点粘贴分享链接解析 | ✅ 6 种协议，可批量 |
| 规则页降噪（按目标策略分组） | ✅ 不再静默截断到 200 |
| 连接统计修正 | ✅ 首帧速率不再恒为 `—` |
| 内核日志改造 | ✅ 只看问题 / 按连接聚合 / 按主机搜 |
| 内存与性能审查 | ✅ 本来就干净，补了观察者注销 |
| 代理模块 UI 美化 | ⚠️ **未做**（`PolicyGroupsView` 未动） |
| 设置模块逐字段梳理 | ⚠️ **部分**（新增外观段，未逐条通读 14 个 Section） |

- 测试：`swift test` **381 通过 / 1 跳过 / 0 失败**，`swift build` 0 警告。
- 成品：`dist/kongshan-0.1.52.dmg`，SHA-256
  `dd78d8c58b5873101650b85562d06b2f62791d5ec4ea743a4f08562b78107876`；已装 `/Applications`。

### 三个别改回去的设计点

1. **会话累计流量只能取 `/connections` 的 `uploadTotal`/`downloadTotal`**。
   速率乘采样间隔会漏掉两次采样之间开完又关的连接；累加活跃连接的字节则漏掉短命连接。
   内核重启计数器归零，靠"检测回退即结转基线"跨过去（`SessionTrafficAccumulator`）。
2. **菜单栏图标必须是模板图标**，状态只能靠形状与不透明度表达。菜单栏把图像染成单色，
   任何配色方案都会失效——所以"开启"是线稿变实心，不是变绿。
3. **`@MainActor` 类的 `deinit` 在 Swift 6 里是 nonisolated 的**，碰不到隔离且非 Sendable
   的属性。要在析构时清理这类资源，得像 `NotificationObserverBag` 那样交给独立持有者。

## 2026-07-30 0.1.51 内网 DNS 分流（当前版本）

### 解决的问题

TUN 模式下用 Windows App 连内网设备"一直在加载"。

**根因不是劫持，是 Fake-IP 把内网域名吞了。** 内网 AD 域是个 `.com`，既不命中
`geosite-cn`，也就必然掉进 `dns-fakeip`；fakeip 不校验域名是否存在，任何名字都给
`240.0.0.0/4` 的假 IP，而假 IP 整段被路由进代理出口 → 流量被发去国外节点连办公室的机器。

**路由层完全没问题**（这点先排除了）：`route_exclude_address` 生效得很干净，
`route get 172.16.16.7` 走 en0，TUN 开着时 TCP 3389/389/135/445/53 实测全通。

### 修法

- `dns.servers` 加 `{tag: dns-lan, type: udp, server: <内网DNS>, port: 53}`，**无 detour**。
- `dns.rules` **首位**插内网后缀规则——必须排在 geosite-cn 与 fakeip 之前。
- 路由把内网后缀并进直连规则（内网域名可能解析到 DMZ 公网 IP，按 IP 判定会落空）。
- 系统代理模式另加 bypass（该模式 DNS 归 OS 管，内核只从 CONNECT 拿域名）。
- 探测**必须在接管系统 DNS 之前**：接管后 `scutil --dns` 只剩内核自己的地址。

### 关键难点：企业网不下发搜索域

真机 `scutil --dns` 只有 nameserver、**没有 search domain**。纯靠搜索域探测一个域名都
找不到。加了 **PTR 推断**，用 AD 的固有结构：`PTR(内网DNS)` → `AD1.<AD域>` → 候选域，
再要求**该域在同一台服务器上解析到私有 IP** 才接受。第二步是防误判的关键
（`114.114.114.114` → `public1.114dns.com`，但 `114dns.com` 解析出公网地址会被拒）。

### 真机验证（系统代理模式，零配置）

- `dns-lan = {172.16.16.7:53, udp}`；`dns.rules[0] = {domain_suffix: ["<AD域>"], server: "dns-lan"}`
- 系统代理绕过表三个服务都含 `*.<AD域>` 与 `<AD域>`
- `settings.json` 里手动项全为空 ⇒ 域名**完全来自 PTR 推断**
- 全量 344 通过 / 1 跳过 / 0 失败，0 编译警告

### 待用户验证

**TUN 模式需要点一次并输密码**（App 重建 cdhash 变，助手要重装一次）。
验完看 `dig @172.19.0.1 <内网主机>` 应返回真实内网 IP 而不是 240.x。

### 已知边界

内网 DNS 只在启动时探测。**TUN 运行中换网络**不会重新探测，旧内网域名会被送去
已不可达的内网 DNS；关掉再开即可。

### 顺带确认

助手连续存活 6 小时以上，0.1.46 的 SIGTRAP 修复稳住了。

## 2026-07-30 11:05 运行复查：两个待修问题（最新）

App 已连续跑 10h41m，0.1.47 的 DNS 修复未复发（~16 分钟节律彻底消失），
崩溃报告归零，排除断网窗口后真实失败率 0.67%。**但发现两个新问题，建议在
推送/发布前一并处理成 0.1.48**（详细证据链见 `docs/progress/SESSION_LOG.md`
「2026-07-30 11:05」条）。

| # | 问题 | 严重度 | 根因位置 |
|---|---|---|---|
| A | 固定 mixed 端口在一次完整重启后从 49609 变成 65408，而 49609 当时空闲 | 中（0.1.45 要治的「正在重新连接」会重现） | `RuntimeSecrets.availableHighPort(preferred:)` 首选端口只探测一次、无重试 |
| B | 主 App 后台空闲时烧 50% CPU 持续 178 秒（04:43–04:46） | 低（自行结束、无崩溃、10h 内 1 次） | `AppState` 每秒无条件写 `@Observable` 属性 → 全图失效 → 深 96 层 AppKit 布局 |

**A 的判定依据**：此前六次启动 mixed 全是 49609、clash-api 是散乱随机端口；
08:35:24 这次 mixed 65408 / clash-api 65409 **相邻**，是「首选端口绑定失败、
连续两次内核分配」的指纹。`preferredMixedPort` 不被 `clearRuntimeState()` 清空，
崩溃自愈路径复用 `currentConfig` 不可能换端口，`config.json` mtime=08:35:24
证明走的是完整 `start()`。端口池 `49_152...65_535` 就是 macOS 临时端口范围，
首选端口随时可能被瞬时占用 → **0.1.45 的保证目前只是概率性的**。
修法：首选端口 3–5 次 × 200–300ms 退避重试；端口真变了给一条 warning。

**B 的判定依据**：`cpu_resource.diag` 热栈无任何业务帧，96 层
`_layoutSubtreeWithOldSize` 触底在 `ObservationCenter.invalidate` /
`SystemSegmentedControl._overrideSizeThatFits`；那三分钟连接量反而更低
（1/3/1/6，邻近 11–15），排除「连接多导致渲染重」。当前后台空闲基线 CPU 4–5.6%，
与「每秒至少一次全图失效」吻合。修法：`AppState.swift:1354/1362/2479-2480`
加等值守卫。**178 秒那次的确切触发条件采样不足，未定论。**

## 2026-07-30 0.1.47 DNS 停摆修复（当前版本）

### 仓库状态：本地领先 `origin/main` 两个提交，**未推送、未发 Release**

```
dac3718 fix(dns): 节点域名解析改走无连接 UDP，根治代理每 ~16 分钟停摆 10 秒   ← 0.1.47
cc10d39 fix(helper): 助手每 30 秒 SIGTRAP 崩溃——Swift 6 顶层代码的 actor 隔离  ← 0.1.46
```

GitHub 上最新 Release 仍是 **v0.1.45**。工作区干净，分支 `main`。
`dist/kongshan-0.1.47.dmg`，`/Applications/kongshan.app` = 0.1.47。
测试 314 通过 / 1 跳过 / 0 失败，0 编译警告。

### 0.1.46：免密码助手每 30 秒 SIGTRAP 崩溃

`swift-tools-version: 6.0` 下 `main.swift` 顶层代码是 @MainActor 隔离的，
助手却把 `DispatchSource` 信号处理与 30 秒自愈定时器挂在自建队列上，
闭包一碰顶层状态就触发执行器断言 → SIGTRAP，**编译期零提示**。
后果：`checkClientLiveness()`（App 消失时停 root 内核）从未执行过一次；
SIGTERM 优雅退出路径从未跑到；一个 root 进程每 30 秒被 launchd 拉起。
一直没被发现是因为 TUN 表面完全正常——内核是独立进程，助手重启后靠
`adoptOrphanKernel()` 重新认领，用户无感。
修法是把并发整个去掉：C 信号处理器 + accept 循环内按 `CLOCK_MONOTONIC` 轮询。
回归测试是源码层守卫（禁 `DispatchSource`/`DispatchQueue`/`setEventHandler`），
已反向验证注入后会失败。**助手需重装一次修复才生效**（helper 二进制不随 App 更新）。

### 0.1.47：`default_domain_resolver` 走 DoH，长连接被 NAT 回收后整个代理停摆

失败每 ~16 分钟一簇、全部 10.0s `context deadline exceeded`，末尾露出
`read tcp ...->223.5.5.5:443: operation timed out`。DoH 是 HTTP/2 over TLS 长连接，
路由器 NAT 悄悄回收后 sing-box 察觉不到，而这条通道正好负责解析**出站节点自己的域名**
——它一卡，整个代理跟着停摆。修法：`dns-bootstrap`（UDP 53）改为无条件生成，
`route.default_domain_resolver` 指向它；地址跟随用户配置的国内 DoH，不硬钉阿里。

### 2026-07-30 00:07 实机复核（本次会话实测，非推断）

| 项 | 结果 |
|---|---|
| 0.1.47 DNS 修复 | ✅ 修复前 19:49→20:05→20:21→20:33 每 16 分钟一簇；20:48 起 3h19m 内**只剩 1 次**（22:11），周期性消失 |
| 0.1.46 助手修复 | ✅ 助手 PID 39659 连续存活 **5h14m**（修复前每 30 秒重启）；崩溃报告停在 42 份，最后一份 18:34（修复前） |
| 0.1.45 端口固定 | ✅ `settings.json` mixedPort = 49609，跨多次重启未变 |
| 资源 | App RSS 100MB / 内核 43MB，运行 3h23m 无增长 |

残留（已知、可接受）：国内网站解析仍可能撞上陈旧 DoH 连接失败一次，
影响面已从"整个代理停摆"缩到"个别请求失败、重试即好"。
另有节点侧偶发 `i/o timeout` / `connection reset by peer`（00:01、00:03），
属节点或链路问题，与 DNS 修复无关。

## 2026-07-28 v0.1.45 固定本地代理端口（已真机验收）

版本号 0.1.45 = 0.1.44 的同一份代码（`verify_m4.sh` 会重新构建并递增补丁号）。

### 真机验收结果（全部实测，非推断）

| 项 | 结果 |
|---|---|
| 端口跨**完全退出重启** | ✅ 保持 49609 |
| 端口跨**三轮关→开** | ✅ 保持 49609（clash_api 端口每次随机，符合设计） |
| 端口跨**重装 App** | ✅ 保持 49609 |
| 崩溃自愈（强杀内核） | ✅ 自动重启且复用同一端口与同一份配置 |
| 崩溃限流（连杀 4 次） | ✅ 停止接管并**自动还原系统代理**，不留指向死端口的设置 |
| 退出清理 | ✅ 1.16s 退出，无残留内核、代理已还原、无恢复文件 |
| 系统代理 bypass | ✅ `127.0.0.1` / `localhost` / `::1` 在列表最前 |
| 诊断快照脱敏 | ✅ clash_api 已移除，password/uuid/reality 全为 `<redacted>` |
| 资源占用 | ✅ App CPU 0.3~0.5% / RSS 140MB；内核 CPU 0% / RSS 43~47MB |
| `verify_m4.sh` | ✅ 通过，空闲 CPU 0%、最大 RSS 123MB |
| 单元测试 | ✅ 311 通过 / 1 跳过 / 0 失败，0 编译警告 |

**驱动方式**：显示器休眠时 SwiftUI 不建可访问性树（`entire contents` 返回 0 个按钮，
截图全黑），AX 定位会失效；改用坐标点击 `{1167, 294}`（仪表盘页「系统代理」胶囊，
窗口在 `(375,112) 960x724` 时）。这不是应用问题。
另：`osascript ... to quit` 可能挂满 2 分钟——那是 AppleScript 等事件回复的默认超时，
应用本身 1.16s 就退干净了；测退出耗时要独立轮询进程，别信 osascript 的返回时刻。

### 本轮环境限制：所在网络在做透明代理，节点连通性无法验证

判据（`docs/design/tun-real-machine-debug.md` 的三条全中）：

- 直连国外出口 = `69.63.217.24`（就是订阅节点的 IP），直连国内出口 = `125.123.17.206`（嘉兴电信）——两个出口。
- 到洛杉矶 `69.63.217.24` 以及 `1.1.1.1`、`8.8.8.8` 的 TCP 握手**全部只要 4.5ms**，真跨太平洋不可能低于 130ms。
- 内核日志清一色 `reality verification failed`（握手被中途改写）。

即**路由器已把国外流量透传到同一个节点**，所以用户"关掉代理也能上外网"。
该环境下任何代理客户端的 Reality 节点都连不上，与本应用无关。
**「经代理取出口 IP」仍需换一个没有透明代理的网络才能验**（手机热点最省事）。

## 2026-07-28 0.1.44 固定本地代理端口

- **解决的问题**：用户报告 codex 在系统代理模式下反复「正在重新连接」、约 5 次后才连上。
- **根因（已坐实，非猜测）**：mixed inbound 端口每次内核启动都重新随机
  （`AppState.start()` → `runtimeFactory()` → `RuntimeSecrets.availableHighPort()`）。
  用户的 codex 是 ChatGPT 桌面版内嵌服务（Chromium 内核，日志 `router: found process path`
  可见），它**缓存**解析到的系统代理地址。内核一重启换端口 → 客户端继续打死端口 →
  「正在重新连接」→ 它自己重新读取系统代理配置并退避重试 → 若干次后才恢复。
  铁证：ChatGPT.app 启动于 10:05:38、内核启动于 10:47:09（晚 42 分钟），
  而 ChatGPT.app 事后连的是内核本次随机到的新端口——它被迫换过一次。
  只在系统代理模式出现，因为 TUN 模式根本不涉及端口。
- **已排除**（真机实测全部健康）：并发 10 条连接全成功；节点出口 69.63.217.24/LAX，
  `cdn-cgi/trace` 连打 12 次全 200 无限流；`ws.chatgpt.com` 的 WebSocket 隧道正常；
  无 DNS 失败（每条连接那 ~300ms 是 LA 节点 RTT，不是超时）。
- **修法**：端口首次分配后写入 `settings.json` 跨启动复用，被占用才另选。
  探测绑定必须置 `SO_REUSEADDR`（对齐 Go `net.Listen` 的默认行为）——否则内核刚停时
  旧连接还在 TIME_WAIT，裸 bind 会 EADDRINUSE，于是仍旧每次换端口，等于没修。
  clash_api 端口与 secret 保持随机（secret 是真正的安全边界；mixed 端口不是，
  它只监听 127.0.0.1、无鉴权，且必然通过系统代理设置公开给本机所有 App）。
- 测试：311 通过 / 1 跳过 / 0 失败，0 警告（新增 6 条回归）。
- 当前状态：0.1.44 / build 144 已装 `/Applications`；`dist/kongshan-0.1.44.dmg`。
- **注意**：升级后第一次启动仍会换一次端口（旧版没落盘过），之后才稳定。

## 2026-07-28 已发布 v0.1.43

- **代码已提交、已 squash 合并 `main`、已推送、已发 GitHub Release**。
  仓库只剩 `main` 一条分支（`fix/config-switch-ui-batch` 已删除）。
- Release：<https://github.com/kongshan-0924/kongshan-proxy/releases/tag/v0.1.43>
  DMG SHA-256 `3606670d0dc7749bf3600b70da04ee87091055c3ce488e49b03eb7aeeb79afe7`
- 本机 `/Applications/kongshan.app` 已是 0.1.43；`dist/` 只保留当前版本 DMG。
- 测试：`swift test` **305 通过 / 1 跳过 / 0 失败**，`swift build` 0 警告。

### 这一轮解决了什么

免密码 TUN 助手**此前从未真正生效**，四个缺陷串在一条链上（修好一个才暴露下一个），
全部修复且每个都有能独立验证该环节的回归测试。完整机理与"别改回去"的理由见
`docs/design/tun-authorization-approaches.md`：

1. 身份校验比对错对象（`SecCodeCopyPath` 对 bundle 返回 `.app` 目录）→ 永远"需重装"
2. launchd 装载竞态（bootout 异步 + helper 慢退）→ `Bootstrap failed: 5: EIO`
3. 线缆层用普通 `read()` 读长度前缀 → SCM_RIGHTS 被内核丢弃 → `missing config fd`
4. `posix_spawn` 继承管道写端 → 内核永远等不到 EOF，卡在读配置

外加睡眠唤醒假死、信号升级、连接重置等生命周期加固（见 SESSION_LOG 2026-07-27/28 各条）。

### 真机验证到什么程度

- **TUN 数据面已完全打通**：352KB 内核日志逐条确认 tun-in 收包、DNS 劫持、规则分流、
  国内直连、进程匹配、Fake-IP 全部正常。
- **系统代理 + TUN 双开可用**，出口 IP 为节点所在地、DNS 无泄漏（用户截图佐证）。
- 系统代理/DNS 的接管与还原在真机上逐字节核对通过；Clash API 三条实时流、退出监控、
  规则集下载编译、日志存储均真跑通过。

### 仍未验证 / 已知边界

- **睡眠唤醒后的自动重建隧道**（0.1.40 新增）尚未经用户真机复现验证。
- 用户家庭网络在做**透明代理 + SNI 分流**，该环境下任何代理客户端的节点都连不上
  （判据见 `docs/design/tun-real-machine-debug.md`）。验证节点连通性须换网络。
- ad-hoc 签名固有代价：**App 每次重新构建 cdhash 都会变，助手需重装一次**
  （首次开 TUN 会自动弹一次密码完成），这不是 bug，不要为省这一次弹窗放宽 cdhash 校验。
- 同时运行多个 TUN 客户端（本应用与 Stash/Surge）会互抢默认路由。

## 2026-07-28 0.1.43 复审第二轮修复（当前版本）

- 专项复审本轮新代码，修 5 处：① 助手自愈停内核失败会弄丢 PID → 可能同时跑两个 root 内核
  （最严重，已与 stopKernel 分支对齐）；② 网络指纹改为只认 `en*`，避免 awdl/llw/bridge 抖动
  被误判成换网而掐断长连接；③ 指纹更新被短路跳过 + getifaddrs 失败时的误判；
  ④ `stop()` 早退丢失还原失败信息；⑤ `start()` 失败时还原错误被静默吞掉。
- 连带：停内核最坏 6 秒（三级信号），安装脚本等待预算 5s → 10s。
- 测试结果：305 通过 / 1 跳过 / 0 失败，0 警告。
- 当前状态：0.1.43 / build 143 已装 `/Applications`；代码未提交。

## 2026-07-28 0.1.42 连接重置收紧（当前版本）

- 0.1.41 加的"换网后重置全部连接"挂在 `NWPathMonitor` 上，会被 Wi-Fi 信号抖动、IPv6 续租
  之类的无关事件触发，**反而会掐断正在进行的长连接**。改为只在物理网络指纹
  （非回环/非隧道接口的 IPv4 集合）真的变化时才重置；睡眠唤醒仍无条件重置。
- 断流排查结论：系统代理日志里 vless 只有 2 条 `context canceled`（关闭时的正常收尾），
  无中途失败痕迹；但有 7 次内核启动（含 16 秒内重启一次）——内核重启会瞬间掐断所有连接，
  是最可能的断流机制。订阅自动更新已关、规则集更新不重启内核，故重启应来自用户操作。
- 测试结果：305 通过 / 2 跳过 / 0 失败，0 警告。
- 当前状态：0.1.42 / build 142 已装 `/Applications`；代码未提交。

## 2026-07-28 0.1.41 换网/唤醒后主动重置连接（当前版本）

- 已完成：`reassertTakeoversAfterNetworkChange`（网络变化 + 睡眠唤醒共用）在补挂代理/DNS 后
  主动 `DELETE /connections`。换网后旧连接已作废但本地客户端不知情，会卡在死 socket 上
  反复重试（TCP 重传耗尽要十几分钟），主动关掉可让客户端立刻收到 RST 并重连。
- 测试结果：305 通过 / 1 跳过 / 0 失败，0 警告。
- 当前状态：0.1.41 / build 141 已装 `/Applications`；`dist/kongshan-0.1.41.dmg`；代码未提交。

## 2026-07-27 0.1.40 睡眠唤醒内核假死修复（当前版本）

- 已完成三项修复（详见 SESSION_LOG 2026-07-27 23:55）：
  1. **助手停内核只发 SIGINT 不升级** → 睡眠唤醒后假死的内核杀不掉，赖着导致
     下次开 TUN 撞 `kernel already running`，即用户说的"休眠后再也起不来"。
     改为 SIGINT→SIGTERM→SIGKILL 逐级升级并确认退出；连带修掉"子进程变僵尸时
     `kill(pid,0)` 仍返回 0"导致的误判（先 `waitpid(WNOHANG)` 收尸）。
  2. **唤醒自检只查 Clash API** → 内核假死时 API 照常应答，TUN 网卡没了却察觉不到。
     改为用 `getifaddrs` 判定 TUN 地址是否还在，没了就走崩溃自愈重建隧道。
  3. **日志轮转用原子写换 inode** → 运行中内核的 fd 指向已 unlink 的旧文件，
     日志静默消失。改为原地 `ftruncate` + `pwrite`。
- 新增 6 条回归测试（信号升级纯逻辑 5 条 + 真起 `trap '' INT` 子进程的实证 1 条）。
- 测试结果：305 通过 / 1 跳过 / 0 失败，0 警告。
- 当前状态：0.1.40 / build 140 已装 `/Applications`；`dist/kongshan-0.1.40.dmg`；代码未提交。

## 2026-07-27 0.1.39 `kernel already running` 自愈（当前版本）

- 已完成：`startTUN` 的 helper 分支无条件先 `recoverIfNeeded()` 再 start——
  助手握着遗留内核时不再把用户顶成死胡同（此前只能去终端 sudo 杀进程）。
- 真机验证（0.1.38 起的内核）：352KB 日志证明 **TUN 数据面完全打通**——
  tun-in 收包、DNS 劫持、规则分流、国内直连、进程匹配、Fake-IP 全部正常。
- 节点连不上系**用户家庭路由器做透明代理 + SNI 分流**所致，与 App 无关。铁证：
  国内/国外 IP 服务给出两个不同出口；任意 SNI 连节点服务器都返回对应证书；
  到美国 IP 的 TCP 握手仅 3~4ms。判据已写入 `docs/design/tun-real-machine-debug.md`。
- 测试结果：299 通过 / 1 跳过 / 0 失败，0 警告。
- 当前状态：0.1.39 / build 139 已装 `/Applications`；`dist/kongshan-0.1.39.dmg`；代码未提交。
- 下一步：在没有透明代理的网络（手机热点最省事）验一次代理出口 IP，通过即可提交合并发布。

## 2026-07-27 0.1.38 spawn 继承管道写端修复（当前版本）

- 已完成：修掉助手链路第四个坑——`posix_spawn` 继承了未置 CLOEXEC 的管道写端，
  sing-box 自己握着自己 stdin 的写端 → 永远等不到 EOF → 卡在读配置：
  进程活着但不监听、日志 0 字节，App 报"控制接口未就绪"。
  两端置 `FD_CLOEXEC`，日志 fd 用 `O_CLOEXEC`；helper 监听/连接 socket 同样置 CLOEXEC。
- 新增 2 条真 spawn 回归测试（`/bin/cat` 替身，正反证明）。
- 测试结果：299 通过 / 2 跳过 / 0 失败，0 警告。
- 当前状态：0.1.38 / build 138 已装 `/Applications`；`dist/kongshan-0.1.38.dmg`；代码未提交。
- 助手四连坑全部修完（身份校验对象错 / launchd 装载竞态 / SCM_RIGHTS 被丢弃 / spawn 继承写端），
  每个都有独立回归测试。
- 遗留：用户机上卡住的 root sing-box(PID 14194) 会在下次开 TUN 或 App 重启时被自动清掉；
  手动清理：`sudo pkill -f '/Library/Application Support/kongshan/helper/sing-box'`。

## 2026-07-27 0.1.37 线缆层修复：missing config fd（当前版本）

- 已完成：修掉助手链路的第三个坑——App 一次 sendmsg 发「长度前缀+body」并挂 SCM_RIGHTS FD，
  helper 却先用普通 `read()` 读长度前缀，内核因此丢弃辅助数据并关闭 FD → `missing config fd`。
  线缆层收拢为 `HelperProtocol.HelperWire` 两端共用，接收端改用 `recvmsg` 读长度前缀。
  顺带修掉 sendResponse 单次 write 截断、sendmsg 部分发送未补齐。
- 新增 6 条真 socketpair 回环测试，含"收到的 FD 与发出的是同一个 pipe"与
  "普通 read 会丢 FD"的反向证明。
- 测试结果：297 通过 / 1 跳过 / 0 失败，0 警告。
- 当前状态：0.1.37 / build 137 已装 `/Applications`；`dist/kongshan-0.1.37.dmg`；代码未提交。
- 助手三连坑至此全部修完（身份校验对象错、launchd 装载竞态、SCM_RIGHTS 被丢弃），均有回归测试。
- 下一步：用户开 TUN 验证零弹窗启动。

## 2026-07-27 0.1.36 助手装载竞态修复（当前版本）

- 已完成：坐实并修复 `Bootstrap failed: 5: Input/output error`——`launchctl bootout` 是异步的，
  helper 收到 SIGTERM 后要一两秒才退出（accept 循环 `poll(...,1000)`），脚本紧接着 `bootstrap`
  就撞上仍在卸载的 label。这正是"输了密码仍显示需重装、开 TUN 要输两次密码"的直接原因。
  已用用户域 LaunchAgent 实证复现（旧写法 exit=5，新写法 exit=0）。
  安装脚本改为 bootout → 轮询等 label 消失 → enable → bootstrap（失败重来一轮）→ print 确认；
  并把脚本抽成纯函数 `makeInstallScript`，加了真 `sh -n` 语法校验等 3 条测试。
- 测试结果：291 通过 / 2 跳过 / 0 失败，0 警告。
- 当前状态：0.1.36 / build 136 已装 `/Applications`；`dist/kongshan-0.1.36.dmg`
  SHA-256 `6ed44ebd7212e0c0662c4e75a7b58c5719c3a87a1fc42527cef454630ea47549`；代码未提交。
- 风险/注意事项：用户机上 **Stash 正在运行且开着 TUN**（utun4=198.18.0.1）并占着系统代理 7890；
  验收 kongshan 的 TUN 前必须先关 Stash 的 TUN，否则两个 TUN 抢默认路由。
  新网络下节点已完全可用（出口 69.63.217.24 / DMIT LA）。
- 下一步：用户关掉 Stash 的 TUN → 点一次 kongshan 的 TUN → 应只弹一次密码 → 之后启停零弹窗。

## 2026-07-27 0.1.35 免密码助手修复 + 模块巡检（当前版本）

- 已完成：修掉**让免密码助手长期完全失效**的根因——`SecCodeCopyPath` 对 bundle 返回 `.app` 目录，
  而 trust.json 钉的是主可执行路径，恒不相等 → 助手静默拒绝所有连接 → 界面永远"需重装"。
  trust schema 升 v3、新增 `clientBundlePath` 作为身份校验字段；安装后自检改轮询 5 秒；
  设置页说明"App 更新过（签名变了）"才是常见原因。
- 新增 `docs/design/tun-authorization-approaches.md`：NetworkExtension / SMJobBless 助手 /
  每次 osascript / setuid 四种做法的对比，以及本项目为何只能钉 cdhash、
  "App 更新 = 重装一次助手"为何是固有代价（禁止为省弹窗放宽 cdhash 校验）。
- 测试结果：288 单测 0 失败 0 警告；真机巡检 Clash API 三条流、退出监控、规则集下载编译、
  日志存储全通过；真机只读回归确认修复后 `isTrusted == true`。
- 当前状态：0.1.35 / build 135 已装 `/Applications`；`dist/kongshan-0.1.35.dmg`；代码未提交。
- 风险/注意事项：**待用户手动点一次「重新安装」助手**（需密码，无法自动化）；
  机器上现存的是旧 v2 助手，显示"需重装"属预期。用户当前网络仍拦着订阅里的两个节点。
- 下一步：用户装助手 → 验证零弹窗 TUN → 提交 → squash 合 `main` → 发 v0.1.35。

## 2026-07-27 0.1.34 全面审计 + 真机全流程测试

- 已完成：对全量源码（13.9k 行）做审计，发现并修复 10 项；细节见 `docs/progress/SESSION_LOG.md` 2026-07-27 00:30 条。最关键的三项：
  - `ProcessRunner` 的 continuation 存在数据竞争（每次 networksetup / sing-box check / version 都走这条路）。
  - Reality 的 `public_key` 未脱敏，真机 `config.json` 明文可见（0.1.32 加 VLESS 时漏的）；已改为按字段名的递归脱敏。
  - 未忽略 SIGPIPE：内核在读完配置前退出会**直接杀掉整个 App**。
- 测试结果：285 单测 0 失败 0 警告；真机跑通「真订阅 → 转换 → 生成 → check → 起内核 → Clash API → 路由 → 真流量」，direct 模式取到真实出口 IP；系统代理与系统 DNS 的接管/还原逐字节核对通过。
- 当前状态：0.1.34 / build 134 已装 `/Applications` 并运行正常；`dist/kongshan-0.1.34.dmg`，SHA-256 `2d58a2e6f2d66783f8d673328c1203144ec0fed733c5597017a84a3554c6bffe`；代码未提交，分支 `fix/config-switch-ui-batch`。
- 风险/注意事项：**用户当前网络拦掉了订阅里的两个节点**（TCP 3ms 假握手、TLS 零响应），因此"经代理取出口 IP"在该网络无法通过——与 App 无关。TUN 需 root 密码，仍待用户实测。
- 下一步：换一个能连通的网络验收代理出口与 TUN；通过后提交 → squash 合 `main` → 发 v0.1.34。

## 2026-07-25 0.1.33 复审问题已全部修复 + 已装本机

- 已完成：复审的 P1~P6 六项全修（详见 `docs/progress/SESSION_LOG.md` 2026-07-25 21:40 条）。
  - P1 残留 root 内核三层封堵：helper 启动 `adoptOrphanKernel()` 认领/清理遗留内核；卸载前先停内核 + 卸载脚本 `pkill` 兜底；TUN 运行时禁用安装/卸载/重装按钮。
  - P2 还原失败改 errorMessage + 手工恢复指引（不再说「可忽略」，仍不阻塞退出）。
  - P3/P4 用量与菜单栏速率占位符修正（菜单栏恢复单字母紧凑格式）。
  - P5/P6 白名单边界写进注释 + 四种模式组合回归；高位端口范围收进 `HelperConstants` 单一来源。
- 修改文件：`HelperProtocol.swift`、`KongshanHelper/main.swift`、`PrivilegedHelperInstaller.swift`、`RuntimeSecrets.swift`、`AppState.swift`、`MainWindowView.swift`、`DashboardView.swift`、`MenuBarView.swift` + 2 个测试文件 + `VERSION`。
- 测试结果：`swift build` 0 警告；`swift test` 285 通过 / 1 跳过 / 0 失败；arm64、deep/strict 签名、hardened runtime、sing-box 1.13.14 均通过。
- 当前状态：0.1.33/build 133 已安装到 `/Applications/kongshan.app` 并启动自检通过（无崩溃、空闲 CPU 0.4%、RSS≈116MB）；成品 `dist/kongshan-0.1.33.dmg`；**代码改动未提交**，分支仍是 `fix/config-switch-ui-batch`。
- 风险/注意事项：App 重建后 cdhash 变，旧 helper 会拒新 App → 首次开 TUN 弹一次密码自动重装助手（预期）。`adoptOrphanKernel` 需真机装 helper 后才能验证。
- 下一步：用户验收 0.1.33 → 提交 → squash 合 `main` → 发布 v0.1.33。
- 接手方式：改 helper 生命周期时保持「只对可执行路径匹配的 PID 发信号」不放宽。

## 2026-07-25 0.1.32 维护者复审结论（合并前）

- 已完成：`origin/main...fix/config-switch-ui-batch` 9 提交逐文件复审；独立复跑 `swift build`（0 警告）、`swift test`（282 通过 / 1 跳过 / 0 失败）；diff 无真实凭据、无二进制入库。
- 结论：helper 白名单投递链、trust v2 fail-closed 迁移、`activeTUNBackend` 后端钉死、`TunStack` 删除的 Codable 兼容性、VLESS `network: tcp` 修复均正确，可合。
- 待修（详见 `docs/progress/SESSION_LOG.md` 2026-07-25 21:10 条 6 项）：
  - P1 卸载/重装助手不先停内核 + 按钮未按 TUN 状态禁用 → 可能留下无法从 App 清理的 root sing-box（既有缺口，本分支让它更易触发）。
  - P2 `stop()` 里 DNS 还原失败的「可忽略」文案与实际断网后果不符。
  - P3 `MainWindowView.swift:341`、`DashboardView.swift:343` 仍用会返回空串的 `Theme.bytes`。
  - P4 菜单栏 `MenuRateFormatter.compact` 改用 ByteCountFormatter 后更宽更跳。
  - P5 白名单未覆盖 `dns`/`route`/outbound 非 type 字段；回归测试只覆盖 `[.tun]`。
  - P6 高位端口范围两处硬编码。
- 建议：P3/P4 + P1 的按钮禁用是分钟级修复，修完再 squash 合 `main`；P1 的 `kernel.pid` 持久化与 helper 启动 reconcile 可排 0.1.33。

## 2026-07-25 0.1.32 功能整合成品

- 已完成：在 0.1.31 审计修复基础上，删除无效 TUN stack/interfaceName，修复 IPv6-only 空地址；新增订阅 VLESS（含 TLS/WS/gRPC/Reality）、兼容性统计、脱敏诊断导出、已安装 App 分流选择和安全的应用更新入口。
- 修改文件：`ProxyMode.swift`、`Models.swift`、`ClashSubscriptionConverter.swift`、`ConfigGenerator.swift`、`AppState.swift`、`MainWindowView.swift`、`RoutingView.swift`、`LogsView.swift`、`Theme.swift` 及对应测试。
- 测试结果：全量 `swift test` 282 通过、1 跳过、0 失败；10 张离屏界面快照生成成功；VLESS 配置通过内置 sing-box 1.13.14 check；M4 自动验证、arm64、deep/strict 签名、hardened runtime、DMG 校验全部通过。
- 当前状态：分支 `fix/config-switch-ui-batch`，未推、未合 main；成品 `dist/kongshan-0.1.32.dmg`，SHA-256 `ec255233febb71d6152719d592bcef970084dca6018069a587b72cce3180f00c`；未安装、未修改真机网络。
- 风险/注意事项：private GitHub 仓库不能安全地由 App 匿名查询版本，因此更新入口只打开 `releases/latest`，绝不内置 Token；诊断包不含凭据，但日志可能含域名/服务器地址。
- 下一步：交用户安装并完成 `NEXT_STEPS.md` 的真机验收；明确通过后再复审并合并 main。
- 接手方式：先核对分支、版本和上述 DMG 哈希；不要在用户验收前合 main。

## 稳定边界

- TUN 固定 gVisor；系统 DNS 指向 TUN 接口自身 IPv4；Fake-IP 使用 `240.0.0.0/4`。
- TUN 启停只经 `startTUN/stopTUN/recoverTUNIfNeeded`；一次生命周期固定 helper/osascript 后端。
- helper 只执行内置、签名钉死的 sing-box；配置经 FD 传递并通过白名单；不得弱化 trust v2。
- 代理/DNS 恢复失败必须保留失败服务快照供下次重试。
- 测试和文档严禁写入真实订阅密码；`subscriptions/*.yaml` 不得提交或导出到诊断包。
