# kongshan 原生 macOS 代理客户端设计

日期：2026-07-20

应用名：`kongshan`

Bundle Identifier：`com.kaysen.kongshan`

目标平台：macOS 14+，仅 arm64

## 1. 权威需求与范围

本设计严格以 [`docs/requirements/original-prompt.md`](../../requirements/original-prompt.md) 为功能和验收权威，不删减 M1 至 M4 的明确需求。应用是 sing-box 的原生 SwiftUI GUI 外壳，不实现代理协议、加密算法或网络内核。

截至 2026-07-20，sing-box 官方最新 1.13 stable 为 `1.13.14`，M1 固定并校验官方 `darwin-arm64` 产物；不使用 1.14 alpha。版本依据：[官方 Releases](https://github.com/SagerNet/sing-box/releases/tag/v1.13.14)，下载包 SHA-256 为 `73e8967b0fc08e17bce4263ca56ebc394822401a16497a1c4e02316c888202ab`。

## 2. 工程路径比较与结论

### 方案 A：Swift Package Manager + 原生打包脚本（采用）

- SwiftPM 管理 App 可执行目标、核心库、资源和 XCTest；Xcode 可直接打开 `Package.swift`。
- 一个短脚本调用 `swift build`，组装标准 `.app/Contents`、复制 sing-box 和资源、写入 Info.plist，并执行 ad-hoc 签名。
- 优点：工程文件可读、测试简单、无需手写易损坏的 `project.pbxproj`，也不新增工程生成器。
- 代价：签名、打包步骤在脚本中显式维护；个人自用场景可接受。

### 方案 B：手写并维护 Xcode `.xcodeproj`

- 优点：最符合传统 Xcode App 工程使用习惯。
- 缺点：Agent 手工维护 pbxproj 容易产生无意义差异和引用错误，测试与资源配置更脆弱。

### 方案 C：XcodeGen 或 Tuist

- 优点：可生成规范 Xcode 工程。
- 缺点：增加任务未授权的外部工具和配置层；违反“除 Yams 外不为小问题新增依赖”的约束。

结论：采用 A。最终交付仍是标准原生 `kongshan.app`，不是命令行程序或 Web 套壳。

## 3. 最小架构

仓库只设两个 Swift target：

1. `KongshanCore`：模型、订阅转换、配置生成、存储、sing-box 进程、系统代理、Clash API。
2. `kongshan`：`MenuBarExtra`、独立主窗口、页面和全局状态协调。

另设一个 `KongshanCoreTests` 测试 target。只引入 Yams 解析 Clash YAML；HTTP、WebSocket、JSON、进程、文件、图表和通知全部使用 Apple 原生框架。

共享状态由单个 `@MainActor AppState` 管理。文件、子进程、网络请求和 WebSocket 放入少量职责明确的 actor；不创建单实现接口、工厂或预留插件系统。

## 4. 数据与安全边界

持久数据位于 `~/Library/Application Support/kongshan/`：

- `settings.json`：模式、DNS、测速 URL、自动更新间隔等设置。
- `subscriptions.json` 与 `subscriptions/`：订阅元数据和最后一次成功缓存。
- `rules.json`：自定义规则、绕过列表和排序。
- `rule-sets/`：校验通过的 `.srs` 缓存。
- `config.json`：不含运行时 Clash API 端口和 secret 的稳定配置快照。
- `logs/`：内核日志与 App 诊断日志。
- `proxy-recovery.json`：仅在系统代理被 kongshan 修改期间存在的恢复快照。

每次启动随机选择 loopback 高位端口，并用 `SecRandomCopyBytes` 生成 secret。完整运行时配置只通过 `/dev/stdin` 或受限命名管道传给 sing-box；不把端口和 secret 写入持久文件。`config.json` 仅用于可读诊断，运行时字段被移除。所有本地控制接口只监听 `127.0.0.1`。

## 5. 核心数据流

### 5.1 订阅导入

`URLSession` 下载 YAML → Yams 解码 → 转为统一 `ProxyNode` → 跳过并记录不支持类型 → 原子写入成功缓存 → 刷新节点列表。转换覆盖 SS/SS2022、Trojan、VMess、Hysteria2、AnyTLS 的常用 TLS 与 transport 字段。网络失败、HTTP 失败或解析失败时保留旧缓存并发非阻塞通知。

手动 Hysteria2 表单写入同一 `ProxyNode` 模型，但来源标记为 `manual`，生成独立“自建” selector。

### 5.2 配置生成与启动

纯函数 `ConfigGenerator.generate(input:)` 接收设置、节点、规则和运行时参数，输出确定性的完整 JSON；不读写文件、不调用进程。

启动顺序固定为：

1. 生成配置并保存无 secret 的诊断快照。
2. 使用同一份完整 JSON 执行 `sing-box check -c /dev/stdin`。
3. 校验成功后再启动内核；失败则显示可读 stderr，保持代理关闭。
4. Clash API 健康检查成功后才修改系统代理或宣告 TUN 已启用。
5. 任一步失败均反向清理进程、代理状态和临时资源。

规则生成严格按需求中的六级优先级；selector/urltest 组在同一次纯函数生成中完成，避免 UI 与实际配置产生两份逻辑。

### 5.3 系统代理模式与恢复

启用前枚举所有启用的网络服务，读取 HTTP/HTTPS/SOCKS/bypass 原值并写入 `proxy-recovery.json`，随后指向 mixed inbound。关闭或正常退出时按快照精确恢复而不是一律关闭。

若 App 被强杀，恢复文件仍在；下次启动先执行自愈恢复，再允许开启代理。恢复成功才删除快照。命令均设置超时并收集 stdout/stderr，不静默吞错。

### 5.4 TUN 模式

TUN 启动由独立 `PrivilegedLauncher` 封装。它用 `Process` 启动 `/usr/bin/osascript`，通过系统管理员授权弹窗运行官方 sing-box；完整配置通过只在内存流动的受限管道交给 root 进程。该模块写明未来迁移到 `SMAppService` 特权 helper 或 Network Extension 的边界，但 MVP 不实现未授权 entitlement。

App 保存已授权启动返回的 PID，监控存活并通过明确的管理员授权停止。系统代理与 TUN 由一个小型状态机互斥切换；切换先完整关闭旧模式再启动新模式，失败时回到关闭态。

### 5.5 Clash API 与 Dashboard

- 节点选择、单个/批量延迟由 Clash API HTTP 接口完成；批量任务使用原生 `TaskGroup`，并发上限 8。
- `/traffic` 和 `/connections` 使用 WebSocket；主窗口关闭即取消任务和连接。
- 内核内存采样只由已收到的 Dashboard 推送事件节流触发，不创建后台轮询器。
- 60 秒曲线只保留 60 个内存样本，Swift Charts 渲染。

## 6. UI 结构

菜单栏使用三种 SF Symbol 状态区分：关闭、系统代理、TUN；菜单中提供一键开关、当前节点、模式切换和打开主窗口。

主窗口使用原生 `NavigationSplitView`，页面固定为：Dashboard、节点、规则、日志、设置。节点按来源分组；规则支持原生拖拽排序；延迟按绿/黄/红/灰显示并同时保留文本，避免只靠颜色表达状态。界面跟随系统深浅色，不加入自定义动效或第三方 UI 库。

## 7. 错误处理与自愈

- 内核意外退出后按滑动窗口计数：10 秒内最多自动重启 3 次，超过后停止并通知。
- 用户主动停止不计入崩溃重启。
- 原子文件写入采用临时文件加替换；旧订阅、规则集和设置在新数据校验成功前不覆盖。
- 规则集下载先校验 HTTP、非空内容及 `sing-box check` 可用性，再替换缓存；离线时用最后成功缓存。
- App 退出按顺序停止 WebSocket、恢复系统代理、停止内核；清理失败会记录并在下次启动重试。
- 不在自动化测试中真实修改当前 Mac 的网络代理或请求管理员授权，避免开发过程中断网；这些操作由明确的人工验收步骤执行。

## 8. 测试与验收策略

自动测试最少覆盖：

- Clash YAML 五类协议和 SS2022 转换；未知类型跳过且保留其他节点。
- 路由六级优先级和 selector/urltest/自建组。
- 绕过列表向 route、系统代理 bypass 参数、TUN route exclude 三处注入。
- 配置 JSON 的确定性、secret 不落盘和错误可读性。
- 系统代理快照的解析与恢复命令生成，不执行真实网络修改。
- 崩溃重启窗口和模式状态机。

每个里程碑必须同时通过 `swift test`、release 构建、`.app` 组装、ad-hoc 签名验证、内置 `sing-box check` 冒烟测试，再追加会话记录。真实订阅、Google 连通、出口 IP、DNS 泄漏、强杀恢复、24 小时资源曲线属于人工验收，结果如实记录，不能用单元测试替代。

## 9. 里程碑交付边界

- M1：可导入/手动添加节点、生成并校验配置、系统代理开关、选择与测速、菜单栏、可运行 `.app`。
- M2：固定分流、自定义规则、route 与系统 bypass、热重启小于 2 秒的本机测量。
- M3：TUN 提权、路由排除、strict route、完整互斥状态机。
- M4：Dashboard、日志、DNS、开机自启、订阅调度、崩溃自愈和性能检查。

每完成上述任一小节，立即追加 `docs/progress/SESSION_LOG.md`；每个里程碑更新 HANDOFF、PROGRESS、NEXT_STEPS，并留下可运行产物路径和自测命令。

## 10. 明确不做

- 不实现代理协议、规则集转换服务、插件系统、云同步、账号体系、更新器或多平台支持。
- 不引入 Network Extension、特权 helper、Electron、Flutter、WebView、XcodeGen/Tuist 或 Yams 之外的第三方依赖。
- 不在没有真实环境证据时声称 Google、TUN、DNS 泄漏或 24 小时性能验收通过。
