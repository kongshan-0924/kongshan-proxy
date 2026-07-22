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

## 2026-07-20 — M3 Task 3 特权 TUN 生命周期与崩溃恢复

- 已完成：先写启动记录、授权异常、PID 身份、停止保留、陈旧记录、重启恢复与敏感值检查并观察生命周期 API 缺失；实现可注入 actor 与默认 osascript/ps 边界。
- 修改文件：`Sources/KongshanCore/PrivilegedLauncher.swift`、`Tests/KongshanCoreTests/PrivilegedLauncherTests.swift`、M3 计划与全部项目记录。
- 测试结果：RED 因 PrivilegedLauncher/PrivilegedProcessRecord/authorization 错误类型缺失而失败；GREEN 为定向 13/13、全量 77/77，`git diff --check` 通过。
- 当前状态：Task 3 完成；`tun-recovery.json` 仅保存 PID、规范内核路径和时间，启/停均验证进程身份，授权失败保留恢复能力。
- 风险/注意事项：自动测试全部注入 fake authorizer，仅对 osascript 参数/结果做纯映射，未触发系统授权。
- 下一步：Task 4 实现 AppState 模式持久化、互斥启停、切换与初始/退出恢复。
- 下一位 Agent 如何接手：从 M3 计划 Task 4 Step 1 先写旧 settings 兼容与 system↔TUN 序列测试，fake launcher 必须能证明互斥不变量。

## 2026-07-20 — M3 Task 4 AppState 模式持久化与互斥切换

- 已完成：先写旧 settings 解码、离线首选、system↔TUN 序列、新模式失败、初始恢复与退出失败测试并观察 API 缺失；实现可注入 PrivilegedLaunching 与互斥状态机。
- 修改文件：`Sources/KongshanCore/PrivilegedLauncher.swift`、`Sources/kongshan/AppState.swift`、`Tests/KongshanAppTests/AppStateTests.swift`、M3 计划与全部项目记录。
- 测试结果：RED 因 PrivilegedLaunching/preferredMode/activeMode/switchMode 缺失失败；GREEN 为 AppState 12/12、全量 82/82，`git diff --check` 通过。
- 当前状态：Task 4 完成；TUN 不调用 networksetup，两种模式切换均先完整停止旧模式，新模式失败不自动回启旧模式。
- 风险/注意事项：TUN 健康失败后若特权停止也失败，activeMode 保留 `.tun` 以如实反映可能仍在接管；Task 5 尚需处理 TUN 在线规则更新。
- 下一步：Task 5 实现 TUN 相同 runtime 更新、旧 root 配置回滚与双重失败关闭。
- 下一位 Agent 如何接手：从 M3 计划 Task 5 Step 1 扩展 mode fixture，断言 config runtime 值复用、CIDR 更新且 networksetup 调用数不变。

## 2026-07-20 — M3 Task 5 TUN 在线分流更新与回滚

- 已完成：先用安全假内核写 runtime 复用、CIDR 更新、零 networksetup、新配置失败回滚和双重失败测试；观察当前错用普通 SingBoxProcess 的 RED，再按 activeMode 实现 TUN 事务。
- 修改文件：`Sources/kongshan/AppState.swift`、`Tests/KongshanAppTests/AppStateTests.swift`、`Tests/KongshanCoreTests/PrivilegedLauncherTests.swift`、M3 计划与全部项目记录。
- 测试结果：RED 显示旧实现仍保持 on/tun 且没有特权重启/回滚；GREEN 为定向 3/3、AppState 15/15、全量 85/85，`git diff --check` 通过。
- 当前状态：Task 5 完成；新配置成功后才持久化 rules，失败保留旧 settings，新旧都无法启动时 activeMode/runtime 清空。
- 风险/注意事项：本节不启动真实 TUN；全量回归曾暴露测试 `Process.waitUntilExit` 偶发不返回，已用有界 done marker 修复并确认无遗留测试进程。
- 下一步：Task 6 实现原生模式与 strict_route UI，运行 debug/release 无授权冒烟。
- 下一位 Agent 如何接手：从 M3 计划 Task 6 Step 1 开始，文案不得宣称 macOS DNS 必然无泄漏。

## 2026-07-20 — M3 Task 6 原生模式与 strict_route 界面

- 已完成：先为 strict 离线保存、在线特权重启与失败回滚写 RED/GREEN 测试；实现 Dashboard/设置模式选择、strict 开关、准确 DNS 边界文案和菜单栏模式图标。
- 修改文件：`Sources/kongshan/AppState.swift`、`Sources/kongshan/MainWindowView.swift`、`Sources/kongshan/MenuBarView.swift`、`Tests/KongshanAppTests/AppStateTests.swift`、M3 计划与全部项目记录。
- 测试结果：RED 因 `applyTunSettings` 缺失失败；GREEN 为 strict 3/3、AppState 18/18、全量 88/88；`swift build`、release App、arm64 与 codesign 通过。
- 当前状态：Task 6 完成；strict 说明明确“可能影响局域网/虚拟化，macOS DNS 防泄漏待 M4 验证”，没有过度承诺。
- 风险/注意事项：空节点 App 仅启动 2 秒后退出，未点击 TUN、未出现恢复文件或授权；本机状态栏管理导致自动视觉点击仍不可靠。
- 下一步：Task 7 实现 M3 一键自动验收、运行并写入 `docs/acceptance/M3.md`。
- 下一位 Agent 如何接手：从 M3 计划 Task 7 Step 1 先运行缺失脚本得到预期失败，自动化只做纯配置/check/注入测试。

## 2026-07-20 — M3 Task 7 自动验收与人工边界

- 已完成：先运行缺失 `verify_m3.sh` 并观察预期失败；实现全量测试、release 打包签名、三个官方规则集与 strict 关/开 TUN fixture 的一键自动验收，并固化人工授权边界。
- 修改文件：`scripts/verify_m3.sh`、`docs/acceptance/M3.md`、M3 计划与全部项目记录。
- 测试结果：`M3 automated verification passed`；88/88 测试、arm64、codesign、plist、sing-box 1.13.14、三个官方规则集以及两份 TUN 配置 `check` 全部通过。
- 当前状态：M3 自动交付完成，产物为 `dist/kongshan.app`（约 51 MB）；验收后无 kongshan/sing-box 测试进程和 TUN recovery/FIFO 残留。
- 风险/注意事项：本轮未请求管理员授权或启动真实 TUN；utun、出口 IP、域名/CIDR 真实路径、关闭恢复、strict 兼容性、强杀自愈和 DNS 防泄漏均未冒充自动通过。
- 下一步：编写并执行 M4 打磨计划；如先人工验收 M3，按 `docs/acceptance/M3.md` 并在可接受网络中断的环境执行。
- 下一位 Agent 如何接手：先读 HANDOFF、M3 验收、原始需求和 M3 计划；M4 开始前先拆分任务，真实 TUN 操作前先确认恢复路径。

## 2026-07-20 — M4 打磨实施计划

- 已完成：对照原始需求逐项盘点 M4 缺口；核验 sing-box 1.13.14 双 DoH、bootstrap resolver、DNS hijack 与 Clash `/traffic`、`/connections`、`/logs` 实际字段；拆为 9 个 TDD Task。
- 修改文件：新增 `docs/superpowers/plans/2026-07-20-kongshan-m4.md`，更新 HANDOFF、PROGRESS、NEXT_STEPS 与本日志。
- 测试结果：打包内核对新格式双 DoH、`route.default_domain_resolver=dns-cn` 和 sniff/hijack fixture 执行 `check`，exit 0；未修改产品代码。
- 当前状态：M4 计划就绪，首个未完成项为 Task 1 DNS 值类型与纯配置。
- 风险/注意事项：system 模式不能宣称全局 DNS 接管；remote DoH 经代理时必须用独立 direct DNS bootstrap 代理节点；所有 WebSocket 必须随页面消失取消。
- 下一步：先写 DNSConfigTests RED，再实现默认/自定义 DNS、TUN hijack 和四份真实配置 check。
- 下一位 Agent 如何接手：使用 executing-plans + TDD，从 M4 计划 Task 1 Step 1 开始；每个小节继续同步记录并提交。

## 2026-07-20 — M4 Task 1 DNS 值类型与纯配置

- 已完成：先写默认/非法 DoH、CN DNS、custom domain bootstrap、TUN hijack 与真实内核测试并观察 API 缺失；实现双 DoH 纯配置。全量回归进一步发现并修复 `check` 不报告、运行期才拒绝的显式 direct detour。
- 修改文件：`Sources/KongshanCore/DNSSettings.swift`、`Sources/KongshanCore/ConfigGenerator.swift`、`Tests/KongshanCoreTests/DNSConfigTests.swift`、M4 计划与全部项目记录。
- 测试结果：首个 RED 因 `DNSSettings`/参数缺失；运行期 RED 日志为 `detour to an empty direct outbound makes no sense`；GREEN 为 DNS 6/6、全量 94/94，debug build 与 diff check 通过。
- 当前状态：默认 CN DoH 直连、remote DoH 经自动选择，代理节点用 CN DoH bootstrap；自定义域名 DoH 有有限直连 bootstrap；TUN 捕获 DNS，system 不伪称全局捕获。
- 风险/注意事项：仅 `sing-box check` 不足以发现所有服务初始化错误，已新增真实启动/Clash health 回归；DNS 泄漏仍需真实网络人工验收。
- 下一步：Task 2 实现 DNS settings 旧文件兼容、离线/在线事务、失败回滚和 UI。
- 下一位 Agent 如何接手：从 M4 计划 Task 2 Step 1 开始，扩展 AppState fixture，严禁测试调用真实 networksetup 或 TUN 授权。

## 2026-07-20 — M4 Task 2 DNS 持久化、在线事务与设置 UI

- 已完成：先写旧 settings、离线保存、system/TUN 在线成功及两类回滚测试并观察 API 缺失；实现统一配置构造、DNS 应用事务、诊断快照和草稿式高级设置 UI。
- 修改文件：`Sources/kongshan/AppState.swift`、`Sources/kongshan/MainWindowView.swift`、`Tests/KongshanAppTests/AppStateTests.swift`、M4 计划与全部项目记录。
- 测试结果：RED 因 `dnsSettings/applyDNSSettings` 不存在；GREEN 为定向 5/5、全量 99/99，release arm64 App、codesign strict 与 `git diff --check` 通过。
- 当前状态：DNS 可离线保存，在线 system 快速重启不重复启用 networksetup，TUN 使用特权事务；失败均保留旧 DNS 与旧运行配置。
- 风险/注意事项：自动测试只用 networksetup 记录器与 fake TUN launcher；没有发起管理员授权或真实 DoH 查询。磁盘完全不可写时的落盘后置失败需最终审视。
- 下一步：Task 3 实现三类 Clash WebSocket 流与一次 version REST。
- 下一位 Agent 如何接手：从 M4 计划 Task 3 Step 1 开始，底层流必须可注入、可取消，secret 仅放 Bearer 内存 header。

## 2026-07-20 — M4 Task 3 Clash API WebSocket 流模型

- 已完成：先写三端点 URL/Bearer/payload、坏消息、取消传播和 version 测试并观察 API 缺失；实现 URLSession WebSocket 到 typed AsyncThrowingStream 的桥接。
- 修改文件：`Sources/KongshanCore/ClashAPIClient.swift`、`Tests/KongshanCoreTests/ClashStreamingTests.swift`、`Tests/KongshanCoreTests/ClashAPIClientTests.swift`、M4 计划与全部项目记录。
- 测试结果：RED 因 traffic/connection/log stream 与 version 不存在；GREEN 为 streaming 5/5、REST 5/5、全量 104/104，`swift build` 和 diff check 通过。
- 当前状态：traffic 解码 up/down，connections 解码数量/内存，logs 映射等级/时间；consumer cancel 会关闭底层 stream。
- 风险/注意事项：当前 data 层不自动重连，防止后台无界循环；Task 4/5 必须按页面可见性创建和取消。真实 URLSession 与打包内核的长期流留到 Dashboard 集成/最终验收。
- 下一步：Task 4 实现 Dashboard AppState 生命周期、有界 60 点缓冲和 Swift Charts UI。
- 下一位 Agent 如何接手：从 M4 计划 Task 4 Step 1 开始，为 AppState 注入 stream client/factory，严禁用 Timer 或 REST 轮询。

## 2026-07-20 — M4 Task 4 Dashboard 实时指标与 60 秒曲线

- 已完成：先写有界 60 点、幂等订阅、离线禁止建流、断线 warning 与停止取消测试并观察 API 缺失；实现 AppState 会话生命周期、运行元数据和 Swift Charts Dashboard。
- 修改文件：`Sources/kongshan/AppState.swift`、新增 `Sources/kongshan/DashboardView.swift`、`Sources/kongshan/MainWindowView.swift`、`Tests/KongshanAppTests/AppStateTests.swift`、M4 计划与全部项目记录。
- 测试结果：RED 因 `ClashClientFactory`/Dashboard 状态与生命周期 API 缺失而编译失败；GREEN 为 Dashboard 3/3、全量 107/107，debug/release 构建、arm64 和 codesign strict 通过。
- 当前状态：Dashboard 只在页面可见且代理开启时建立 traffic/connections WebSocket；离开、停止或配置重载均取消，曲线严格保留最近 60 点。
- 风险/注意事项：无节点 release App 启动后进程稳定且 CPU 0.0%，未生成运行文件或启动内核；菜单栏 UIElement 仍无法由当前桌面可访问性工具附着，因此本节无自动视觉截图。
- 下一步：Task 5 实现有界内核日志存储、实时日志页、等级切换与安全导出。
- 下一位 Agent 如何接手：从 M4 计划 Task 5 Step 1 写 KernelLogStore RED；内存上限 2000 行，导出不得包含 config、secret 或订阅 URL。

## 2026-07-20 — M4 Task 5 有界内核日志、实时页与导出

- 已完成：先写 2000 行缓冲、5 MiB 轮转、超大写入、已知文件导出、普通内核 stdout/stderr、流生命周期与断线测试；实现日志 actor、事件驱动 TUN 轮转和原生日志页/导出。
- 修改文件：新增 `Sources/KongshanCore/KernelLogStore.swift`、`Sources/kongshan/LogsView.swift`、`Tests/KongshanCoreTests/KernelLogStoreTests.swift`；修改 SingBoxProcess、PrivilegedLauncher、AppState、MainWindowView 及相关测试/记录。
- 测试结果：RED 分别为 `KernelLogStore`、`logStore` 接口和 AppState 日志 API 缺失；GREEN 为日志定向 12/12、全量 119/119，debug/release、arm64、codesign strict 与 diff check 通过。
- 当前状态：日志页只在可见+代理开启时订阅；info/warning/error 切换先取消旧流，可暂停自动滚动/清空/导出；普通与 TUN 日志均保留当前+1 份轮转。
- 风险/注意事项：自动测试未启动真实 TUN 或真实节点 `/logs`；TUN 轮转使用 DispatchSource 写事件而非轮询，日志写错误只记 warning 不中断代理。Swift 6.3 方法引用 IRGen 崩溃已用显式闭包稳定规避。
- 下一步：Task 6 实现无轮询订阅定时更新、缓存保留告警和可注入本地通知。
- 下一位 Agent 如何接手：从 M4 计划 Task 6 Step 1 开始；自动测试只用 fake sleeper/notification，不得请求真实通知权限。

## 2026-07-20 — M4 Task 6 订阅定时更新与非阻塞通知

- 已完成：先写默认 24h、1–168 小时校验、最早到期、过期立即执行、取消/重排、旧设置兼容、缓存回退和 fake 通知测试；实现一次性 sleep 调度、失败保留旧节点、按需本地通知及原生设置入口。
- 修改文件：新增 `Sources/kongshan/SubscriptionUpdateScheduler.swift`、`Sources/kongshan/NotificationService.swift`、`Tests/KongshanAppTests/SubscriptionUpdateSchedulerTests.swift`；修改 `AppState.swift`、`MainWindowView.swift`、`AppStateTests.swift`、M4 计划与全部项目记录。
- 测试结果：RED 因 scheduler/settings/notification API 缺失；GREEN 为调度器 4/4、相关 AppState 3/3、全量 126/126，release arm64、codesign strict、diff check 与无节点冷启动通过。
- 当前状态：每次只安排一个可取消睡眠任务，完成后按订阅时间重排；失败或 `usedCache=true` 不替换旧节点/成功时间，记 warning 并尝试通知；权限拒绝只追加 warning。
- 风险/注意事项：自动测试没有发送真实通知或使用真实订阅；通知权限只在首次实际失败需要通知时按需请求。无节点冒烟约 70 MB、0% CPU，未启动内核或生成接管恢复文件。
- 下一步：Task 7 实现 `SMAppService.mainApp` 开机自启状态映射、用户开关和系统设置入口。
- 下一位 Agent 如何接手：从 M4 计划 Task 7 Step 1 开始；测试只用 fake manager，初始化只能读状态，禁止静默注册登录项。

## 2026-07-20 — M4 Task 7 SMAppService 开机自启

- 已完成：先写四状态映射、初始化只读、用户启停、拒绝、待系统批准和设置跳转测试；实现 `SMAppService.mainApp` 适配及原生设置区。
- 修改文件：新增 `Sources/kongshan/LoginItemManager.swift`；修改 `Sources/kongshan/AppState.swift`、`Sources/kongshan/MainWindowView.swift`、`Tests/KongshanAppTests/AppStateTests.swift`、M4 计划与全部项目记录。
- 测试结果：RED 因 LoginItem manager/status/AppState API 缺失；GREEN 为 AppState 38/38、全量 131/131，release arm64、codesign strict、diff check 与空节点 `.app` 冷启动通过。
- 当前状态：初始化只读取系统实际状态，只有用户开关会 register/unregister；requiresApproval 不重复注册，仅提供打开系统登录项设置与刷新状态。
- 风险/注意事项：自动测试全部用 actor fake；未真实注册或注销本机登录项。非 `.app` 测试宿主返回 notFound，避免 XCTest 接触系统服务。
- 下一步：Task 8 实现普通/TUN 内核事件驱动退出监控与 10 秒最多 3 次崩溃自愈。
- 下一位 Agent 如何接手：从 M4 计划 Task 8 Step 1 开始；普通模式可用普通用户假内核退出测试，TUN 只能 fake，主动 stop/reload 必须先取消 monitor。

## 2026-07-20 — M4 Task 8 普通/TUN 内核崩溃自愈

- 已完成：先写 10 秒滚动限流、精确 PID 退出事件、取消抑制、currentPID、真实普通内核 SIGKILL、主动停止、重启失败和 fake TUN 第 4 次终止测试；实现统一崩溃自愈状态机。
- 修改文件：新增 `Sources/KongshanCore/CrashRestartLimiter.swift`、`Sources/KongshanCore/ProcessExitMonitor.swift`、`Tests/KongshanCoreTests/CrashRestartTests.swift`；修改 SingBoxProcess、AppState、NotificationService、AppStateTests、SingBoxProcessTests、M4 计划与全部项目记录。
- 测试结果：RED 因 limiter/monitor/currentPID/AppState 注入缺失；首次完整 AppState 回归发现主动 DNS/分流重载误判并触发额外重启，修复后 AppState 42/42、全量 137/137，release arm64、codesign strict、diff check 与无节点冒烟通过。
- 当前状态：普通/TUN 均用 `DispatchSourceProcess(.exit)` 监听精确 PID；主动 stop/reload 先取消，成功/回滚后绑定新 PID；10 秒前 3 次自动重启，第 4 次清理接管并通知。
- 风险/注意事项：真实普通用户 sing-box SIGKILL 路径已验证且未重复写 networksetup；TUN 仍只用 fake launcher/monitor，真实 root PID 监听、授权重启和通知需人工。非 `.app` 测试宿主已硬禁止真实通知中心。
- 下一步：Task 9 编写 `verify_m4.sh`、性能采样、README/M4 验收记录，并区分自动与真实人工边界。
- 下一位 Agent 如何接手：从 M4 计划 Task 9 Step 1 开始；脚本只能无节点启动，不得注册登录项、改 networksetup、请求 TUN 或通知权限，最终行必须为 `M4 automated verification passed`。

## 2026-07-20 — M4 Task 9 性能、完整自动验收与人工边界

- 已完成：先运行缺失 `verify_m4.sh` 获得预期 RED；实现复用 M3 回归、M4 定向门禁、隔离无节点启动、5 次 CPU/RSS、socket/子进程/recovery/FIFO 与精确 TERM 的一键验收；完成 README、M4 验收和依赖声明。
- 修改文件：新增 `scripts/verify_m4.sh`、`README.md`、`docs/acceptance/M4.md`；修改 `Resources/THIRD_PARTY_NOTICES.md`、M4 计划与全部项目记录。
- 测试结果：完整脚本执行 137/137 测试并覆盖官方规则集/release/签名/M4 定向项；稳态 5 次 CPU 0.0%、平均 0.000%、最大 RSS 73,984 KB，最终输出 `M4 automated verification passed`。缺产物、1 KB RSS、注入 recovery 三个负向场景均失败。
- 当前状态：M1–M4 自动交付完成，arm64 ad-hoc 产物为 `dist/kongshan.app`（约 51 MB）；脚本结束无 App/内核/临时目录或恢复残留。
- 风险/注意事项：真实订阅/节点、系统代理浏览、root TUN、三处绕过、DNS leak、登录项批准、通知 UI、强杀 App 和 24h Instruments/Energy Impact 未冒充自动通过。
- 下一步：按 `docs/acceptance/M4.md` 在可接受网络中断和管理员授权的环境逐项完成人工验收；完成前原始“全部通过”清单保持未最终勾选。
- 下一位 Agent 如何接手：先读 README 与 M1–M4 acceptance；人工操作前确认真实订阅、网络恢复路径和授权窗口，每完成一项把证据追加到 M4 验收及 SESSION_LOG。

## 2026-07-20 — 双击启动与菜单栏位置诊断

- 已完成：复现并区分两个界面现象；确认 `kongshan` 进程正常运行，但当前没有创建任何主窗口；确认菜单栏排序由 Bartender 6 接管。
- 修改文件：仅更新项目记录；未修改产品代码、代理设置或 TUN 状态。
- 测试结果：`lsappinfo` 显示 PID 82372 为 `type="UIElement"`；Core Graphics 窗口枚举结果为 `COUNT=0`；`Info.plist` 为 `LSUIElement=true`；代码只有菜单项调用 `openWindow(id: "main")`，启动路径没有显式打开窗口。Computer Use 附着超时，与无可访问主窗口的结果一致。
- 当前状态：双击只启动菜单栏代理进程，不会出现前台主窗口；新状态项的屏幕和顺序由 macOS/Bartender 决定，应用自身未设置且也不能指定菜单栏坐标。
- 风险/注意事项：修复启动窗口时需保留登录启动的静默常驻体验，避免开机登录时强制弹窗；Bartender 内的显示位置需要由用户在 Bartender 中调整，产品代码只能保证状态项正常注册。
- 下一步：为“用户双击/重新打开”增加显式主窗口展示与激活，同时让登录项启动保持菜单栏静默；完成后重打包并人工验证双击、关闭窗口后重开、Bartender 可见性三条路径。
- 下一位 Agent 如何接手：先为启动/重新打开行为补测试或可验证边界，再最小修改 `KongshanApp.swift`/AppDelegate；不要尝试用私有 API 控制状态项坐标。

## 2026-07-20 — 修复双击无窗口并按 Stash 风格重做界面

- 已完成：修复双击不出主窗口；重做菜单栏托盘面板、Dashboard、节点、规则、日志页视觉；新增共享样式层；顺带发现并修复绕过列表串行的真实 bug。
- 修改文件：新增 `Sources/kongshan/Theme.swift`、`Tests/KongshanAppTests/RenderSnapshotTests.swift`；重写 `KongshanApp.swift`、`MenuBarView.swift`、`DashboardView.swift`、`MainWindowView.swift`；修改 `RoutingView.swift`、`LogsView.swift`、`AppState.swift`（menuBarSymbol）。
- 测试结果：`swift test` 138 项通过（1 项快照工具按 env 跳过）、0 失败；`zsh scripts/verify_m4.sh` 输出 `M4 automated verification passed`，5 次采样平均 CPU 0.040%、最大 RSS 118,336 KB（低于 150 MB 红线）。
- 当前状态：`open dist/kongshan.app` 实测 CGWindowList 可见窗口数 1（此前为 0）。托盘改为 `.menuBarExtraStyle(.window)` 自绘面板，不建立任何 WebSocket。

### 窗口修复的关键诊断

- 先按“人工启动会激活应用”实现，实测失败。探针数据：`didFinishLaunching isDefault=true`、`isActive=false`、`ppid=1`、`XPC_SERVICE_NAME=application.com.kaysen.kongshan.*`、`didBecomeActive` 完全不触发。
- 结论：LSUIElement 应用启动时不会被激活，且环境变量与登录项同形，无法据此区分启动来源。
- 最终判据：`LoginItemManager().currentStatus() != .enabled` 才在启动时展示主窗口；配合 `applicationShouldHandleReopen` 覆盖“已在运行时再次双击”。
- 副作用修复：`AppState` 改由 AppDelegate 直接持有。此前靠视图 `onAppear` 注入，用户没打开过菜单时 `applicationShouldTerminate` 会拿到 nil，退出时不还原系统代理。
- 主窗口改为 AppDelegate 自建 `NSWindow` + `NSHostingView`，去掉 SwiftUI `Window` scene；窗口打开期间切 `.regular`（恢复菜单栏与 ⌘Q/⌘W），`windowWillClose` 切回 `.accessory`。

### 发现并修复的既有 bug

- 规则页两个绕过列表都用 `ForEach(indices, id: \.self)` 且结构相同，SwiftUI 判为同一批视图身份，导致「绕过域名」与「绕过 IP / CIDR」互相显示对方内容。
- 探针验证：域名设为 `AAA/BBB` 时，域名区显示的是 `127.0.0.0/8`、`10.0.0.0/8`。
- 修复：抽出 `BypassListSection`，行上加 `.id("\(identity)-\(index)")` 区分两组身份；重新渲染确认两列表各自正确。

### 视觉自查方式

- 本机终端无屏幕录制权限，`screencapture` 只能得到全黑图；`osascript` 无辅助功能权限。
- 改用 `RenderSnapshotTests`：NSWindow + NSHostingView + `cacheDisplay` 离屏出图，可正确渲染 ScrollView 内容与 AppKit 原生控件（`ImageRenderer` 两者都渲染不出来）。
- 运行：`KONGSHAN_SNAPSHOT_DIR=/tmp/kongshan-shots swift test --filter RenderSnapshotTests`；不设该环境变量时自动跳过。
- 据此修掉：协议标签 `SHADOWSOCKS` 撑成两行（改短名）、指标卡 4+2 残行（改固定 3 列）、图表占位把卡片撑高数百点（`minHeight` 改 `frame(height:)`）。
- 已核对浅色与深色两套外观。

- 风险/注意事项：NavigationSplitView 侧栏在 `cacheDisplay` 下抓不到内容（对照组证明普通 `.sidebar` List 可以），侧栏视觉未经离屏验证，需人工确认。托盘面板刻意不显示实时速率——两个消费者共用 `isDashboardVisible` 布尔量会互相取消订阅，改造会破坏既有幂等测试。窗口首次打开位置由 `window.center()` 决定，多显示器下可能不在主屏，移动后由 `setFrameAutosaveName` 记住。
- 下一步：人工确认侧栏、托盘面板交互与 Bartender 可见性；随后继续 `docs/acceptance/M4.md` 的真实网络人工验收。
- 下一位 Agent 如何接手：改界面前先跑 `RenderSnapshotTests` 拿到基线图；不要用 `ImageRenderer`。动窗口逻辑前先读本节的探针结论，别再用激活状态判断启动来源。

## 2026-07-20 — 按 Stash 截图二次调整界面与交互

- 已完成：托盘从自绘面板改回原生菜单并按 Stash 操作逻辑重组；仪表盘改为 Stash 式白卡布局；侧栏加分组；页头加接管方式胶囊开关。
- 修改文件：`MenuBarView.swift`（整体重写）、`DashboardView.swift`（整体重写）、`Theme.swift`、`MainWindowView.swift`、`KongshanApp.swift`、`RoutingView.swift`、`LogsView.swift`、`RenderSnapshotTests.swift`。
- 测试结果：`swift build` 无错误无警告；`zsh scripts/verify_m4.sh` 输出 `M4 automated verification passed`。
- 当前状态：主窗口 1000×680 下六张指标卡两行三列，白卡浮于灰底，深浅色均已离屏核对。

### 托盘按 Stash 重做（关键决定）

- 上一版做成 `.menuBarExtraStyle(.window)` 自绘面板，但用户提供的 Stash 截图显示其托盘是**原生菜单**：快捷键右对齐、子菜单带当前选择、开关是勾选项。
- 因此去掉 `.menuBarExtraStyle(.window)`，回到原生菜单，结构为：状态文字 / 打开仪表盘 ⌘D / 接管方式子菜单（inline Picker 出勾选）/ 节点子菜单（按订阅分 Section，显示延迟与勾选）/ 开启代理 ⌘S / 登录时启动 / 测速全部 ⌘T / 刷新订阅 ⌘R / 错误提示 / 退出 ⌘Q。
- 原生菜单同时解决了大量节点时自绘列表要限高滚动的问题。`Theme.PanelRowButton` 与 `panelWidth` 随之删除。

### 视觉层次的关键修正

- 首版卡片用 `.background` / `.background.secondary`，浅色下两者几乎同色，完全分不出层次（离屏截图确认）。
- 改为 `Theme.cardFill = controlBackgroundColor`（浅色为白）、`Theme.pageFill = windowBackgroundColor`，卡片加 0.07 投影，才得到 Stash 那种白卡浮于灰底的效果。
- 指标卡改为 Stash 结构：左上彩色圆角图标块 + 右上角标 + 底部说明与大号数值。

### 一次 CPU 尖峰的排查（结论：非本项目代码）

- `verify_m4.sh` 出现平均 CPU 0.780%、单次尖峰 4.3%，高于历史的 0.040%。
- `sample` 抓栈：4776 个样本中 4719 在 `mach_msg` 空等，实际工作几乎全部集中在
  `FBSSceneObserver scene:didUpdateSettings:` → `NSStatusItem _updateReplicant:` → `_redrawReplicantSnapshot:`。
- 「replicant」是第三方菜单栏管理器复制状态项的机制；本机 Bartender 6 与其 XPC 服务在运行，反复触发状态项快照重绘。
- 系统静置后连续 20 次采样：CPU 全部 0.0%，RSS 89,632 KB。确认是外部环境在我反复启停进程时造成的抖动，不是界面改动引入的回归。

- 风险/注意事项：托盘为原生菜单，无法用 `RenderSnapshotTests` 离屏验证，需人工点开确认子菜单与勾选。侧栏同样抓不到。性能采样应在系统静置时进行，否则 Bartender 会污染读数。
- 下一步：人工确认托盘菜单与侧栏，然后继续真实网络人工验收。
- 下一位 Agent 如何接手：卡片配色必须用 `Theme.cardFill`/`Theme.pageFill`，不要退回 `.background` 系列。测性能前先静置，先用 `sample` 确认工作落在哪个栈再下结论。

## 2026-07-20 — 图标、并发接管、跳过 TUN 列表与 GeoIP 数据库设置

- 已完成：修掉速率显示 “Zero KB”；生成并接入应用图标；系统代理与 TUN 改为可同时开启；拆出独立的「跳过 TUN」列表；新增 GeoIP/规则集下载源与更新设置。
- 修改文件：新增 `Resources/AppIcon.icns`、`scripts/make_app_icon.swift`；修改 `Theme.swift`、`Info.plist`、`build_app.sh`、`RoutingModels.swift`、`ConfigGenerator.swift`、`RuleSetService.swift`、`AppState.swift`、`MenuBarView.swift`、`DashboardView.swift`、`MainWindowView.swift`、`RoutingView.swift`、`TunConfigTests.swift`、`AppStateTests.swift`。
- 测试结果：`swift test` 140 项通过 0 失败（1 项快照工具按 env 跳过，新增 2 项并发模式测试）；`zsh scripts/verify_m4.sh` 输出 `M4 automated verification passed`，平均 CPU 0.220%、最大 RSS 118,144 KB。
- 当前状态：`dist/kongshan.app` 已带图标（`CFBundleIconFile=AppIcon`）；两种接管方式可各自独立开关。

### 速率显示 Zero

- `ByteCountFormatter` 的 `.memory` 风格会把 0 本地化成 “Zero KB”。改用 `formatted(.byteCount(style: .memory, spellsOutZero: false))`。

### 应用图标

- 之前没有图标资源，Finder/Dock 显示通用图标。
- `scripts/make_app_icon.swift` 用 CoreGraphics 画：蓝紫渐变 squircle + 白盾 + 盾内三点分流图形，输出 10 个尺寸的 PNG，`iconutil -c icns` 打包成 `Resources/AppIcon.icns`。
- `Info.plist` 增加 `CFBundleIconFile`，`build_app.sh` 复制 icns 进 bundle。改图标重跑该脚本即可。

### 系统代理与 TUN 并发（原为互斥）

- `ConfigInput.proxyMode: ProxyMode` → `enabledModes: Set<ProxyMode>`；保留单模式便捷 init，既有调用点与测试不受影响。
- `inbounds` 由 switch 改为按集合累加，可同时产出 mixed 与 tun；`auto_detect_interface` 与 DNS hijack 只看是否含 TUN。
- `AppState.activeMode` 由存储属性改为派生（含 TUN 时返回 `.tun`），真值是新的 `activeModes: Set<ProxyMode>`。这样既有断言 `activeMode == .tun` 的测试全部保持有效。
- 关键判据：**TUN 决定内核是否以 root 运行，系统代理决定是否改 networksetup**。启动、停止、分流重载、DNS 重载、崩溃自愈五条路径全部按这两个正交条件重写，不再 switch 单一模式。
- 同时开启时只有一个 sing-box 进程（提权），mixed inbound 由该 root 进程提供。
- 新增 `setMode(_:enabled:)`：变更需重建配置，因此先完整停机再按新集合启动，复用既有 stop/start 的回滚路径。
- 新增测试：双模式配置产出 mixed+tun 两个 inbound，且打包内核 `check` 通过。

### 跳过 TUN 独立列表

- 原先 tun 的 `route_exclude_address` 直接复用 `bypassCIDRs`，语义混在一起。
- `RoutingSettings` 新增 `tunExcludeCIDRs`，自定义 `init(from:)` 让旧设置文件解码时回落到默认私有网段，避免升级后排除列表变空。
- 规则页新增「跳过 TUN」编辑区；两个既有测试改为断言解耦后的语义。

### GeoIP / 规则集数据库

- 澄清来源：本项目用的是 sing-box 官方 `.srs` 规则集，来自开源仓库 SagerNet/sing-geoip 与 sing-geosite（不是 MaxMind mmdb）。
- 新增 `RuleSetMirror`：GitHub 原始地址 / jsDelivr CDN（Fastly）。默认改为 jsDelivr，国内可达性明显更好。
- 新增 `RuleSetSettings`（镜像、自动更新、最后更新时间），随 settings.json 持久化。
- 关闭自动更新时 `prepare` 不发起下载，直接走缓存；「立即更新」强制走网络，成功才写入最后更新时间。
- 设置页新增区块，展示当前三个下载地址、下载源选择、自动更新开关、最后更新时间与立即更新按钮。

- 风险/注意事项：并发模式下同时开启会请求管理员授权（因为内核转为 root 运行）；从单一系统代理切到「同时开启」会经历一次完整停机再启动。规则集镜像切换与立即更新只刷新缓存，不重启内核，下次启动或应用规则时生效。真实双模式共存、真实 TUN 授权、jsDelivr 可达性均未人工验证。
- 下一步：人工验证双模式同开的真实行为（授权弹窗、出口 IP、系统代理是否仍生效）、跳过 TUN 列表的实际命中、规则集立即更新。
- 下一位 Agent 如何接手：改模式相关逻辑时记住两个正交条件（是否含 TUN → 是否提权；是否含系统代理 → 是否动 networksetup），不要退回 switch 单一模式。`activeMode` 是派生只读属性，写入要用 `activeModes`。

## 2026-07-20 — 新会话阅读项目

- 已完成：阅读 README、HANDOFF、PROGRESS、NEXT_STEPS、SESSION_LOG、设计稿与源码/测试/脚本目录结构。
- 修改文件：无代码变更。
- 测试结果：未跑测试。
- 当前状态：已建立项目全貌认知，待命后续任务。
- 风险/注意事项：真实网络/TUN/登录项等人工验收仍未完成。
- 下一步：等待用户指令；人工验收项见 docs/NEXT_STEPS.md。
- 下一位 Agent 如何接手：先读 docs/HANDOFF.md 与 docs/PROGRESS.md。

## 2026-07-20 — 修复真实 TUN 无法启动与测速崩溃

- 已完成：定位并修复 TUN 从未真正可用的根因；修复测速崩溃；仪表盘延迟卡改为出口连通性实测。
- 修改文件：`PrivilegedLauncher.swift`、`PrivilegedLauncherTests.swift`、`AppState.swift`、`DashboardView.swift`。
- 测试结果：`swift test` 140 项通过 0 失败。
- 当前状态：TUN 与测速两个阻塞问题已修，待真机验证。

### TUN 无法启动的根因（重要）

- 现象：`logs/sing-box-tun.log` 只有一行 `FATAL[0057] decode config at /dev/stdin: EOF`，内核空等 57 秒后拿到 EOF。
- 根因：提权命令为
  `/bin/cat FIFO | sing-box run -c /dev/stdin >> LOG 2>&1 & /bin/echo $!`
  后台管道里 `cat` 的 stdin/stderr 仍连着 osascript 的捕获描述符，`do shell script` 因此永不返回。
  `launch()` 阻塞 → `writeAll` 从未执行 → FIFO 里一个字节都没有 → 内核读到 EOF。
- 实测验证：原写法 osascript 30 秒未返回；加上 `</dev/null 2>/dev/null` 后 **0.088 秒返回**，并成功把 68,795 字节（141 节点配置）完整送达消费端。
- 修复：`cat` 增加 `</dev/null 2>/dev/null`；`PrivilegedLauncherTests` 增加断言防回归。
- 说明：此前 M3 只用 fake launcher 测过，真实 root 路径从未跑通，所以该缺陷一直存在。

### 测速崩溃（EXC_CRASH / __cxa_pure_virtual）

- 崩溃栈：`AppState.testAllDelays` → `delays.modify` → `ObservationRegistrar.willSet` → SwiftUI `GraphHost.asyncTransaction`；触发线程在 `swift::AsyncTask::completeFuture`。
- 处理：141 个节点逐条写 `@Observable` 的 `delays`，每次都触发一次 SwiftUI 事务，在列表可见时形成观察风暴。改为本地聚合后一次性赋值。
- 同时把 `nodes.map(ConfigGenerator.outboundTag)` 换成显式闭包——本工具链的方法引用有已知 IRGen 问题（M4 Task 5 已踩过一次）。
- 未在本机复现（无真实订阅与运行中代理），以上是依据崩溃栈的定向修复，需真机确认。

### 仪表盘出口连通性

- 原「延迟」卡展示的是节点握手延迟，改为开启接管后经当前节点实测到 Google 与 GitHub 的往返延迟。
- 走 Clash API 的 `/proxies/{tag}/delay?url=...`，测的是真实经该节点访问目标。
- 触发时机：接管启动成功后自动跑一次；切换节点后重跑；卡片右上角可手动重测。停止接管时清空。

- 风险/注意事项：测速崩溃未本地复现，修复基于崩溃栈推断。TUN 修复已用等价命令实测，但真实管理员授权路径仍需人工走一遍。
- 下一步：节点页改造（导入前可改订阅名、按订阅分组折叠、每组独立自动更新开关）尚未开始。
- 下一位 Agent 如何接手：改提权命令时务必保证后台进程不持有 osascript 的捕获描述符，否则 `do shell script` 不返回；改动后用本节的 osascript 计时实验复验。

## 2026-07-20 — 节点页改造：订阅分组、导入前改名、按组自动更新

- 已完成：订阅按组折叠展示；导入前可改名并设定是否自动更新；每组独立自动更新开关、重命名、删除；识别机场塞进节点名的套餐信息并聚合到组内说明行。
- 修改文件：`Models.swift`、`AppState.swift`、`MainWindowView.swift`、`MenuBarView.swift`、`ClashSubscriptionConverterTests.swift`、`RenderSnapshotTests.swift`。
- 测试结果：`swift test` 141 项通过 0 失败（新增信息条目识别测试）；`zsh scripts/verify_m4.sh` 输出 `M4 automated verification passed`。
- 当前状态：节点页离屏渲染确认——分组头含折叠箭头、名称、真实节点数、自动更新勾选、⋯ 菜单；套餐信息独占一行不再混入可选节点。

### 订阅分组与自动更新粒度

- `SubscriptionSource` 新增 `autoUpdate`，自定义 `init(from:)` 让旧订阅文件解码时默认开启，行为不变。
- `performSubscriptionRefresh` 新增 `automaticOnly` 参数：定时更新跳过关掉自动更新的订阅，用户主动「刷新订阅」仍然全量。
- `rescheduleSubscriptionUpdates` 只把 `autoUpdate == true` 的订阅纳入调度，避免为已关闭的订阅安排唤醒。
- 新增 `renameSubscription(id:to:)`、`setSubscriptionAutoUpdate(id:enabled:)`、`removeSubscription(id:)`。
- `importSubscription` 增加 `name` 与 `autoUpdate` 参数；点「导入」先弹确认表单（名称预填 host、可改，附自动更新开关），确认后才真正拉取。

### 机场套餐信息条目

- 机场把「剩余流量 / 重置日 / 到期日 / 官网」当成节点下发，它们是合法 outbound 但没有代理用途。
- `ProxyNode.isSubscriptionInfo` 按关键词与「491.89 G | 500.00 G」这类用量格式识别，附单元测试（含真实节点名的反例）。
- 仅影响展示：这些条目仍在 `nodes` 里参与配置生成，不改动代理逻辑；界面上聚合成组内一行说明，菜单栏节点子菜单也过滤掉。
- `selectFirstNodeIfNeeded` 改为优先选真实节点，避免默认选中信息条目。

- 风险/注意事项：信息条目识别是关键词启发式，可能误判名字里带「流量」「官网」等字样的真实节点；误判只影响展示与默认选中，不影响已生成的配置。`NodesView` 由 private 改为 internal 以便离屏渲染自查。
- 下一步：本轮四项（TUN、测速崩溃、连通性卡、节点页）需真机验证。
- 下一位 Agent 如何接手：订阅相关改动记得同时看「手动刷新全量 / 定时更新按开关过滤」这条区分，别把两者合并。

## 2026-07-20 — 出站模式、托盘策略组、日志切换与测速加固

- 已完成：新增直连/全局/规则三种出站模式；托盘按 Stash 重排（测速全部置顶、出站模式子菜单、每个策略组独立选节点并显示延迟）；修复日志等级切换看似无效；测速全部加防重入与结构简化。
- 修改文件：`ProxyMode.swift`、`ConfigGenerator.swift`、`AppState.swift`、`MenuBarView.swift`（重写）、`DashboardView.swift`、`MainWindowView.swift`、`RoutingConfigTests.swift`。
- 测试结果：`swift test` 142 项通过 0 失败（新增三种出站模式的内核校验测试）；`zsh scripts/verify_m4.sh` 通过，平均 CPU 0.020%、最大 RSS 118,912 KB。

### 出站模式（直连 / 全局 / 规则）

- 新增 `OutboundMode`，与「接管方式」正交：接管方式决定流量怎么进来，出站模式决定流量怎么出去。
- `route` 生成按模式分派：`.rule` 保持原有六级优先级；`.global` 清空规则、final 指向「手动选择」；`.direct` 清空规则、final 指向 direct。
- 连带修正：全局/直连不声明规则集，DNS 里引用 `geosite-cn` 的那条规则必须同步去掉，否则内核校验直接失败。直连模式的 DNS final 也改为国内 DoH，不再绕到代理出口。
- 新增测试：三种模式生成的配置都用打包内核 `check` 验证通过，并断言各自的 rules/final 形态。
- 切换时未运行只持久化；运行中复用分流的热重载路径重建配置。

### 托盘按 Stash 重排

- 顺序：状态 / 打开仪表盘 ⌘D / 测速全部 ⌘T（置顶）/ 出站模式子菜单 / 系统代理 ⌘E / TUN ⌘U / 各策略组子菜单 / 登录时启动 / 刷新订阅 ⌘R / 退出 ⌘Q。
- 策略组：`AppState.policyGroups` 暴露配置里实际生成的 selector 组（手动选择、自建），每组一个子菜单，可单独指定节点，右侧显示上次测速的 ms。
- 新增 `select(_:in:)`，通过 Clash API 的分组选择接口切换；「手动选择」会同步全局当前节点并重测连通性。

### 日志等级切换看似无效

- `setLogLevel` 只重建了推送流，没有清空已显示的行，旧等级的日志仍留在列表里，看起来像没切换。改为切换时清空显示。

### 测速崩溃的进一步加固（仍未复现）

- 写了针对性复现：141 个节点走真实 actor + TaskGroup 批量测速路径、控制端口无人监听，本地跑 5 轮均未崩溃，说明问题不在并发路径本身。
- 加固内容：`isTestingAllDelays` 防重入（托盘与节点页都能触发，重复点击会叠加数百个并发请求）；只把 `(id, tag)` 这类 Sendable 数据带过 await，挂起后不再遍历节点数组；两处按钮在进行中禁用。
- 崩溃栈为 `swift_release` → `destroy for ProxyNode`，属于内存/运行时层面，未能本地复现，以上为定向加固。

### 一次误判的性能回归

- 验收曾报 `CPU sample 6.8% exceeds 5.0%`，连续两次失败。
- 排查：手动以相同隔离环境（`CFFIXED_USER_HOME`）启动同一产物，`sample` 抓栈显示主线程完全空等；按时间序列采样 `%cpu` 主要为 0.0%，偶发 2.2% 尖峰。
- 结论：`ps %cpu` 是衰减平均，构建期机器繁忙会把读数抬高。机器静置 30 秒后干净复跑，平均 0.020% 通过。
- 教训：这类阈值失败先静置复跑并抓栈，不要直接改阈值或回滚代码。

- 风险/注意事项：出站模式切换会重建配置并重启内核（TUN 下会再次请求授权）。策略组子菜单目前只有「手动选择」和「自建」，因为配置只生成这两个 selector；若将来按分流规则生成更多策略组，`policyGroups` 需同步扩展。
- 下一步：真机验证测速是否仍崩、三种出站模式的实际出口行为、托盘策略组切换。
- 下一位 Agent 如何接手：改 `route` 生成时记得 DNS 的 `rule_set` 引用必须和 route 里声明的规则集保持一致，否则内核 check 直接失败。

## 2026-07-20 — 内核与接管解耦、自定义策略组、采样窗口修正

- 已完成：测速不再要求先开接管；新增用户自定义策略组（按服务分流，对应 Stash 的 Netflix/YouTube 分组）；修正验收脚本的 CPU 采样窗口。
- 修改文件：`RoutingModels.swift`、`ConfigGenerator.swift`、`AppState.swift`、`MenuBarView.swift`、`MainWindowView.swift`、`RoutingView.swift`、`RoutingConfigTests.swift`、`scripts/verify_m4.sh`。
- 测试结果：`swift test` 144 项通过 0 失败（新增策略组生成与命名校验测试）；`zsh scripts/verify_m4.sh` 通过，平均 CPU 0.000%、最大 RSS 114,352 KB。

### 测速按钮为什么是灰的（根因：内核生命周期和接管绑死）

- 测速走 Clash API，而此前内核只在「接管开启」时才启动，于是没开代理就无法测速。这是与 Stash 模型的关键差异：Stash 的内核常驻，接管只是开关。
- 解耦：`start(modes:)` 允许空集合 = 只跑内核（本地 mixed inbound + Clash API），不改系统代理也不建 TUN。
- `stop()` 增加 `runtime != nil` 判断，未接管状态下也能真正停进程。
- 新增 `startCoreForTestingIfNeeded()`：测速时若内核未运行则自动拉起，状态显示为「内核已就绪（未接管）」。
- 托盘在该状态下显示「停止内核」，避免出现用户无法关闭的隐藏运行态。
- 两处「测速」「测速全部」按钮不再要求 `isOn`。

### 自定义策略组（按服务分流）

- 新增 `PolicyGroup`（名称 + selector/urltest），随 `RoutingSettings` 持久化，旧文件解码回落空数组。
- 校验：组名非空、不得占用内置名（手动选择/自动选择/自建/direct/reject）、不得重复。
- 配置生成为每个组产出对应出站；自定义规则的「策略组」下拉自动包含它们。
- `AppState.policyGroups` 只暴露 selector 类型供手动指定，urltest 由内核自行选路。
- 托盘为每个组生成子菜单，可单独指定节点并显示延迟。
- 新增测试：策略组出站生成、urltest 类型正确、规则指向生效、配置通过打包内核校验；以及保留名/重名被拒。

### 验收脚本采样窗口修正（不是放宽阈值）

- 现象：`verify_m4.sh` 反复报 CPU 超限，但采样 4/5 都是 0.0%，且手动以相同隔离环境启动、`sample` 抓栈显示主线程完全空等。
- 根因：`ps %cpu` 是衰减平均值；脚本启动后只 `sleep 2` 就采样，把「建主窗口 + 首次渲染仪表盘」的启动开销算了进去。窗口修复前应用启动不开窗，所以这段开销以前不存在。
- 处理：把静置时间改为 `sleep ${KONGSHAN_VERIFY_SETTLE_SECONDS:-15}`，**阈值一律不动**。红线要求的是空闲稳态，这样测的才是稳态。
- 修正后 5 次采样全 0.0%。

- 风险/注意事项：「内核已就绪（未接管）」是新增状态，用户若只测速会留下一个运行中的内核，需从托盘「停止内核」或开启接管。策略组名直接用作 sing-box outbound tag，含特殊字符时未做额外转义，仅做了非空/保留名/重名校验。
- 下一步：真机验证未接管测速、策略组按服务分流的实际命中。
- 下一位 Agent 如何接手：`ps %cpu` 是衰减平均，性能类失败先静置复跑并 `sample` 抓栈，确认是稳态问题再动代码，永远不要直接调阈值。

## 2026-07-20 — 策略组独立成页、订阅自动发现、规则改名分流

- 已完成：策略组从「规则」页拆出成独立模块；订阅 YAML 的 `proxy-groups` 自动解析并可一键导入；「规则」改名为「分流」；补齐组名字符校验与节点延迟列。
- 修改文件：新增 `Sources/kongshan/PolicyGroupsView.swift`；修改 `ClashSubscriptionConverter.swift`、`SubscriptionService.swift`、`RoutingModels.swift`、`AppState.swift`、`MainWindowView.swift`、`RoutingView.swift`、`ClashSubscriptionConverterTests.swift`、`RenderSnapshotTests.swift`。
- 测试结果：`swift test` 145 项通过 0 失败（新增 proxy-groups 解析测试）。
- 当前状态：侧栏为 仪表盘 / 管理（节点、策略组、分流）/ 其他（日志、设置）。

### 订阅自动发现策略组

- `ClashSubscriptionConverter` 解析 `proxy-groups`：`url-test`/`fallback`/`load-balance` 映射为 urltest，其余为 selector。
- 逐个跳过非法项而不是整体失败：与内置组重名、含非法字符、组内重复的都直接忽略，不影响其余导入。
- 结果经 `SubscriptionRefreshResult.policyGroups` 带到 `AppState.discoveredPolicyGroups`，按订阅 ID 存放。
- 策略组页顶部列出「订阅里发现的策略组」，可单个或全部导入；已导入的不再重复出现。

### 策略组页

- 三个区：订阅发现（可导入）、我的策略组（增删改 + 手动组可直接挑节点并显示延迟）、内置策略组（只读说明）。
- 「手动指定」组在已生效时可直接在页内切换节点，右侧显示该节点上次测速结果。

### 命名调整

- 侧栏「规则」→「分流」，页头与按钮同步（「应用规则」→「应用分流」）。理由：该页现在包含自定义规则、绕过域名、绕过 CIDR、跳过 TUN 与广告拦截，「分流」比「规则」更准确；「规则」这个词已被策略组页的引用关系占用。

### 其余优化

- 策略组名加字符白名单：组名直接作为 sing-box outbound tag，排除 `"\{}[],:` 与换行制表符，长度上限 40。
- 节点行延迟改为固定列（宽 64、等宽数字），批量测速后一眼可比；测速按钮仍悬停出现。

- 风险/注意事项：订阅里的策略组只导入「名称 + 类型」，成员节点仍是我们自己的全量节点列表，不还原订阅里 `proxies:` 指定的成员。若机场的分组成员有意义（如只含解锁节点），当前实现不会体现这一点。
- 下一步：真机验证订阅导入策略组、分流规则指向新组后的实际命中。
- 下一位 Agent 如何接手：策略组的成员目前固定为全部节点，如要还原订阅分组成员，需要在 `PolicyGroup` 上加成员列表并在配置生成时按名称解析引用（注意订阅里的组可能互相嵌套引用）。

## 2026-07-20 — 按 Stash 重做代理页、设置分区与维护操作

- 已完成：策略组页重做为 Stash 式「代理」页（左策略组 / 右节点卡片 / 顶部出站模式与延迟测试）；设置页按 Stash 拆成 通用/隧道/网络/资源/更多 五个分区；新增数据目录与日志目录的 Finder 入口和缓存清理。
- 修改文件：`PolicyGroupsView.swift`（重写）、`MainWindowView.swift`、`AppState.swift`、`ProxyMode.swift`。
- 测试结果：`swift test` 145 项通过 0 失败；`zsh scripts/verify_m4.sh` 通过（退出码 0，平均 CPU 0.000%、最大 RSS 113,296 KB）。

### 代理页（对应 Stash 的「代理」）

- 顶部：出站模式分段控件 + 延迟测试按钮。
- 左列：策略组列表，每项显示图标、组名与当前选中节点；底部有「管理策略组」入口和「N 个可导入」提示。
- 右列：该组可选节点的卡片网格，卡片含名称、协议标签、带色点的延迟；选中项高亮描边。
- 策略组的增删改与订阅导入移到 sheet，主界面只负责选节点。

### 两处按截图修正

- `OutboundMode.allCases` 顺序改为 直连 / 规则 / 全局，与 Stash 一致（枚举顺序即界面顺序，托盘同步生效）。
- 左列原本漏掉「自动选择」：`policyGroups` 只返回可手动指定的组。新增 `displayPolicyGroups` 用于展示（含只读的自动选择），选中它时右列禁用点击并给出说明。

### 设置分区与维护操作

- 设置页顶部分段：通用（开机自启、关于）/ 隧道（代理模式、strict_route）/ 网络（测速、DNS）/ 资源（订阅自动更新、GeoIP 规则集）/ 更多（数据与日志、清理）。
- 「更多」新增：数据目录与日志目录的「在 Finder 中显示」、路径可选中复制。
- 「清理缓存」删除内核日志与规则集缓存（都能自动重建），设置/订阅缓存/节点不动；内核运行时禁用。

- 风险/注意事项：代理页右列在非 selector 组下仍渲染全部节点卡片但禁用点击，节点极多时这一列会较长。设置分区用 `if tab == …` 包裹 Section，新增 Section 时注意放进正确的分区块。
- 下一步：Stash 还有若干可借鉴项未做，见 NEXT_STEPS 的可选清单。
- 下一位 Agent 如何接手：`OutboundMode`/`SidebarPage` 的枚举顺序直接决定界面顺序，调整时先确认托盘与仪表盘两处都跟着变。

## 2026-07-20 — 通读后回答优化建议

- 已完成：通读 original-prompt、设计稿、M1–M4 acceptance、HANDOFF/PROGRESS/NEXT、核心 ConfigGenerator/RoutingModels/AppState/UI/托盘。
- 修改文件：无代码变更。
- 测试结果：未跑。
- 当前状态：可给出有依据的优化优先级，非空想功能清单。

## 2026-07-20 — 订阅自带分流规则接入

- 已完成：解析并应用订阅 YAML 的 `rules:`；分流页新增只读、可搜索的订阅规则区与总开关。
- 修改文件：`RoutingModels.swift`、`ClashSubscriptionConverter.swift`、`SubscriptionService.swift`、`ConfigGenerator.swift`、`AppState.swift`、`RoutingView.swift`、`RoutingConfigTests.swift`。
- 测试结果：`swift test` 146 项通过 0 失败；`zsh scripts/verify_m4.sh` 通过（退出码 0，平均 CPU 0.000%、最大 RSS 113,360 KB）。

### 为什么做这个

此前我们完全忽略订阅里的 `rules:`，机场按服务写好的几千条分流全部丢失，用户只能靠内置的 geosite-cn 兜底。这是与 Stash 差距最大的功能缺口。

### 实现

- 新增 `SubscriptionRule`（类型 + 值 + 目标），`parse` 把 Clash 规则行映射到我们支持的五种类型。
- 不支持的类型（GEOIP、GEOSITE、RULE-SET、MATCH…）与非法值直接跳过，不影响其余规则。MATCH 与 GEOIP 本来就由我们自己的兜底和规则集覆盖。
- 存放在 `AppState.discoveredRules`（按订阅 ID），拼接时按订阅顺序去重。不写进用户自定义规则列表，避免几千条污染设置文件与编辑器。
- 配置生成插入位置：**用户自定义规则 → 绕过列表 → 订阅规则 → 私有网段 → 广告 → 中国直连 → 兜底**。
- **目标必须能解析到已存在的出站**（direct/reject/内置组/已导入的策略组），否则该条直接丢弃——否则 sing-box 校验会因为引用不存在的 outbound 直接失败。测试专门覆盖了这条。
- `RoutingSettings.useSubscriptionRules` 总开关，默认开启；旧设置文件解码回落为 true。

### 界面

- 分流页新增「订阅自带规则」区：显示总条数、开关、搜索框、类型/值/目标三列（DIRECT 绿、REJECT 红、策略组用强调色）。
- 只渲染前 200 条并提示匹配总数，避免几千行拖垮列表。

- 风险/注意事项：订阅规则指向的策略组必须先在「代理」页导入，否则整条规则被静默丢弃——用户可能困惑为什么某条规则没生效。目前没有在界面上标出「被丢弃」的规则，值得后续补。
- 下一步：真机验证订阅规则命中；补「被丢弃规则」的可见提示。
- 下一位 Agent 如何接手：新增规则来源时注意插入顺序与「目标出站必须存在」这两条，配置校验失败多半是引用了不存在的 outbound。

## 2026-07-21 调研会话（子 Agent：开源客户端经验调研）
- 已完成：针对 7 个主题（订阅抓取/网络切换/睡眠唤醒/macOS TUN/配置坑/进程生命周期/macOS 专属问题）完成 Web 调研，来源含 sing-box 官方文档与 issues、clash-verge-rev issues/FAQ、mihomo #2624、ClashX helper、Stash Wiki、GUI.for.SingBox 文档等。
- 修改文件：仅本日志（调研结论以会话消息形式交付主 Agent，未写报告文件）。
- 当前状态：调研完成，结论已交付；建议主 Agent 将采纳项落入 NEXT_STEPS.md。
- 下一步：按报告中"具体建议"逐项排入开发计划（优先：代理守卫+网络切换重挂、崩溃后系统代理恢复、TUN 开启时改系统 DNS、订阅 UA/userinfo）。

## 2026-07-21 全面体检：需求对照 + UI 审计 + 开源避坑加固

三路并进：需求矩阵对照、全控件交互审计（子代理）、GitHub 开源 sing-box/Clash 客户端坑位调研（子代理，报告含 40+ 条带出处的结论）。

### 真实世界坑位修复（来自调研）
- 订阅 UA：默认 URLSession UA 会被机场面板发错格式。现固定 `clash.meta kongshan/1.0`（必含 clash、不含 sing-box），`SubscriptionService.request(for:)` 可测。
- `subscription-userinfo` 响应头解析为 `SubscriptionUsage`（upload/download/total/expire，字段可缺省/小数），存 `SubscriptionSource.usage`（旧文件兼容），节点页订阅组内显示进度条+到期日；>85% 橙色。
- `profile-title`（含 base64: 前缀）/`Content-Disposition` 文件名 → 用户未起名时的默认订阅名。
- **节点 ID 确定性**（重大）：转换器原来每次刷新随机 UUID，导致自动刷新后选中节点重置、延迟清零。现 `stableNodeID(sourceID,name,occurrence)`＝SHA-256 前 16 字节（RFC4122 版本/变体位），同名节点按序号区分。
- **TUN 下接管系统 DNS**（macOS 最大坑，mihomo#2624）：新增 `SystemDNSManager`（与 SystemProxyManager 同构：快照先落盘→改→失败回滚→崩溃自愈→事务串行），TUN 启动时把所有服务 DNS 指向 `TunSettings.dnsServerAddress`（接口地址+1，如 172.19.0.2，会被 hijack-dns 截获），停止/退出/崩溃全路径还原。dns-recovery.json。
- **切网补挂**：`SystemProxyManager.reassert(port:bypass:)` / `SystemDNSManager.reassert(server:)` 只处理新出现或漂移的服务，先并入快照再设置；AppState 用 NWPathMonitor（事件驱动非轮询）+2s 防抖触发。
- **睡眠唤醒**：NSWorkspace.didWake → 3s 后 Clash API health 检查（失败给警告）+ 补挂。测试夹具不受影响（监听闸在 monitorsSystemEvents=automaticallyInitialize）。
- TUN stack 可配置（mixed/system/gvisor），默认从 system 改为 mixed（sing-box#2500/#3529 system 栈翻车记录）；旧设置文件解码兼容。
- 规则模式统一前置 sniff（原仅 TUN）：SOCKS 客户端只送 IP 时域名规则不再落空。
- 主窗口显示时校验 window.screen，为 nil（外接屏拔掉）则重新居中。

### 架构级修复（自查发现）
- **策略组选择持久化**：groupSelections 原为内存态，重启全部回退。现入 PersistedSettings；ConfigGenerator.ConfigInput 增 groupDefaults，自定义 selector 组/自建组的 default 用记住的节点（不存在则回退全局选中）。
- **节点变化热重载**：订阅刷新/增删订阅/增删自建原来不重载运行中的内核（新节点用不了、删的还在）。现 `hotReloadAfterNodeChange()` 复用分流热重载（校验→快速重启→回滚）；节点删光或「只跑内核」态直接停。确定性 ID 保证内容没变时不重启。
- **推流断线自动重连**：traffic/connections/logs WebSocket 断开（睡眠唤醒必现)原来只报警告、页面冻结。现指数退避 2→30s，收到数据复位，仅页面可见+内核在跑时重试；退避不在 suspend 中复位（否则退化 2s 死循环）。
- 修复 performSubscriptionRefresh 中重复的 discoveredRules 赋值行。

### UI 审计修复（P1 全清）
- F1 全局错误/警告条：挂在 NavigationSplitView detail 顶部（GlobalNoticeBar），红色错误可忽略、橙色警告可清除（新增 clearWarnings()）；移除仪表盘旧 errorBanner 与节点页内联警告避免重复。
- F2 删除订阅 confirmationDialog；删除自建节点同样确认。
- F3 设置页「首选接管方式」单选 Picker（双开时点击会静默丢模式）→ 与仪表盘/托盘一致的两个独立开关 + 当前接管集合展示。
- F4 「只跑内核（未接管）」在主窗口无法停止 → 仪表盘蓝色横幅 + 停止内核按钮。
- F5 自建节点删不掉 → AppState.removeManualNode（清组选择、selectFirstNodeIfNeeded、运行中热重载），NodeRow hover 垃圾桶（仅自建组）。
- F6 导入 sheet 先关后导致失败不可见 → sheet 内进度+错误、成功才关闭。
- F7 测速 URL 直改内存 → 草稿+未保存徽标+saveTestURL(raw) 校验后才写入。
- F8 ManualNodeSheet 后端失败显示 state.errorMessage（就地显示后 dismissError 防全局重复）。
- F12 「延迟测试」→「测速全部」统一文案；F16 删除死代码 SectionCaption。

### 测试与验证
- 新增 SystemDNSManagerTests（6 项：快照先行/回滚/reassert 增量/无快照零命令）、订阅 UA/userinfo/建议名/旧 JSON 兼容（5 项）、稳定 ID、groupDefaults 回退、TunSettings 旧格式解码。
- 更新既有断言：sniff 前置（RoutingConfig/DNSConfig）、stack=mixed（TunConfig）、TUN 流程 networksetup 白名单改为「仅 DNS 三命令」（AppStateTests isDNSTakeoverCommand）。
- `swift test`：160 通过 0 失败（原 146）。`verify_m4.sh` 通过：平均 CPU 0.000%，最大 RSS 115,264 KB。离屏快照重渲染确认节点页配额行、仪表盘正常。app 已重打包并运行。

### 风险/注意
- TUN 现在会改系统 DNS（networksetup -setdnsservers），恢复路径与系统代理同构（独立 dns-recovery.json）；真机验证时若 TUN 后无网，先查 `networksetup -getdnsservers Wi-Fi` 是否残留 172.19.0.2，`打开 App 会自愈`。
- TUN stack 默认从 system 改为 mixed，行为变化需真机回归。
- 订阅刷新如果节点集合变化，运行中会短暂重启内核（<2s）——定时刷新也如此，属预期。
- 蔽而未做：面板 UA 自定义字段、HEAD 轻量刷新配额、profile-update-interval 按订阅覆盖、base64/JSON 订阅格式回退、特权 helper 替代 osascript（记入 NEXT_STEPS）。

## 2026-07-21 — 用户查询最新进度

- 已完成：汇总 HANDOFF/PROGRESS/NEXT/SESSION_LOG 当前状态给用户。
- 修改文件：无。

## 2026-07-21 配置为中心重构 + TUN/测速两个真机 bug

### 真机 bug（读用户实机日志定位）
- **TUN 起不动（每次弹密码、输对也开不了）**：`sing-box-tun.log` 明确 `FATAL configure tun interface: bad tun name: kongshan-tun`。macOS 的 utun 名必须是 utunN，自定义名被内核拒绝。提权其实成功了，是内核起 TUN 立即 FATAL。修复：ConfigGenerator 不再输出 `interface_name`，交给 sing-box 自动分配 utunN。TunConfigTests 断言 interface_name 为 nil，集成用例过 `sing-box check`。
- **测速慢且全失败**：原来只有「经代理请求 gstatic」一种（要内核在跑、100+ 节点并发到 gstatic）。新增 `SpeedTestMethod`：`.tcpPing`（默认，Network 框架直连 server:port 握手计时，不需要内核，快而稳）/`.urlTest`（经代理测真实链路）。设置-网络可切；TCP 直连不依赖代理是否可用。测速只针对当前生效配置的可用节点。

### 配置为中心（Stash 心智模型）——不建新数据模型，用 activeConfigID 过滤
- AppState 加 `activeConfigID`（订阅 ID 或 `localConfigID` 伪配置＝自建节点），持久化；`configItems` 列表；`setActiveConfig`（切换即清组选择/延迟并热重载）；`ensureActiveConfig`（导入/删除/加载后兜底选一个）。
- 生成配置、节点、策略组、规则全部按 activeConfigNodes/activeConfigPolicyGroups/subscriptionRules（当前配置）过滤；`start`/`testAll`/`hotReload` 的空判断改成 activeConfigNodes。
- **策略组带真实成员**：PolicyGroup 加 `members`（节点名/子组/DIRECT/REJECT，空＝全部节点，旧数据兼容解码）。converter 保留 proxy-groups 的 proxies 成员。ConfigGenerator 把成员名解析成出站 tag（节点→tag、子组→组名、DIRECT/REJECT→direct/reject），解析不到丢弃、全丢光回退全部节点（绝不产空组）。
- **选择模型改为按成员名**：groupSelections 由 [组名:UUID] 改成 [组名:成员名]，统一处理节点与子组/DIRECT/REJECT；`GroupOption` 枚举；`select(optionName:in:)` 走 Clash API select（tag 映射）。旧 [String:UUID] 的 JSON 与 [String:String] 同形（UUID 即字符串），加载不崩，失配则回退默认。
- 加载路径补上从缓存恢复 discoveredPolicyGroups/discoveredRules（否则重启后生效配置的策略/规则为空）。

### 界面重构
- 侧栏：仪表盘 / **配置** / 代理 / **规则** / 日志 / 设置。
- **配置页**（原节点页重写）：只列配置（订阅+本地节点），单选生效、导入/更新/重命名/删除、配额进度条，**不显示节点**。
- **代理页**：左＝当前配置的策略（内置手动/自动+配置自带），右＝所选策略的成员（节点显示协议+延迟可测速，子组显示为「策略引用」），逐策略选成员；删掉了旧的「管理/导入策略组」编辑器（配置自带，无需手动导入）。
- **规则页**（原分流页重写）：只读展示当前配置带出的规则（类型/值/目标，颜色区分），搜索、前 200 条；顶部「应用订阅规则/拦截广告」开关即时应用。手动绕过域名/IP/跳过TUN 三个列表**移到 设置→隧道**，可滚动逐条增删+应用。
- 托盘：各 selector 策略子菜单，成员（节点/子组）逐个可选，节点带延迟。
- 删除死代码：importablePolicyGroups/setPolicyGroups/NodeRow/PolicyGroupEditorSheet/SectionCaption。

### 测试与验证
- 新增：配置策略组成员解析+过 `sing-box check`、空成员回退全部节点、TCP ping 失败路径、SpeedTestMethod 编解码。改既有断言：TUN 无 interface_name、start 空节点文案、fixtures 补 activeConfigID。
- `swift test` 165 通过 0 失败（原 160）。`verify_m4.sh` 通过（平均 CPU 0.020%，最大 RSS 120,256 KB）。离屏渲染确认配置/代理/规则三页符合 Stash 布局。app 已重打包运行。

### 风险/注意
- 配置层面 TUN 名已修；真机需实测「点 TUN→授权→成功接管」（bad tun name 应消失）。
- Clash 配置里 GEOSITE/GEOIP/RULE-SET 规则仍不转换（converter 只认 DOMAIN*/IP-CIDR/PROCESS-NAME），靠内置 geosite-cn/geoip-cn/ads/private 兜底；规则页展示的是可解析规则。
- 子组选择（如主组指向地区组）经 Clash API 生效并持久化为成员名，但生成默认仍取该组首个成员——重启后主组的子组选择由 groupDefaults 的 tag 恢复（子组名即 tag），OK。
- 升级会一次性重置策略组选择（旧 UUID 值配不上节点名），用户重选即可。

## 2026-07-21 六项优化：UUID/菜单、启动、TUN、审计、版本发布

真机诊断（读实机进程/网络）：发现两个 root sing-box 孤儿（PPID 1，失败重试残留），且数据目录被 CleanMyMac 清空。

1. 手动选择显示 UUID：旧持久化 groupSelections 是 UUID、新按成员名。selectedMemberName 现在校验存的值仍是当前有效成员，否则回退默认（不再直接显示原始 UUID）。groupOptions 剔除机场套餐信息条目。托盘菜单名截断（组≤14/成员≤16）收窄宽度；testAll 禁用条件改 testableNodes。
2. 启动慢/转圈：loadPersistedState 在主 actor 同步解析大 YAML（上百节点+7539规则）阻塞 UI。改用 Task.detached 后台解析，主线程只赋值。
3. TUN 点击转圈最终失败：孤儿 root 内核占着 utun+默认路由，新内核 auto_route 撞 `add route: file exists`。PrivilegedCommandBuilder.start 现在在同一次授权里先 `pkill -f <binary>` 清残留再启动（一次密码）。
4. 内存/性能审计：所有流/重试/监听 Task 均 [weak self] 且存储可取消；无 Timer/轮询/死循环；缓冲有上限；scheduler 有 deinit。无泄漏/环。感知卡顿来自 2/3 + 孤儿核，已消除。
5. 使用/运行速度：随 2/3 改善；空闲 0.0% CPU、~104MB。
6. 版本发布：新增 VERSION 文件（唯一来源），build_app.sh 每次构建自增修订号并用 PlistBuddy 写进 staged Info.plist（模板不动，无 git 抖动）；CFBundleVersion=major*10000+minor*100+patch。设置-关于显示应用版本。本次 0.1.1 / build 101 已发布到 dist/。

测试 165 通过；dist/kongshan.app 0.1.1 运行，空闲 0% CPU。
注意：CleanMyMac 会把 ~/Library/Application Support/kongshan 当垃圾清掉，导致订阅/设置丢失，需在 CleanMyMac 里排除该目录；本次数据已被清，用户需重新导入订阅。

## 2026-07-21 四项体验修复（0.1.2）

1. 测速全部改后台增量：testAllDelays 从「批量跑完一次性刷新」改为有界并发（TCP 16 / URL 8）TaskGroup，每测完一个立刻 applyDelay 回填，边测边显示、不阻塞前台。删掉不再用的 TCPPinger.pingAll。
2. 系统代理/TUN 开启慢（根因）：start() 每次都 ruleSetService.prepare(allowsNetwork:true) 同步联网下载 3 个规则集，代理没开时国内直连 jsDelivr/GitHub 卡到 URLSession 默认 60s×3。改为缓存优先（有 .srs 就直接用、不下载不重复校验），下载给 15s 超时；forceRefresh 仅「立即更新」用；启动后按天在后台刷新缓存（非阻塞）。启动从数十秒→秒级。
3. 最小化后程序坞点击呼不出窗口：showMainWindow 对 isMiniaturized 窗口先 deminiaturize 再 makeKeyAndOrderFront。
4. 其他提速：规则集缓存优先 + 后台日更；启动路径不再有可预见的网络等待。

测试 166 通过；0.1.2/build 102 发布 dist、运行中。

## 2026-07-21 修「新版打不开/启动没反应」（0.1.6）

现象：点了没反应。两个叠加原因：
1. CleanMyMac 5 后台代理把 dist/kongshan.app 整个删了（进程还在跑但没了 bundle，既看不到也无法重开）。已改为安装并从 /Applications 运行；根治需用户在 CleanMyMac 里排除该目录。
2. 多显示器：主屏是笔记本（屏0，菜单栏所在），另有大外接屏（屏1）在其上方。窗口被 macOS 窗口状态还原（Resume）+ 旧的 frameAutosave 还原到外接屏一角（CG Y=-1414），用户在笔记本屏看不到。
   - 去掉 setFrameAutosaveName；window.isRestorable=false 关掉状态还原；showMainWindow 里在激活前捕获主屏、showWindow 后（含 next-runloop 再补一次）把窗口居中到主屏；最小化先 deminiaturize。
   - 清掉残留：defaults 的 "NSWindow Frame kongshan.main" 与 Saved Application State。
   - 实测窗口从 (445,-1414)/屏1 变为 (375,125)/屏0，可见。

测试 166 通过；0.1.6/build 106 已装到 /Applications 并运行。

## 2026-07-21 修 TUN 又回到 EOF 失败（自杀式 pkill，0.1.7）

真机 sing-box-tun.log 又是 `FATAL decode config at /dev/stdin: EOF`。根因是上一版给 TUN 启动加的
预清理 `pkill -f <binary>`：`do shell script` 执行本命令的 shell，其命令行里也含内核路径
（后段 `... | <binary> run -c /dev/stdin`），pkill -f 把这个 shell 连同后续启动一起杀了，
配置写不进 FIFO，内核只读到 EOF；App 端等健康检查超时再回滚——就是「转圈很久最后失败」。
改为按进程名精确匹配 `pgrep -x sing-box` 再核对可执行路径只杀自己的核，shell 名为 sh 不会被匹配。
测试加回归断言：含 `pgrep -x sing-box`、不含 `pkill -f`。规则集缓存已存在（下载非瓶颈）。
166 通过；0.1.7 已装 /Applications。

## 2026-07-21 系统代理/TUN 开启很卡的真因（0.1.9）

真机日志显示 TUN 内核其实已起来在路由（inbound/tun 有包）。慢+卡的真因是两处：
1. 配置巨大：机场 7539 条规则里 4780 条被逐条塞进 route.rules，config.json 达 1MB、360 出站。
2. 生成这份配置的 generateConfiguration + diagnosticSnapshot 是在主 actor 上同步跑（构建 dict + JSON 编码/再解析 1MB），把 UI 卡死——每次开代理/切配置/切模式都卡一下。
   （sing-box check 本身只 0.11s，不是瓶颈。）
修复：
- ConfigGenerator.mergedSubscriptionRules：把「连续的同类型同出站」订阅规则并成一条（值进数组），4780→约166 条，语义与顺序不变；配置随之瘦身。
- generateConfiguration 改 async，实际生成放 Task.detached 后台线程；diagnosticSnapshot 统一走 writeDiagnosticConfig 也放后台。主线程不再被大配置阻塞。
另发现：用户同时开着 Stash 的 TUN（日志里满是 Stash 进程），两个 TUN 抢默认路由会互相干扰——需只留一个。
测试 167 通过；0.1.9 已装 /Applications。

## 2026-07-21 TUN 启动路径继续加固（0.1.10）

- 预清理只有真杀掉残留内核才 sleep 1（等路由/utun 释放）；常态无残留不再白等 1 秒。
- 健康检查上限 30→60 次（~3s→~6s），成功即返回不加时；容忍首次建 TUN、大量出站时内核稍慢就绪，避免误判失败回滚。
- 复核 DNS 段结构正常（dns-cn 直连 DoH、dns-remote 经 自动选择、geosite-cn→dns-cn、final dns-remote）；之前 EOF 是打到机场伪域名 + Stash 抢路由，非配置问题。
测试 167 通过；0.1.10 已装 /Applications。等用户关掉 Stash 后实测 TUN。

## 2026-07-21 系统代理/TUN 开启慢：跳出去实测（0.1.11）

逐项实测把之前的猜测都排除了：
- networksetup 单次 0.016s，用户仅 4 个网络服务 → 全部调用 <1s，不是瓶颈。
- 规则集缓存在（geoip-cn/geosite-cn），cache-first 命中，不下载。
- 合并生效：config.json 1MB→470KB、route.rules 4780→166、outbounds 360（342 SS 节点+15 selector+1 urltest）。
- 把 config.json 去掉 tun 入站单跑核心：`sing-box started (0.01s)`，Clash API 0.14s 就绪 → 核心启动/健康检查都极快。
结论：start 各步在隔离测试里都很快，与用户「卡半天」矛盾 → 需要真机逐步计时。
本版给 start() 加了逐步计时（规则集/生成/落盘/校验/内核/健康/接管），成功后把「启动耗时 → …」写进提示条，直接看清慢在哪一步。
另：强烈怀疑是同时开着 Stash 的 TUN 在抢路由/劫持流量——用户测系统代理时也应先退 Stash。
其他小改：pgrep 清理只有真杀到残留才 sleep 1（常态不白等）；健康检查上限 30→60（~6s）容忍首次建 TUN 稍慢。
测试 167 通过；0.1.11 装 /Applications。

## 2026-07-21 找到「很卡/CPU高」真凶：托盘菜单 O(n²) 死循环渲染（0.1.15）

用户截图显示 kongshan 持续 99.9% CPU。实测：一启动加载 342 节点配置就稳定 ~100% CPU（与代理无关）。
sample 命中热点：MenuBarView.optionMenuContent/optionButton 在 SwiftUI 图里被无限重渲染。
根因（本会话配置为中心重构引入）：
1. MenuBarExtra 的菜单是「所有子菜单一次性全建」——15 个 selector 组 × 每组最多 342 节点 ≈ 5000 个菜单项。
2. 每个 optionButton 调 isSelected → selectedMemberName → groupOptions，每次都重建一遍全节点字典（O(n)），
   于是每次建菜单是 O(n²)（342²×组数≈百万级），且 SwiftUI 反复重求值 → 单核 100% + RSS 271MB。
3. 附带：displayPolicyGroups 每次新建内置组用随机 UUID，ForEach 按 id 渲染会误判列表变化再加剧churn。
修复：
- 内置「手动选择/自动选择」用固定 UUID；ForEach 显式 id: \.name。
- optionMenuContent 每组只算一次 selectedMemberName，optionButton 收 selected: Bool（O(1)/项）。
- 子菜单每组最多列 40 项，超出显示「在代理页选择全部（N 个）…」。
实测：CPU 从持续 100% → 空闲 0%（启动一次性 ~2s 峰值）；RSS 271MB → ~141MB。
这也解释了之前「系统代理/TUN 开启很慢很卡」——App 一直 100% CPU，什么操作都卡，根本不是启动路径的问题。
测试 167 通过；0.1.15 装 /Applications。

## 2026-07-21 会话收尾（上下文清理）
- TUN 已可正常开启且快（自杀式 pkill 修复后）。系统代理/TUN 的「很卡」根因是托盘菜单 O(n²) 死循环渲染，已修（0.1.15，CPU 100%→0%，RSS→141MB）。
- 唯一遗留问题：**开 TUN 后仪表盘出站 IP 一直跳/一会一变**（用户最后反馈，未排查）。假设与修法见 NEXT_STEPS 顶部（多半是 final=自动选择 urltest 或规则指向 urltest 组）。
- 当前版本 0.1.15，已装 /Applications 并运行，代码推送 GitHub（eccc2c9，main 与远端一致）。
- 提醒：CleanMyMac 反复删数据/App，用户需在其排除列表加入 kongshan 目录与 .app。

## 2026-07-21 修「开代理没效果 / 手动选择不生效 / 出站IP跳」根因（0.1.16）
- **确诊**（读真实 config.json + 订阅 proxy-groups）：机场是"轮辐"结构，主组 `🙂 TAGSS` 被 7 个策略当默认引用，而它自身首个成员是 `🎯 绕过代理`(直连) → "需代理"流量(国外媒体 66 条规则/漏网之鱼兜底/直接指向 TAGSS 的 25 条)全走**直连** → Google/GitHub 墙内不可达。同时我们内置 `手动选择` 不被任何 rule/final/组引用（`final=自动选择`），**用户在手动选择里选节点完全不生效**（孤儿组）。
- **修复**（仅 `ConfigGenerator`，不新增数据模型/不动 UI）：
  1. 识别机场主组＝被 ≥2 个其它组当"首个成员(默认)"引用、且自身非直连/拒绝包装的代理组；把它的默认接到 `手动选择`（并把手动选择放进其成员）。指向主组的策略(国外媒体/漏网之鱼…)自然跟随；微软/苹果/Steam→绕过代理=直连 的机场意图**保持不动**；地区子组(被引用<2)也不动。
  2. `route.final`：`自动选择`(urltest) → `手动选择`（**顺带修掉出站 IP 跳动**：final 不再是自动测速切换组）。
  3. DNS remote detour：`自动选择` → `手动选择`（DNS 也不再跳节点，统一走用户选的节点）。
- **验证**：全量测试 168 通过(+1 新测 `testHubMasterDefaultsToManualSelectionAndBypassPreserved` 锁死行为)；另用 Python 按真实订阅结构模拟，主组正确识别为 TAGSS、各组默认符合预期。
- 修改文件：`Sources/KongshanCore/ConfigGenerator.swift`（主组识别+final+DNS detour）、`Tests/KongshanCoreTests/{RoutingConfigTests,ConfigGeneratorTests,DNSConfigTests}.swift`。
- 发布 0.1.16 到 dist + /Applications（54MB）。
- **TUN(#3) 未复现**：当前运行态干净（无残留内核/无 tun-recovery.json/runtime 空），日志显示 16:53 TUN 曾正常接管(utun4、路由 Chrome 流量)。"一直弹密码框"是运行期现象，无法从静态产物复现。机制上：start 提权 1 次密码；若健康检查/进程校验失败 → catch 里 `privilegedLauncher.stop()` 会**再弹 1 次密码**去杀刚起的 root 内核（内核已自行退出时则不弹）。**需用户用 0.1.16 再点一次 TUN，抓当次错误提示 + `logs/sing-box-tun.log` 新增尾部**才能定位。

## 2026-07-21 「还是不可达」实为误报 + 按用户意愿只用机场策略组（0.1.17）
- **关键发现**：0.1.16 装上后用户仍报"不可达"。查运行中内核日志（sing-box.log 19:24–19:25）证明**代理其实是通的**——claude.ai / api.github.com / datadog 全部经 `node-0d40ae4c`(香港03=手动选择) 成功建连(1ms)、零报错。config 也确认修复到位(TAGSS default=手动选择、final=手动选择)。所以"出口连通性 不可达"是**仪表盘那张探测卡在误报**（它测 `www.google.com/generate_204`——很多节点被 Google 拦/超时；且测的是 selectedNode 未必与真实路由同步）。config.json 落盘时不含 clash_api(secret 不落盘)，故无法从盘上直接查 secret，用内核日志取证。
- **用户决策**：代理页 `手动选择` 和机场 `TAGSS` 都能选节点，重复又乱。用户选"**只用配置自带的策略组**"（去掉内置手动/自动选择）。
- **重构（Option B）**：
  - `ConfigGenerator`：抽出 `primaryGroupName(among:)`(公开，供 App 共用)。**有机场策略组时不再生成内置手动/自动选择**；主组(TAGSS)默认改为指向**真实节点**(记住的→App 当前节点→首个节点成员，绝不再默认走绕过代理直连)；`final`/DNS detour/自定义代理规则兜底 全部走 `primaryOutbound`(有机场组=主组，否则=手动选择)。订阅规则 `available` 改为按真正生成的出站过滤。无机场组(纯手动/自建)时仍生成手动/自动选择作兜底。
  - `AppState`：`displayPolicyGroups` 有机场组时只返回机场组；加 `primaryGroupName`；`selectedMemberName`/`select` 把"在主组挑节点"视作选主节点(同步 selectedNodeID + 重探连通性)；`probeConnectivity` 改测**主组**(真实会走的路径)而非可能不同步的 selectedNode，探测端点换成更稳的 `gstatic/generate_204`。
- 验证：`swift test` 168 通过（更新 `testHubMasterDefaultsToSelectedNodeAndBypassPreserved` 断言新行为：无内置组、主组默认真实节点、final=主组）。真实订阅模拟确认主组仍识别为 TAGSS。发布 0.1.17 到 dist + 暂存替换装 /Applications（未打断运行中的 0.1.16）。
- **待用户真机确认**：关掉旧实例、重开 0.1.17 → 代理页只剩机场策略组 → 在 TAGSS 里挑节点 → 出口连通性应可达（现在测主组+稳定端点）。注意：用户旧的 groupSelections["🙂 TAGSS"]=台湾02 会被当作主组记住值，主组默认走台湾02；想换就在 TAGSS 里重挑。

## 2026-07-21 ★真凶★：SS 节点缺 obfs 插件 → 能测速却打不开网站（0.1.18）
- **关键澄清**（用户提供）：用户在国内，**跟 Claude 对话必须开另一个工作代理(Stash等)**；测 kongshan 时关掉它、只开 kongshan。**⇒ 我之前用 Bash 实测"代理已通"全是经用户的工作代理，不是 kongshan！** 而 App 那张连通性卡走 kongshan 自己内核测，一直显示不可达——**卡是对的，我错了**。教训：本项目里用 Bash 实测连通性会被用户的工作代理污染，不可信；要测 kongshan 必须走它自己的端口/内核或让用户隔离测。
- **真凶**：机场 342 个节点**全部是 `type: ss` + `plugin: obfs`(simple-obfs, mode:http, host:*.microsoft.com) + cipher aes-128-gcm**。`ClashSubscriptionConverter` 根本没解析 `plugin`/`plugin-opts`，生成的是**裸 shadowsocks**。服务器要求 obfs 混淆 → 裸连能完成 TCP 握手(所以 TCP 测速 66ms 有值)但 SS 层被服务器丢弃 → **传不了任何数据 → 所有国外站不可达**。这解释了这一整轮"节点能测速/延迟正常，但开了代理打不开网站"。
- **修复**：
  - `Models.ProxyNode` 加 `pluginName`/`pluginOptions`（直接存 sing-box 就绪值）。
  - `ClashSubscriptionConverter`：SS 解析 `plugin: obfs` → `obfs-local` + `obfs=<mode>;obfs-host=<host>`；不认识的插件(v2ray-plugin/shadow-tls…)抛 `unsupportedPlugin` 跳过该节点并计入 warnings（不静默生成坏节点）。
  - `ConfigGenerator.outbound` SS：输出 `plugin`/`plugin_opts`。
  - **打包 sing-box 1.13.14 实测 `sing-box check` 接受 `obfs-local`**（关键：确认内核支持）。
- 验证：+2 测试(解析+生成+跳过不支持插件)，170 通过。发布 0.1.18 到 dist + 装 /Applications。
- **待用户真机确认**：重开 0.1.18 → **刷新订阅一次**(重新解析出带 obfs 的节点；loadPersistedState 也会在启动时重解析存的 YAML) → 在 TAGSS 挑节点 → 应能打开国外网站、连通卡可达。这次是隔离测(用户关工作代理只开 kongshan)。
- TUN password-loop 仍未复现取证（同一批节点坏，之前 TUN"起不来"也可能是这个连不通导致的健康/体验问题，obfs 修好后需重测）。

## 2026-07-21 obfs 修复后用户确认代理通；一批交互/界面改进（0.1.19）
- 用户确认 0.1.18 obfs 修复后**代理正常生效**。随后提 8 项：
  1. **切换节点不生效**（切到日本OK，再切斐济等刷新仍是日本 IP）→ 真因：`select()` 只调 Clash API 改选择，没关旧连接，浏览器 keep-alive 连接继续走旧节点。修：切换后 `closeAllConnections()`（DELETE /connections）逼重连。
  2. **加连接监控页**：新增侧栏「连接」页 `ConnectionsView` + `ClashAPIClient.connectionsSnapshot()`（解析 GET /connections 明细）+ 单条/全部关闭（DELETE /connections[/{id}]）。ConnectionDetail 模型：host/process/rule/chains/network/up/down。只在本页可见时轮询(1.5s)。
  3. **托盘「测速全部」移到每个策略选节点子菜单最上面**（原在菜单顶部，已移除顶部那个）。
  4. **代理页策略列表去掉每项前面的图标**（groupRow 去掉 IconBadge）。
  5. **关于页去掉「接管能力」「出站模式」两行**。
  6. **关于页内核显示版本号**：启动时跑 `sing-box version` 填 `coreVersion`（原来只在开代理时从 Clash API 取、没开就是「—」）；旁边加「更新内核」按钮 `updateKernel()`（查 GitHub 最新 release，有新版提示并打开发布页；内核内置随 App 构建更新）。
  7. **「系统状态」改名「登录项状态」**（用户不懂这行干嘛）。
  8. **去掉「启动耗时→…」提示**（诊断用，移除 append，mark() 留空桩）。
- 另外：给用户讲清 TUN 反复弹密码=osascript 每次提权 root 内核的固有代价；日常建议用系统代理(免密码)，passwordless TUN 需做一次性特权 helper(未做，待用户拍板)。
- 验证：`swift build` 通过，`swift test` 170 通过。发布 0.1.19 装 /Applications。
- 待用户真机：切换节点即时生效、连接监控页、各界面改动。TUN 免密码 helper 仍待拍板。

## 2026-07-21 发布 0.1.19（DMG + GitHub Release）
- **杜绝"第二个程序"**：dist/kongshan.app 被 Spotlight 自动索引、登记进启动服务，冒充第二个程序出现在启动台（用户没点开过）。已注销 + 给 dist 加 `.metadata_never_index`，并写进 build_app.sh（每次构建自动标记不索引 + lsregister -u）。正式副本始终在 /Applications。
- **DMG 打包**：新增 `scripts/make_dmg.sh`（拖拽安装式：kongshan.app + /Applications 软链，UDZO 压缩）。产出 `dist/kongshan-0.1.19.dmg`（23M，hdiutil verify 通过）。
- **推送 + 发布**：7 个提交推上 `kongshan-0924/kongshan-proxy`（main 同步）；创建 GitHub Release **v0.1.19**，附 DMG 资产。地址 https://github.com/kongshan-0924/kongshan-proxy/releases/tag/v0.1.19
- 提醒：ad-hoc 签名，别人首次打开需右键→打开绕 Gatekeeper。

## 2026-07-22 合并两位协作 agent 的工作，统一到 main，发布 0.1.20
- 排查发现：gemini/main/trae 三分支提交点相同(439f089=0.1.19)，真正差异在**未提交的 worktree 改动**：
  - **Trae agent**（本 worktree 已暂存）：核心层安全加固+性能（PrivilegedLauncher grep -F、Storage 0700/0600、ConfigGenerator 全凭据脱敏、ProcessRunner 强制 en_US.UTF-8 修中文 networksetup、ClashAPIClient nonisolated 并发测速、RuleSetService 并发下载、KernelLogStore 句柄缓存、SingBoxProcess async）。+457 行，已在 0.1.19 二进制里、170 测试通过。
  - **Gemini agent**（.worktrees/gemini）：UI 增强（连接/节点/日志搜索、节点排序、仪表盘控制卡、侧栏折叠）。+384 行。
  - 两人改的文件**不重叠**（Trae=核心，Gemini=界面）。
- 各起一个 general-purpose subagent **并行审查**两份 diff：均 **SAFE TO MERGE**，无安全/正确性阻断项。Trae 列 6 条低危边缘项、Gemini 列 2 条观感建议。
- 合并顺序：提交 Trae 核心 → 复制 Gemini 7 个 UI 文件 → 顺手修连接页停止后列表不清空（审查 #3）→ `swift build`+`swift test` 170 通过 → build 0.1.20 + DMG。
- **统一到 main**：`git branch -f main HEAD` → checkout main → `git worktree remove --force .worktrees/gemini` → 删 gemini/trae 分支 → push。现只剩 main 一个分支/worktree。
- **只留最新版**：装 0.1.20 到 /Applications；删本地旧 DMG(0.1.19)；GitHub 建 Release v0.1.20、删 v0.1.19(含 tag)；注销所有非 /Applications 的 LaunchServices 残留登记（Trash/已删 worktree/dist）。现系统只认 /Applications/kongshan.app(0.1.20)。
- 待用户：退出运行中的旧版、重开即 0.1.20。

## 2026-07-22 双侧栏按钮修复设计

- 已完成：根据用户截图定位 0.1.20 自定义紧凑侧栏按钮与 `NavigationSplitView` 原生按钮重复；用户确认采用“只保留原生按钮”的最小方案，设计文档已落盘。
- 修改文件：新增 `docs/superpowers/specs/2026-07-22-single-sidebar-toggle-design.md`，更新项目记录；产品代码尚未修改。
- 测试结果：本阶段仅完成根因追踪与设计，无产品测试。
- 当前状态：设计待用户复核后进入实施。
- 风险/注意事项：移除紧凑图标侧栏功能，保留原生完整侧栏的显示/隐藏；不使用延时清理或私有 API。
- 下一步：编写最小实施计划，按 RED→GREEN 修改并重打包。
- 下一位 Agent 如何接手：先读本设计，测试应验证真实窗口只有一个原生侧栏切换项；不要修改代理/TUN 路径。

## 2026-07-22 双侧栏按钮修复实施（0.1.21）

- 已完成：按用户批准方案移除自定义紧凑侧栏、紧凑行/状态布局、`.toolbar(removing: .sidebarToggle)` 和 AppDelegate 的两次时序清理，只保留系统原生侧栏按钮。
- 修改文件：`Sources/kongshan/MainWindowView.swift`、`Sources/kongshan/KongshanApp.swift`、新增 `Tests/KongshanAppTests/MainWindowToolbarTests.swift`，更新设计、计划、版本与项目记录。
- 测试结果：回归检查在旧代码上 4 个断言 RED，修复后定向 1/1、App 48/48、全量 171 项（1 项既有快照跳过）0 失败；`verify_m4.sh` 最终输出通过，平均 CPU 0.000%、最大 RSS 107,168 KB；`hdiutil verify` 确认 23 MB 的 0.1.21 DMG 有效。
- 当前状态：分支 `fix/sidebar-toggle` 已生成 `dist/kongshan.app` 0.1.21 和 `dist/kongshan-0.1.21.dmg`，尚未合并/安装。
- 风险/注意事项：CLI XCTest 的 SwiftUI Scene 工具栏不可见，真实窗口测试得到 0 项而非产品截图中的 2 项，因此改为架构回归检查；打包 App 的按钮数量和点击行为仍保留为人工验收。
- 下一步：按 finishing 流程合并回 main，在主工作区重出 0.1.21 并人工打开仪表盘/设置核对。
- 下一位 Agent 如何接手：不要恢复 `isSidebarCompact`、自定义 navigation ToolbarItem 或 `removeSystemSidebarToggle`；如需紧凑侧栏，应先设计与原生按钮互斥的新方案。

## 2026-07-22 0.1.21 单一副本安装待验收

- 已完成：保持 `fix/sidebar-toggle` 未合并 main，将已验证的 0.1.21 安装到 `/Applications/kongshan.app` 并启动；清理旧 0.1.20 工作区 App/DMG，只保留主工作区一个 0.1.21 DMG。
- 修改文件：仅更新项目记录；安装产物和 DMG 均为 git 忽略文件。
- 测试结果：安装后版本 0.1.21/build 121，codesign strict 有效，进程从 `/Applications/kongshan.app` 运行；`mdfind` 只返回该 App，工作区没有其他 `.app`，DMG 只有 `dist/kongshan-0.1.21.dmg`。
- 当前状态：等待用户人工检查各页面标题栏和原生侧栏隐藏/显示；main 保持在 0.1.20 基线。
- 风险/注意事项：旧 0.1.20 和构建中间 App 已移入废纸篓，仍可恢复；不要在验收前清理 `fix/sidebar-toggle` worktree。
- 下一步：用户明确验收通过后，本地合并分支到 main，再跑合并后测试并清理 worktree。
- 下一位 Agent 如何接手：先确认用户验收结果；未通过就在 `fix/sidebar-toggle` 修，不要提前合并 main。

## 2026-07-22 侧边栏按钮固定位置需求确认

- 已完成：复核用户新截图，确认是同一原生侧栏按钮在侧栏折叠后被系统迁到标题栏最右侧；可视化对比中用户选择 B，要求按钮始终固定在左上角。
- 修改文件：仅追加本阶段项目记录；产品代码未改。
- 测试结果：浏览器选择事件两次记录 `choice=b`，与用户对话回复一致。
- 当前状态：正在比较固定按钮的技术实现，`fix/sidebar-toggle` 仍未合并 main。
- 风险/注意事项：不能恢复上一版“自定义按钮 + 未可靠移除原生按钮”的组合，否则会再次出现双按钮。
- 下一步：提出最小稳定设计，经用户批准后再写实施计划与回归测试。
- 下一位 Agent 如何接手：成功标准是展开/折叠均只有一个按钮，且位置始终紧邻红黄绿窗口控制键右侧。

## 2026-07-22 侧边栏按钮固定位置设计批准

- 已完成：比较纯 SwiftUI 受控分栏、AppKit 监听与重写分栏三种方案；用户批准纯 SwiftUI 最小方案，并形成固定位置设计文档。
- 修改文件：新增 `docs/superpowers/specs/2026-07-22-fixed-sidebar-toggle-position-design.md`，在旧设计标记后续修订，追加本记录。
- 测试结果：设计自查无 TBD/TODO；目标、作用域、状态切换、测试、验收与回退均明确，产品代码尚未修改。
- 当前状态：等待用户复核书面设计；`fix/sidebar-toggle` 未合并 main。
- 风险/注意事项：CLI XCTest 仍不能直接读取真实 SwiftUI 标题栏，自动架构检查与打包 App 人工验收缺一不可。
- 下一步：用户复核通过后调用 `writing-plans`，再按 RED→GREEN 实施并发布 0.1.22。
- 下一位 Agent 如何接手：默认按钮必须在侧栏 `List` 作用域移除；固定按钮只允许一个，使用受控 `NavigationSplitViewVisibility`。

## 2026-07-22 固定位置实施授权与计划

- 已完成：用户复核书面设计并明确后续无需逐步确认；只在当前分支/worktree 修改，最终成品直接交付验收。实施计划已按 RED→GREEN、发布、单副本安装和交接拆分并自查。
- 修改文件：新增 `docs/superpowers/plans/2026-07-22-fixed-sidebar-toggle-position.md`，追加本记录；产品代码尚未修改。
- 测试结果：计划与设计逐项对应，无 TBD/TODO；确认 `verify_m4.sh` 会经 `verify_m3.sh` 调用 `build_app.sh` 并自动递增一次版本，计划已避免二次构建误升 0.1.23。
- 当前状态：`fix/sidebar-toggle` 独立 worktree 已验证，准备运行基线测试并开始失败回归测试。
- 风险/注意事项：验收通过前不合并 main；只有遇到真正阻断或高风险扩权才暂停询问。
- 下一步：运行 `swift test` 基线，随后完成回归 RED、最小实现 GREEN、0.1.22 全量验证与安装。
- 下一位 Agent 如何接手：直接执行计划，不再要求用户逐步确认；保持单分支、单 App、单最新版 DMG。

## 2026-07-22 固定位置实施基线

- 已完成：确认当前目录是 `fix/sidebar-toggle` linked worktree，main 未参与实施；运行产品代码修改前的完整测试基线。
- 修改文件：将 `MainWindowToolbarTests` 改为固定位置目标的失败回归检查，产品代码尚未修改。
- 测试结果：基线 `swift test` 执行 171 项、1 项既有跳过、0 失败。
- 当前状态：准备运行定向测试确认缺失的受控可见性、正确移除和唯一固定按钮均为 RED。
- 风险/注意事项：该测试锁死可验证的 SwiftUI 架构，不能替代打包 App 标题栏人工验收。
- 下一步：运行定向测试记录 RED，再提交回归测试。
- 下一位 Agent 如何接手：必须先保留 RED 证据，再改 `MainWindowView.swift`。

## 2026-07-22 固定位置回归测试 RED

- 已完成：运行 `MainWindowToolbarTests/testMainWindowUsesOneFixedSidebarToggle`，确认测试确实能捕获 0.1.21 的迁移按钮架构。
- 修改文件：`Tests/KongshanAppTests/MainWindowToolbarTests.swift` 与本记录。
- 测试结果：定向 1 项按预期失败，共 4 个断言失败：缺少可见性状态、受控 `NavigationSplitView`、默认按钮移除和唯一 `.navigation` 按钮。
- 当前状态：RED 证据完整，尚未修改产品代码。
- 风险/注意事项：不得为了转绿放宽断言；实现必须与已批准设计一致。
- 下一步：提交 RED 测试，再以最小 SwiftUI 修改转绿。
- 下一位 Agent 如何接手：修改范围仅 `MainWindowView.swift`，不要增加 AppKit 观察器或紧凑侧栏。

## 2026-07-22 固定位置最小实现 GREEN

- 已完成：使用 `NavigationSplitViewVisibility` 受控分栏，在侧栏 `List` 正确移除系统默认按钮，并增加唯一 `.navigation` 固定按钮切换 `.all`/`.detailOnly`；补齐帮助和辅助功能标签。
- 修改文件：`Sources/kongshan/MainWindowView.swift` 与本记录。
- 测试结果：定向回归 1/1 通过；App 测试 48 项、1 项既有快照跳过、0 失败。
- 当前状态：最小产品实现已转绿，未修改 `KongshanApp.swift` 或任何代理/TUN 路径。
- 风险/注意事项：真实标题栏位置仍需打包安装后人工确认；自动测试只证明单按钮架构和作用域正确。
- 下一步：提交实现并运行 `verify_m4.sh` 全量验证和 0.1.22 单次发布构建。
- 下一位 Agent 如何接手：若视觉不符，只调整 SwiftUI toolbar 作用域/placement，不引入 AppKit 时序清理。

## 2026-07-22 0.1.22 全量验证、安装与真实界面检查

- 已完成：`verify_m4.sh` 单次构建 0.1.22/build 122；生成并验证 DMG；将旧 0.1.21 App/DMG 与 worktree 构建副本移入废纸篓，安装并启动 `/Applications/kongshan.app`；发现并卸载旧 `kongshan 0.1.19` DMG 挂载卷。
- 修改文件：`VERSION` 自动更新为 0.1.22；发布产物为主工作区 `dist/kongshan-0.1.22.dmg`，并追加本记录。
- 测试结果：全量 171 项、1 项既有跳过、0 失败；M4 平均 CPU 0.000%、最大 RSS 111,280 KB；签名严格校验和 `hdiutil verify` 通过；DMG SHA-256 为 `301c79a41540482f664ff0bb9e6f7a8c75047b75c211116fd8497975231c4dd6`。
- 当前状态：真实 App 展开时只有一个“隐藏侧边栏”toolbar 按钮，折叠后仍只有一个“显示侧边栏”按钮且保持左侧，再次点击已恢复侧栏；等待用户最终视觉验收。
- 风险/注意事项：Computer Use 在完成展开/折叠/恢复核心验证后连接中止，未继续逐页自动点击；toolbar 位于 `MainWindowView` 根层，各页面共用，仍由用户作最终验收。
- 下一步：完成单 App/单 DMG/分支与 main 边界核验，更新四份交接记录；用户通过前不合并 main。
- 下一位 Agent 如何接手：0.1.22 已安装；先听取用户验收，不通过继续在 `fix/sidebar-toggle` 修，通过后才合并 main。

## 2026-07-22 0.1.22 最终交接核验

- 已完成：按用户指定的 finishing 选择保留 `fix/sidebar-toggle` 及 worktree，完成安装态、单副本、挂载卷、恢复文件和 main 边界的最终核验。
- 修改文件：更新 `docs/HANDOFF.md`、`docs/PROGRESS.md`、`docs/NEXT_STEPS.md` 与本记录。
- 测试结果：安装版本 0.1.22/build 122、codesign strict 有效、PID 62714 从 `/Applications/kongshan.app` 运行；Spotlight 仅返回该 App；工作区无其他 `.app`、无 kongshan DMG 挂载，只保留 `dist/kongshan-0.1.22.dmg`；无 sing-box 和三类 recovery 文件。
- 当前状态：main 保持 `ec29ab1` 未合并；功能分支最新产品提交为 `8baabac`，等待用户验收成品。
- 风险/注意事项：废纸篓中的旧版本未永久删除，可恢复；用户验收前不要清理 worktree 或合并 main。
- 下一步：用户验收；通过后执行本地合并、合并后全量测试与 worktree 清理。
- 下一位 Agent 如何接手：先读取本节和 HANDOFF 顶部；只有收到“验收通过”才进入 main 合并流程。
## 2026-07-22 网络可观测与控制增强：设计与实施计划

- 已完成：基于用户清单核对仪表盘、节点、连接 WebSocket、测速、process_name 路由、托盘监控与持久化现状；将重复的出口连通性/出口 IP 合并成一套出口诊断；确定使用 Mullvad 公开连接检查接口并采用 DNS 三态启发式结论；建立独立分支 `codex/network-observability-batch`。
- 修改文件：新增 `docs/superpowers/specs/2026-07-22-network-observability-and-control-design.md`、`docs/superpowers/plans/2026-07-22-network-observability-and-control.md`；追加本记录。
- 测试结果：本阶段仅设计与只读代码/API 核验，尚未修改生产代码；实测 Mullvad `/json` 返回 IP/城市/国家/组织，`/config` 返回 DNS 唯一域名，唯一小写 UUID 查询返回解析器列表。
- 当前状态：需求边界、数据结构、UI 落点、错误/隐私策略和 9 阶段 TDD 计划已固定；上一版侧边栏修复完整保留。
- 风险/注意事项：DNS 泄漏无法靠 IP 相等作绝对判断，成品文案必须保持“未发现明显泄漏/可能泄漏/无法判断”；第三方检测失败不可当作泄漏；用户验收前禁止合并 main。
- 下一步：按 RED→GREEN 实现出口诊断模型、服务和仪表盘卡。
- 下一位 Agent 如何接手：在当前 worktree/分支先运行 `swift test` 基线，然后从计划 Task 1 开始，严格先写失败测试。
## 2026-07-22 出口 IP 与 DNS 一键自测

- 已完成：删除 Google/GitHub 可达性探测，新增真实出口 IP、城市/国家、网络组织与 DNS 解析器自测；仪表盘进入、切换主节点和手动“检测”都会刷新；请求失败保留最后一次成功结果。
- 修改文件：新增 `Sources/KongshanCore/ExitDiagnostics.swift`、`Sources/kongshan/ExitDiagnosticsService.swift`、`Tests/KongshanCoreTests/ExitDiagnosticsTests.swift`、`Tests/KongshanAppTests/ExitDiagnosticsServiceTests.swift`；修改 `Sources/kongshan/AppState.swift`、`Sources/kongshan/DashboardView.swift`、`Tests/KongshanAppTests/AppStateTests.swift`。
- 测试结果：RED 已验证缺少模型、服务和 AppState 注入点；GREEN 的 6 项诊断模型测试、2 项服务测试、1 项 AppState 保留最后成功结果测试通过；`swift test` 全量回归退出码 0。
- 当前状态：出口诊断功能代码完成，DNS 结论按远程 DoH 提供商/出口地区输出“未发现明显泄漏、可能泄漏、无法判断”。
- 风险/注意事项：依赖 Mullvad 公开接口，失败仅显示错误、不误报；DNS 结论是启发式判断，界面未作绝对安全承诺。
- 下一步：实现节点名称旗帜/地区/倍率解析并接入已有搜索排序卡片。
- 下一位 Agent 如何接手：先从 `Tests/KongshanCoreTests/NodeNameMetadataTests.swift` 写 RED，再新增纯解析器；不得修改订阅原始节点名。
## 2026-07-22 节点旗帜、地区与倍率展示

- 已完成：新增不修改订阅原名的节点元数据解析器；支持名称内双区域旗帜、常见英文/中文地区词和独立国家代码；支持 `3x`、`3×`、`3倍`、`倍率：1.5`；代理页节点卡显示推断旗帜并高亮倍率，托盘节点菜单同步显示。
- 修改文件：新增 `Sources/KongshanCore/NodeNameMetadata.swift`、`Tests/KongshanCoreTests/NodeNameMetadataTests.swift`；修改 `Sources/kongshan/PolicyGroupsView.swift`、`Sources/kongshan/MenuBarView.swift`。
- 测试结果：RED 验证解析器缺失；GREEN 5 项测试覆盖显式旗帜、JP/香港/洛杉矶/斐济、四种倍率形式、短代码边界和无元数据；修正中文关键词不应按 ASCII 短 token 处理后全部通过；`swift test` 全量回归退出码 0。
- 当前状态：已有搜索、默认/名称/延迟排序完全保留；节点数据和选中逻辑未变，仅增强展示。
- 风险/注意事项：地区是名称启发式推断，无法识别时不显示，不会猜错后写回节点；短国家码必须是独立 token，避免 `project` 误命中 JP。
- 下一步：基于连接 WebSocket 累计字节快照计算单连接实时速率、顶部总速率和排序。
- 下一位 Agent 如何接手：先写 `ConnectionRateTrackerTests` 的首帧、差分、回退、移除连接 RED；时间必须注入，禁止在测试里 sleep。
## 2026-07-22 连接监控实时速率与排序

- 已完成：复用现有每秒连接 WebSocket 推送，以连接 ID 的相邻累计字节/时间差计算每条上传、下载和总速率；顶部显示所有连接总上传/下载；每行同时显示实时 B/s 与累计流量；增加累计流量、实时总速率、下载、上传四种排序。
- 修改文件：新增 `Sources/KongshanCore/ConnectionRateTracker.swift`、`Tests/KongshanCoreTests/ConnectionRateTrackerTests.swift`；修改 `Sources/kongshan/AppState.swift`、`Sources/kongshan/ConnectionsView.swift`。
- 测试结果：RED 验证 tracker 类型缺失；GREEN 4 项测试覆盖首帧 0、两秒差分、累计计数回退、连接移除后重现；UI/应用目标编译通过；全量 `swift test` 通过（含 1 项条件跳过）。
- 当前状态：连接页不增加网络请求，速率更新频率跟随内核 1 秒推送；离页、全部关闭会重置历史样本。
- 风险/注意事项：首个快照必须显示 0 B/s；短于/等于 0 的时间差与字节回退不得产生负数或尖峰。
- 下一步：实现“测速并自动选最快”，只在当前 selector 策略的节点成员内选择最低成功延迟。
- 下一位 Agent 如何接手：扩展 AppState 测速返回值/选择逻辑，先写全成功与全失败 RED，复用现有 `select(optionName:in:)`，不要复制切节点事务。
## 2026-07-22 测速并自动选择最快节点

- 已完成：为 TCP 测速注入可测试提供器；新增当前 selector 策略“测速并选最快”，复用原有有界并发测速和切节点事务；代理页与每个托盘策略子菜单增加一键入口；全失败时保持原节点并明确提示。
- 修改文件：修改 `Sources/kongshan/AppState.swift`、`Sources/kongshan/PolicyGroupsView.swift`、`Sources/kongshan/MenuBarView.swift`、`Tests/KongshanAppTests/AppStateTests.swift`。
- 测试结果：RED 验证 AppState 缺少测速注入点；GREEN 2 项 AppState 测试分别验证 18ms 节点胜过 90ms 节点，以及所有节点超时时保持原选择；全量 `swift test` 通过（1 项条件跳过）。
- 当前状态：自动选择范围严格限制为当前策略的节点成员，不会误选策略引用或其它配置节点；切换仍会关闭旧连接并触发出口刷新。
- 风险/注意事项：urltest 自动策略不可手动选择，按钮禁用；无成功测速结果不得改变当前组选择。
- 下一步：实现分应用代理 UI，并允许 process_name 规则安全指向指定节点 tag。
- 下一位 Agent 如何接手：先给 ConfigGenerator 写指定 node tag 的路由 RED；生成器必须过滤不存在的目标，避免 sing-box check 失败。
## 2026-07-22 分应用代理 UI

- 已完成：规则页新增分应用代理编辑器，可刷新并选择当前运行的普通/辅助 macOS App，设置直连、默认代理或指定当前节点；同进程规则采用 upsert；现有 process_name 规则以胶囊列表展示并可删除；生成器允许 node UUID tag 并把已失效目标安全回退默认代理。
- 修改文件：修改 `Sources/KongshanCore/ConfigGenerator.swift`、`Sources/kongshan/AppState.swift`、`Sources/kongshan/RoutingView.swift`、`Tests/KongshanCoreTests/RoutingConfigTests.swift`、`Tests/KongshanAppTests/AppStateTests.swift`。
- 测试结果：RED 验证悬空 node target 原样写入和 AppState 缺少规则 API；GREEN 验证有效 node tag 精确生效、失效 tag 回退、相同进程替换和删除；14 项 RoutingConfigTests 含多次真实 sing-box check 全通过；全量 `swift test` 通过（1 项条件跳过）。
- 当前状态：process_name 底层与 UI 全链路接通，运行中更新继续走原有热重载/回滚事务；离线更新直接持久化。
- 风险/注意事项：选择列表来自当前运行 App 的可执行文件名；指定节点订阅刷新后若节点 ID 消失会回退默认代理，避免阻断内核启动。
- 下一步：让托盘状态项常驻显示实时上下行，并把仪表盘/托盘从 visibility Bool 改为共享消费者集合，消除订阅互相取消。
- 下一位 Agent 如何接手：先扩展 dashboard monitor 测试覆盖 menu+dashboard 双消费者；必须断言 `/traffic` 只有一次请求且 dashboard 离开后仍在推送。
## 2026-07-22 托盘实时速率与共享订阅

- 已完成：菜单栏状态项在内核运行时显示紧凑下载/上传速率，下拉菜单顶部显示完整 B/s；把单一 `isDashboardVisible` 改为 dashboard/menuBar 消费者集合，两个入口共享唯一 `/traffic` 与 `/connections` WebSocket，只有最后消费者离开才取消；应用启动即注册常驻托盘消费者。
- 修改文件：修改 `Sources/kongshan/AppState.swift`、`Sources/kongshan/KongshanApp.swift`、`Sources/kongshan/MenuBarView.swift`、`Tests/KongshanAppTests/AppStateTests.swift`。
- 测试结果：RED 验证缺少 menu 监控 API；GREEN 新测试断言 menu+dashboard 只有各 1 次 WebSocket 请求、dashboard 离开不终止、menu 最后离开才终止 2 条流；原 dashboard 幂等/关闭/离线测试同组 3 项通过；全量 `swift test` 通过（1 项条件跳过）。
- 当前状态：此前已知的两个订阅互相取消问题已由幂等消费者集合消除；托盘速率在主窗口关闭后仍持续更新。
- 风险/注意事项：状态项文字仅在内核运行时出现，关闭时保持单图标；速率源仍是内核唯一推送，不增加轮询。
- 下一步：实现版本化配置/设置 JSON 导出导入与 Settings → 更多 UI。
- 下一位 Agent 如何接手：先写备份模型 round-trip/版本拒绝 RED；导入必须在停止状态，完整验证后才替换内存与磁盘，不得包含日志、缓存或运行时密钥。
