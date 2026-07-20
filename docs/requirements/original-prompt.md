# Agent 执行提示词：开发原生 macOS 代理客户端（基于 sing-box 内核）

> 使用方法：将本文档全文作为任务提示词交给编码 Agent（如 Claude Code）执行。

---

## 一、角色与目标

你是一名资深 macOS 原生应用开发工程师，精通 Swift / SwiftUI、macOS 网络栈与进程管理。

你的任务：为一台 Apple Silicon（M4）MacBook 开发一个**个人自用的原生代理客户端**。它是 sing-box 内核的图形化外壳（GUI wrapper），不是代理内核本身。最终交付一个可以双击运行的 `.app`。

设计基调：**界面简洁但不简陋**——参考 Surge Mac / Stash 的克制风格，菜单栏常驻 + 一个主窗口，信息密度适中，无花哨动效；**长期常驻不卡顿、资源占用低**是最高优先级的非功能需求。

---

## 二、硬性技术选型（不可更改，不要自作主张替换）

1. **内核**：sing-box 官方最新 stable 版本（1.13.x），使用官方 GitHub Releases 的 `darwin-arm64` 二进制，捆绑进 App 的 `Contents/Resources/` 中。
   - **严禁**自研代理内核或协议实现。
   - **严禁**使用 mihomo / clash 系内核。
2. **UI**：Swift 5.10+ / SwiftUI，使用 `MenuBarExtra` 实现菜单栏常驻 + 独立主窗口。
   - **严禁**使用 Electron、Flutter、Tauri 或任何 WebView 套壳方案。
3. **内核集成方式**：App 以子进程方式启动/停止/守护 sing-box 二进制（`Process` API）。
   - TUN 模式需要 root：MVP 阶段通过 `osascript` 的 `do shell script ... with administrator privileges` 请求一次管理员授权来启动内核；在代码中把"提权启动"封装为独立模块，注释注明未来可迁移到 `SMAppService` 特权 helper 或 Network Extension。
   - **不要**假设有付费 Apple 开发者账号，**不要**依赖 Network Extension entitlement。本地开发用 ad-hoc 签名即可。
4. **App 与内核通信**：生成的 sing-box 配置中启用 `experimental.clash_api`（监听 `127.0.0.1` 随机高位端口，`secret` 每次启动随机生成，仅保存在内存）。节点切换、延迟测速、实时流量、连接列表全部通过 clash_api 完成，不要重复造轮子。
5. **系统要求**：macOS 14+，仅 arm64。
6. **配置与数据存储**：`~/Library/Application Support/<AppName>/`，包括用户设置（JSON/plist）、订阅缓存、规则集缓存、生成的 `config.json`、内核日志。

---

## 三、功能需求

### 3.1 订阅与节点管理
- 支持添加 **Clash YAML 格式订阅链接**（用户机场为奶昔/Nexitally，下发 Clash 订阅，节点以 Shadowsocks 为主）。App 内实现 Clash YAML → sing-box outbounds 的转换器，至少支持 `ss`（含 ss2022 各加密方式）、`trojan`、`vmess`、`hysteria2`、‘anytls’ 五种节点类型的字段映射；遇到不支持的节点类型跳过并在日志中记录，不得导致整个订阅导入失败。
- 支持**手动添加自建 Hysteria2 节点**，表单字段：名称、服务器地址、端口、密码、SNI、跳过证书验证（bool）、混淆 obfs（salamander，可选）、上行/下行带宽（可选，Mbps）。
- 订阅支持手动刷新与定时自动更新（默认 24h，可设置），更新失败弹出非阻塞通知并沿用旧缓存。
- 节点列表按订阅分组展示，显示每个节点的协议类型标签和最近一次延迟。

### 3.2 代理模式（两种接管方式，互斥切换）
- **系统代理模式**：sing-box 开 `mixed` inbound（127.0.0.1 随机端口），App 通过 `networksetup` 设置/清除所有活动网络服务的 HTTP/HTTPS/SOCKS 代理；退出或关闭时必须可靠还原系统代理（包括 App 被强杀后下次启动的自愈检查）。
- **TUN 模式**：配置 `tun` inbound，`auto_route: true`；`strict_route` 提供开关（默认关，UI 注明开启后更严格但可能影响局域网访问）。
- 菜单栏一键开关代理；开关状态、当前模式在菜单栏图标上有可视区分。

### 3.3 分流（核心功能，必须准确 + 可自定义）
- 生成配置时按以下**固定优先级**排布 route 规则（从高到低）：
  1. 用户自定义规则（见下）
  2. 用户"绕过列表"（域名/IP → direct）
  3. 私有网段（`geoip-private` / RFC1918）→ direct
  4. 广告拦截（可选开关，默认关；开启时 `geosite-category-ads-all` → reject）
  5. `geosite-cn`、`geoip-cn` → direct
  6. 兜底 → 代理（默认走"自动选择"组）
- 规则集使用 sing-box 官方远程 rule-set（`.srs` 二进制格式，SagerNet/sing-geosite 与 sing-geoip 源），本地缓存、启动时校验、失败时用缓存兜底。
- **自定义规则编辑器**（UI）：支持类型 = 域名后缀 / 域名关键词 / 完整域名 / IP CIDR / 进程名；动作 = 直连 / 代理（可选指定策略组）/ 拒绝；支持拖拽排序、启用/禁用单条规则；改动后热重载配置（调用 sing-box 重载或快速重启内核，中断时间 < 2s）。
- 策略组：至少生成两个——`手动选择`（selector，含全部节点）与 `自动选择`（urltest，全部节点，interval 5min）。自建 Hysteria2 节点单独再生成一个 `自建` selector 组。

### 3.4 绕过设置（bypass）
- 设置页提供全局"绕过列表"：两个可编辑列表，分别是**域名**（支持后缀匹配写法）与 **IP/CIDR**。
- 绕过列表必须**同时**生效于三处：① route 规则最高优先级 direct（仅次于自定义规则）；② 系统代理模式下写入 `networksetup -setproxybypassdomains`；③ TUN 模式下加入路由排除（`route_exclude_address` 等对应字段）。
- 预置合理默认值：`localhost`、`*.local`、私有网段、常见国内直连域（如 `*.cn` 可作为示例但允许用户删除）。

### 3.5 延迟测速
- 单节点测速与整组批量测速（通过 clash_api 的 delay 接口，测试 URL 默认 `http://www.gstatic.com/generate_204`，可在设置中修改，超时 5s）。
- 节点列表内联显示延迟数值并按颜色分级（绿/黄/红/超时灰）；提供"测速全部"按钮，批量测速需并发限制（同时 ≤ 8 个）避免瞬时资源尖峰。

### 3.6 Dashboard（主窗口首页）
- 显示：代理开关与当前模式、当前选中节点、实时上下行速率（走 clash_api 的 `/traffic` WebSocket）、活动连接数、内核内存占用、内核版本、运行时长。
- 一个轻量的最近 60 秒速率迷你曲线（原生 Swift Charts，不引第三方图表库）。
- 日志页：实时滚动查看内核日志（等级可切换），支持一键导出。

### 3.7 DNS（防泄漏默认方案，用户可改）
- 国内域名（geosite-cn 匹配）→ 国内 DoH（如 `https://223.5.5.5/dns-query`）直连解析。
- 其余域名 → 远程 DoH（如 `https://8.8.8.8/dns-query`）经代理解析。
- 提供"DNS 高级设置"入口允许修改上述两个服务器；默认不启用 fake-ip（注释说明原因：兼容性优先）。

### 3.8 其他
- 开机自启（`SMAppService.mainApp`）、深浅色跟随系统、内核崩溃自动重启（10s 内最多 3 次，超过则停止并通知）、App 退出时优雅停止内核并还原系统代理。

---

## 四、性能与质量红线

- 代理空闲时 App 进程 CPU 占用接近 0%；**禁止任何轮询式刷新**，速率/连接数一律用 clash_api WebSocket 推送，窗口未打开时断开这些订阅。
- App 常驻内存（不含内核进程）< 150 MB；Activity Monitor 中 Energy Impact 长期为 Low。
- 连续运行 24h 无内存增长趋势（用 Instruments 的 Leaks/Allocations 自查一轮）。
- **配置生成器必须是纯函数模块**：输入（用户设置 + 节点列表 + 规则）→ 输出完整 `config.json` 字符串，为其编写单元测试（覆盖：Clash 订阅转换的每种协议、规则优先级排布、绕过列表三处注入）。
- 每次生成配置后、启动内核前，先执行 `sing-box check -c config.json` 校验，失败则展示可读的错误信息，绝不带病启动。
- Swift 侧开启严格并发检查；所有对 `networksetup`、文件、子进程的调用有超时与错误处理，不允许静默失败。

---

## 五、里程碑（按顺序交付，每个里程碑结束时给出可运行版本与自测说明）

- **M1 可用代理**：内核进程管理（启动/停止/守护）+ clash_api 对接 + Clash 订阅导入与转换 + 手动添加 Hysteria2 + 系统代理模式 + 节点选择与测速 + 菜单栏开关。
- **M2 分流**：默认分流模板 + 自定义规则编辑器 + 绕过列表（先落地 route 规则与系统代理 bypass 两处）+ 热重载。
- **M3 TUN**：提权启动方案 + TUN 模式 + 绕过列表的路由排除 + strict_route 开关 + 模式切换的完整状态机。
- **M4 打磨**：Dashboard 速率曲线与连接数 + 日志页 + DNS 设置 + 开机自启 + 订阅定时更新 + 崩溃自愈 + 性能自查（红线逐条验证）。

---

## 六、验收清单（全部通过才算完成）

- [ ] 导入奶昔的 Clash 订阅链接后，节点完整显示、可切换、可测速，浏览器经系统代理正常访问 Google。
- [ ] 手动添加自建 Hysteria2 节点后连通可用，测速有结果。
- [ ] TUN 模式开启后，终端 `curl ifconfig.me` 出口为代理 IP；关闭后恢复本机出口。
- [ ] 在绕过列表添加某域名后，三种生效位置均验证直连（route 规则命中日志 + 系统代理 bypass + TUN 下直连）。
- [ ] 自定义一条"进程名 → 直连"规则并验证命中。
- [ ] 国内网站直连（日志中命中 geosite-cn → direct），无 DNS 泄漏（用 dnsleaktest 类站点粗验）。
- [ ] 强制杀死 App 后重启，系统代理状态被正确自愈还原。
- [ ] 空闲时 CPU ≈ 0%，主窗口关闭后无 WebSocket 流量，内存符合红线。
- [ ] 配置生成器单元测试全部通过；`sing-box check` 集成在启动链路中。

---

## 七、明确禁止事项

- 禁止自研内核、协议栈或加密实现；禁止 fork 修改 sing-box 源码（只允许作为二进制/官方产物使用）。
- 禁止 Electron / Flutter / WebView。
- 禁止将 clash_api 的端口与 secret 写死或落盘明文共享。
- 禁止在用户未授权的情况下静默提权；每次提权操作要有明确的系统授权弹窗。
- 禁止引入大型第三方依赖解决小问题（YAML 解析可用轻量库如 Yams，此为唯一预授权的第三方依赖；新增其他依赖需在交付说明中给出理由）。
- 遇到 Apple 签名/权限导致的阻塞，不要绕过安全机制，改为在 README 中记录限制与手动步骤。
