# Session Log

## 2026-07-20 — 初始化与需求读取

- 已完成：完整读取用户提供的 122 行任务文档；确认 macOS 14+、arm64、SwiftUI、sing-box 1.13.x、M1 至 M4 和验收红线。
- 修改文件：创建四个项目记录文件。
- 测试结果：当前无代码，无可运行测试。
- 当前状态：需求已读取，等待关键命名确认后进入设计方案评审。
- 风险/注意事项：目录为空且不是 Git 仓库；缺少真实订阅与 Apple 开发者签名环境不影响本地 ad-hoc MVP，但会影响部分人工验收。
- 下一步：确认应用名称与 Bundle Identifier；提出实现方案并完成设计审批。
- 下一位 Agent 如何接手：先读根目录项目记录，再读原始任务文档；不得跳过设计审批直接实现。

## 2026-07-20 — 应用命名确认

- 已完成：用户确认应用名为 `kongshan`。
- 修改文件：更新四个项目记录文件中的命名与下一步。
- 测试结果：仅文档更新，无代码测试。
- 当前状态：应用名已定，Bundle Identifier 待确认。
- 风险/注意事项：Bundle Identifier 会影响 Xcode target 与未来签名，应在工程初始化前固定。
- 下一步：确认 Bundle Identifier，继续设计评审。
- 下一位 Agent 如何接手：沿用应用名 `kongshan`，不要自行改名。

## 2026-07-20 — 设计稿完成

- 已完成：确认 `com.kaysen.kongshan`；保存原始需求副本；比较三种工程路径并确定 SwiftPM + 原生打包脚本；完成架构、数据流、安全、恢复、测试和里程碑设计；完成占位符、冲突、范围和歧义自审。
- 修改文件：新增 `.gitignore`、`docs/requirements/original-prompt.md`、`docs/superpowers/specs/2026-07-20-kongshan-design.md`；更新三份项目记录。
- 测试结果：文档自审通过；本机已确认 Apple Swift 6.3.3、Xcode 26.6、arm64，可满足 Swift 5.10+ 和 macOS 原生构建要求。
- 当前状态：设计稿等待用户复核，尚未写实现代码。
- 风险/注意事项：当前官方 stable 已核实为 sing-box 1.13.12；真实网络代理、TUN 与管理员授权不在自动测试中擅自执行。
- 下一步：用户确认设计稿后生成实施计划，再按 M1 至 M4 执行。
- 下一位 Agent 如何接手：先读设计稿；保持 SwiftPM 两 target、Yams 唯一第三方依赖和 secret 不落盘边界。

## 2026-07-20 — 设计确认与内核版本校正

- 已完成：用户确认设计并授权继续；通过官方 GitHub tag 与资产实时核验，最新 stable 已从旧搜索快照中的 1.13.12 校正为 1.13.14；下载官方 darwin-arm64 包并计算 SHA-256。
- 修改文件：更新设计稿、HANDOFF、PROGRESS、NEXT_STEPS 与本日志。
- 测试结果：官方资产可下载；SHA-256 为 `73e8967b0fc08e17bce4263ca56ebc394822401a16497a1c4e02316c888202ab`。
- 当前状态：设计已确认，正在编写 M1 实施计划。
- 风险/注意事项：下载脚本必须同时固定版本与哈希；不得依赖会漂移的 `latest` URL。
- 下一步：完成并自审 M1 计划，内联执行首个任务。
- 下一位 Agent 如何接手：以 1.13.14 和上述哈希为唯一 M1 内核基线。

## 2026-07-20 — M1 实施计划完成

- 已完成：使用 writing-plans 将 M1 拆为 11 个可验证 Task；完成需求覆盖、占位符和类型命名自审；确定按用户授权内联执行，不启用子 Agent。
- 修改文件：新增 `docs/superpowers/plans/2026-07-20-kongshan-m1.md`；更新 HANDOFF、PROGRESS、NEXT_STEPS 与本日志。
- 测试结果：`git diff --check` 通过；计划无 TBD/TODO/FIXME，占位符扫描为空。
- 当前状态：M1 计划就绪，Task 1 尚未开始。
- 风险/注意事项：真实系统代理切换仍只做明确人工验收，自动测试使用命令记录器，避免开发期间断网。
- 下一步：调用 executing-plans，执行 Task 1 工程骨架的红-绿测试流程。
- 下一位 Agent 如何接手：打开 M1 计划，从第一个未勾选步骤执行；每个 Task 完成即写日志和提交。

## 2026-07-20 — M1 Task 1 原生工程骨架

- 已完成：先写 AppIdentity 测试并观察缺少 `Package.swift` 的预期失败；随后建立 Swift 6/macOS 14 SwiftPM 工程，锁定 Yams 6.2.2，创建 MenuBarExtra、独立 Window、Info.plist 和应用身份常量。
- 修改文件：`Package.swift`、`Package.resolved`、`Sources/KongshanCore/AppIdentity.swift`、`Sources/kongshan/*`、`Resources/Info.plist`、`Tests/KongshanCoreTests/AppIdentityTests.swift`、M1 计划与记录。
- 测试结果：RED 为 `Could not find Package.swift`；GREEN 为 `swift test` 1/1 通过、`swift build` 成功、`plutil -lint` 通过，无编译警告。
- 当前状态：Task 1 完成，可生成原生 arm64 debug 可执行文件。
- 风险/注意事项：当前 UI 仅为工程冒烟骨架，代理功能尚未接入。
- 下一步：Task 2 定义节点模型和手动 Hysteria2 表单校验。
- 下一位 Agent 如何接手：从 M1 计划 Task 2 Step 1 开始，严格先写失败测试。

## 2026-07-20 — M1 Task 2 节点模型与手动 Hysteria2

- 已完成：先写有效节点、空字段、端口和带宽边界测试并观察缺少类型的预期失败；实现 Codable/Hashable/Sendable 节点与 transport 模型、手动 Hysteria2 表单和中文可读错误。
- 修改文件：`Sources/KongshanCore/Models.swift`、`Sources/KongshanCore/ManualHysteria2.swift`、`Tests/KongshanCoreTests/ManualHysteria2Tests.swift`、M1 计划与记录。
- 测试结果：RED 因 `ManualHysteria2` 不存在而失败；GREEN 为定向 4/4、全量 5/5 通过，无编译警告。
- 当前状态：Task 2 完成，手动 Hysteria2 可生成经过 trim 和边界校验的统一节点。
- 风险/注意事项：尚未生成 sing-box outbound；字段映射在 Task 3/4 完成。
- 下一步：Task 3 实现 Clash YAML 五类协议转换与不支持类型跳过。
- 下一位 Agent 如何接手：从 M1 计划 Task 3 Step 1 写 YAML fixture 失败测试。

## 2026-07-20 — M1 Task 3 Clash YAML 五协议转换

- 已完成：先写五协议、SS2022、WebSocket 字段、未知类型和坏节点容错测试并观察缺少转换器的预期失败；实现纯 Clash YAML 转换器。
- 修改文件：`Sources/KongshanCore/ClashSubscriptionConverter.swift`、`Tests/KongshanCoreTests/ClashSubscriptionConverterTests.swift`、M1 计划与记录。
- 测试结果：RED 因 `ClashSubscriptionConverter` 不存在而失败；GREEN 为定向 3/3、全量 8/8 通过，无编译警告。
- 当前状态：Task 3 完成，SS/SS2022、Trojan、VMess、Hysteria2、AnyTLS 可转为统一模型；坏节点只记录 warning。
- 风险/注意事项：具体 sing-box outbound 结构仍需 Task 4 生成并由官方内核 check 验证。
- 下一步：Task 4 实现纯配置生成器、随机高位端口和内存 secret。
- 下一位 Agent 如何接手：从 M1 计划 Task 4 Step 1 写配置 JSON 失败测试。

## 2026-07-20 — M1 Task 4 纯配置生成器与运行时参数

- 已完成：对照官方 1.13 文档确认 outbound/inbound/selector/urltest/route 字段；先写配置结构、五协议、自建组、脱敏快照和随机源测试并观察预期失败；实现纯 JSON 生成器。
- 修改文件：`Sources/KongshanCore/ConfigGenerator.swift`、`Sources/KongshanCore/RuntimeSecrets.swift`、`Tests/KongshanCoreTests/ConfigGeneratorTests.swift`、M1 计划与记录。
- 测试结果：RED 因生成器/运行时类型不存在而失败；GREEN 为定向 5/5、全量 13/13 通过，无编译警告。
- 当前状态：Task 4 完成，可生成 mixed inbound、五协议 outbound、三个策略组、Clash API 和 final route；诊断快照不含 Clash port/secret。
- 风险/注意事项：尚未用真实 sing-box 1.13.14 执行 `check`；Task 5 必须验证并修正任何版本字段差异。
- 下一步：Task 5 固定官方内核、实现带超时 ProcessRunner 和 check/start/stop。
- 下一位 Agent 如何接手：先执行官方内核下载和 SHA 校验，再从 Task 5 进程测试开始。

## 2026-07-20 — M1 Task 5 官方内核与进程生命周期

- 已完成：固定并下载官方 sing-box 1.13.14 darwin-arm64；校验归档 SHA、Mach-O 架构、版本、revision 和 Clash API tag；先写 ProcessRunner/内核测试并观察缺少类型的预期失败；实现 check/start/stop、实时输出和超时终止。
- 修改文件：`scripts/fetch_sing_box.sh`、`Vendor/sing-box/sing-box`、`Resources/THIRD_PARTY_NOTICES.md`、`Sources/KongshanCore/ProcessRunner.swift`、`Sources/KongshanCore/SingBoxProcess.swift`、`Tests/KongshanCoreTests/SingBoxProcessTests.swift`、M1 计划与记录。
- 测试结果：官方归档 SHA-256 为 `73e8967b0fc08e17bce4263ca56ebc394822401a16497a1c4e02316c888202ab`；RED 因进程类型不存在而失败；GREEN 为真实生成配置 check 成功、定向 4/4、全量 17/17 通过。
- 当前状态：Task 5 完成，官方内核可从内存配置校验、启动和停止，短命令具备超时与 stderr 采集。
- 风险/注意事项：M1 仅检测异常退出并提供回调；10 秒内最多三次自动重启策略按设计留到 M4。
- 下一步：Task 6 实现 Application Support 原子存储和订阅旧缓存兜底。
- 下一位 Agent 如何接手：从 M1 计划 Task 6 Step 1 写 Storage/SubscriptionService 失败测试。

## 2026-07-20 — M1 Task 6 原子存储与订阅缓存兜底

- 已完成：先写临时目录原子替换、成功刷新、下载失败、坏 YAML 和无缓存测试并观察缺少类型的预期失败；实现 Application Support 目录、Foundation 原子写入和订阅刷新事务。
- 修改文件：`Sources/KongshanCore/Models.swift`、`Sources/KongshanCore/Storage.swift`、`Sources/KongshanCore/SubscriptionService.swift`、`Tests/KongshanCoreTests/StorageTests.swift`、`Tests/KongshanCoreTests/SubscriptionServiceTests.swift`、M1 计划与记录。
- 测试结果：RED 因 Storage/SubscriptionService 不存在而失败；GREEN 为定向 5/5、全量 22/22 通过，无编译警告。
- 当前状态：Task 6 完成；新订阅仅在转换成功后覆盖缓存，任何失败都保留并使用最后成功节点。
- 风险/注意事项：失败通知由 Task 9 AppState/UI 消费 warning 后展示；当前服务层不直接依赖通知框架。
- 下一步：Task 7 实现 Clash API 节点选择、单测延迟与 ≤8 并发批量测速。
- 下一位 Agent 如何接手：从 M1 计划 Task 7 Step 1 写 URLProtocol 与并发计数失败测试。

## 2026-07-20 — M1 Task 7 Clash API 节点选择与限流测速

- 已完成：先写 Bearer 鉴权、中文路径编码、健康检查、HTTP 错误和并发上限测试并观察缺少客户端的预期失败；实现 Clash API 节点选择、延迟测试与最多 8 并发批处理。
- 修改文件：`Sources/KongshanCore/ClashAPIClient.swift`、`Tests/KongshanCoreTests/ClashAPIClientTests.swift`、M1 计划与记录。
- 测试结果：RED 因 `ClashAPIClient` 不存在而失败；GREEN 为定向 5/5、全量 27/27 通过，无编译警告。
- 当前状态：Task 7 完成，客户端可在内存 secret 保护下选择节点、查健康和批量测速。
- 风险/注意事项：单测使用 URLProtocol 仿真 Clash API；真实内核联调留到 AppState/UI 集成阶段。
- 下一步：Task 8 实现系统代理快照、失败回滚和启动自愈恢复。
- 下一位 Agent 如何接手：从 M1 计划 Task 8 Step 1 写纯解析/命令生成测试，自动测试不得修改本机代理。

## 2026-07-20 — M1 Task 8 系统代理快照、自愈与恢复

- 已完成：先写启用服务解析、HTTP/HTTPS/SOCKS/bypass 快照、精确恢复、启用失败回滚和启动自愈测试并观察缺少类型的预期失败；实现原子恢复快照与带超时/错误的 `networksetup` 事务。
- 修改文件：`Sources/KongshanCore/SystemProxyManager.swift`、`Tests/KongshanCoreTests/SystemProxyManagerTests.swift`、M1 计划与记录。
- 测试结果：RED 因 `SystemProxyCommands`/`SystemProxyManager` 不存在而失败；GREEN 为定向 5/5、全量 32/32 通过，无编译警告。
- 当前状态：Task 8 完成；启用前快照所有已启用服务，任一设置失败立即回滚，只有全部恢复成功才删除快照。
- 风险/注意事项：自动测试使用命令记录器，未修改本机代理；真实网络服务验收留到 M1 人工步骤。
- 下一步：Task 9 串联 AppState、内核健康检查、系统代理和菜单栏/主窗口。
- 下一位 Agent 如何接手：从 M1 计划 Task 9 Step 1 开始，启动链严格保持 check → start → health → system proxy 顺序。

## 2026-07-20 — M1 Task 9 AppState 与原生界面

- 已完成：先写空节点不可修改系统代理、手动节点持久化测试并观察 `AppState` 缺失的预期失败；完成固定 check → start → health → system proxy 启动事务、反向清理、订阅/手动节点持久化、节点选择/测速、退出恢复与原生菜单栏/主窗口。
- 修改文件：`Package.swift`、`Sources/kongshan/AppState.swift`、`KongshanApp.swift`、`MenuBarView.swift`、`MainWindowView.swift`、`Tests/KongshanAppTests/AppStateTests.swift`、M1 计划与记录。
- 测试结果：RED 因 `AppState` 不存在而失败；GREEN 为 AppState 定向 2/2、全量 34/34 通过，`swift build` 成功无警告；debug 进程实际启动并干净退出。
- 当前状态：Task 9 完成；空节点时开关返回可读错误且不执行系统代理命令。
- 风险/注意事项：debug 裸可执行文件未注册 LaunchServices bundle，自动可访问性工具无法按 bundle ID 读取窗口；Task 10 将对组装后 `.app` 做实际界面冒烟。
- 下一步：Task 10 完成 Info.plist、打包脚本、ad-hoc 签名与 M1 自动验证脚本。
- 下一位 Agent 如何接手：从 M1 计划 Task 10 Step 1 开始，打包后先以空节点做不改网络的界面冒烟。

## 2026-07-20 — M1 Task 10 组装、签名与验证 kongshan.app

- 已完成：先写 M1 验证脚本并观察缺少 `build_app.sh` 的预期失败；实现固定内核下载、release arm64 构建、分阶段 App 组装、ad-hoc 签名和端到端验证。
- 修改文件：`scripts/build_app.sh`、`scripts/verify_m1.sh`、M1 计划与记录；`Resources/Info.plist` 与 `.gitignore` 的计划字段/忽略项已在先前小节满足，无需重复修改。
- 测试结果：RED 为 34/34 测试通过后因 `scripts/build_app.sh` 不存在退出 127；GREEN 为 `M1 automated verification passed`，覆盖 release 构建、arm64、签名、plist、sing-box 1.13.14 和内置配置 check。
- 当前状态：Task 10 完成；可双击产物为 `dist/kongshan.app`，空节点冒烟期间进程、LaunchServices bundle 与系统状态项注册正常，无 `proxy-recovery.json`。
- 风险/注意事项：本机菜单栏管理环境将新状态项放在不可见坐标，自动界面工具无法点击“打开 kongshan”；已通过主线程采样确认 App 正常空闲（约 15 MB、0% CPU），真实菜单展开仍列入人工验收。
- 下一步：Task 11 记录产物、commit、自动验证摘要与所有未执行的真实网络验收。
- 下一位 Agent 如何接手：从 M1 计划 Task 11 Step 1 开始，不得将自动测试写成真实订阅/系统代理已验收。

## 2026-07-20 — M1 Task 11 阶段验收记录

- 已完成：固化 M1 基线提交、产物路径、自动验收命令/结果、内核版本/归档与二进制 SHA-256，并将所有真实网络、系统代理与强杀自愈项明确标为待人工验收。
- 修改文件：`docs/acceptance/M1.md`、`docs/HANDOFF.md`、`docs/PROGRESS.md`、`docs/NEXT_STEPS.md`、本日志与 M1 计划。
- 测试结果：`zsh scripts/verify_m1.sh` 再次输出 `M1 automated verification passed`；34/34 测试通过，release arm64、签名、plist、内核版本与 check 全部通过。
- 当前状态：M1 自动交付完成，可运行产物为 `dist/kongshan.app`；人工验收边界已如实记录。
- 风险/注意事项：尚未使用用户真实订阅/节点，也未真实改写当前 Mac 系统代理；不得将自动测试作为这些项目已验收的证据。
- 下一步：人工执行 M1 真实网络验收；或先为 M2 分流编写设计与分步实施计划。
- 下一位 Agent 如何接手：先读 HANDOFF、`docs/acceptance/M1.md` 和 M1 计划；如做人工验收，在首次真实代理切换前与用户确认网络环境和恢复路径。

## 2026-07-20 — M2 分流实施计划

- 已完成：对照官方 1.13 route/rule-set 文档与内置 CLI 确认字段、本地 `.srs` 验证命令和无完整 reload API；实时确认三个官方 rule-set URL 为 HTTP 200；将 M2 拆为 7 个 TDD Task。
- 修改文件：新增 `docs/superpowers/plans/2026-07-20-kongshan-m2.md`；更新 HANDOFF、PROGRESS、NEXT_STEPS 与本日志。
- 测试结果：官方 `geosite-cn.srs`、`geoip-cn.srs`、`geosite-category-ads-all.srs` 均返回 HTTP 200；`sing-box rule-set decompile --help` 可用；计划尚未修改产品代码。
- 当前状态：M2 实施计划就绪，Task 1 尚未开始。
- 风险/注意事项：不使用已移除的旧 geosite/geoip 数据库字段；完整 route 变更用快速重启，不假设不存在的热重载 API。
- 下一步：使用 executing-plans + TDD 执行 M2 Task 1 routing 值类型。
- 下一位 Agent 如何接手：从 M2 计划第一个未勾选步骤开始，每个 Task 代码、测试和记录同提交。

## 2026-07-20 — M2 Task 1 分流数据模型与校验

- 已完成：先写默认 bypass、五种规则类型、三种动作、Codable 往返和非法输入测试并观察缺少类型的预期失败；实现 Sendable/Hashable 值类型、CIDR 校验与中文错误。
- 修改文件：`Sources/KongshanCore/RoutingModels.swift`、`Tests/KongshanCoreTests/RoutingModelsTests.swift`、M2 计划与记录。
- 测试结果：RED 因 `RoutingSettings`/`CustomRouteRule` 不存在而失败；GREEN 为定向 5/5、全量 39/39 通过，无编译警告。
- 当前状态：Task 1 完成；规则可持久化排序/启停、匹配五类值并路由到直连/代理/拒绝。
- 风险/注意事项：当前仅完成数据边界，ConfigGenerator 尚未注入 route；单 IP 需以 `/32` 或 `/128` 表示。
- 下一步：Task 2 实现六级 route、本地 rule-set 定义和绕过域名归一化。
- 下一位 Agent 如何接手：从 M2 计划 Task 2 Step 1 写纯 JSON 结构失败测试。

## 2026-07-20 — M2 Task 2 六级 route 与本地 rule-set

- 已完成：先写六级顺序、五类字段、bypass 归一化、广告开关与真实内核测试并观察缺少 routing API 的预期失败；扩展纯 ConfigGenerator，保持 M1 调用默认兼容。
- 修改文件：`Sources/KongshanCore/ConfigGenerator.swift`、`Tests/KongshanCoreTests/RoutingConfigTests.swift`、M2 计划与记录。
- 测试结果：RED 因 `PreparedRuleSets`/`RoutingConfiguration`/`routing` 不存在而失败；GREEN 为定向 4/4、全量 43/43 通过，临时 binary `.srs` 由官方 CLI 编译且生成配置通过内置 sing-box 1.13.14 `check`。
- 当前状态：Task 2 完成；route 按自定义、bypass、私网、可选广告、中国规则、final 顺序生成，规则集只接收本地路径。
- 风险/注意事项：尚未下载或缓存官方 `.srs`；`*.local` 仅在 route 中归一，持久值与系统 bypass 保持原形。
- 下一步：Task 3 实现官方 rule-set 下载、解析验证、原子替换与最后成功缓存兜底。
- 下一位 Agent 如何接手：从 M2 计划 Task 3 Step 1 写 loader/validator 注入的失败测试。

## 2026-07-20 — M2 Task 3 官方 rule-set 验证与缓存兜底

- 已完成：先写成功替换、HTTP/空内容/解析失败、坏缓存和无缓存测试并观察缺少服务的预期失败；实现固定官方 URL、下载临时文件解析、成功后原子替换及旧缓存再验证。全量回归同时捕获并修复 ProcessRunner timeout 完成顺序竞态。
- 修改文件：`Sources/KongshanCore/RuleSetService.swift`、`Sources/KongshanCore/ProcessRunner.swift`、`Tests/KongshanCoreTests/RuleSetServiceTests.swift`、M2 计划与记录。
- 测试结果：RED 因 `RuleSetService` 不存在而失败；GREEN 为定向 7/7、timeout 连续 10/10、全量 50/50 通过。实时下载的 `geosite-cn` 53669 B、`geoip-cn` 33920 B、ads 8176 B 均通过内置 sing-box 1.13.14 反编译。
- 当前状态：Task 3 完成；坏下载绝不覆盖正式缓存，坏旧缓存绝不作为兜底，广告关闭时不下载 ads。
- 风险/注意事项：尚未接入 AppState；官方资源可随上游更新，程序每次使用前会以固定内核解析验证。临时真实冒烟目录留给系统临时目录自动清理。
- 下一步：Task 4 实现运行中 system bypass 事务与失败回滚。
- 下一位 Agent 如何接手：从 M2 计划 Task 4 Step 1 扩展命令记录器测试，严禁测试调用真实 networksetup。

## 2026-07-20 — M2 Task 4 运行中 system bypass 更新与回滚

- 已完成：先写仅使用恢复快照服务、恢复文件不变、无 endpoint 命令、失败全服务回滚和未启用错误测试并观察 API 缺失；实现带现有事务锁的 bypass 更新入口。
- 修改文件：`Sources/KongshanCore/SystemProxyManager.swift`、`Tests/KongshanCoreTests/SystemProxyManagerTests.swift`、M2 计划与记录。
- 测试结果：RED 因 `updateBypassDomains`/`noActiveProxySession` 不存在而失败；GREEN 为定向 8/8、全量 53/53 通过，所有测试均使用命令记录器且未调用真实 networksetup。
- 当前状态：Task 4 完成；更新不重写 `proxy-recovery.json`，任一服务失败会向快照内全部服务写回旧 bypass。
- 风险/注意事项：传入的 `rollbackTo` 必须是 AppState 当前已生效设置；Task 5 负责维护该状态与双重回滚。
- 下一步：Task 5 串联 rules.json、规则集、配置 check、相同运行时参数快速重启和 bypass 事务。
- 下一位 Agent 如何接手：从 M2 计划 Task 5 Step 1 开始，测试不可让真实 SystemProxyManager 修改本机网络。

## 2026-07-20 — M2 Task 5 rules.json、快速重启与双重回滚

- 已完成：先为 process restart、rules.json 离线持久化、相同运行时热更新、内核健康失败、bypass 失败和旧核心恢复失败编写测试并观察缺少 API 的预期失败；串联完整启动/更新/回滚事务。
- 修改文件：`Sources/KongshanCore/SingBoxProcess.swift`、`Sources/kongshan/AppState.swift`、`Tests/KongshanCoreTests/SingBoxProcessTests.swift`、`Tests/KongshanAppTests/AppStateTests.swift`、M2 计划与记录。
- 测试结果：restart RED 因 API 不存在失败，AppState RED 因 routing/ruleSetService 缺失失败；GREEN 为 AppState 7/7、全量 59/59。真实 sing-box/Clash API 快速重启单次实测 0.270651417 秒，低于 2 秒目标。
- 当前状态：Task 5 完成；启动顺序为规则集 → generate/check/start/health → system proxy，在线改动复用 runtime 且不先关闭系统代理。
- 风险/注意事项：失败恢复链已自动覆盖，但 system proxy 在测试中仍是记录器；只有旧内存配置也无法恢复时才恢复系统代理并进入 failed。
- 下一步：Task 6 实现原生规则编辑器、拖拽排序、两类 bypass 与广告开关。
- 下一位 Agent 如何接手：从 M2 计划 Task 6 Step 1 开始，View 只编辑副本并调用 `applyRoutingSettings`，不得直接生成配置。

## 2026-07-20 — M2 Task 6 原生规则编辑器与 bypass 界面

- 已完成：新增“规则”侧栏和原生编辑页，支持五类匹配、三种动作、策略组、启停/删除/拖拽排序、域名与 CIDR bypass、广告开关、恢复默认、放弃与统一应用；菜单栏展示分流摘要。
- 修改文件：`Sources/kongshan/RoutingView.swift`、`Sources/kongshan/MainWindowView.swift`、`Sources/kongshan/MenuBarView.swift`、`Sources/kongshan/AppState.swift`、M2 计划与记录。
- 测试结果：`swift build`、release App 组装、codesign 严格校验和全量 59/59 测试通过；空节点进程约 15.5 MB、主线程正常空闲，无代理恢复快照。
- 当前状态：Task 6 完成；View 仅维护编辑副本并调用 AppState 事务，不直接生成配置或操作网络。
- 风险/注意事项：本机状态栏管理器使 Computer Use 获取主窗口超时，未完成自动视觉点击；该限制与 M1 相同，需在人工验收中点击“打开 kongshan”核对布局。
- 下一步：Task 7 编写 M2 自动验证脚本、完整运行并记录产物与人工边界。
- 下一位 Agent 如何接手：从 M2 计划 Task 7 Step 1 开始，先让缺失脚本测试失败，再实现 fixture 与官方 `.srs` 冒烟。

## 2026-07-20 — M2 Task 7 自动验收与人工边界

- 已完成：先运行缺失 `verify_m2.sh` 并观察预期失败；实现全量测试、release 打包、签名、三个官方 `.srs` 解析和六级 route fixture 的一键验收，并固化 M2 验收记录。
- 修改文件：`scripts/verify_m2.sh`、`docs/acceptance/M2.md`、M2 计划与全部项目记录。
- 测试结果：`M2 automated verification passed`；59/59 测试、arm64、codesign、plist、sing-box 1.13.14、三个实时官方规则集和完整 route `check` 全部通过；热重启本轮 0.216799667 秒。
- 当前状态：M2 自动交付完成，产物为 `dist/kongshan.app`（约 50 MB）。
- 风险/注意事项：真实中国直连、广告拒绝、进程规则、route/system bypass 双处命中和真实浏览流量中断仍待人工；TUN 第三处 bypass 属于 M3。
- 下一步：为 M3 TUN 编写可执行计划，重点先解决提权与恢复边界。
- 下一位 Agent 如何接手：先读 `docs/acceptance/M2.md` 与 M2 计划，再从 M3 计划/设计门禁开始；不得直接猜测 macOS TUN 权限实现。

## 2026-07-20 — M3 TUN 实施计划

- 已完成：使用官方 sing-box 1.13 TUN/route 文档与 Apple 权限文档核验字段、回环保护、提权和 shell 安全边界；将 M3 拆为 7 个 TDD Task，并明确 DNS 留在 M4。
- 修改文件：`docs/superpowers/plans/2026-07-20-kongshan-m3.md` 与全部项目记录。
- 测试结果：strict=false、双栈地址、auto_route、route_exclude_address、system stack 和 auto_detect_interface 的本地 fixture 通过内置 sing-box 1.13.14 `check`；计划尚未修改产品代码。
- 当前状态：M3 实施计划就绪，Task 1 未开始。
- 风险/注意事项：每次真实 TUN 启停可能触发系统管理员授权；自动测试不得触发。strict_route 的 macOS DNS语义不得夸大。
- 下一步：M3 Task 1 实现模式模型和纯 TUN 配置。
- 下一位 Agent 如何接手：使用 executing-plans + TDD，从 M3 计划首个未勾选步骤开始。

## 2026-07-20 — M3 Task 1 模式模型与纯 TUN 配置

- 已完成：先写模式 Codable、TUN 默认值、CIDR 第三处注入、回环保护、M1 兼容和 strict 双态测试并观察类型缺失；实现纯 mixed/tun inbound 分支。补充测试发现并修复 route exclude 未使用 trim 后 CIDR。
- 修改文件：`Sources/KongshanCore/ProxyMode.swift`、`Sources/KongshanCore/ConfigGenerator.swift`、`Tests/KongshanCoreTests/TunConfigTests.swift`、M3 计划与记录。
- 测试结果：首个 RED 因 ProxyMode/TunSettings/参数不存在；第二个 RED 捕获未 trim CIDR；GREEN 为定向 5/5、全量 64/64，strict false/true 均通过真实 1.13.14 check。
- 当前状态：Task 1 完成；TUN 使用双栈地址、auto_route、system stack、strict 开关、CIDR route_exclude 和 auto_detect_interface。
- 风险/注意事项：仅完成配置生成与静态检查，没有 root/TUN 网络副作用；域名无法作为静态系统路由排除。
- 下一步：Task 2 实现安全提权命令白名单和 0600 FIFO transport。
- 下一位 Agent 如何接手：先写单引号路径、坏 PID、大于 pipe buffer 数据与清理失败测试，不运行真实 osascript 授权。

## 2026-07-20 — M3 Task 2 安全提权命令与内存 FIFO

- 已完成：先写含单引号路径、坏 PID、AppleScript 编译、大数据传输和失败清理测试并观察 API 缺失；实现固定 start/stop 命令与 POSIX FIFO transport。
- 修改文件：`Sources/KongshanCore/PrivilegedLauncher.swift`、`Tests/KongshanCoreTests/PrivilegedLauncherTests.swift`、M3 计划与全部项目记录。
- 测试结果：RED 因 PrivilegedCommandBuilder/PrivilegedLauncherError/POSIXConfigPipe 缺失而编译失败；GREEN 为定向 6/6、全量 70/70，262144 字节通过真实 FIFO + `/bin/cat` 完整传输。
- 当前状态：Task 2 完成；runtime 目录强制 0700、FIFO 为 0600，成功/失败后均 unlink，阻塞写入不占用 Swift 协作执行器。
- 风险/注意事项：测试只调用 `osacompile`，没有执行提权脚本或真实 TUN；授权返回后的 PID 身份与恢复文件由 Task 3 实现。
- 下一步：Task 3 实现特权 TUN 生命周期、进程身份复核和崩溃恢复记录。
- 下一位 Agent 如何接手：从 M3 计划 Task 3 Step 1 写注入 fake authorizer/inspector 的失败测试，所有自动测试严禁真实授权。
