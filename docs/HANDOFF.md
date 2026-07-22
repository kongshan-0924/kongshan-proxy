# 项目交接

## 2026-07-23 免密码 TUN 助手 加固+合并+交付 0.1.24（本会话完成）

- 已完成：审核（两轮独立对抗式）+ 加固 + 合并 `feat/tun-passwordless-helper` → main（merge `64c2b00`）+ 构建交付 0.1.24。
- 审核裁决：第三轮（C①/C②/N1/N2）正确。首轮 re-audit 揪出并**实证** 2 个 BLOCKER：① stock sing-box `run` 无视 stdin（缺 `-c /dev/stdin`）→ 免密码 TUN 从未真正起来过；② §5.1 客户端身份可被同用户进程伪造（identifier 可重签 + 客户端 cdhash 未钉 + ad-hoc 主可执行可写 + 无 hardened runtime）→ 提权到 root。
- 加固（3 提交 `83fa28b`/`7e8f625`/`ff49201`）：argv `run -c /dev/stdin` + spawn 存活探测；安装钉客户端 cdhash（fail-closed）；`build_app.sh` 加 `--options runtime`（**实测** ad-hoc 也被内核强制、DYLD 注入被挡）；helper fd 卫生补齐（finding3/4 + 短读关 fd）。
- 二轮 re-audit：**未发现同用户→root 提权链**，逐向量（替换重签→cdhash 拒；DYLD/task 注入→hardened runtime；插件/框架→无 dlopen/不捆 dylib；配置武器化→生成 schema 无 root 写/执行落点）均被挡，铁律 §1.1–1.6 保持。剩 2 条非阻塞（配置未在信任边界收窄=纵深；trust.json 无版本）。
- 修改文件：`Sources/KongshanHelper/main.swift`、`Sources/KongshanCore/PrivilegedHelperInstaller.swift`、`scripts/build_app.sh`、`Tests/KongshanCoreTests/PrivilegedHelperInstallerTests.swift` + 合并带入的全部 helper 文件；`VERSION`→0.1.24；4 份记录文档。
- 测试结果：合并后 `swift test` **257 通过 1 跳过 0 失败**；构建 0.1.24 硬化签名验证（主可执行 + KongshanHelper `flags=0x10002(adhoc,runtime)`、`--deep --strict` 有效）；启动测试通过（hardened runtime 未阻断）。
- 当前状态：`main` 0.1.24（**待推 origin**）；`/Applications/kongshan.app` 0.1.24、`dist/kongshan-0.1.24.dmg`（SHA-256 `7fd707cc…`），旧 0.1.23 产物已删。集成 `tunLauncher = helperClient.isReachable() ? helperClient : privilegedLauncher`。
- 风险/注意：**免密码 TUN 需用户真机点「设置→隧道→安装免密码助手」授权一次**（此前 BLOCKER① 令其从未端到端跑通，路径匹配 `SecCodeCopyPath` 也需真机确认；不匹配则回退 osascript 兜底、功能正常只是没免密）。切勿在自动化里真装 daemon（§1.5）。
- 下一步：用户真机验收零弹窗 TUN（见 NEXT_STEPS 顶部）。收尾：推 main、删已并入的 `feat/tun-passwordless-helper`。
- 接手方式：读本节 + NEXT_STEPS 顶部。助手设计/威胁模型/审查在 `docs/design/tun-passwordless-helper*.md`（已随合并进 main）。

## 2026-07-22 审核并合并 0.1.23 → main（本会话完成）
## 2026-07-22 22:40 TUN 助手第三轮安全修复（feat/tun-passwordless-helper，4 提交完成，待维护者复审）

- 已完成：按 `docs/design/tun-passwordless-helper-fixes.md`「第三轮」实现 C①/C②/N1 必修 + N2 可选，4 个独立提交留在 `feat/tun-passwordless-helper`（未推、未合 main）。
- 提交：`dcf4914` C② fail-closed → `f13795f` C① sing-box 拷 root-only 消除 TOCTOU → `0760ec1` N1 defer close FD → `276dacf` N2 client pipe 清理。
- 修复要点：
  - C① [阻断·root 提权]：sing-box 没迁 root-only，trust.singBoxExecutablePath 指 bundle（admin 可写）→ verify→exec TOCTOU。修法与 helper 同构：`installedSingBoxURL = stateDirectory + "/sing-box"`，安装脚本加 cp/chown/chmod，trust 指向拷贝。提取 `makeTrustConfig` 纯函数单测。
  - C② [低危]：`computeCDHashHex` nil 时静默写 null → 不钉 cdhash。提取 `failClosedCDHash(_:)` 纯函数，nil/空抛 `authorizationFailed`。
  - N1 [可靠性]：`startSingBox` 早抛泄漏 configFD → App 写线程永久阻塞。顶部 `defer { close(configFD) }` + logFD 打开后 `defer { close(logFD) }`，删 spawn 后显式 close。
  - N2 [可选·非安全]：`Client.start` 的 `pipe()` 后 sendFrame 抛错泄漏两端。do/catch 补关再 rethrow。
- 修改文件：`Sources/KongshanCore/PrivilegedHelperInstaller.swift`、`Sources/KongshanHelper/main.swift`、`Sources/KongshanCore/PrivilegedHelperClient.swift`、`Tests/KongshanCoreTests/PrivilegedHelperInstallerTests.swift`（新增）。未碰侧栏、未 merge main、未真装 daemon（§1.5）。
- 测试：`swift build` 通过；`swift test` **225 通过 1 跳过 0 失败**（+9 新：C① 5 + C② 4）。
- 铁律复核：§1.1-1.6 全部仍生效（C① 只改 sing-box 加载位置，仍 internal/固定 run/stdin；C② 强化拒绝优先；N1/N2 不涉及铁律）。
- 当前状态：4 提交在 `feat/tun-passwordless-helper`，未推。等维护者重跑独立对抗式安全审查（重点验 C① 是否真消除 TOCTOU），过了才合 main。
- 风险：main 已升 0.1.23，与本分支在 AppState.swift/MainWindowView.swift 会冲突——维护者合并时手动解（本分支未 merge/rebase main，按要求）。N1 defer 不便纯函数单测（运行时保证），已在 commit 写思路说明。
- 下一步：维护者重跑安全审查；通过后合 main（手动解冲突）；真机重打包验证零弹窗 TUN + 检查 `/Library/Application Support/kongshan/helper/sing-box` 存在且 root:wheel 755 + trust.json 指向它。
- 接手方式：在 `feat/tun-passwordless-helper`，读 4 个 commit + SESSION_LOG 2026-07-22 22:40 段。

## 2026-07-22 TUN 免密码特权助手（feat/tun-passwordless-helper 分支，里程碑 2b-5 完成）

- 已完成：按 `docs/design/tun-passwordless-helper-tasks.md` 实现里程碑 2b-5，4 个独立提交（每里程碑一条）。
  - 2b helper 安全核心（`Sources/KongshanHelper/main.swift`）：socket 服务 + audit_token 身份校验（纯函数 `HelperTrustEvaluation.isTrusted`）+ startTun 收 SCM_RIGHTS FD 固定 exec 内置 sing-box（exec 前 SecStaticCodeCheckValidity）+ stopTun 只杀自起 PID（proc_pidpath 验证）+ 30s 自愈定时器。
  - 3 App 客户端 + 接线 + UI：`PrivilegedHelperClient`（actor，符合 `PrivilegedLaunching`，pipe+sendmsg 传 FD）+ `PrivilegedHelperInstaller`（一条 osascript 安装/卸载）+ AppState `tunLauncher`（helper 可达用 helper，否则回退 `privilegedLauncher`）+ 设置→隧道「免密码助手」Section。
  - 4 打包：`build_app.sh` 拷 `KongshanHelper` → `Contents/MacOS/`、plist 模板 → `Contents/Resources/`；Installer 优先读 .app 内模板（占位符替换），内联兜底。
  - 5 测试：25 个纯逻辑单测（isTrusted 各拒绝分支/decide 各分发/trust 解码缺失损坏）。
- 修改文件：新增 `Sources/KongshanCore/PrivilegedHelperClient.swift`、`PrivilegedHelperInstaller.swift`、`Resources/com.kaysen.kongshan.helper.plist`、`Tests/HelperProtocolTests/HelperTrustEvaluationTests.swift`；改 `HelperProtocol.swift`、`KongshanHelper/main.swift`、`PrivilegedLauncher.swift`、`AppState.swift`、`MainWindowView.swift`、`build_app.sh`。
- 测试结果：`swift build` 通过；`swift test` 199 通过 1 跳过 0 失败（+25）。
- 当前状态：里程碑 2b-5 代码完成，4 提交在 `feat/tun-passwordless-helper` 分支，未推 main。
- 风险/注意事项：
  1. 铁律 §1 全部满足：固定 exec / 拒绝优先 / FD 不落盘 / 只杀自起 / 不在自动化装 daemon / 不弱化兜底。
  2. 助手安装需用户在真机点一次「安装免密码助手」按钮（osascript 提权一次）；未装时 TUN 仍走 `PrivilegedLauncher`（osascript 每次弹密码）。
  3. helper ad-hoc 签名，`SecStaticCodeCheckValidity(nil)` 接受；身份校验靠路径+identifier 钉死，默认不钉 cdhash。
  4. 真机安装授权验收由用户完成；未在自动化里 bootstrap daemon。
  5. 未碰侧栏文件（侧栏修复在 `fix/sidebar-toggle` 分支）。
- 下一步：维护者审查（重点 §5.1 身份校验 / §1.3 FD 不落盘 / §1.4 只杀自起）；审查通过后合并 main；用户真机点一次安装授权验收。
- 接手方式：在 `feat/tun-passwordless-helper` 分支上，先读 `docs/design/tun-passwordless-helper-tasks.md` 和 `docs/design/tun-passwordless-helper.md`；动 helper 安全逻辑前理解 audit_token→SecCode→identifier+path 链路与拒绝优先原则。

## 2026-07-22 双侧栏按钮修复设计

- 已完成：审核 + ff-only 合并超集分支 `fix/tun-ipv6-no-route` → main 并推 origin；分支整理到「`main` + `feat/tun-passwordless-helper`」两条。
- 审核（我负责）：`swift test` 绿（202/1跳过/0）；亲读 IPv6 修复（getifaddrs 内存安全、fe80::/10 分类正确）；独立对抗式 subagent 复审整份 Sources/ diff（+2653/-264，36 文件）→ **无 blocker**（无崩溃/数据竞争/备份回滚破损/明文 secret）。合并前修 2 个 medium 并重测通过：①出口诊断代理关时不再用真实 IP 自动直连 Mullvad（`DashboardView.onAppear` 加 `state.isOn` 门控，手动「检测」按钮保留）②节点倍率正则改 `static let` 缓存（避免逐节点每帧现编译，命中项目历史 CPU 雷区）。
- 修改文件：`Sources/KongshanCore/NodeNameMetadata.swift`、`Sources/kongshan/DashboardView.swift`（审核修复，`14ee357`）；4 份记录文档。
- 测试结果：`swift test` 202 通过 1 跳过 0 失败。
- 当前状态：`origin/main = 14ee357`（0.1.23，领先 0）；本地仅 `main` + `feat/tun-passwordless-helper`。**⚠️ `dist/kongshan-0.1.23.dmg` 为旧产物，不含 IPv6 + 2 条审核修复**——真机跑需重打包（自增版本）。
- 风险/注意：合并前的 4 条 low 待办（tray 常驻 WebSocket、备份 remoteDoH 未校 https、分应用规则按主进程名匹配、stripIPv6 纯 IPv6 配置产空地址）见 NEXT_STEPS 文末，非阻塞。
- 下一步：用户 `scripts/build_app.sh` 重打包 → 真机验证 IPv6 修复 + 审核修复 + 0.1.23 界面；再收尾助手第三轮。
- 接手方式：读本节 + NEXT_STEPS 顶部「✅ 合并已完成」。助手第三轮在 `feat/tun-passwordless-helper`，合并会与 network-obs 在 AppState/MainWindowView 冲突需手动解。

## 2026-07-22 修复 0.1.23 TUN 开启无效果（fix/tun-ipv6-no-route，1 提交完成）

- 已完成：诊断 0.1.23 真机 TUN「开了没效果」根因并修复，1 提交（a6bb609）在 `fix/tun-ipv6-no-route` 分支（基于 `codex/network-observability-batch`）。
- 根因（确诊）：用户 Wi-Fi（en0）只有链路本地 `fe80::`，无全局 IPv6；但 TUN 默认配了 `fdfe:dcba:9876::1/126`。TUN 起来后应用看到 IPv6 接口 + AAAA → 尝试 IPv6 直连中国 IPv6（240e:...）→ `direct` 出站因 en0 无全局 IPv6 报 `no route to host` → 应用不快速回退 IPv4 → 网断。代理流量其实正常（ChatGPT/Google 经 hysteria2）。证据：`sing-box-tun.log` 全是 `outbound/direct[direct]: ... no route to host` 且目标全 240e:...；`ifconfig en0` 仅 fe80::；`netstat -rn -f inet6` 默认路由全在 utun0/1/2/3/5。
- 修复（ponytail 最短根因修复，3 文件 +81/-1）：
  - `TunSettings.stripIPv6()`（ProxyMode.swift）：纯函数剥 IPv6 保 IPv4；`dnsServerAddress` 只看 IPv4 不受影响。
  - `AppState.physicalNetworkHasGlobalIPv6()`：`getifaddrs` 排除 utun/lo/bridge/gif/stf/llw/awdl，跳过 fe80::/10 链路本地。
  - `generateConfiguration` 入口统一处理：TUN 模式且物理网络无全局 IPv6 时调 stripIPv6。start / applyRoutingSettings / applyDnsSettings 三条路径都受益；持久化与备份仍写原始 tunSettings。
- 修改文件：`Sources/KongshanCore/ProxyMode.swift`、`Sources/kongshan/AppState.swift`、`Tests/KongshanCoreTests/TunConfigTests.swift`。未碰侧栏、未碰 helper。
- 测试：`swift build` 通过；`swift test` 202 通过 1 跳过 0 失败（+3 新）。真机验证探针返回 false（en0 仅 fe80::）。
- 当前状态：1 提交在 `fix/tun-ipv6-no-route`，未推。
- 风险/注意事项：切到有 IPv6 的网络探测自动返回 true，TUN 自动恢复 IPv6；探针排除 utun 等虚拟接口，其它 VPN 的 IPv6 不会被误判。
- 下一步：用户真机重打包验证；通过后合 `fix/tun-ipv6-no-route` → main（或先合进 codex 分支再统一合 main）。
- 接手方式：在 `fix/tun-ipv6-no-route`，读 commit a6bb609 + SESSION_LOG 2026-07-22 21:30 段。改探测前理解 getifaddrs 链路与 fe80::/10 判定。

## 2026-07-22 网络可观测与控制增强（0.1.23 待用户验收）

- 已完成：仪表盘真实出口 IP/地区/运营商和 DNS 一键自测；节点名地区旗帜与倍率高亮；连接页单连接及顶部实时速率/排序；测速并自动选最快；分应用直连/默认代理/指定节点；托盘实时上下行；配置与设置 JSON 备份/恢复。
- 修改文件：新增 `ExitDiagnostics.swift`、`NodeNameMetadata.swift`、`ConnectionRateTracker.swift`、`ExitDiagnosticsService.swift`、`KongshanBackup.swift`、`BackupDocument.swift` 及对应测试；更新 AppState、Dashboard、PolicyGroups、Connections、Routing、MenuBar、Settings、ConfigGenerator 等。
- 测试结果：两次新鲜全量 `swift test` 均为 199 项、0 失败、1 项条件快照跳过；`verify_m4.sh` 通过，平均 CPU 0.000%、最大 RSS 115,280 KB；arm64、ad-hoc strict 签名、sing-box 1.13.14、真实规则集、残留检查和 DMG 校验通过。
- 当前状态：所有代码与发布记录均在 `codex/network-observability-batch`，main 仍为 `ec29ab1` 未合并；`/Applications/kongshan.app` 正运行 0.1.23/build 123；唯一安装包为主工作区 `dist/kongshan-0.1.23.dmg`，SHA-256 `cb8e1ba96b0507df2ceb7c1a0fcb97a52eb7cb8224aa2c5f5358fa51608c7fa2`。
- 风险/注意事项：DNS 泄漏是基于多次解析器结果的三态启发式判断，不作绝对安全承诺；出口检测依赖 Mullvad 公开接口；备份包含订阅与节点凭据，需当作敏感文件；旧产物仅移入废纸篓，可恢复。
- 下一步：用户在真实节点/代理状态下验收七类界面与出口/DNS/速率数据；明确验收通过后才合并 main。
- 接手方式：保留当前分支与 worktree；查问题先看 `docs/progress/SESSION_LOG.md` 本日各功能阶段；未收到“验收通过”不得合并 main。

## 2026-07-22 侧边栏按钮固定位置（0.1.22 待用户验收）

- 已完成：使用受控 `NavigationSplitViewVisibility`，在侧栏作用域移除系统默认按钮，并以唯一 `.navigation` 按钮固定左上角；0.1.22 已完成构建、DMG、单副本安装和真实展开/折叠/恢复检查。
- 修改文件：`Sources/kongshan/MainWindowView.swift`、`Tests/KongshanAppTests/MainWindowToolbarTests.swift`、`VERSION`、固定位置设计/计划及全部项目记录。
- 测试结果：回归先 RED 4 处、后 GREEN 1/1；App 48 项和全量 171 项（1 项既有快照跳过）0 失败；M4 平均 CPU 0.000%、最大 RSS 111,280 KB；签名与 DMG 校验通过。
- 当前状态：`fix/sidebar-toggle` 保持独立，main 仍为 `ec29ab1`；0.1.22/build 122 正从 `/Applications/kongshan.app` 运行，系统只索引这一份 App，唯一 DMG 为主工作区 `dist/kongshan-0.1.22.dmg`。
- 风险/注意事项：CLI XCTest 不能直接读取真实标题栏；Computer Use 已确认展开/折叠均只有一个左侧按钮并恢复侧栏，最终仍由用户验收。旧 App/DMG 在废纸篓中可恢复。
- 下一步：用户检查仪表盘、设置及其他页面；明确验收通过后才合并 main。
- 接手方式：保持分支/worktree，不要在验收前合并或清理；如有视觉问题继续在本分支修。

## 2026-07-22 双侧栏按钮修复（0.1.21）

- 已完成：删除 0.1.20 新增的自定义紧凑侧栏按钮，只保留 `NavigationSplitView` 原生按钮；同时删除 AppDelegate 中依赖时序的系统按钮清理。
- 修改文件：`MainWindowView.swift`、`KongshanApp.swift`、新增 `MainWindowToolbarTests.swift`，并更新设计、计划和全部项目记录。
- 测试结果：回归检查先命中 4 处重复机制（RED），修改后定向 1/1、App 48/48、全量 171 项（1 项既有快照跳过）0 失败；`verify_m4.sh` 通过，平均 CPU 0.000%，最大 RSS 107,168 KB；0.1.21 DMG 校验有效。
- 当前状态：修复仍位于 `fix/sidebar-toggle`，未合并 main；0.1.21（build 121）已安装并启动，系统只发现 `/Applications/kongshan.app`，唯一保留的安装包为主工作区 `dist/kongshan-0.1.21.dmg`。
- 风险/注意事项：命令行 XCTest 不暴露 SwiftUI 标题栏按钮，不能伪造窗口计数；自动测试改锁死“无自定义按钮/无时序删除”架构，最终视觉仍需打开打包 App 核对。
- 下一步：用户人工确认仪表盘、设置及其他页面都只有一个按钮；通过后再合并到 main。
- 接手方式：保持原生侧栏显示/隐藏，不要重新增加紧凑图标侧栏或延时删除 toolbar item。

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

## 2026-07-21（最新 · 上下文清理前）当前状态 0.1.15

### 本轮关键成果
- **找到并修复「很卡/CPU 100%」真凶**：托盘菜单 MenuBarView 一次性建出所有子菜单（15 组×最多342节点≈5000 项），且每个 optionButton 调 isSelected→selectedMemberName→groupOptions 重建全节点字典（O(n)），每次建菜单 O(n²)，SwiftUI 反复重求值 → 单核持续 100% CPU + RSS 271MB。**这让整个 App（含开系统代理/TUN）都卡，根本不是代理路径问题**。修复：内置组固定 UUID + ForEach id:\.name；选中项每组只算一次、optionButton 收 selected:Bool（O(1)/项）；子菜单每组最多 40 项。实测 CPU 100%→0%、RSS→141MB。
- **TUN 已可正常开启且快**：之前的 EOF 是我上一版的自杀式 `pkill -f <binary>`（匹配到执行启动命令的 shell 自己）导致，改为 `pgrep -x sing-box` + 路径核对。真机确认 TUN 能起、路由正常。
- 系统代理/TUN 开启慢的其他优化：订阅规则合并 4780→166（config 1MB→470KB）、生成移出主线程、规则集缓存优先+15s超时、health 上限放宽到 ~6s、pgrep 清理只在真杀到残留才 sleep。
- 「打不开/启动没反应」：多显示器下窗口被状态还原到外接屏角落 → 去掉 frameAutosave、isRestorable=false、每次居中到主屏、最小化先 deminiaturize。
- 版本自增（VERSION 文件 + build_app.sh 用 PlistBuddy 写入）、发布 dist 并 cp 到 /Applications 运行。设置-关于显示版本。

### 唯一已知未解决问题
- **开 TUN 后仪表盘出站 IP 一直跳/一会一变**（用户最后反馈）。疑 `final: 自动选择`(urltest) 或订阅规则指向 urltest 组。排查方案见 NEXT_STEPS 顶部。

### 环境（关键）
- ~~CleanMyMac 5 在后台反复删除数据/.app~~ **已更正**：经用户确认，早前那次数据/App 丢失是**手动删除一次**，不是 CleanMyMac 后台反复清理。2026-07-21 实测数据目录（订阅 11:28 起）与 app（54MB）稳定留存，无需特意排除。之前把一次性事件误判成规律，特此纠正。
- GitHub 私有仓库：`kongshan-0924/kongshan-proxy`（remote origin 已设，main 与远端一致）。基线标签 `baseline-20260721`。用户 gh 登录名是 Ks-Ht，但仓库归 kongshan-0924（有写权限）。
- 多显示器：笔记本(主屏/菜单栏) + 上方大外接屏。

### 关键结论（避免重复踩坑）
1. SwiftUI ForEach 的数据源若每次返回新身份（随机 UUID）或 body 里做 O(n) 计算×n 项，会导致持续重渲染/100% CPU。计算属性别在 body 热路径里重建大字典。用 `sample <pid>` 抓栈最快定位。
2. TUN 启动的 osascript shell 命令行里含内核路径，**清理残留内核必须按进程名 `pgrep -x sing-box` 匹配，不能 `pkill -f <路径>`**（会杀自己）。
3. macOS TUN 接口名必须 utunN 或不指定（我们不指定，自动分配）。
4. 多显示器 + macOS 窗口状态还原会把窗口丢到看不见的屏；已用 isRestorable=false + 主屏居中解决。
5. 测速默认 TCP 握手（不需内核）；系统代理/TUN 开启的规则集用缓存优先（别每次联网下载）。

### 测试/验证
- `swift test` 167 通过（1 跳过）。空闲 CPU 0%、RSS ~141MB。
- 真机：TUN 可开、路由正常。系统代理待用户再确认顺畅（CPU 已不再被菜单吃满）。
- 下一位接手：先读本节 + NEXT_STEPS + SESSION_LOG 2026-07-21 各段。动 UI 计算属性前想清楚是否在 ForEach 热路径。

## 2026-07-21（0.1.16）修「开代理没效果 / 手动选择不生效 / 出站IP跳」

### 根因（确诊，非猜测）
读真实 `config.json` + 订阅 `proxy-groups` 得出：机场是**轮辐结构**，主组 `🙂 TAGSS` 被 7 个策略当默认引用，但它自身首个成员是 `🎯 绕过代理`(直连)。于是"需代理"的流量（国外媒体 66 条规则、漏网之鱼兜底、直接指向 TAGSS 的 25 条）全部走**直连** → 墙内 Google/GitHub 不可达。与此同时我方内置 `手动选择` 不被任何 rule/final/组引用（`final` 当时＝`自动选择`）＝**孤儿组**，用户在里面选节点完全不生效。

### 修复（仅 `ConfigGenerator.swift`，无新数据模型、不动 UI）
1. **识别机场主组**＝被 ≥2 个其它组当"首个成员(默认)"引用、且自身不是纯直连/拒绝包装的代理组；把主组默认接到 `手动选择`（并把手动选择放进其成员）。指向主组的策略自然跟随；`微软/苹果/Steam/FCM → 绕过代理=直连` 的机场意图**保留不动**；被引用<2 的地区子组也不动。
2. `route.final`：`自动选择`(urltest) → `手动选择`。**顺带修掉出站 IP 跳动**（final 不再是自动测速切换组）。
3. DNS remote detour：`自动选择` → `手动选择`。
- 用户模型达成：在「手动选择」挑一次节点 → 所有需代理流量走它；微软/苹果/Steam 仍直连。

### 验证
- `swift test` 168 通过（+1 新测 `testHubMasterDefaultsToManualSelectionAndBypassPreserved`，锁死主组→手动选择/指向主组的策略不被强改/直连组保留/final=手动选择）。
- Python 按真实订阅结构模拟：主组正确识别为 `🙂 TAGSS`(被7引用)，各组默认符合预期。
- 0.1.16 已发 dist + 装 /Applications（54MB）。

### 未解决 / 待取证
- **TUN「一直弹密码框 / 起不来」**：无法从静态产物复现（运行态干净、无残留内核/恢复记录；日志证明 16:53 TUN 曾正常接管）。机制见 NEXT_STEPS B 段。**需用户用 0.1.16 再点一次 TUN，提供当次错误提示 + `logs/sing-box-tun.log` 新增尾部**才能定位。切勿在无证据下盲改提权/TUN 路径（本项目已有"猜代理路径"翻车教训）。

### 关键结论（新增）
- 机场 proxy-groups 常是轮辐：一个主组汇聚全部节点、其它策略默认指向它；主组可能默认直连。要让"手动选择/用户选的节点"生效，必须把这个主组的默认接到用户可控的选择组，而不是只生成一个不被引用的内置组。
- 改路由默认前，先读**真实生成的 config.json** 的 outbounds/route（`python3` 起一个分析脚本最快），别凭 UI 猜。

## 2026-07-21（0.1.17）只用机场策略组 + 连通性卡误报

- **「0.1.16 仍不可达」是误报**：内核日志(sing-box.log)证明代理已通(claude.ai/api.github.com 经所选节点成功建连、零报错)，config 也修复到位。是仪表盘连通性卡测 `www.google.com/generate_204`(常被拦)、且测 selectedNode 未必与真实路由同步所致。取证要点：config.json **不含 clash_api**(secret 不落盘)，查实时状态靠内核日志或给 sing-box pid 找监听端口(仍无 secret 无法调 API)。
- **重构（用户拍板 Option B：只用配置自带策略组）**：
  - `ConfigGenerator.primaryGroupName(among:)` 抽为 public，App 与生成器共用同一主组识别。
  - 有机场策略组 → **不生成内置手动/自动选择**；主组默认指向真实节点(记住的→App当前节点→首个节点成员)；`final`/DNS/自定义规则兜底走 `primaryOutbound`(主组，识别不到则用户选中节点)。无机场组 → 仍生成手动/自动选择兜底。
  - `AppState.displayPolicyGroups` 有机场组时只回机场组；`primaryGroupName` 计算属性；在主组挑节点＝选主节点(同步 selectedNodeID)；`probeConnectivity` 测主组(真实路径)+ gstatic 端点。
- 测试 168 通过；0.1.17 发 dist + 暂存替换装 /Applications(未打断运行中的 0.1.16)。
- **接手/真机**：让用户关旧实例、重开 0.1.17，代理页只剩机场组，在 TAGSS 挑节点。旧 groupSelections["🙂 TAGSS"]=台湾02 会成主组默认。TUN password-loop 仍待复现取证(见 NEXT_STEPS B)。
