# 项目交接

- 已完成：M1–M4 代码与自动交付；M4 包含 Dashboard、日志、双 DoH、订阅自动更新、SMAppService、崩溃自愈和一键性能/残留验收。
- 修改文件：最终新增 `verify_m4.sh`、README、M4 acceptance，并更新第三方声明、计划和全部接力记录；功能代码基线为 `46fe328`。
- 测试结果：`zsh scripts/verify_m4.sh` 覆盖 138 项测试、release arm64、ad-hoc strict 签名、官方规则集和 M4 门禁；平均 CPU 0.040%、最大 RSS 118,336 KB，标记通过。
- 当前状态：可双击产物为 `dist/kongshan.app`（约 51 MB）。自动验收后无进程、socket、recovery、FIFO 或临时目录残留。
- 风险/注意事项：真实订阅/节点、浏览/出口、root TUN、DNS leak、登录项批准、通知 UI、强杀 App 和 24h Instruments/Energy Impact 均待人工，不得称为原始清单全部通过。
- 下一步：按 `docs/acceptance/M4.md` 完成人工验收并追加证据。
- 接手方式：先读 `README.md` 和四份 acceptance；任何真实系统代理/TUN 操作前确认恢复路径，遇到 recovery 文件先核对进程身份，不盲删/盲杀。

## 2026-07-20 界面修复与重做（当前状态）

- 已完成：双击不出主窗口已修复并实测；托盘按 Stash 改回原生菜单并重组操作逻辑；仪表盘/侧栏/节点/规则/日志按 Stash 视觉重做；修掉绕过列表内容串行的既有 bug。
- 修改文件：新增 `Sources/kongshan/Theme.swift`、`Tests/KongshanAppTests/RenderSnapshotTests.swift`；重写 `KongshanApp.swift`、`MenuBarView.swift`、`DashboardView.swift`、`MainWindowView.swift`；改 `RoutingView.swift`、`LogsView.swift`、`AppState.swift`。
- 测试结果：`swift test` 138 项通过 0 失败（1 项快照工具按 env 跳过）；`verify_m4.sh` 通过。启动后 CGWindowList 可见窗口数由 0 变为 1；静置 20 次采样 CPU 全 0.0%、RSS 89,632 KB。
- 当前状态：托盘为原生菜单（打开仪表盘 ⌘D / 接管方式子菜单 / 节点子菜单 / 开启代理 ⌘S / 登录时启动 / 测速全部 ⌘T / 刷新订阅 ⌘R / 退出 ⌘Q）。主窗口由 AppDelegate 自建 NSWindow 承载，打开时切 `.regular` 恢复菜单栏与 ⌘Q/⌘W，关闭切回 `.accessory`。

### 必须知道的五条结论

1. **不要用激活状态判断启动来源**。实测 LSUIElement 应用启动时 `isActive=false`、`didBecomeActive` 不触发、`ppid=1`、`XPC_SERVICE_NAME` 与登录项同形。现用判据是「开机自启未启用才在启动时开窗」，配合 `applicationShouldHandleReopen`。
2. **AppState 由 AppDelegate 直接持有**，不要退回视图 `onAppear` 注入——那样用户没打开过菜单时退出不会还原系统代理。
3. **自查界面用 `RenderSnapshotTests`，不要用 `ImageRenderer`**。本机终端无屏幕录制/辅助功能权限，`screencapture` 只出全黑图；`ImageRenderer` 渲染不出 ScrollView 内容和 AppKit 控件。运行方式：
   ```bash
   KONGSHAN_SNAPSHOT_DIR=/tmp/kongshan-shots swift test --filter RenderSnapshotTests
   ```
4. **卡片配色必须用 `Theme.cardFill` / `Theme.pageFill`**。`.background` 与 `.background.secondary` 在浅色下几乎同色，卡片会糊在背景里。
5. **测性能前先静置**。本机 Bartender 6 会反复触发 `NSStatusItem _updateReplicant:` 快照重绘，在忙时能把平均 CPU 抬到 0.78%。下结论前先用 `sample <pid>` 看工作落在哪个栈。

- 风险/注意事项：
  - 托盘原生菜单与 NavigationSplitView 侧栏都无法离屏渲染验证，需人工点开确认。
  - 托盘不显示实时速率：`isDashboardVisible` 是布尔量，托盘与 Dashboard 两个消费者会互相取消订阅，加引用计数会破坏既有幂等测试。
  - 主窗口首次位置由 `window.center()` 决定，多显示器下可能不在主屏；用户移动后由 `setFrameAutosaveName("kongshan.main")` 记住。
  - 开机自启开启后手动重开应用，首次不会自动开窗，需再双击一次（走 reopen）。这是判据 1 的已知取舍。
- 下一步：人工确认托盘菜单、侧栏与 Bartender 可见性，然后继续真实网络人工验收。

## 2026-07-21 全面体检与加固（当前状态）

- 已完成：需求对照 + 全控件 UI 审计 + 开源客户端避坑调研，落地三层修复——真实世界坑（订阅 UA=clash.meta、userinfo 配额、确定性节点 ID、TUN 接管系统 DNS、切网补挂、唤醒检查、stack=mixed、全局 sniff）、架构缺口（组选择持久化+配置 default、节点变化热重载、推流断线重连）、UI P1 全清（全局错误条、删除确认、双模式开关、停止内核入口、自建节点删除、导入 sheet、测速 URL 草稿）。
- 修改文件：新增 `Sources/KongshanCore/SystemDNSManager.swift`、`Tests/KongshanCoreTests/SystemDNSManagerTests.swift`；改 Models / SubscriptionService / ClashSubscriptionConverter / ConfigGenerator / ProxyMode / SystemProxyManager / AppState / MainWindowView / DashboardView / PolicyGroupsView / Theme / KongshanApp 及 5 个测试文件。
- 测试结果：`swift test` 160 通过 0 失败（+14）；`verify_m4.sh` 通过（平均 CPU 0.000%，最大 RSS 115,264 KB）；离屏快照复查通过；`dist/kongshan.app` 已重打包并在运行。
- 当前状态：功能层与 Stash 的差距只剩托盘速率/外部访问（需破红线，等用户拍板）与组成员还原。
- 风险/注意事项：
  1. **TUN 现在会临时改系统 DNS**（指向 TUN 网段 +1，如 172.19.0.2），恢复与自愈完全复刻系统代理那套（独立 `dns-recovery.json`）。真机若 TUN 后断网先查 `networksetup -getdnsservers Wi-Fi`；重开 App 会自愈。
  2. TUN stack 默认 system→mixed，需真机回归。
  3. 订阅刷新节点集合变化时运行中内核会 <2s 快速重启（含定时刷新），预期行为。
  4. 测试红线未破：TUN 流程的 networksetup 白名单是「仅 DNS 三命令」（AppStateTests.isDNSTakeoverCommand）；系统事件监听（NWPathMonitor/didWake）闸在 monitorsSystemEvents=automaticallyInitialize，夹具默认关闭。
- 下一步：按 NEXT_STEPS 真机回归本轮行为变化，然后继续 M4 人工验收。
- 接手方式：先读本节 + SESSION_LOG 2026-07-21 段；动 TUN/DNS/代理路径前先理解三份恢复文件（proxy-recovery.json / dns-recovery.json / privileged 记录）的自愈链路，不要绕过快照直接改系统设置。

## 2026-07-21 配置为中心重构 + 两个真机 bug（当前状态）

- 已完成：
  - 真机 TUN 修复（`interface_name=kongshan-tun` 被 macOS 内核拒 → 不再输出，自动分配 utunN）。
  - 测速加 `SpeedTestMethod`（默认 `.tcpPing` 直连握手、不需内核；`.urlTest` 经代理），设置-网络可选。
  - 配置为中心：AppState `activeConfigID`（订阅或 `localConfigID`）过滤 nodes/策略/规则，不建新数据模型；PolicyGroup 加 `members`，选择模型改为按成员名（GroupOption / `select(optionName:in:)`），成员解析成出站 tag 且空组回退全部节点。
  - 界面：节点页→配置页（只列配置、单选生效、不显示节点）、代理页（配置策略+成员节点/子组选择+测速）、分流页→规则页（只读）、绕过三列表移入设置-隧道、托盘按策略选成员。
- 修改文件：新增 `Sources/KongshanCore/SpeedTest.swift`；改 ConfigGenerator/ProxyMode/RoutingModels/ClashSubscriptionConverter/SubscriptionService(无关)/AppState/MainWindowView/PolicyGroupsView/RoutingView/MenuBarView/Theme 及多份测试。
- 测试：`swift test` 165 通过 0 失败；`verify_m4.sh` 通过（平均 CPU 0.020%，最大 RSS 120,256 KB）；离屏渲染确认三页布局。dist/kongshan.app 已重打包运行。
- 风险/注意：
  1. TUN 名已在配置层修好，但「起 TUN」是运行期行为，需真机点一次确认接管成功。
  2. Clash GEOSITE/GEOIP/RULE-SET 规则仍不转换，靠内置 geosite-cn/geoip-cn/ads/private 兜底；规则页只列可解析规则。
  3. 升级会一次性重置策略组选择（旧持久化是 UUID，新按成员名），用户重选即可；不会崩。
  4. 一个生效配置只用它自己的节点/策略/规则；多订阅不再合并成一个大池。
- 下一步：按 NEXT_STEPS 真机验证 TUN/测速/配置切换，再继续 M4 人工验收。
- 接手方式：先读本节 + SESSION_LOG 2026-07-21 两段。改生成/选择逻辑前，理解 activeConfig* 过滤链路与 GroupOption/memberTag 的 名字↔tag 映射；改 TUN 前记住 macOS utun 名约束。

## 2026-07-21 手动选择 UUID + 托盘宽度

- 已完成：groupSelections 旧 UUID 迁移为节点名；托盘菜单短文案与截断。
- 测试：166 通过。
- 分支：feature/menu-display-and-uuid-fix。
