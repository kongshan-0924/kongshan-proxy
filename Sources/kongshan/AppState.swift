import AppKit
import Foundation
import KongshanCore
import Network
import Observation

/// 策略组里的一个可选成员：节点，或对另一个策略组 / DIRECT / REJECT 的引用。
enum GroupOption: Identifiable, Sendable {
    case node(ProxyNode)
    case reference(String)

    var id: String {
        switch self {
        case let .node(node): node.id.uuidString
        case let .reference(name): "ref:\(name)"
        }
    }

    var name: String {
        switch self {
        case let .node(node): node.name
        case let .reference(name): name
        }
    }
}

struct TrafficPoint: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let upload: Int64
    let download: Int64

    init(id: UUID = UUID(), timestamp: Date, upload: Int64, download: Int64) {
        self.id = id
        self.timestamp = timestamp
        self.upload = upload
        self.download = download
    }
}

struct LiveLogEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let entry: CoreLogEntry
    /// 结构化解析结果（连接 ID / 主机 / 类别）。
    ///
    /// **必须在入库时解析一次并存下来**，不能在视图里按需解析：日志页按连接聚合与按主机
    /// 搜索都要用它，而这两处都在 view body 里——2000 行 × 每来一条日志重算一次，
    /// 高负载下就是每秒几万次字符串扫描。入库是每行只发生一次的地方。
    let parsed: CoreLogLine

    init(id: UUID = UUID(), entry: CoreLogEntry) {
        self.id = id
        self.entry = entry
        self.parsed = CoreLogLine.parse(entry.message)
    }
}

private final class AppWarningRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (String) -> Void)?

    func install(_ handler: @escaping @Sendable (String) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func send(_ message: String) {
        let handler = lock.withLock { self.handler }
        handler?(message)
    }
}

@MainActor
@Observable
final class AppState {
    /// 入参是上次用过的 mixed 端口，可用就复用（见 `RuntimeSecrets.stableHighPort(preferred:)`）。
    /// 是 `async` 的：首选端口撞占用时要退避重试，不能同步 sleep 卡住主线程。
    typealias RuntimeFactory = @Sendable (UInt16?) async throws -> RuntimeParameters
    typealias HealthVerifier = @Sendable (ClashAPIClient) async throws -> Void
    typealias ClashClientFactory = @Sendable (URL, String) -> ClashAPIClient
    typealias NowProvider = @Sendable () -> Date
    typealias ExitDiagnosticsProvider = @Sendable (String) async throws -> ExitDiagnosticsReport
    typealias TCPPingProvider = @Sendable (String, Int) async -> DelayResult
    /// 入参是要排除的地址（TUN 自身），返回探测到的内网 DNS 快照。
    typealias LANResolverProbing = @Sendable (Set<String>) async -> LANResolverSnapshot

    enum Status: Equatable {
        case off
        case starting
        case on
        case stopping
        case failed(String)
    }

    private enum DashboardMonitorConsumer: Hashable {
        case dashboard
        case menuBar
    }

    private enum TUNBackend {
        case helper
        case fallback
    }

    var status: Status = .off
    var nodes: [ProxyNode] = []
    var subscriptions: [SubscriptionSource] = []
    var selectedNodeID: UUID?
    var delays: [UUID: Int?] = [:]
    var mixedPort: UInt16?
    var testURLString = "http://www.gstatic.com/generate_204"
    var speedTestMethod: SpeedTestMethod = .tcpPing
    var errorMessage: String?
    var warnings: [String] = []
    private(set) var runtimeEvents: [RuntimeEvent] = []
    var isReady = false
    var routingSettings = RoutingSettings.defaults
    var preferredMode: ProxyMode = .systemProxy
    private(set) var outboundMode: OutboundMode = .rule
    /// 生效中的接管方式，两者可同时存在。
    private(set) var activeModes: Set<ProxyMode> = []

    /// 兼容旧调用点：同时开启时以 TUN 为主（它决定内核是否以 root 运行）。
    var activeMode: ProxyMode? {
        if activeModes.contains(.tun) { return .tun }
        return activeModes.contains(.systemProxy) ? .systemProxy : nil
    }
    var tunSettings: TunSettings = .defaults
    var dnsSettings: DNSSettings = .defaults
    private(set) var subscriptionUpdateSettings = SubscriptionUpdateSettings.defaults
    private(set) var ruleSetSettings = RuleSetSettings.defaults
    private(set) var isUpdatingRuleSets = false
    private(set) var nextSubscriptionUpdateAt: Date?
    private(set) var loginItemStatus: LoginItemStatus = .notRegistered
    private(set) var uploadRate: Int64 = 0
    private(set) var downloadRate: Int64 = 0
    private(set) var activeConnectionCount = 0
    private(set) var coreMemory: UInt64 = 0
    private(set) var coreVersion = "—"
    private(set) var isCheckingKernelUpdate = false
    /// 连接监控页的实时连接列表（仅该页可见时才轮询）。
    private(set) var connections: [ConnectionLiveDetail] = []
    @ObservationIgnored private var connectionsTask: Task<Void, Never>?
    @ObservationIgnored private var connectionRateTracker = ConnectionRateTracker()
    private(set) var runtimeStartedAt: Date?
    private(set) var trafficHistory: [TrafficPoint] = []
    /// 只让一半的流量采样点进图表，见 receiveTraffic。
    @ObservationIgnored private var trafficSampleParity = false
    /// 整机网卡速率（菜单栏用）。
    ///
    /// 与 `uploadRate`/`downloadRate` 不是一回事：那两个读的是内核 `/traffic`，
    /// **只统计走代理的流量**，且代理没开时恒为 0。菜单栏要回答的是"现在网速多少"，
    /// 所以直接读物理网卡计数器，代理开不开都有读数。见 `NetworkThroughput`。
    /// **发布的是格式化后的文字，不是原始字节数**。
    ///
    /// 菜单栏每秒读一次这两个值。原始速率几乎每秒都在变（哪怕只差几字节），
    /// 而 `@Observable` 的每次写入都会失效视图图 → MenuBarExtra 的 label 重建 →
    /// 重新绘制 NSImage → 状态项尺寸变化 → 整条菜单栏重排。
    /// 按**显示文字**比较能把绝大多数无谓的更新挡在源头：空闲时文字长时间是 `—`，
    /// 有流量时同一档位内（如 1.2M）也往往连续多秒不变。
    private(set) var nicUploadText = "—"
    private(set) var nicDownloadText = "—"
    @ObservationIgnored private var throughputCalculator = ThroughputRateCalculator()
    @ObservationIgnored private var throughputTask: Task<Void, Never>?

    /// 本次接管会话的累计流量。跨内核重启连续，停止接管时归零。
    /// 见 `SessionTrafficAccumulator` —— 数据源必须是内核的权威累计量，不能靠速率积分。
    private(set) var sessionUpload: Int64 = 0
    private(set) var sessionDownload: Int64 = 0
    var sessionTotal: Int64 { sessionUpload + sessionDownload }
    @ObservationIgnored private var sessionTraffic = SessionTrafficAccumulator()
    private(set) var liveLogs: [LiveLogEntry] = []
    private(set) var logLevel: CoreLogLevel = .info
    private(set) var isApplyingRouting = false
    private(set) var exitDiagnostics: ExitDiagnosticsReport?
    private(set) var exitDiagnosticsError: String?
    private(set) var isRefreshingExitDiagnostics = false
    private(set) var isTestingAllDelays = false
    /// 各订阅自带的策略组（来自 Clash 的 proxy-groups），键为订阅 ID。
    var discoveredPolicyGroups: [UUID: [PolicyGroup]] = [:]
    /// 各订阅自带的分流规则（Clash 的 rules:），键为订阅 ID。
    var discoveredRules: [UUID: [SubscriptionRule]] = [:]
    /// 当前生效的配置（订阅）ID。同一时刻只有一个配置生效——这是 Stash 式的心智模型：
    /// 一个机场 = 一个配置文件，切换后其节点/策略/规则整套替换。
    /// `localConfigID` 代表「本地自建节点」这个特殊配置。
    var activeConfigID: UUID?

    /// 手动自建节点归属的伪配置 ID。
    static let localConfigID = UUID(uuidString: "10CA110C-0000-0000-0000-000000000001")!

    /// 当前生效配置里的节点。订阅配置→该订阅的节点；本地配置→自建节点。
    var activeConfigNodes: [ProxyNode] {
        guard let activeConfigID else { return [] }
        if activeConfigID == Self.localConfigID { return manualNodes }
        return nodes.filter { $0.sourceID == activeConfigID }
    }

    /// 可测速/可选择的节点：当前配置里排除机场塞进来的套餐信息条目。
    var testableNodes: [ProxyNode] {
        activeConfigNodes.filter { !$0.isSubscriptionInfo }
    }

    /// 当前配置自带的策略组（带真实成员）。本地配置没有，返回空。
    var activeConfigPolicyGroups: [PolicyGroup] {
        guard let activeConfigID, activeConfigID != Self.localConfigID else { return [] }
        return discoveredPolicyGroups[activeConfigID] ?? []
    }

    /// 当前配置自带的分流规则（只读展示 + 写入运行配置）。
    var subscriptionRules: [SubscriptionRule] {
        guard let activeConfigID, activeConfigID != Self.localConfigID else { return [] }
        var seen = Set<String>()
        return (discoveredRules[activeConfigID] ?? []).filter { seen.insert($0.id).inserted }
    }

    /// 只有这些内容会进入当前运行配置。其它订阅的节点、用量和更新时间变化都不该重启内核。
    private struct ActiveRuntimeContent: Equatable {
        let id: UUID?
        let nodes: [ProxyNode]
        let policyGroups: [PolicyGroup]
        let rules: [SubscriptionRule]
    }

    private var activeRuntimeContent: ActiveRuntimeContent {
        ActiveRuntimeContent(
            id: activeConfigID,
            nodes: activeConfigNodes,
            policyGroups: activeConfigPolicyGroups,
            rules: subscriptionRules
        )
    }

    /// 配置页展示用的一项配置。
    struct ConfigItem: Identifiable, Sendable {
        let id: UUID
        let name: String
        let nodeCount: Int
        let isLocal: Bool
        let usage: SubscriptionUsage?
        let lastUpdatedAt: Date?
        let autoUpdate: Bool
    }

    struct RunningApp: Identifiable, Hashable {
        var id: String { processName }
        let name: String
        let processName: String
    }

    var runningApplications: [RunningApp] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { application in
            guard !application.isTerminated,
                  application.activationPolicy != .prohibited,
                  let processName = application.executableURL?.lastPathComponent,
                  !processName.isEmpty,
                  seen.insert(processName).inserted else { return nil }
            return RunningApp(name: application.localizedName ?? processName, processName: processName)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var processRules: [CustomRouteRule] {
        routingSettings.customRules.filter { $0.type == .processName }
    }

    /// 全部配置：每个订阅一项，另有自建节点时追加「本地节点」。
    var configItems: [ConfigItem] {
        var items = subscriptions.map { source in
            ConfigItem(
                id: source.id,
                name: source.name,
                nodeCount: nodes.filter { $0.sourceID == source.id && !$0.isSubscriptionInfo }.count,
                isLocal: false,
                usage: source.usage,
                lastUpdatedAt: source.lastUpdatedAt,
                autoUpdate: source.autoUpdate
            )
        }
        if !manualNodes.isEmpty {
            items.append(ConfigItem(
                id: Self.localConfigID,
                name: "本地节点",
                nodeCount: manualNodes.count,
                isLocal: true,
                usage: nil,
                lastUpdatedAt: nil,
                autoUpdate: false
            ))
        }
        return items
    }

    /// 切换生效配置。组选择与延迟按节点归属，换配置即清空；运行中则用新配置热重载。
    func setActiveConfig(_ id: UUID) async {
        guard id != activeConfigID, configItems.contains(where: { $0.id == id }) else { return }
        activeConfigID = id
        groupSelections = [:]
        selectedNodeID = nil
        delays = [:]
        selectFirstNodeIfNeeded()
        try? await persistSettings()
        await hotReloadAfterNodeChange()
    }

    /// 没有生效配置或它已消失时，挑一个可用配置顶上。
    private func ensureActiveConfig() {
        if let activeConfigID, configItems.contains(where: { $0.id == activeConfigID }) { return }
        activeConfigID = configItems.first?.id
        selectFirstNodeIfNeeded()
    }

    /// 仅供离屏渲染自查使用。
    var snapshotSourceID: UUID?

    @ObservationIgnored private let storage: Storage
    @ObservationIgnored private let subscriptionService: SubscriptionService
    @ObservationIgnored private let ruleSetService: RuleSetService
    @ObservationIgnored private let systemProxyManager: SystemProxyManager
    @ObservationIgnored private let systemDNSManager: SystemDNSManager
    /// 网络路径监听（切 Wi-Fi / 插网线 / 新服务出现时补挂代理与 DNS）。事件驱动，非轮询。
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var pathChangeTask: Task<Void, Never>?
    /// 上一次记录的物理网络指纹，用于判断"网络是否真的换了"（而不是信号抖动）。
    @ObservationIgnored private var lastNetworkSignature: String?
    /// 通知观察者令牌。交给独立持有者统一摘除，见 `NotificationObserverBag`。
    @ObservationIgnored private let observerBag = NotificationObserverBag()
    /// 窗口内容是否真的在屏幕上。
    ///
    /// SwiftUI 的 onAppear/onDisappear 只反映"页面还在导航栈里"：App 被切到后台、
    /// 窗口被完全遮挡、最小化，全都不会触发。而 `@Observable` 的写入**不做等值判断**，
    /// 每秒往仪表盘/连接列表写一次就失效整棵视图图，AppKit 照样跑完整的布局与
    /// CoreAnimation 提交——实机出现过后台空闲烧 50% CPU 持续 178 秒
    /// （栈里 96 层 `_layoutSubtreeWithOldSize`，业务帧一个都没有）。
    ///
    /// 只挡"没人看的视图状态"，不挡数据流本身：托盘速率在菜单栏始终可见，
    /// 连接速率跟踪也要连续采样才算得准，两者都不受此标志影响。
    @ObservationIgnored private var windowContentIsVisible = true
    /// 是否监听系统事件（网络路径、睡眠唤醒）。测试夹具以 automaticallyInitialize=false
    /// 构建，不该有后台监听扰动断言的命令序列，因此跟随该标志。
    @ObservationIgnored private let monitorsSystemEvents: Bool
    @ObservationIgnored private let singBoxProcess: SingBoxProcess
    @ObservationIgnored private let processExitMonitor: any ProcessExitMonitoring
    @ObservationIgnored private let privilegedLauncher: any PrivilegedLaunching
    @ObservationIgnored private let runtimeFactory: RuntimeFactory
    @ObservationIgnored private let healthVerifier: HealthVerifier
    @ObservationIgnored private let clashClientFactory: ClashClientFactory
    @ObservationIgnored private let now: NowProvider
    @ObservationIgnored private let exitDiagnosticsProvider: ExitDiagnosticsProvider
    @ObservationIgnored private let tcpPingProvider: TCPPingProvider
    @ObservationIgnored private let kernelLogStore: KernelLogStore
    @ObservationIgnored private let subscriptionUpdateScheduler: SubscriptionUpdateScheduler
    @ObservationIgnored private let notificationSender: any NotificationSending
    @ObservationIgnored private let loginItemManager: any LoginItemManaging
    @ObservationIgnored private var clashAPIClient: ClashAPIClient?
    @ObservationIgnored private var runtime: RuntimeParameters?
    /// TUN 接管系统 DNS 之前探测到的内网 DNS 与搜索域。见 `LANResolverSnapshot`。
    /// 接管期间探测不到，所以要在内存里留住上一次的结果。
    @ObservationIgnored private(set) var lanResolverSnapshot: LANResolverSnapshot = .empty
    /// 菜单栏图标样式，用户可在设置里切换。
    private(set) var menuBarIconStyle: MenuBarIconStyle = .peak
    /// 上次实际用过的 mixed 端口，落盘复用。系统代理的地址会被 Chromium 系客户端缓存，
    /// 每次启动换端口会让它们打死端口、反复「正在重新连接」。nil 表示还没分配过。
    @ObservationIgnored private var preferredMixedPort: UInt16?
    @ObservationIgnored private var currentConfig: Data?
    @ObservationIgnored private var dashboardTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var dashboardMonitorConsumers: Set<DashboardMonitorConsumer> = []
    @ObservationIgnored private var logTask: Task<Void, Never>?
    @ObservationIgnored private var isLogsVisible = false
    /// 尚未并入 `liveLogs` 的日志行，以及负责并入的定时任务。见 `receiveLog`。
    @ObservationIgnored private var pendingLogs: [LiveLogEntry] = []
    @ObservationIgnored private var logFlushTask: Task<Void, Never>?
    /// 断流重连（睡眠唤醒后 WebSocket 必断）。指数退避，收到数据即复位。
    @ObservationIgnored private var dashboardRetryTask: Task<Void, Never>?
    @ObservationIgnored private var dashboardRetryDelay: Double = 2
    @ObservationIgnored private var logRetryTask: Task<Void, Never>?
    @ObservationIgnored private var logRetryDelay: Double = 2
    @ObservationIgnored private var monitoredCorePID: Int32?
    @ObservationIgnored private var crashRestartLimiter = CrashRestartLimiter()
    @ObservationIgnored private var isHandlingCoreCrash = false
    /// 崩溃自愈期间用户点 stop 的中止信号。handleUnexpectedCoreExit 在每个 await 之后检查，
    /// 若置位则不再恢复 .on 状态、不再 arm 监控，让 stop() 接管清理。
    @ObservationIgnored private var stopRequestedDuringCrashHandling = false
    /// 切节点等高频操作的落盘防抖任务。500ms 内的多次切节点只触发一次磁盘写入，
    /// 避免连续点选节点时每次都同步落盘 settings.json。退出前 flush 确保最后一次选择不丢。
    @ObservationIgnored private var persistSettingsTask: Task<Void, Never>?
    @ObservationIgnored private var persistRuntimeEventsTask: Task<Void, Never>?

    /// 特权助手客户端（零弹窗 TUN）。助手不可达时回退 `privilegedLauncher`（osascript）。
    @ObservationIgnored private let helperClient: PrivilegedHelperClient
    @ObservationIgnored private let lanResolverProbe: LANResolverProbing
    /// 一次 TUN 生命周期固定使用同一后端，避免 helper 状态变化后 stop/reload 操作错进程。
    @ObservationIgnored private var activeTUNBackend: TUNBackend?
    /// 助手安装状态（UI 展示 + 决定是否走 helper 路径）。
    private(set) var helperInstallStatus: HelperInstallStatus = .notInstalled
    /// 助手安装/卸载进行中（UI 禁用按钮）。
    private(set) var isHelperOperationInProgress = false

    init(
        storage: Storage = Storage(),
        subscriptionService: SubscriptionService? = nil,
        ruleSetService: RuleSetService? = nil,
        systemProxyManager: SystemProxyManager? = nil,
        systemDNSManager: SystemDNSManager? = nil,
        singBoxProcess: SingBoxProcess? = nil,
        processExitMonitor: (any ProcessExitMonitoring)? = nil,
        kernelLogStore: KernelLogStore? = nil,
        subscriptionUpdateScheduler: SubscriptionUpdateScheduler? = nil,
        notificationSender: (any NotificationSending)? = nil,
        loginItemManager: (any LoginItemManaging)? = nil,
        privilegedLauncher: (any PrivilegedLaunching)? = nil,
        runtimeFactory: RuntimeFactory? = nil,
        healthVerifier: HealthVerifier? = nil,
        clashClientFactory: ClashClientFactory? = nil,
        exitDiagnosticsProvider: ExitDiagnosticsProvider? = nil,
        tcpPingProvider: TCPPingProvider? = nil,
        lanResolverProbe: LANResolverProbing? = nil,
        now: @escaping NowProvider = Date.init,
        automaticallyInitialize: Bool = true
    ) {
        let binaryURL = Self.singBoxBinaryURL()
        let logWarningRelay = AppWarningRelay()
        let resolvedLogStore = kernelLogStore ?? KernelLogStore(
            directory: storage.rootDirectory.appending(path: "logs", directoryHint: .isDirectory),
            errorHandler: logWarningRelay.send
        )
        self.storage = storage
        self.subscriptionService = subscriptionService ?? SubscriptionService(storage: storage)
        self.ruleSetService = ruleSetService ?? RuleSetService(storage: storage, binaryURL: binaryURL)
        self.systemProxyManager = systemProxyManager ?? SystemProxyManager(storage: storage)
        self.systemDNSManager = systemDNSManager ?? SystemDNSManager(storage: storage)
        self.singBoxProcess = singBoxProcess ?? SingBoxProcess(
            binaryURL: binaryURL,
            logStore: resolvedLogStore,
            logErrorHandler: logWarningRelay.send
        )
        self.processExitMonitor = processExitMonitor ?? ProcessExitMonitor()
        self.privilegedLauncher = privilegedLauncher ?? PrivilegedLauncher(
            storage: storage,
            binaryURL: binaryURL,
            logStore: resolvedLogStore,
            logErrorHandler: logWarningRelay.send
        )
        self.helperClient = PrivilegedHelperClient(binaryURL: binaryURL)
        // 探测要跑 `scutil --dns` 和 `dig`，是**读真实宿主网络**的操作。
        // 沿用本项目既有约定（`automaticallyInitialize == false` 的测试夹具不碰真实系统）：
        // 夹具默认拿到空探测器。否则单测会读到开发机所在网络的内网 DNS 与域名，
        // 悄悄污染绕过列表断言——真机上这条链路一切正常，CI 却在别人机器上飘。
        // 想验证探测本身的测试自行注入。
        let liveProbe: LANResolverProbing = { excluded in
            let physical = await LANResolver.probePhysicalService(excluding: excluded)
            if !physical.servers.isEmpty { return physical }
            return await LANResolver.probe(excluding: excluded)
        }
        let inertProbe: LANResolverProbing = { _ in .empty }
        self.lanResolverProbe = lanResolverProbe ?? (automaticallyInitialize ? liveProbe : inertProbe)
        self.runtimeFactory = runtimeFactory ?? Self.makeRuntimeParameters
        self.healthVerifier = healthVerifier ?? Self.waitUntilHealthy
        self.clashClientFactory = clashClientFactory ?? { controller, secret in
            ClashAPIClient(controller: controller, secret: secret)
        }
        self.exitDiagnosticsProvider = exitDiagnosticsProvider ?? { remoteDoH in
            try await ExitDiagnosticsService().run(remoteDoH: remoteDoH)
        }
        self.tcpPingProvider = tcpPingProvider ?? { host, port in
            await TCPPinger.ping(host: host, port: port)
        }
        self.now = now
        self.kernelLogStore = resolvedLogStore
        self.subscriptionUpdateScheduler = subscriptionUpdateScheduler ?? SubscriptionUpdateScheduler(now: now)
        self.notificationSender = notificationSender ?? NotificationService()
        self.loginItemManager = loginItemManager ?? LoginItemManager()
        monitorsSystemEvents = automaticallyInitialize
        logWarningRelay.install { [weak self] message in
            Task { @MainActor [weak self] in
                self?.appendWarning("内核日志写入失败：\(message)")
            }
        }
        if monitorsSystemEvents {
            // 睡眠唤醒后核心可能进入拒绝连接的假死态（sing-box#1709），网络也可能已切换。
            observerBag.add(to: NSWorkspace.shared.notificationCenter, NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleDidWake()
                }
            })
            // 窗口被遮挡/App 进后台时停掉"没人看的"视图状态刷新，见 windowContentIsVisible。
            observerBag.add(to: .default, NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeOcclusionStateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.windowContentIsVisible = NSApplication.shared.occlusionState.contains(.visible)
                }
            })
        }

        if automaticallyInitialize {
            Task { await initialize() }
        }
    }

    var isBusy: Bool {
        status == .starting || status == .stopping || isApplyingRouting
    }

    func refreshExitDiagnostics() async {
        guard !isRefreshingExitDiagnostics else { return }
        isRefreshingExitDiagnostics = true
        defer { isRefreshingExitDiagnostics = false }
        do {
            exitDiagnostics = try await exitDiagnosticsProvider(dnsSettings.remoteDoH)
            exitDiagnosticsError = nil
        } catch {
            exitDiagnosticsError = "出口诊断失败：\(error.localizedDescription)"
        }
    }

    var isOn: Bool {
        status == .on
    }

    /// 启动后的一次出口自检。内核起得来、控制接口健康，不代表**节点**通——
    /// 节点被墙/服务器挂了时，App 会显示"已开启"而用户什么网页都打不开，且毫无线索。
    /// 接管已生效却探测不到出口时给一条明确提示，指向真正该做的事（测速/换节点）。
    private func verifyExitAfterStart() async {
        await refreshExitDiagnostics()
        guard status == .on, !activeModes.isEmpty, exitDiagnosticsError != nil else { return }
        appendWarning("已接管但探测不到出口，当前节点可能连不上——请到节点页测速或换一个节点")
    }

    var selectedNode: ProxyNode? {
        nodes.first { $0.id == selectedNodeID }
    }

    var menuBarSymbol: String {
        if let activeMode {
            return activeMode == .tun ? "network.badge.shield.half.filled" : "shield.fill"
        }
        return switch status {
        case .starting, .stopping, .on: "shield.lefthalf.filled"
        case .off, .failed: "shield.slash"
        }
    }

    var statusText: String {
        switch status {
        case .off:
            return "已关闭"
        case .starting:
            return preferredMode == .tun ? "正在启动 TUN…" : "正在启动系统代理…"
        case .on:
            // 内核可以在不接管任何流量的情况下运行（测速、节点管理只需要这个状态）
            guard !activeModes.isEmpty else { return "内核已就绪（未接管）" }
            let ordered: [ProxyMode] = [.systemProxy, .tun]
            let names = ordered.filter(activeModes.contains).map(\.displayName)
            return names.joined(separator: " + ") + "已开启"
        case .stopping:
            return "正在关闭…"
        case let .failed(message):
            return "失败：\(message)"
        }
    }

    /// 0 时用固定占位符，避免空串让菜单栏宽度来回跳。
    nonisolated static func menuRateText(_ value: Int64) -> String {
        let text = MenuRateFormatter.compact(value)
        return text.isEmpty ? "—" : text
    }

    /// 每 2 秒采一次网卡计数器。菜单栏常驻，所以这个循环也常驻——
    /// 一次 sysctl 是微秒级，比为省这点开销而让菜单栏时有时无划算。
    private func startThroughputSampling() {
        guard throughputTask == nil else { return }
        throughputTask = Task { [weak self] in
            while !Task.isCancelled {
                if let counters = NetworkThroughput.physicalCounters() {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        let rate = self.throughputCalculator.rate(from: counters, at: self.now())
                        let up = Self.menuRateText(rate.upload)
                        let down = Self.menuRateText(rate.download)
                        if self.nicUploadText != up { self.nicUploadText = up }
                        if self.nicDownloadText != down { self.nicDownloadText = down }
                    }
                }
                // 2 秒一次。菜单栏速率是"扫一眼知道有没有在跑"的信息，不需要秒级精度；
                // 而每次更新的真实代价是一次全菜单栏重排，频率减半就是代价减半。
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func initialize() async {
        startThroughputSampling()
        guard !isReady else { return }
        do {
            // 清理上次遗留的接管。常见情况（无残留记录）都是秒回的空操作；
            // 只有真有残留 root TUN 内核时才会走授权，那正是我们要清掉的僵尸隧道。
            try await recoverTUNIfNeeded()
            // 配置仍要加载，但恢复失败必须保留快照并提示，不能静默丢掉再次恢复的机会。
            do {
                try await systemProxyManager.recoverIfNeeded()
            } catch {
                appendWarning("启动时恢复系统代理失败：\(error.localizedDescription)")
            }
            do {
                try await systemDNSManager.recoverIfNeeded()
            } catch {
                appendWarning("启动时恢复系统 DNS 失败：\(error.localizedDescription)")
            }
            try await storage.prepare()
            // 大订阅 YAML 的解析已挪到后台线程（见 loadPersistedState），不再卡住启动。
            try await loadPersistedState()
            isReady = true
            loginItemStatus = await loginItemManager.currentStatus()
            await rescheduleSubscriptionUpdates()
        } catch {
            setFailure("启动恢复失败：\(error.localizedDescription)")
        }
    }

    func startSystemProxy() async {
        await startPreferredProxy()
    }

    func startPreferredProxy() async {
        await start(modes: [preferredMode])
    }

    /// 开启或关闭单个接管方式；两者互不排斥，可同时生效。
    /// 变更需要重建内核配置，因此先完整停机再按新集合启动。
    func setMode(_ mode: ProxyMode, enabled: Bool) async {
        guard !isBusy, isReady else { return }
        var target = activeModes
        if enabled { target.insert(mode) } else { target.remove(mode) }
        guard target != activeModes else { return }

        if status == .on {
            await stop()
            guard status == .off, activeModes.isEmpty else { return }
        }
        guard !target.isEmpty else { return }

        preferredMode = target.contains(.tun) ? .tun : .systemProxy
        try? await persistSettings()
        await start(modes: target)
    }

    /// 启动内核。`modes` 为空表示只跑内核（本地 mixed inbound + Clash API），
    /// 不改系统代理也不建 TUN——测速、节点管理都只需要这个状态。
    private func start(modes: Set<ProxyMode>) async {
        guard !isBusy, status != .on, activeModes.isEmpty else { return }
        guard !activeConfigNodes.isEmpty else {
            setFailure("当前配置没有可用节点")
            return
        }

        await cancelCoreExitMonitoring()
        crashRestartLimiter.reset()
        status = .starting
        errorMessage = nil
        // TUN 需要 root，因此只要集合里含 TUN，整个内核就走提权启动；
        // 同时开启时 mixed inbound 也由这个 root 进程提供。
        let usesTun = modes.contains(.tun)
        let usesSystemProxy = modes.contains(.systemProxy)
        var tunStarted = false
        var startedPID: Int32?
        do {
            let prepared = try await ruleSetService.prepare(includeAds: routingSettings.blockAds, mirror: ruleSetSettings.mirror, allowsNetwork: ruleSetSettings.autoUpdate)
            appendWarnings(prepared.warnings)
            let runtime = try await runtimeFactory(preferredMixedPort)
            // 端口只在首次分配或旧端口被占时才变；变了立刻落盘，否则下次启动又是新端口。
            if preferredMixedPort != runtime.mixedPort {
                // 退避重试都没等到首选端口才会走到这里（见 `RuntimeSecrets.stableHighPort`）。
                // 端口一变系统代理设置也跟着变，缓存了旧端口的客户端会重连一次——
                // 不说一声用户只会看到"某个 App 又开始转圈"，无从判断原因。
                if let previous = preferredMixedPort {
                    appendWarning("本地代理端口 \(previous) 被占用，已改用 \(runtime.mixedPort)；缓存了旧端口的客户端可能需要重连一次")
                }
                preferredMixedPort = runtime.mixedPort
                try? await persistSettings()
            }
            let (config, configWarnings) = try await generateConfiguration(
                runtime: runtime,
                ruleSets: prepared.ruleSets,
                routingSettings: routingSettings,
                enabledModes: modes,
                outboundMode: outboundMode,
                tunSettings: tunSettings,
                dnsSettings: dnsSettings
            )
            appendWarnings(configWarnings)
            try await writeDiagnosticConfig(config)

            let check = try await singBoxProcess.check(config: config)
            guard check.exitCode == 0 else {
                throw AppStateError.coreCheckFailed(check.stderr)
            }
            let client = clashClientFactory(
                URL(string: "http://127.0.0.1:\(runtime.clashPort)")!,
                runtime.secret
            )
            if usesTun {
                // 首次开 TUN 没装助手时，弹一次密码持久化安装助手；后续零弹窗。
                // 失败/取消不阻塞：回退 privilegedLauncher（每次弹密码），功能正常。
                if !(await helperIsHealthy()) {
                    await installHelper()
                    // 新装/重装后的 helper 会认领上一实例遗留的 root 内核（adoptOrphanKernel）；
                    // 先清掉再起，否则 helper 会以 "kernel already running" 拒绝这次启动。
                    try? await helperClient.recoverIfNeeded()
                }
                let record = try await startTUN(config: config)
                tunStarted = true
                startedPID = record.pid
            } else {
                try await singBoxProcess.start(config: config)
                startedPID = await singBoxProcess.currentPID
            }
            try await healthVerifier(client)
            if usesSystemProxy {
                try await systemProxyManager.enable(
                    port: Int(runtime.mixedPort),
                    bypassDomains: bypassEntries(for: routingSettings)
                )
            }
            if usesTun {
                // macOS 的 scoped resolver 会绑定物理网卡发 DNS、绕开 TUN。
                // 把系统 DNS 指进 TUN 网段（hijack-dns 会截获），关闭时还原。
                try await systemDNSManager.enable(server: tunSettings.dnsServerAddress)
            }

            self.runtime = runtime
            clashAPIClient = client
            currentConfig = config
            mixedPort = usesSystemProxy ? runtime.mixedPort : nil
            activeModes = modes
            status = .on
            recordRuntimeEvent(
                title: "内核已启动",
                detail: runtimeModeDescription(modes),
                currentPID: startedPID
            )
            markRuntimeStarted()
            startNetworkPathMonitoringIfNeeded()
            if let startedPID {
                await armCoreExitMonitoring(pid: startedPID)
            } else {
                appendWarning("无法监控内核退出：启动后没有可用 PID")
            }
            resumeDashboardMonitoringIfNeeded()
            resumeLogMonitoringIfNeeded()
            Task { await verifyExitAfterStart() }
            // 规则集用缓存优先保证启动快；开了自动更新就在启动后台悄悄刷新缓存，供下次用，不阻塞。
            refreshRuleSetCacheInBackgroundIfDue()
        } catch {
            // 无论走到哪一步，先无条件尝试还原系统代理与 DNS（无快照时是空操作）。
            // 还原失败**不能静默吞掉**：启动失败 + 还原也失败时，系统代理会留在指向已关闭端口的
            // 状态，用户只看到"启动失败"却完全不知道网为什么全废。收集起来附到最终错误里。
            var restoreFailures: [String] = []
            do {
                try await systemProxyManager.restore()
            } catch {
                restoreFailures.append("系统代理（系统设置 → 网络 → 详细信息 → 代理）")
            }
            do {
                try await systemDNSManager.restore()
            } catch {
                restoreFailures.append("系统 DNS（系统设置 → 网络 → 详细信息 → DNS）")
            }
            let restoreNote = restoreFailures.isEmpty
                ? ""
                : "；另外这些系统设置未能还原，请手工清空或重开 kongshan 自动重试：" + restoreFailures.joined(separator: "、")
            if usesTun {
                if tunStarted {
                    do {
                        try await stopTUN()
                    } catch let stopError {
                        activeModes = modes
                        currentConfig = nil
                        mixedPort = nil
                        if let startedPID { await armCoreExitMonitoring(pid: startedPID) }
                        setFailure(
                            "TUN 启动失败且无法停止：\(error.localizedDescription)；\(stopError.localizedDescription)\(restoreNote)"
                        )
                        return
                    }
                }
            } else {
                await singBoxProcess.stop()
            }
            clearRuntimeState()
            setFailure(error.localizedDescription + restoreNote)
            recordRuntimeEvent(level: .error, title: "内核启动失败")
        }
    }

    func stop() async {
        // 崩溃自愈期间 isBusy 包含 .starting，旧实现的 guard 会直接 return，用户点停止无响应。
        // 这里特殊放行：置位 stopRequestedDuringCrashHandling 让 handleUnexpectedCoreExit 中止，
        // 然后继续走正常 stop 流程（还原系统代理 / DNS、停内核）。
        if isHandlingCoreCrash {
            stopRequestedDuringCrashHandling = true
        }
        guard !isBusy || isHandlingCoreCrash, status != .off else { return }
        let stoppingModes = activeModes
        // 内核可能在「未接管」状态下运行（测速用），此时没有模式但仍要停进程。
        guard !stoppingModes.isEmpty || runtime != nil else {
            await cancelCoreExitMonitoring()
            clearRuntimeState()
            status = .off
            return
        }
        let previousPID = monitoredCorePID
        await cancelCoreExitMonitoring()
        suspendDashboardMonitoring()
        suspendLogMonitoring()
        status = .stopping
        errorMessage = nil

        // 先还原系统代理再停内核，避免中间态把流量指向已消失的端口。
        // 代理/DNS 还原失败不应阻塞停内核——否则用户「无法退出」被卡死。
        // 但也绝不能说成「可忽略」：残留的系统代理指向已关闭的端口、残留的 DNS 指向已消失的
        // TUN 地址，到下次启动 recoverIfNeeded 重试之前，用户是实打实的断网/解析瘫痪。
        // 这里只收集失败项，停完内核后统一升成 errorMessage + 手工恢复指引。
        var restoreFailures: [String] = []
        if stoppingModes.contains(.systemProxy) {
            do {
                try await systemProxyManager.restore()
            } catch {
                restoreFailures.append("系统代理（系统设置 → 网络 → 详细信息 → 代理）：\(error.localizedDescription)")
            }
        }

        if stoppingModes.contains(.tun) {
            // 先把系统 DNS 还原（此刻 TUN 还在，解析不断档），再停内核。
            do {
                try await systemDNSManager.restore()
            } catch {
                restoreFailures.append("系统 DNS（系统设置 → 网络 → 详细信息 → DNS）：\(error.localizedDescription)")
            }
            do {
                try await stopTUN()
            } catch {
                // 这条早退路径原来会把已收集的还原失败一起丢掉——而"TUN 停不掉"恰恰是
                // 最需要同时告知"系统 DNS 也没还原"的场景（否则用户完全不知道网为什么全废）。
                let restoreNote = restoreFailures.isEmpty
                    ? ""
                    : "；另外这些系统设置未能还原，请手工清空：" + restoreFailures.joined(separator: "；")
                setFailure("停止 TUN 失败：\(error.localizedDescription)\(restoreNote)")
                if let previousPID { await armCoreExitMonitoring(pid: previousPID) }
                resumeDashboardMonitoringIfNeeded()
                resumeLogMonitoringIfNeeded()
                return
            }
        } else {
            await singBoxProcess.stop()
        }
        clearRuntimeState()
        status = .off
        recordRuntimeEvent(title: "内核已停止", previousPID: previousPID)
        if !restoreFailures.isEmpty {
            // 快照已保留，重开 App 会自动重试；但在那之前网络是坏的，必须明确告知怎么手工恢复。
            errorMessage = "以下系统设置未能还原，网络可能不通，请手工清空或重开 kongshan 自动重试——"
                + restoreFailures.joined(separator: "；")
        }
    }

    func switchMode(to mode: ProxyMode) async {
        guard !isBusy else { return }
        if activeMode == mode, status == .on {
            preferredMode = mode
            do {
                try await persistSettings()
                errorMessage = nil
            } catch {
                errorMessage = "保存代理模式失败：\(error.localizedDescription)"
            }
            return
        }

        let shouldRestart = status == .on && !activeModes.isEmpty
        if !activeModes.isEmpty {
            await stop()
            guard status == .off, activeModes.isEmpty else { return }
        }

        preferredMode = mode
        do {
            try await persistSettings()
            errorMessage = nil
        } catch {
            setFailure("保存代理模式失败：\(error.localizedDescription)")
            return
        }
        if shouldRestart {
            await startPreferredProxy()
        }
    }

    func prepareForTermination() async -> Bool {
        // 退出前先冲掉未完成的防抖落盘（用户切节点后 500ms 内退出会丢最后一次选择）。
        await flushPersistSettingsIfNeeded()
        if !activeModes.isEmpty {
            await stop()
            await flushRuntimeEventsIfNeeded()
            return status == .off
        } else {
            do {
                await cancelCoreExitMonitoring()
                try await recoverTUNIfNeeded()
                try await systemProxyManager.recoverIfNeeded()
                try await systemDNSManager.recoverIfNeeded()
                clearRuntimeState()
                status = .off
                await flushRuntimeEventsIfNeeded()
                return true
            } catch {
                setFailure("退出前恢复系统代理失败：\(error.localizedDescription)")
                await flushRuntimeEventsIfNeeded()
                return false
            }
        }
    }

    func importSubscription(url: URL, name: String? = nil, autoUpdate: Bool = true) async {
        guard !isBusy else { return }
        let previousActiveContent = activeRuntimeContent
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let source = SubscriptionSource(
            name: trimmed.isEmpty ? (url.host ?? "订阅 \(subscriptions.count + 1)") : trimmed,
            url: url,
            autoUpdate: autoUpdate
        )
        do {
            let result = try await subscriptionService.refresh(source)
            var savedSource = source
            savedSource.lastUpdatedAt = now()
            savedSource.usage = result.usage
            // 用户没起名时优先用机场自己下发的标题（profile-title / 文件名）。
            if trimmed.isEmpty, let suggested = result.suggestedName {
                savedSource.name = suggested
            }
            subscriptions.append(savedSource)
            replaceNodes(result.nodes, for: source.id)
            discoveredPolicyGroups[source.id] = result.policyGroups
            discoveredRules[source.id] = result.subscriptionRules
            appendWarnings(result.warnings)
            // 第一个配置自动生效；已有生效配置则保持不变（不打断用户）。
            ensureActiveConfig()
            try await persistSubscriptions()
            try await persistSettings()
            errorMessage = nil
            await rescheduleSubscriptionUpdates()
            await reloadAfterActiveContentChange(from: previousActiveContent)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameSubscription(id: UUID, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = subscriptions.firstIndex(where: { $0.id == id }),
              subscriptions[index].name != trimmed else { return }
        subscriptions[index].name = trimmed
        do {
            try await persistSubscriptions()
            errorMessage = nil
        } catch {
            errorMessage = "保存订阅名称失败：\(error.localizedDescription)"
        }
    }

    func setSubscriptionAutoUpdate(id: UUID, enabled: Bool) async {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }),
              subscriptions[index].autoUpdate != enabled else { return }
        subscriptions[index].autoUpdate = enabled
        do {
            try await persistSubscriptions()
            errorMessage = nil
            await rescheduleSubscriptionUpdates()
        } catch {
            errorMessage = "保存订阅更新开关失败：\(error.localizedDescription)"
        }
    }

    func removeSubscription(id: UUID) async {
        guard !isBusy, let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        let previousActiveContent = activeRuntimeContent
        subscriptions.remove(at: index)
        nodes.removeAll { $0.sourceID == id }
        discoveredPolicyGroups[id] = nil
        discoveredRules[id] = nil
        // 删掉的正是生效配置时，换一个顶上。
        if activeConfigID == id { activeConfigID = nil }
        ensureActiveConfig()
        do {
            try await persistSubscriptions()
            try await persistSettings()
            errorMessage = nil
            await rescheduleSubscriptionUpdates()
        } catch {
            errorMessage = "删除订阅失败：\(error.localizedDescription)"
            return
        }
        await reloadAfterActiveContentChange(from: previousActiveContent)
    }

    /// 删除本地「自建节点」配置：清空全部手动节点。
    func removeLocalConfig() async {
        guard !isBusy, !manualNodes.isEmpty else { return }
        let previousActiveContent = activeRuntimeContent
        nodes.removeAll { $0.sourceID == nil }
        if activeConfigID == Self.localConfigID { activeConfigID = nil }
        ensureActiveConfig()
        do {
            try await persistManualNodes()
            try await persistSettings()
            errorMessage = nil
        } catch {
            errorMessage = "删除自建节点失败：\(error.localizedDescription)"
            return
        }
        await reloadAfterActiveContentChange(from: previousActiveContent)
    }

    func refreshSubscriptions() async {
        let hadFailures = await performSubscriptionRefresh(notifyOnFailure: false)
        await rescheduleSubscriptionUpdates(
            notBefore: hadFailures ? now().addingTimeInterval(15 * 60) : nil
        )
    }

    /// 只刷新单个订阅。
    func refreshSubscription(id: UUID) async {
        guard !isBusy, let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        let previousActiveContent = activeRuntimeContent
        let source = subscriptions[index]
        do {
            let result = try await subscriptionService.refresh(source)
            if !result.usedCache {
                subscriptions[index].lastUpdatedAt = now()
                if let usage = result.usage { subscriptions[index].usage = usage }
            }
            replaceNodes(result.nodes, for: id)
            discoveredPolicyGroups[id] = result.policyGroups
            discoveredRules[id] = result.subscriptionRules
            appendWarnings(result.warnings)
            ensureActiveConfig()
            try await persistSubscriptions()
            try await persistSettings()
            errorMessage = nil
        } catch {
            errorMessage = "刷新配置失败：\(error.localizedDescription)"
            return
        }
        await reloadAfterActiveContentChange(from: previousActiveContent)
    }

    private func performSubscriptionRefresh(
        notifyOnFailure: Bool,
        automaticOnly: Bool = false
    ) async -> Bool {
        guard !isBusy else { return true }
        var collectedWarnings: [String] = []
        var failedSubscriptions: [String] = []
        let previousActiveContent = activeRuntimeContent
        for index in subscriptions.indices {
            let source = subscriptions[index]
            // 定时更新跳过关掉自动更新的订阅；用户主动刷新不受限制。
            if automaticOnly, !source.autoUpdate { continue }
            do {
                let result = try await subscriptionService.refresh(source)
                collectedWarnings.append(contentsOf: result.warnings)
                if result.usedCache {
                    failedSubscriptions.append(source.name)
                } else {
                    subscriptions[index].lastUpdatedAt = now()
                    if let usage = result.usage { subscriptions[index].usage = usage }
                    replaceNodes(result.nodes, for: source.id)
                    discoveredPolicyGroups[source.id] = result.policyGroups
                    discoveredRules[source.id] = result.subscriptionRules
                }
            } catch {
                collectedWarnings.append("订阅 \(source.name) 更新失败：\(error.localizedDescription)")
                failedSubscriptions.append(source.name)
            }
        }
        appendWarnings(collectedWarnings)
        selectFirstNodeIfNeeded()
        try? await persistSubscriptions()
        try? await persistSettings()
        await reloadAfterActiveContentChange(from: previousActiveContent)
        if notifyOnFailure, !failedSubscriptions.isEmpty {
            do {
                try await notificationSender.send(
                    title: "kongshan 订阅更新失败",
                    body: failedSubscriptions.joined(separator: "、")
                )
            } catch {
                appendWarning("通知未发送：\(error.localizedDescription)")
            }
        }
        return !failedSubscriptions.isEmpty
    }

    func setSubscriptionUpdateSettings(_ requestedSettings: SubscriptionUpdateSettings) async {
        let oldSettings = subscriptionUpdateSettings
        do {
            let settings = try requestedSettings.validated()
            subscriptionUpdateSettings = settings
            try await persistSettings()
            errorMessage = nil
            await rescheduleSubscriptionUpdates()
        } catch {
            subscriptionUpdateSettings = oldSettings
            errorMessage = "保存订阅更新设置失败：\(error.localizedDescription)"
        }
    }

    /// 数据目录，供「在 Finder 中显示」使用。
    var supportDirectory: URL { storage.rootDirectory }

    /// 清理可再生的缓存：内核日志与规则集。设置、订阅缓存与节点不动。
    func clearRegenerableCaches() async {
        guard status != .on else {
            errorMessage = "请先停止内核再清理缓存"
            return
        }
        let manager = FileManager.default
        var removed = 0
        var totalBytes: Int64 = 0
        for directory in ["logs", "rule-sets"] {
            let url = storage.rootDirectory.appending(path: directory, directoryHint: .isDirectory)
            guard let entries = try? manager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
            ) else {
                continue
            }
            for entry in entries {
                if let attrs = try? manager.attributesOfItem(atPath: entry.path),
                   let size = attrs[.size] as? Int64 {
                    totalBytes += size
                }
                if (try? manager.removeItem(at: entry)) != nil {
                    removed += 1
                }
            }
        }
        liveLogs.removeAll(keepingCapacity: false)
        discardPendingLogs()
        ruleSetSettings.lastUpdatedAt = nil
        try? await persistSettings()
        errorMessage = nil
        await refreshCacheSize()
        let sizeText = Self.formatBytes(totalBytes)
        appendWarning("已清理 \(removed) 个缓存文件（\(sizeText)），下次启动会重新下载规则集")
    }

    /// 当前可再生缓存（日志 + 规则集）总字节，供设置页展示。
    private(set) var cacheSizeBytes: Int64 = 0

    func refreshCacheSize() async {
        let manager = FileManager.default
        var total: Int64 = 0
        for directory in ["logs", "rule-sets"] {
            let url = storage.rootDirectory.appending(path: directory, directoryHint: .isDirectory)
            guard let entries = try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
                continue
            }
            for entry in entries {
                if let attrs = try? manager.attributesOfItem(atPath: entry.path),
                   let size = attrs[.size] as? Int64 {
                    total += size
                }
            }
        }
        cacheSizeBytes = total
    }

    /// 统一字节格式化；0 时返回空串，由 UI 统一显示占位符。
    nonisolated static func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }

    /// 统一速率格式化：基于 formatBytes 加 /s；0 时空白。
    nonisolated static func formatRate(_ bytes: Int64) -> String {
        let s = formatBytes(bytes)
        return s.isEmpty ? "" : "\(s)/s"
    }

    func setRuleSetSettings(_ settings: RuleSetSettings) async {
        var updated = settings
        updated.lastUpdatedAt = ruleSetSettings.lastUpdatedAt
        guard updated != ruleSetSettings else { return }
        ruleSetSettings = updated
        do {
            try await persistSettings()
            errorMessage = nil
        } catch {
            errorMessage = "保存规则集设置失败：\(error.localizedDescription)"
        }
    }

    /// 立即从当前镜像拉取规则集；无论自动更新开关如何都强制走网络。
    /// 只刷新缓存，不重启内核——下次启动或应用规则时自然生效。
    /// 启动后台刷新规则集缓存：一天最多一次，失败静默（下次再试），绝不阻塞启动或界面。
    private func refreshRuleSetCacheInBackgroundIfDue() {
        guard ruleSetSettings.autoUpdate else { return }
        if let last = ruleSetSettings.lastUpdatedAt, now().timeIntervalSince(last) < 24 * 3_600 {
            return
        }
        let includeAds = routingSettings.blockAds
        let mirror = ruleSetSettings.mirror
        Task { [weak self] in
            guard let self else { return }
            guard let prepared = try? await self.ruleSetService.prepare(
                includeAds: includeAds,
                mirror: mirror,
                allowsNetwork: true,
                forceRefresh: true
            ), prepared.warnings.isEmpty else { return }
            self.ruleSetSettings.lastUpdatedAt = self.now()
            try? await self.persistSettings()
        }
    }

    func updateRuleSetsNow() async {
        guard !isUpdatingRuleSets else { return }
        isUpdatingRuleSets = true
        defer { isUpdatingRuleSets = false }
        do {
            let prepared = try await ruleSetService.prepare(
                includeAds: routingSettings.blockAds,
                mirror: ruleSetSettings.mirror,
                allowsNetwork: true,
                forceRefresh: true
            )
            appendWarnings(prepared.warnings)
            guard prepared.warnings.isEmpty else {
                errorMessage = "规则集更新未全部成功，已保留可用缓存"
                return
            }
            ruleSetSettings.lastUpdatedAt = now()
            try await persistSettings()
            errorMessage = nil
        } catch {
            errorMessage = "规则集更新失败：\(error.localizedDescription)"
        }
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) async {
        do {
            loginItemStatus = try await loginItemManager.setEnabled(enabled)
            errorMessage = nil
        } catch {
            loginItemStatus = await loginItemManager.currentStatus()
            errorMessage = "设置开机自启失败：\(error.localizedDescription)"
        }
    }

    func refreshLoginItemStatus() async {
        loginItemStatus = await loginItemManager.currentStatus()
    }

    func openLoginItemSystemSettings() async {
        await loginItemManager.openSystemSettings()
    }

    /// 批量加入自建节点（分享链接解析的结果）。
    ///
    /// `sourceID` 必须清成 nil —— 「本地自建」这个伪配置就是按 `sourceID == nil` 判定的
    /// （见 `manualNodes`），带着别的 sourceID 进来会归到某个不存在的订阅下、界面上找不到。
    /// `id` 也重发一遍：同一条链接粘两次不该被当成同一个节点覆盖掉。
    /// 切换菜单栏图标样式。纯显示项，不碰内核，立即落盘即可。
    func setMenuBarIconStyle(_ style: MenuBarIconStyle) async {
        guard style != menuBarIconStyle else { return }
        menuBarIconStyle = style
        try? await persistSettings()
    }

    /// 菜单栏图标当前该显示哪种状态。
    var menuBarIconState: MenuBarIcon.State {
        guard let activeMode else { return .off }
        return activeMode == .tun ? .tun : .systemProxy
    }

    func addManualNodes(_ parsed: [ProxyNode]) async {
        guard !parsed.isEmpty else { return }
        let previousActiveContent = activeRuntimeContent
        nodes.append(contentsOf: parsed.map { node in
            var copy = node
            copy.sourceID = nil
            copy.id = UUID()
            return copy
        })
        ensureActiveConfig()
        do {
            try await persistManualNodes()
            try await persistSettings()
            errorMessage = nil
        } catch {
            errorMessage = "保存自建节点失败：\(error.localizedDescription)"
            return
        }
        await reloadAfterActiveContentChange(from: previousActiveContent)
    }

    func addManual(_ form: ManualHysteria2) async {
        let previousActiveContent = activeRuntimeContent
        do {
            nodes.append(try form.makeNode())
            // 没有其他配置时，本地节点配置自动生效。
            ensureActiveConfig()
            try await persistManualNodes()
            try await persistSettings()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        await reloadAfterActiveContentChange(from: previousActiveContent)
    }

    func removeManualNode(id: UUID) async {
        guard !isBusy,
              let index = nodes.firstIndex(where: { $0.id == id && $0.sourceID == nil }) else { return }
        let previousActiveContent = activeRuntimeContent
        let removedName = nodes[index].name
        nodes.remove(at: index)
        for (group, name) in groupSelections where name == removedName {
            groupSelections[group] = nil
        }
        // 自建节点删光后本地配置会消失，若它正生效需另选一个。
        if manualNodes.isEmpty, activeConfigID == Self.localConfigID { activeConfigID = nil }
        ensureActiveConfig()
        do {
            try await persistManualNodes()
            try await persistSettings()
            errorMessage = nil
        } catch {
            errorMessage = "删除自建节点失败：\(error.localizedDescription)"
            return
        }
        await reloadAfterActiveContentChange(from: previousActiveContent)
    }

    private func reloadAfterActiveContentChange(from previous: ActiveRuntimeContent) async {
        guard previous != activeRuntimeContent else { return }
        await hotReloadAfterNodeChange()
    }

    /// 节点集合变化后（订阅刷新 / 增删自建），运行中的内核不重载就用不上新出站，
    /// 已删除的节点还会留在旧配置里。复用分流的热重载路径（校验 → 快速重启 → 失败回滚）。
    private func hotReloadAfterNodeChange() async {
        guard status == .on else { return }
        if activeConfigNodes.isEmpty || activeModes.isEmpty {
            // 节点删光后配置生成必然失败；「只跑内核」的测速态也没有回滚需求。
            // 两种情况都直接停掉，而不是让热重载报错回滚到含幽灵节点的旧配置。
            await stop()
            return
        }
        await applyRoutingSettings(routingSettings, operation: "当前配置")
    }

    // 内置策略组用固定 ID：PolicyGroup(name:) 默认每次生成新 UUID，
    // 而 displayPolicyGroups 是计算属性，每次访问都会新建这两个内置组。
    // 一旦被 ForEach 按 Identifiable 的 id 渲染（托盘/代理页），每次求值 id 都变，
    // SwiftUI 就以为列表变了 → 无限重渲染 → 单核 100% CPU（实测就是这个原因）。
    @ObservationIgnored private static let manualGroupID = UUID(uuidString: "00000000-0000-0000-0000-0000000A0001")!
    @ObservationIgnored private static let autoGroupID = UUID(uuidString: "00000000-0000-0000-0000-0000000A0002")!

    /// 当前配置的主组名（机场轮辐主组，如 TAGSS）——用户在这里挑主节点。
    /// 与 ConfigGenerator 用同一套识别逻辑，保证 App 与生成的 config 一致。
    var primaryGroupName: String? {
        ConfigGenerator.primaryGroupName(among: activeConfigPolicyGroups)
    }

    /// 代理页/托盘展示的策略：有机场自带策略组时只显示它们（用户在主组里挑主节点，对应 Stash）；
    /// 没有机场组时才回退内置「手动选择/自动选择」，供纯手动/自建节点选择。
    var displayPolicyGroups: [PolicyGroup] {
        if !activeConfigPolicyGroups.isEmpty { return activeConfigPolicyGroups }
        return [
            PolicyGroup(id: Self.manualGroupID, name: "手动选择", kind: .selector),
            PolicyGroup(id: Self.autoGroupID, name: "自动选择", kind: .urltest)
        ]
    }

    /// 某个策略组里可展示/可选的成员。空成员＝该组含全部节点；
    /// 有成员时保留原顺序，节点解析成节点、其余（子策略组 / DIRECT / REJECT）保留为引用。
    /// 机场塞进 proxies 的套餐信息条目（剩余流量/到期）不是可用节点，从选项里剔除。
    func groupOptions(_ group: PolicyGroup) -> [GroupOption] {
        let pool = testableNodes
        guard !group.members.isEmpty else { return pool.map(GroupOption.node) }
        let byName = Dictionary(pool.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let infoNames = Set(activeConfigNodes.filter(\.isSubscriptionInfo).map(\.name))
        return group.members.compactMap { member in
            if let node = byName[member] { return .node(node) }
            if infoNames.contains(member) { return nil }
            return .reference(member)
        }
    }

    /// 每个策略组当前选中的成员名（节点名 / 子组名 / DIRECT / REJECT），键为组名。
    private(set) var groupSelections: [String: String] = [:]

    /// 某组当前选中的成员名；未记录时回退默认（手动选择用全局节点，其余用首个成员）。
    /// 只在存下的选择仍是当前有效成员时才采用——否则（如升级前存的是旧 UUID）回退默认，
    /// 不把无法解析的原始值直接显示出来。
    func selectedMemberName(in group: String) -> String? {
        let options = displayPolicyGroups.first { $0.name == group }.map(groupOptions) ?? []
        if let name = groupSelections[group], options.contains(where: { $0.name == name }) {
            return name
        }
        // 主组 / 内置手动选择：默认跟随全局当前节点，回退到首个「节点」成员（不落到直连/子组引用上）。
        if group == "手动选择" || group == primaryGroupName {
            if let node = selectedNode, options.contains(where: { $0.name == node.name }) {
                return node.name
            }
            if let firstNode = options.first(where: { if case .node = $0 { return true } else { return false } }) {
                return firstNode.name
            }
        }
        return options.first?.name
    }

    /// 选中成员是节点时返回它（供托盘/副标题展示）；是子组则返回 nil。
    func selectedNode(in group: String) -> ProxyNode? {
        guard let name = selectedMemberName(in: group) else { return nil }
        return activeConfigNodes.first { $0.name == name }
    }

    func isSelected(_ option: GroupOption, in group: String) -> Bool {
        selectedMemberName(in: group) == option.name
    }

    /// 成员名 → 配置里的出站 tag。节点→节点 tag；DIRECT/REJECT→direct/reject；子组→组名即 tag。
    private func memberTag(_ name: String) -> String? {
        switch name.uppercased() {
        case "DIRECT": return "direct"
        case "REJECT", "REJECT-DROP": return "reject"
        default:
            if let node = activeConfigNodes.first(where: { $0.name == name }) {
                return ConfigGenerator.outboundTag(for: node)
            }
            return displayPolicyGroups.contains { $0.name == name } ? name : nil
        }
    }

    /// 为某策略组切换成员（节点或子组）。「手动选择」选中节点时同步全局当前节点。
    func select(optionName name: String, in group: String) async {
        guard let tag = memberTag(name) else { return }
        if let clashAPIClient, status == .on {
            do {
                try await clashAPIClient.select(node: tag, in: group)
                // 切换后关掉旧连接，逼浏览器等复用的 keep-alive 连接重连——否则出口 IP 不变。
                try? await clashAPIClient.closeAllConnections()
            } catch {
                errorMessage = "切换 \(group) 失败：\(error.localizedDescription)"
                return
            }
        }
        groupSelections[group] = name
        // 在"主组"(或内置手动选择)里挑节点＝选主节点：同步全局当前节点，供仪表盘与连通性探测使用。
        let isPrimaryPick = group == "手动选择" || group == primaryGroupName
        if isPrimaryPick, let node = activeConfigNodes.first(where: { $0.name == name }) {
            selectedNodeID = node.id
        }
        // 组选择要落盘，否则重启后按策略分流的选择全部回退。
        // 切节点是高频操作（用户连续点选多个节点试延迟），用 debounce 合并 500ms 内的多次落盘。
        // 立即生效靠 Clash API 的 select 已经发出；落盘只关乎重启后恢复，延迟 500ms 无感知。
        schedulePersistSettingsDebounced()
        if isPrimaryPick, status == .on {
            Task { await refreshExitDiagnostics() }
        }
    }

    func select(_ node: ProxyNode, in group: String) async {
        await select(optionName: node.name, in: group)
    }

    /// 默认在「主组」里挑节点：有机场组时主组是机场的轮辐主组（如 TAGSS），
    /// 没有时退到内置「手动选择」。直接硬编码"手动选择"会在机场组模式下 404——
    /// ConfigGenerator 在有机场组时根本不生成「手动选择」出站。
    func select(_ node: ProxyNode) async {
        await select(optionName: node.name, in: primaryGroupName ?? "手动选择")
    }

    /// 启动时读取打包内核版本（运行 `sing-box version`），让"关于"页即使没开代理也显示版本号。
    func loadBundledCoreVersionIfNeeded() async {
        guard coreVersion == "—" else { return }
        let url = Self.singBoxBinaryURL()
        guard let result = try? await ProcessRunner.run(executable: url, arguments: ["version"], timeout: 5),
              result.exitCode == 0 else { return }
        // "sing-box version 1.13.14 (...)" → 取第三段
        let parts = result.stdout.split(separator: "\n").first?.split(separator: " ") ?? []
        if parts.count >= 3 { coreVersion = String(parts[2]) }
    }

    /// 检查 sing-box 最新发布版本。内核内置于 App、随 App 构建更新；有新版就提示并打开发布页。
    func updateKernel() async {
        guard !isCheckingKernelUpdate else { return }
        isCheckingKernelUpdate = true
        defer { isCheckingKernelUpdate = false }
        await loadBundledCoreVersionIfNeeded()
        warnings.removeAll { $0.hasPrefix("内核") }
        guard let api = URL(string: "https://api.github.com/repos/SagerNet/sing-box/releases/latest") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: api)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let tag = (json?["tag_name"] as? String) ?? ""
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            if latest.isEmpty {
                appendWarning("内核更新检查失败：未取到最新版本号")
            } else if latest == coreVersion {
                appendWarning("内核已是最新（\(latest)）")
            } else {
                appendWarning("内核有新版 \(latest)（当前 \(coreVersion)）；已打开发布页，更新 App 即随附新内核")
                if let page = URL(string: "https://github.com/SagerNet/sing-box/releases") {
                    NSWorkspace.shared.open(page)
                }
            }
        } catch {
            appendWarning("内核更新检查失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 连接监控

    /// 连接监控页出现时订阅 WebSocket 推送；离开时停止（取消订阅释放 socket）。
    /// 旧实现用 1.5s 轮询 GET /connections，每次都建 HTTP 请求 + 全量解析；
    /// 改用 WebSocket 推送后由内核按 1s 间隔主动推，省掉轮询请求，对笔记本电池更友好。
    func startConnectionsMonitoring() {
        guard connectionsTask == nil else { return }
        connectionsTask = Task { [weak self] in
            while !Task.isCancelled {
                // self 没了说明 App 已释放：直接结束循环。留着会变成没人能取消的空转任务。
                guard let self else { return }
                guard let client = self.clashAPIClient, self.status == .on else {
                    // 未运行/已停止时清空，避免残留旧连接列表。已经是空的就别再赋值——
                    // `@Observable` 不做等值判断，无条件写会让这条 1.5 秒的空转循环
                    // 变成每 1.5 秒一次全量视图失效。
                    if !self.connections.isEmpty { self.connections = [] }
                    try? await Task.sleep(for: .seconds(1.5))
                    continue
                }
                do {
                    let stream = await client.connectionDetailsStream()
                    for try await details in stream {
                        guard !Task.isCancelled else { break }
                        // 速率跟踪必须每一帧都喂，否则速率算不准；排序和赋值可以省。
                        let tracked = self.connectionRateTracker.update(details, at: self.now())
                        guard self.windowContentIsVisible else { continue }
                        let sorted = tracked
                            .sorted { ($0.download + $0.upload) > ($1.download + $1.upload) }
                        if self.connections != sorted { self.connections = sorted }
                    }
                } catch {
                    // 流断开（内核重启 / 网络抖动）：等一会再重订。
                    try? await Task.sleep(for: .seconds(1.5))
                }
            }
        }
    }

    func stopConnectionsMonitoring() {
        connectionsTask?.cancel()
        connectionsTask = nil
        connectionRateTracker.reset()
        connections = []   // 离开监控页即清空，下次进入重新拉取
    }

    /// 一键关闭全部连接。
    func closeAllActiveConnections() async {
        guard let client = clashAPIClient else { return }
        try? await client.closeAllConnections()
        connectionRateTracker.reset()
        connections = []
    }

    /// 关闭单条连接。
    func closeConnection(_ id: String) async {
        guard let client = clashAPIClient else { return }
        try? await client.closeConnection(id: id)
        connections.removeAll { $0.id == id }
    }

    /// 测速依赖 Clash API，内核必须在跑。未运行时自动拉起「只跑内核」状态：
    /// 只开本地 mixed inbound，不改系统代理也不建 TUN。用户可在托盘停止。
    @discardableResult
    func startCoreForTestingIfNeeded() async -> Bool {
        if status == .on { return true }
        guard !isBusy else { return false }
        guard !activeConfigNodes.isEmpty else {
            errorMessage = "当前配置没有可用节点"
            return false
        }
        await start(modes: [])
        return status == .on
    }

    func testDelay(_ node: ProxyNode) async {
        // TCP 握手直连节点服务器，不需要内核在跑，快且稳。
        if speedTestMethod == .tcpPing {
            let result = await tcpPingProvider(node.server, node.port)
            applyDelay(result, to: node.id)
            return
        }
        guard await startCoreForTestingIfNeeded() else { return }
        guard let clashAPIClient, let testURL = URL(string: testURLString) else {
            errorMessage = "内核控制接口不可用"
            return
        }
        do {
            let value = try await clashAPIClient.delay(
                node: ConfigGenerator.outboundTag(for: node),
                testURL: testURL
            )
            delays[node.id] = value
        } catch {
            delays.updateValue(nil, forKey: node.id)
            errorMessage = "测速失败：\(error.localizedDescription)"
        }
    }

    private func applyDelay(_ result: DelayResult, to id: UUID) {
        switch result {
        case let .success(value): delays[id] = value
        case .failure: delays.updateValue(nil, forKey: id)
        }
    }

    func testAllDelays() async {
        // 防重入：托盘与节点页都能触发，重复点击会叠加出成百上千个并发请求。
        guard !isTestingAllDelays else { return }
        // 测速只针对当前生效配置里的可用节点，避免对上百个节点全量握手。
        let testable = testableNodes
        guard !testable.isEmpty else {
            errorMessage = "当前配置没有可测速的节点"
            return
        }
        isTestingAllDelays = true
        defer { isTestingAllDelays = false }

        // TCP 方式：直连握手，不需要内核。有界并发 + 每测完一个立刻回填延迟——
        // 后台跑、不阻塞前台，测速结果一个个显示出来，而不是全部跑完才一次性刷新。
        if speedTestMethod == .tcpPing {
            let nodes = testable
            await withTaskGroup(of: (UUID, DelayResult).self) { group in
                var next = 0
                let seed = min(16, nodes.count)
                while next < seed {
                    let node = nodes[next]; next += 1
                    group.addTask { [tcpPingProvider] in
                        (node.id, await tcpPingProvider(node.server, node.port))
                    }
                }
                while let (id, result) = await group.next() {
                    applyDelay(result, to: id)
                    if next < nodes.count {
                        let node = nodes[next]; next += 1
                        group.addTask { [tcpPingProvider] in
                            (node.id, await tcpPingProvider(node.server, node.port))
                        }
                    }
                }
            }
            return
        }

        // URL 方式：需要内核在跑，之后同样有界并发 + 逐个回填。
        guard await startCoreForTestingIfNeeded() else { return }
        guard let client = clashAPIClient, let testURL = URL(string: testURLString) else {
            errorMessage = "内核控制接口不可用"
            return
        }
        let targets: [(id: UUID, tag: String)] = testable.map {
            (id: $0.id, tag: ConfigGenerator.outboundTag(for: $0))
        }
        await withTaskGroup(of: (UUID, DelayResult).self) { group in
            var next = 0
            let seed = min(8, targets.count)
            func delayTask(_ target: (id: UUID, tag: String)) -> @Sendable () async -> (UUID, DelayResult) {
                { @Sendable in
                    do { return (target.id, .success(try await client.delay(node: target.tag, testURL: testURL))) }
                    catch { return (target.id, .failure(error.localizedDescription)) }
                }
            }
            while next < seed {
                group.addTask(operation: delayTask(targets[next])); next += 1
            }
            while let (id, result) = await group.next() {
                applyDelay(result, to: id)
                if next < targets.count {
                    group.addTask(operation: delayTask(targets[next])); next += 1
                }
            }
        }
    }

    func testAndSelectFastest(in group: String) async {
        let candidates = displayPolicyGroups
            .first { $0.name == group }
            .map(groupOptions)?
            .compactMap { option -> ProxyNode? in
                guard case let .node(node) = option else { return nil }
                return node
            } ?? []
        guard !candidates.isEmpty else {
            errorMessage = "当前策略没有可测速的节点"
            return
        }

        await testAllDelays()
        let fastest = candidates.compactMap { node -> (ProxyNode, Int)? in
            guard case let .some(.some(value)) = delays[node.id] else { return nil }
            return (node, value)
        }.min { $0.1 < $1.1 }
        guard let fastest else {
            errorMessage = "没有测速成功的节点，已保留当前选择"
            return
        }
        await select(fastest.0, in: group)
    }

    /// 保存测速地址。界面上绑定的是草稿，校验通过才写进运行值，
    /// 避免输入中途的半截 URL 被测速直接用掉。
    func saveTestURL(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme ?? "") else {
                throw AppStateError.invalidTestURL
            }
            testURLString = trimmed
            try await persistSettings()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setSpeedTestMethod(_ method: SpeedTestMethod) async {
        guard method != speedTestMethod else { return }
        speedTestMethod = method
        try? await persistSettings()
    }

    /// 切换出站模式。未运行时只持久化；运行中复用分流的热重载路径重建配置。
    func setOutboundMode(_ mode: OutboundMode) async {
        guard !isBusy, mode != outboundMode else { return }
        let previous = outboundMode
        outboundMode = mode
        guard status == .on else {
            do {
                try await persistSettings()
                errorMessage = nil
            } catch {
                outboundMode = previous
                errorMessage = "保存出站模式失败：\(error.localizedDescription)"
            }
            return
        }
        await applyRoutingSettings(routingSettings, operation: "出站模式")
        if case .failed = status {
            outboundMode = previous
            return
        }
        try? await persistSettings()
    }

    func applyRoutingSettings(_ requestedSettings: RoutingSettings, operation: String = "分流规则") async {
        guard !isBusy else { return }
        isApplyingRouting = true
        defer { isApplyingRouting = false }

        do {
            let settings = try requestedSettings.validated()
            guard status == .on else {
                routingSettings = settings
                try await persistRoutingSettings()
                errorMessage = nil
                return
            }
            guard let runtime,
                  let oldConfig = currentConfig,
                  let client = clashAPIClient,
                  !activeModes.isEmpty else {
                throw AppStateError.missingRuntimeState
            }

            let oldSettings = routingSettings
            let prepared = try await ruleSetService.prepare(includeAds: settings.blockAds, mirror: ruleSetSettings.mirror, allowsNetwork: ruleSetSettings.autoUpdate)
            appendWarnings(prepared.warnings)
            let (newConfig, configWarnings) = try await generateConfiguration(
                runtime: runtime,
                ruleSets: prepared.ruleSets,
                routingSettings: settings,
                enabledModes: activeModes,
                outboundMode: outboundMode,
                tunSettings: tunSettings,
                dnsSettings: dnsSettings
            )
            appendWarnings(configWarnings)
            let check = try await singBoxProcess.check(config: newConfig)
            guard check.exitCode == 0 else {
                throw AppStateError.coreCheckFailed(check.stderr)
            }

            // 内核重启方式由是否含 TUN 决定；系统代理是否在集合中决定要不要改 bypass。
            if activeModes.contains(.tun) {
                guard await reloadTUNConfiguration(
                    newConfig: newConfig,
                    oldConfig: oldConfig,
                    client: client,
                    operation: operation
                ) else {
                    return
                }
            } else {
                suspendDashboardMonitoring()
                suspendLogMonitoring()
                await cancelCoreExitMonitoring()
                do {
                    try await singBoxProcess.restart(config: newConfig)
                    try await healthVerifier(client)
                } catch {
                    await restoreOldSystemConfiguration(
                        config: oldConfig,
                        client: client,
                        updateError: error,
                        operation: operation
                    )
                    return
                }
            }

            if activeModes.contains(.systemProxy) {
                do {
                    try await systemProxyManager.updateBypassDomains(
                        to: bypassEntries(for: settings),
                        rollbackTo: bypassEntries(for: oldSettings)
                    )
                } catch {
                    await restoreOldSystemConfiguration(
                        config: oldConfig,
                        client: client,
                        updateError: error,
                        operation: operation
                    )
                    return
                }
            }

            routingSettings = settings
            currentConfig = newConfig
            if !activeModes.contains(.tun) {
                await armRunningSystemCoreIfAvailable()
            }
            try await persistRoutingSettings()
            try await writeDiagnosticConfig(newConfig)
            errorMessage = nil
            markRuntimeStarted()
            resumeDashboardMonitoringIfNeeded()
            resumeLogMonitoringIfNeeded()
            if !activeModes.contains(.tun) {
                recordConfigurationApplied(operation: operation)
            }
        } catch {
            errorMessage = "应用分流规则失败：\(error.localizedDescription)"
            recordRuntimeEvent(level: .error, title: "\(operation)应用失败")
        }
    }

    func upsertProcessRule(processName: String, action: RouteAction, proxyTarget: String?) async {
        let processName = processName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !processName.isEmpty else {
            errorMessage = "请选择要分流的应用"
            return
        }
        var settings = routingSettings
        settings.customRules.removeAll {
            $0.type == .processName && $0.value.caseInsensitiveCompare(processName) == .orderedSame
        }
        let order = (settings.customRules.map(\.order).max() ?? -1) + 1
        settings.customRules.append(CustomRouteRule(
            order: order,
            type: .processName,
            value: processName,
            action: action,
            proxyGroup: action == .proxy ? proxyTarget : nil
        ))
        await applyRoutingSettings(settings)
    }

    func removeProcessRule(_ id: UUID) async {
        var settings = routingSettings
        settings.customRules.removeAll { $0.id == id && $0.type == .processName }
        await applyRoutingSettings(settings)
    }

    func processRuleTargetName(_ rule: CustomRouteRule) -> String {
        switch rule.action {
        case .direct: return "直连"
        case .reject: return "拒绝"
        case .proxy:
            guard let target = rule.proxyGroup else { return "默认代理" }
            if let node = activeConfigNodes.first(where: { ConfigGenerator.outboundTag(for: $0) == target }) {
                return node.name
            }
            return target == (primaryGroupName ?? "手动选择") ? "默认代理" : target
        }
    }

    func applyTunSettings(_ requestedSettings: TunSettings, operation: String = "TUN 设置") async {
        guard !isBusy else { return }
        isApplyingRouting = true
        defer { isApplyingRouting = false }

        let oldTunSettings = tunSettings
        do {
            guard status == .on, activeMode == .tun else {
                tunSettings = requestedSettings
                try await persistSettings()
                errorMessage = nil
                return
            }
            guard let runtime, let oldConfig = currentConfig, let client = clashAPIClient else {
                throw AppStateError.missingRuntimeState
            }

            let prepared = try await ruleSetService.prepare(includeAds: routingSettings.blockAds, mirror: ruleSetSettings.mirror, allowsNetwork: ruleSetSettings.autoUpdate)
            appendWarnings(prepared.warnings)
            let (newConfig, configWarnings) = try await generateConfiguration(
                runtime: runtime,
                ruleSets: prepared.ruleSets,
                routingSettings: routingSettings,
                enabledModes: activeModes,
                outboundMode: outboundMode,
                tunSettings: requestedSettings,
                dnsSettings: dnsSettings
            )
            appendWarnings(configWarnings)
            let check = try await singBoxProcess.check(config: newConfig)
            guard check.exitCode == 0 else {
                throw AppStateError.coreCheckFailed(check.stderr)
            }

            guard await reloadTUNConfiguration(
                newConfig: newConfig,
                oldConfig: oldConfig,
                client: client,
                operation: operation
            ) else {
                tunSettings = oldTunSettings
                return
            }

            tunSettings = requestedSettings
            currentConfig = newConfig
            try await persistSettings()
            try await writeDiagnosticConfig(newConfig)
            errorMessage = nil
            markRuntimeStarted()
            resumeDashboardMonitoringIfNeeded()
            resumeLogMonitoringIfNeeded()
        } catch {
            tunSettings = oldTunSettings
            errorMessage = "应用 TUN 设置失败：\(error.localizedDescription)"
            recordRuntimeEvent(level: .error, title: "\(operation)应用失败")
        }
    }

    func applyDNSSettings(_ requestedSettings: DNSSettings, operation: String = "DNS 设置") async {
        guard !isBusy else { return }
        isApplyingRouting = true
        defer { isApplyingRouting = false }

        let oldDNSSettings = dnsSettings
        do {
            let settings = try requestedSettings.validated()
            guard status == .on else {
                dnsSettings = settings
                try await persistSettings()
                errorMessage = nil
                return
            }
            guard let runtime,
                  let oldConfig = currentConfig,
                  let client = clashAPIClient,
                  !activeModes.isEmpty else {
                throw AppStateError.missingRuntimeState
            }

            let prepared = try await ruleSetService.prepare(includeAds: routingSettings.blockAds, mirror: ruleSetSettings.mirror, allowsNetwork: ruleSetSettings.autoUpdate)
            appendWarnings(prepared.warnings)
            let (newConfig, configWarnings) = try await generateConfiguration(
                runtime: runtime,
                ruleSets: prepared.ruleSets,
                routingSettings: routingSettings,
                enabledModes: activeModes,
                outboundMode: outboundMode,
                tunSettings: tunSettings,
                dnsSettings: settings
            )
            appendWarnings(configWarnings)
            let check = try await singBoxProcess.check(config: newConfig)
            guard check.exitCode == 0 else {
                throw AppStateError.coreCheckFailed(check.stderr)
            }

            if activeModes.contains(.tun) {
                guard await reloadTUNConfiguration(
                    newConfig: newConfig,
                    oldConfig: oldConfig,
                    client: client,
                    operation: operation
                ) else {
                    return
                }
            } else {
                suspendDashboardMonitoring()
                suspendLogMonitoring()
                await cancelCoreExitMonitoring()
                do {
                    try await singBoxProcess.restart(config: newConfig)
                    try await healthVerifier(client)
                } catch {
                    await restoreOldSystemConfiguration(
                        config: oldConfig,
                        client: client,
                        updateError: error,
                        operation: "DNS 设置"
                    )
                    return
                }
            }

            dnsSettings = settings
            currentConfig = newConfig
            if !activeModes.contains(.tun) {
                await armRunningSystemCoreIfAvailable()
            }
            try await persistSettings()
            try await writeDiagnosticConfig(newConfig)
            errorMessage = nil
            markRuntimeStarted()
            resumeDashboardMonitoringIfNeeded()
            resumeLogMonitoringIfNeeded()
            if !activeModes.contains(.tun) {
                recordConfigurationApplied(operation: operation)
            }
        } catch {
            dnsSettings = oldDNSSettings
            errorMessage = "应用 DNS 设置失败：\(error.localizedDescription)"
            recordRuntimeEvent(level: .error, title: "\(operation)应用失败")
        }
    }

    func startDashboardMonitoring() {
        dashboardMonitorConsumers.insert(.dashboard)
        resumeDashboardMonitoringIfNeeded()
    }

    func stopDashboardMonitoring() {
        dashboardMonitorConsumers.remove(.dashboard)
        if dashboardMonitorConsumers.isEmpty { suspendDashboardMonitoring() }
    }

    func startMenuBarMonitoring() {
        dashboardMonitorConsumers.insert(.menuBar)
        resumeDashboardMonitoringIfNeeded()
    }

    func stopMenuBarMonitoring() {
        dashboardMonitorConsumers.remove(.menuBar)
        if dashboardMonitorConsumers.isEmpty { suspendDashboardMonitoring() }
    }

    func startLogMonitoring() {
        isLogsVisible = true
        resumeLogMonitoringIfNeeded()
    }

    func stopLogMonitoring() {
        isLogsVisible = false
        suspendLogMonitoring()
    }

    func setLogLevel(_ level: CoreLogLevel) {
        guard [.info, .warning, .error].contains(level), level != logLevel else { return }
        logLevel = level
        // 不清空的话旧等级的行仍留在列表里，用户会以为切换没生效。
        liveLogs.removeAll(keepingCapacity: true)
        discardPendingLogs()
        suspendLogMonitoring()
        resumeLogMonitoringIfNeeded()
    }

    func clearLiveLogs() {
        liveLogs.removeAll(keepingCapacity: false)
        discardPendingLogs()
    }

    func exportLogs() async throws -> String {
        try await kernelLogStore.exportText()
    }

    /// 导出可直接发给维护者的脱敏诊断文本。只收集现有脱敏配置和日志，
    /// 不读取订阅 YAML、备份、节点缓存或运行时 API secret。
    func exportDiagnostics() async throws -> String {
        let root = storage.rootDirectory
        let configURL = root.appending(path: "config.json")
        let configText: String
        if let data = try await storage.readIfPresent(from: configURL) {
            let sanitized = try ConfigGenerator.diagnosticSnapshot(from: data)
            configText = String(decoding: sanitized, as: UTF8.self)
        } else {
            configText = "（尚未生成配置）"
        }
        let recoveryNames = ["proxy-recovery.json", "dns-recovery.json", "tun-recovery.json"]
        let recoveryState = recoveryNames.map {
            "\($0): \(FileManager.default.fileExists(atPath: root.appending(path: $0).path) ? "存在" : "无")"
        }.joined(separator: "\n")
        let modes = activeModes.map(\.displayName).sorted().joined(separator: " + ")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        let diagnostics = """
        kongshan 脱敏诊断
        导出时间：\(now().formatted(.iso8601))
        应用版本：\(version) (\(build))
        内核版本：\(coreVersion)
        状态：\(statusText)
        接管：\(modes.isEmpty ? "未开启" : modes)
        出站模式：\(outboundMode.displayName)
        当前配置：\(configItems.first { $0.id == activeConfigID }?.name ?? "无")

        ===== 恢复状态 =====
        \(recoveryState)

        ===== 当前消息 =====
        \(errorMessage ?? "无错误")
        \(warnings.isEmpty ? "无警告" : warnings.joined(separator: "\n"))

        ===== 运行事件 =====
        \(runtimeEventDiagnosticText)

        ===== 脱敏配置 =====
        \(configText)

        ===== 内核日志 =====
        \(try await kernelLogStore.exportText())
        """
        return diagnostics.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    func exportBackup() async throws -> Data {
        var caches: [UUID: Data] = [:]
        for source in subscriptions {
            if let data = try await storage.readIfPresent(from: storage.cacheURL(for: source)) {
                caches[source.id] = data
            }
        }
        let settings = BackupSettings(
            selectedNodeID: selectedNodeID,
            testURL: testURLString,
            preferredMode: preferredMode,
            tunSettings: tunSettings,
            dnsSettings: dnsSettings,
            subscriptionUpdateSettings: subscriptionUpdateSettings,
            ruleSetSettings: ruleSetSettings,
            outboundMode: outboundMode,
            groupSelections: groupSelections,
            activeConfigID: activeConfigID,
            speedTestMethod: speedTestMethod
        )
        return try JSONEncoder.sorted.encode(KongshanBackup(
            version: KongshanBackup.currentVersion,
            createdAt: now(),
            subscriptions: subscriptions,
            manualNodes: manualNodes,
            settings: settings,
            routingSettings: routingSettings,
            subscriptionCaches: caches
        ))
    }

    func importBackup(_ data: Data) async {
        guard status == .off, !isBusy else {
            errorMessage = "请先停止代理和内核，再导入备份"
            return
        }
        do {
            let backup = try KongshanBackup.decodeValidated(from: data)
            let settings = backup.settings
            let persisted = PersistedSettings(
                selectedNodeID: settings.selectedNodeID,
                testURL: settings.testURL,
                preferredMode: settings.preferredMode,
                tunSettings: settings.tunSettings,
                dnsSettings: settings.dnsSettings,
                subscriptionUpdateSettings: settings.subscriptionUpdateSettings,
                ruleSetSettings: settings.ruleSetSettings,
                outboundMode: settings.outboundMode,
                groupSelections: settings.groupSelections,
                activeConfigID: settings.activeConfigID,
                speedTestMethod: settings.speedTestMethod,
                menuBarIconStyle: menuBarIconStyle,
                // 备份不含端口：那是本机运行时状态，导入别的机器的备份不该顶掉本机端口。
                mixedPort: preferredMixedPort
            )

            var importedNodes = backup.manualNodes
            var importedGroups: [UUID: [PolicyGroup]] = [:]
            var importedRules: [UUID: [SubscriptionRule]] = [:]
            for source in backup.subscriptions {
                guard let yamlData = backup.subscriptionCaches[source.id],
                      let yaml = String(data: yamlData, encoding: .utf8) else { continue }
                let converted = try ClashSubscriptionConverter.convert(yaml: yaml, sourceID: source.id)
                importedNodes.append(contentsOf: converted.nodes)
                importedGroups[source.id] = converted.policyGroups
                importedRules[source.id] = converted.subscriptionRules
            }

            try await storage.prepare()
            let filePayloads: [(URL, Data)] = [
                (subscriptionsURL, try JSONEncoder.sorted.encode(backup.subscriptions)),
                (manualNodesURL, try JSONEncoder.sorted.encode(backup.manualNodes)),
                (settingsURL, try JSONEncoder.sorted.encode(persisted)),
                (rulesURL, try JSONEncoder.sorted.encode(backup.routingSettings))
            ] + backup.subscriptions.compactMap { source in
                backup.subscriptionCaches[source.id].map { (storage.cacheURL(for: source), $0) }
            }
            var snapshots: [FileSnapshot] = []
            for item in filePayloads {
                snapshots.append(FileSnapshot(
                    url: item.0,
                    data: try await storage.readIfPresent(from: item.0)
                ))
            }
            do {
                for (url, payload) in filePayloads {
                    try await storage.writeAtomically(payload, to: url)
                }
            } catch {
                for snapshot in snapshots {
                    if let old = snapshot.data {
                        try? await storage.writeAtomically(old, to: snapshot.url)
                    } else {
                        try? FileManager.default.removeItem(at: snapshot.url)
                    }
                }
                throw error
            }

            subscriptions = backup.subscriptions
            nodes = importedNodes
            discoveredPolicyGroups = importedGroups
            discoveredRules = importedRules
            selectedNodeID = settings.selectedNodeID
            testURLString = settings.testURL
            preferredMode = settings.preferredMode
            tunSettings = settings.tunSettings
            dnsSettings = settings.dnsSettings
            subscriptionUpdateSettings = settings.subscriptionUpdateSettings
            ruleSetSettings = settings.ruleSetSettings
            outboundMode = settings.outboundMode
            groupSelections = settings.groupSelections
            activeConfigID = settings.activeConfigID
            speedTestMethod = settings.speedTestMethod
            routingSettings = backup.routingSettings
            delays = [:]
            ensureActiveConfig()
            await rescheduleSubscriptionUpdates()
            errorMessage = nil
        } catch {
            errorMessage = "导入备份失败：\(error.localizedDescription)"
        }
    }

    func dismissError() {
        errorMessage = nil
        if case .failed = status, activeModes.isEmpty { status = .off }
    }

    func clearWarnings() {
        warnings.removeAll(keepingCapacity: false)
    }

    /// 消息条数上限。App 常驻运行，断流重连、订阅刷新等都会产生消息，
    /// 不封顶的话消息页会无限增长（内存 + 列表渲染都吃亏）。
    private static let warningLimit = 200

    /// 唯一的告警写入口：**去重 + 封顶**。
    /// 别再写 `warnings = xxx`——那会把其它模块刚产生的消息一起抹掉（订阅刷新曾这样吞掉内核告警）。
    private func appendWarning(_ message: String) {
        appendWarnings([message])
    }

    private func appendWarnings(_ messages: [String]) {
        for message in messages where !warnings.contains(message) {
            warnings.append(message)
        }
        if warnings.count > Self.warningLimit {
            warnings.removeFirst(warnings.count - Self.warningLimit)
        }
    }

    func nodes(for source: SubscriptionSource) -> [ProxyNode] {
        nodes.filter { $0.sourceID == source.id }
    }

    var manualNodes: [ProxyNode] {
        nodes.filter { $0.sourceID == nil }
    }

    private func rescheduleSubscriptionUpdates(notBefore: Date? = nil) async {
        nextSubscriptionUpdateAt = await subscriptionUpdateScheduler.schedule(
            sources: subscriptions.filter(\.autoUpdate),
            settings: subscriptionUpdateSettings,
            notBefore: notBefore
        ) { [weak self] in
            await self?.runScheduledSubscriptionRefresh()
        }
    }

    private func runScheduledSubscriptionRefresh() async {
        if isBusy {
            await rescheduleSubscriptionUpdates(notBefore: now().addingTimeInterval(15 * 60))
            return
        }
        let hadFailures = await performSubscriptionRefresh(notifyOnFailure: true, automaticOnly: true)
        await rescheduleSubscriptionUpdates(
            notBefore: hadFailures ? now().addingTimeInterval(15 * 60) : nil
        )
    }

    private func loadPersistedState() async throws {
        Task { await loadBundledCoreVersionIfNeeded() }   // 后台读内核版本，不阻塞加载
        if let data = try await storage.readIfPresent(from: subscriptionsURL) {
            subscriptions = try JSONDecoder().decode([SubscriptionSource].self, from: data)
        }
        if let data = try await storage.readIfPresent(from: manualNodesURL) {
            nodes = try JSONDecoder().decode([ProxyNode].self, from: data)
        }
        for source in subscriptions {
            guard let data = try await storage.readIfPresent(from: storage.cacheURL(for: source)),
                  let yaml = String(data: data, encoding: .utf8) else {
                continue
            }
            // 大订阅的 YAML（上百节点 + 数千规则）解析很重，放到后台线程做，
            // 别在主 actor 上同步解析，否则启动时界面会卡住转圈。
            let sourceID = source.id
            let converted = await Task.detached(priority: .userInitiated) {
                try? ClashSubscriptionConverter.convert(yaml: yaml, sourceID: sourceID)
            }.value
            guard let result = converted else { continue }
            nodes.append(contentsOf: result.nodes)
            appendWarnings(result.warnings)
            // 重启后配置自带的策略组与规则也要从缓存恢复，否则生效配置的策略/规则会是空的。
            discoveredPolicyGroups[source.id] = result.policyGroups
            discoveredRules[source.id] = result.subscriptionRules
        }
        if let data = try await storage.readIfPresent(from: settingsURL) {
            let settings = try JSONDecoder().decode(PersistedSettings.self, from: data)
            selectedNodeID = settings.selectedNodeID
            testURLString = settings.testURL
            speedTestMethod = settings.speedTestMethod ?? .tcpPing
            preferredMode = settings.preferredMode ?? .systemProxy
            tunSettings = settings.tunSettings ?? .defaults
            dnsSettings = settings.dnsSettings ?? .defaults
            subscriptionUpdateSettings = settings.subscriptionUpdateSettings ?? .defaults
            ruleSetSettings = settings.ruleSetSettings ?? .defaults
            outboundMode = settings.outboundMode ?? .rule
            groupSelections = settings.groupSelections ?? [:]
            activeConfigID = settings.activeConfigID
            preferredMixedPort = settings.mixedPort
            menuBarIconStyle = settings.menuBarIconStyle ?? .peak
        }
        if let data = try await storage.readIfPresent(from: rulesURL) {
            routingSettings = try JSONDecoder().decode(RoutingSettings.self, from: data).validated()
        }
        if let data = try await storage.readIfPresent(from: runtimeEventsURL),
           let decoded = try? JSONDecoder().decode([RuntimeEvent].self, from: data) {
            runtimeEvents = Array(decoded.suffix(Self.runtimeEventLimit))
        }
        ensureActiveConfig()
    }

    private static let runtimeEventLimit = 200

    func clearRuntimeEvents() {
        runtimeEvents.removeAll(keepingCapacity: false)
        scheduleRuntimeEventsPersist()
    }

    func recordRuntimeEvent(
        level: RuntimeEvent.Level = .info,
        title: String,
        detail: String? = nil,
        previousPID: Int32? = nil,
        currentPID: Int32? = nil
    ) {
        runtimeEvents.append(RuntimeEvent(
            timestamp: now(),
            level: level,
            title: title,
            detail: detail,
            previousPID: previousPID,
            currentPID: currentPID
        ))
        if runtimeEvents.count > Self.runtimeEventLimit {
            runtimeEvents.removeFirst(runtimeEvents.count - Self.runtimeEventLimit)
        }
        scheduleRuntimeEventsPersist()
    }

    private func scheduleRuntimeEventsPersist() {
        persistRuntimeEventsTask?.cancel()
        persistRuntimeEventsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.persistRuntimeEventsTask = nil
            try? await self.persistRuntimeEvents()
        }
    }

    private func persistRuntimeEvents() async throws {
        try await storage.writeAtomically(
            try JSONEncoder.sorted.encode(runtimeEvents),
            to: runtimeEventsURL
        )
    }

    private func flushRuntimeEventsIfNeeded() async {
        guard persistRuntimeEventsTask != nil else { return }
        persistRuntimeEventsTask?.cancel()
        persistRuntimeEventsTask = nil
        try? await persistRuntimeEvents()
    }

    private var runtimeEventDiagnosticText: String {
        guard !runtimeEvents.isEmpty else { return "无" }
        return runtimeEvents.map { event in
            var fields = [event.timestamp.formatted(.iso8601), event.title]
            if let detail = event.detail { fields.append(detail) }
            if event.previousPID != nil || event.currentPID != nil {
                fields.append("PID \(event.previousPID.map { String($0) } ?? "-") -> \(event.currentPID.map { String($0) } ?? "-")")
            }
            return fields.joined(separator: " | ")
        }.joined(separator: "\n")
    }

    private func runtimeModeDescription(_ modes: Set<ProxyMode>) -> String {
        let names = [ProxyMode.systemProxy, .tun].filter(modes.contains).map(\.displayName)
        return names.isEmpty ? "未接管" : names.joined(separator: " + ")
    }

    private func recordConfigurationApplied(operation: String) {
        recordRuntimeEvent(title: "\(operation)已应用", currentPID: monitoredCorePID)
    }

    private func persistSubscriptions() async throws {
        try await storage.writeAtomically(
            try JSONEncoder.sorted.encode(subscriptions),
            to: subscriptionsURL
        )
    }

    private func persistManualNodes() async throws {
        try await storage.writeAtomically(
            try JSONEncoder.sorted.encode(manualNodes),
            to: manualNodesURL
        )
    }

    private func persistSettings() async throws {
        try await storage.writeAtomically(
            try JSONEncoder.sorted.encode(PersistedSettings(
                selectedNodeID: selectedNodeID,
                testURL: testURLString,
                preferredMode: preferredMode,
                tunSettings: tunSettings,
                dnsSettings: dnsSettings,
                subscriptionUpdateSettings: subscriptionUpdateSettings,
                ruleSetSettings: ruleSetSettings,
                outboundMode: outboundMode,
                groupSelections: groupSelections,
                activeConfigID: activeConfigID,
                speedTestMethod: speedTestMethod,
                menuBarIconStyle: menuBarIconStyle,
                mixedPort: preferredMixedPort
            )),
            to: settingsURL
        )
    }

    /// 切节点等高频操作 500ms 防抖落盘。立即生效靠 Clash API 的 select 已发出；
    /// 落盘只关乎重启后恢复——延迟 500ms 用户无感知，但能避免连续点选时每次都同步 IO。
    private func schedulePersistSettingsDebounced() {
        persistSettingsTask?.cancel()
        persistSettingsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.persistSettingsTask = nil
            try? await self.persistSettings()
        }
    }

    /// 退出前调用：取消未完成的防抖并立即落盘，确保最后一次切节点不丢。
    private func flushPersistSettingsIfNeeded() async {
        if persistSettingsTask != nil {
            persistSettingsTask?.cancel()
            persistSettingsTask = nil
            try? await persistSettings()
        }
    }

    private func persistRoutingSettings() async throws {
        try await storage.writeAtomically(
            try JSONEncoder.sorted.encode(routingSettings),
            to: rulesURL
        )
    }

    private func restoreOldSystemConfiguration(
        config: Data,
        client: ClashAPIClient,
        updateError: Error,
        operation: String
    ) async {
        do {
            try await singBoxProcess.restart(config: config)
            try await healthVerifier(client)
            currentConfig = config
            status = .on
            errorMessage = "应用\(operation)失败，已恢复旧配置：\(updateError.localizedDescription)"
            markRuntimeStarted()
            await armRunningSystemCoreIfAvailable()
            resumeDashboardMonitoringIfNeeded()
            resumeLogMonitoringIfNeeded()
            recordRuntimeEvent(level: .warning, title: "\(operation)应用失败，已回滚", currentPID: monitoredCorePID)
        } catch {
            await singBoxProcess.stop()
            let restoreMessage: String
            do {
                try await systemProxyManager.restore()
                restoreMessage = "系统代理已恢复"
            } catch let proxyError {
                restoreMessage = "系统代理恢复失败：\(proxyError.localizedDescription)"
            }
            try? await systemDNSManager.restore()
            clearRuntimeState()
            setFailure(
                "\(operation)更新失败且旧配置无法恢复：\(updateError.localizedDescription)；\(error.localizedDescription)；\(restoreMessage)"
            )
            recordRuntimeEvent(level: .error, title: "\(operation)应用与回滚均失败")
        }
    }

    private func reloadTUNConfiguration(
        newConfig: Data,
        oldConfig: Data,
        client: ClashAPIClient,
        operation: String
    ) async -> Bool {
        let previousModes = activeModes
        let previousPID = monitoredCorePID
        await cancelCoreExitMonitoring()
        suspendDashboardMonitoring()
        suspendLogMonitoring()
        do {
            try await stopTUN()
            activeModes = []
        } catch {
            status = .on
            errorMessage = "应用\(operation)失败，旧 TUN 配置仍在运行：\(error.localizedDescription)"
            if let previousPID { await armCoreExitMonitoring(pid: previousPID) }
            resumeDashboardMonitoringIfNeeded()
            resumeLogMonitoringIfNeeded()
            return false
        }

        var newConfigurationRecord: PrivilegedProcessRecord?
        do {
            let record = try await startTUN(config: newConfig)
            newConfigurationRecord = record
            activeModes = previousModes
            try await healthVerifier(client)
            currentConfig = newConfig
            await armCoreExitMonitoring(pid: record.pid)
            recordRuntimeEvent(
                title: "\(operation)已重载",
                previousPID: previousPID,
                currentPID: record.pid
            )
            return true
        } catch {
            let updateError = error
            if let newConfigurationRecord {
                do {
                    try await stopTUN()
                    activeModes = []
                } catch let stopError {
                    currentConfig = newConfig
                    activeModes = previousModes
                    await armCoreExitMonitoring(pid: newConfigurationRecord.pid)
                    setFailure(
                        "新 TUN 配置健康检查失败且无法停止：\(updateError.localizedDescription)；\(stopError.localizedDescription)"
                    )
                    return false
                }
            }

            var oldConfigurationRecord: PrivilegedProcessRecord?
            do {
                let record = try await startTUN(config: oldConfig)
                oldConfigurationRecord = record
                activeModes = previousModes
                try await healthVerifier(client)
                currentConfig = oldConfig
                status = .on
                errorMessage = "应用\(operation)失败，已恢复旧 TUN 配置：\(updateError.localizedDescription)"
                markRuntimeStarted()
                await armCoreExitMonitoring(pid: record.pid)
                resumeDashboardMonitoringIfNeeded()
                resumeLogMonitoringIfNeeded()
                recordRuntimeEvent(
                    level: .warning,
                    title: "\(operation)重载失败，已回滚",
                    previousPID: previousPID,
                    currentPID: record.pid
                )
                return false
            } catch let rollbackError {
                if oldConfigurationRecord != nil {
                    try? await stopTUN()
                } else {
                    // start 失败时默认 launcher 也会清理临时记录；再次 stop 是幂等安全网。
                    try? await stopTUN()
                }
                // TUN 已经起不来了，接管的系统 DNS 不还原会导致全网解析瘫痪。
                try? await systemDNSManager.restore()
                clearRuntimeState()
                setFailure(
                    "\(operation)更新失败且旧 TUN 配置无法恢复：\(updateError.localizedDescription)；\(rollbackError.localizedDescription)"
                )
                recordRuntimeEvent(level: .error, title: "\(operation)重载与回滚均失败", previousPID: previousPID)
                return false
            }
        }
    }

    private func replaceNodes(_ newNodes: [ProxyNode], for sourceID: UUID) {
        nodes.removeAll { $0.sourceID == sourceID }
        nodes.append(contentsOf: newNodes)
    }

    private func resumeDashboardMonitoringIfNeeded() {
        guard !dashboardMonitorConsumers.isEmpty,
              status == .on,
              let client = clashAPIClient,
              dashboardTasks.isEmpty else {
            return
        }

        let trafficTask = Task { [weak self] in
            do {
                let stream = await client.trafficStream()
                for try await sample in stream {
                    guard !Task.isCancelled else { return }
                    self?.receiveTraffic(sample)
                }
                if !Task.isCancelled {
                    self?.dashboardStreamEnded("流量推送已断开")
                }
            } catch {
                if !Task.isCancelled {
                    self?.dashboardStreamEnded("流量推送已断开：\(error.localizedDescription)")
                }
            }
        }
        let connectionTask = Task { [weak self] in
            do {
                let stream = await client.connectionStream()
                for try await snapshot in stream {
                    guard !Task.isCancelled else { return }
                    // 同样的等值判断：连接数和内存占用在空闲时经常一秒都不变。
                    self?.receiveConnectionSnapshot(snapshot)
                }
                if !Task.isCancelled {
                    self?.dashboardStreamEnded("连接推送已断开")
                }
            } catch {
                if !Task.isCancelled {
                    self?.dashboardStreamEnded("连接推送已断开：\(error.localizedDescription)")
                }
            }
        }
        let versionTask = Task { [weak self] in
            guard let version = try? await client.version(), !Task.isCancelled else { return }
            self?.coreVersion = version
        }
        dashboardTasks = [trafficTask, connectionTask, versionTask]
    }

    private func suspendDashboardMonitoring() {
        dashboardRetryTask?.cancel()
        dashboardRetryTask = nil
        // 退避间隔不在这里复位：重连路径会经过本方法，复位会退化成 2 秒死循环。
        // 只有真正收到数据（receiveTraffic）才回到起始间隔。
        dashboardTasks.forEach { $0.cancel() }
        dashboardTasks.removeAll()
    }

    private func resumeLogMonitoringIfNeeded() {
        guard isLogsVisible,
              status == .on,
              let client = clashAPIClient,
              logTask == nil else {
            return
        }

        let level = logLevel
        logTask = Task { [weak self] in
            do {
                let stream = await client.logStream(level: level)
                for try await entry in stream {
                    guard !Task.isCancelled else { return }
                    self?.receiveLog(entry)
                }
                if !Task.isCancelled {
                    self?.logStreamEnded("内核日志推送已断开")
                }
            } catch {
                if !Task.isCancelled {
                    self?.logStreamEnded("内核日志推送已断开：\(error.localizedDescription)")
                }
            }
        }
    }

    private func suspendLogMonitoring() {
        logRetryTask?.cancel()
        logRetryTask = nil
        logTask?.cancel()
        logTask = nil
        // 停止前把攒着的行补上：日志页是用户主动打开看的，最后 200ms 不该凭空消失。
        // 退出/切等级路径会先清空 liveLogs 再走到这里，那时 pendingLogs 已被丢弃，不会复活。
        logFlushTask?.cancel()
        logFlushTask = nil
        flushPendingLogs()
    }

    /// 日志行先攒着，按 `logFlushInterval` 成批并入 `liveLogs`。
    ///
    /// 逐行 append 的代价：`@Observable` 每次写入都失效整棵视图图，而内核忙起来
    /// （开着 info 等级 + 连接量大）一秒能推几十行 → 一秒几十次全量重排。
    /// 这比之前修掉的"每秒一次"严重一个数量级，而且正好发生在用户盯着日志页的时候。
    /// 攒批**不丢行**，只是最多晚 200ms 显示——日志页本来就是滚动流，没人能分辨。
    private static let logFlushInterval = Duration.milliseconds(200)

    private func receiveLog(_ entry: CoreLogEntry) {
        logRetryDelay = 2
        pendingLogs.append(LiveLogEntry(entry: entry))
        // 单次爆发也不能无限攒：超过上限的部分横竖会被 trim 掉，留着只是白占内存。
        if pendingLogs.count > KernelLogStore.defaultBufferedLineLimit {
            pendingLogs.removeFirst(pendingLogs.count - KernelLogStore.defaultBufferedLineLimit)
        }
        scheduleLogFlush()
    }

    private func scheduleLogFlush() {
        guard logFlushTask == nil else { return }
        logFlushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.logFlushInterval)
            guard let self, !Task.isCancelled else { return }
            self.logFlushTask = nil
            self.flushPendingLogs()
        }
    }

    private func flushPendingLogs() {
        guard !pendingLogs.isEmpty else { return }
        liveLogs.append(contentsOf: pendingLogs)
        pendingLogs.removeAll(keepingCapacity: true)
        if liveLogs.count > KernelLogStore.defaultBufferedLineLimit {
            liveLogs.removeFirst(liveLogs.count - KernelLogStore.defaultBufferedLineLimit)
        }
    }

    /// 丢弃尚未并入的日志行。切等级/清空/停止监控都要调用——
    /// 否则待发的旧行会在下一次 flush 时"复活"到已经清空的列表里。
    private func discardPendingLogs() {
        logFlushTask?.cancel()
        logFlushTask = nil
        pendingLogs.removeAll(keepingCapacity: false)
    }

    private func logStreamEnded(_ message: String) {
        guard isLogsVisible, status == .on else { return }
        if warnings.last != message { appendWarning(message) }
        scheduleLogReconnect()
    }

    private func scheduleLogReconnect() {
        guard logRetryTask == nil else { return }
        let delay = logRetryDelay
        logRetryDelay = min(logRetryDelay * 2, 30)
        logRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.logRetryTask = nil
            guard self.isLogsVisible, self.status == .on else { return }
            self.suspendLogMonitoring()
            self.resumeLogMonitoringIfNeeded()
        }
    }

    private func receiveConnectionSnapshot(_ snapshot: ConnectionSnapshot) {
        if activeConnectionCount != snapshot.connectionCount {
            activeConnectionCount = snapshot.connectionCount
        }
        if coreMemory != snapshot.memory { coreMemory = snapshot.memory }

        // 会话累计流量。这条流是唯一的权威来源，无论仪表盘是否可见都要喂——
        // 断一秒就永久少一秒的量，不像速率那样只是显示滞后。
        sessionTraffic.record(
            uploadTotal: snapshot.uploadTotal,
            downloadTotal: snapshot.downloadTotal
        )
        if sessionUpload != sessionTraffic.upload { sessionUpload = sessionTraffic.upload }
        if sessionDownload != sessionTraffic.download { sessionDownload = sessionTraffic.download }
    }

    private func receiveTraffic(_ sample: TrafficSample) {
        dashboardRetryDelay = 2
        // `@Observable` 赋同样的值也会通知观察者 → 失效整棵视图图。空闲时速率长时间是 0，
        // 无条件写就是每秒一次纯白工的全量重排。等值判断在这里几乎总是命中。
        if uploadRate != sample.up { uploadRate = sample.up }
        if downloadRate != sample.down { downloadRate = sample.down }
        // trafficHistory 只有仪表盘的折线图在读，且每个点的时间戳都不同、等值判断救不了。
        // 托盘速率订阅的是同一条流但根本不看历史 → 仪表盘不在屏幕上时继续 append，
        // 等于每秒白白失效一次视图图。代价是重开仪表盘时折线从空开始画（有占位态）。
        guard windowContentIsVisible, dashboardMonitorConsumers.contains(.dashboard) else { return }
        // 隔一个采样点才入图。图表是这一页最贵的部件（60 个点 + 面积/折线双系列），
        // 每次 append 都要整页重排；实测仪表盘开着时它占了三成以上的 CPU。
        // 曲线是看趋势的，2 秒一个点足够，而代价直接减半。
        trafficSampleParity.toggle()
        guard trafficSampleParity else { return }
        trafficHistory.append(TrafficPoint(
            timestamp: now(),
            upload: sample.up,
            download: sample.down
        ))
        if trafficHistory.count > 60 {
            trafficHistory.removeFirst(trafficHistory.count - 60)
        }
    }

    private func dashboardStreamEnded(_ message: String) {
        guard !dashboardMonitorConsumers.isEmpty, status == .on else { return }
        if warnings.last != message { appendWarning(message) }
        scheduleDashboardReconnect()
    }

    /// 不是轮询：仅在推流失败后重试，页面仍可见且内核在跑才继续。
    private func scheduleDashboardReconnect() {
        guard dashboardRetryTask == nil else { return }
        let delay = dashboardRetryDelay
        dashboardRetryDelay = min(dashboardRetryDelay * 2, 30)
        dashboardRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.dashboardRetryTask = nil
            guard !self.dashboardMonitorConsumers.isEmpty, self.status == .on else { return }
            self.suspendDashboardMonitoring()
            self.resumeDashboardMonitoringIfNeeded()
        }
    }

    private func markRuntimeStarted() {
        runtimeStartedAt = now()
        uploadRate = 0
        downloadRate = 0
        activeConnectionCount = 0
        coreMemory = 0
        coreVersion = "—"
        trafficHistory.removeAll(keepingCapacity: true)
    }

    private func clearDashboardRuntime() {
        suspendDashboardMonitoring()
        uploadRate = 0
        downloadRate = 0
        activeConnectionCount = 0
        coreMemory = 0
        coreVersion = "—"
        runtimeStartedAt = nil
        trafficHistory.removeAll(keepingCapacity: false)
        // 会话累计只在**停止接管**时归零。内核重启（改设置 / 崩溃自愈 / 切配置）
        // 走的是 markRuntimeStarted，那里不能清——跨内核重启保持连续正是这个累计量的意义。
        sessionTraffic.reset()
        sessionUpload = 0
        sessionDownload = 0
    }

    /// 系统代理绕过表：在用户配置之外补上探测到的内网域名。
    ///
    /// TUN 模式靠 `dns-lan` + 直连路由解决内网访问；**系统代理模式必须靠绕过表**——
    /// 系统代理下 DNS 归 OS 管，内核只从 CONNECT 里拿到域名，若不绕过就会拿这个内网域名
    /// 去问 `dns-remote`（经代理的公共 DoH），公共 DNS 当然不知道你的内网主机。
    private func bypassEntries(for settings: RoutingSettings) -> [String] {
        let lan = LANResolver.effective(settings: tunSettings, detected: lanResolverSnapshot)
        guard lan.isUsable else { return settings.systemProxyBypassEntries }
        var entries = settings.systemProxyBypassEntries
        for suffix in lan.searchDomains {
            // 同时给通配和裸后缀：macOS 的 `*.corp.com` 不匹配 `corp.com` 本身。
            for entry in ["*.\(suffix)", suffix] where !entries.contains(entry) {
                entries.append(entry)
            }
        }
        return entries
    }

    /// 探测内网 DNS。只在能读到有效结果时才覆盖已有快照——TUN 接管期间读到的
    /// 只有内核自己的地址（已被 excluding 排除），此时保留旧值而不是清空。
    private func refreshLANResolverIfPossible(tunSettings: TunSettings) async {
        // 关掉功能时**不清快照**：快照是探测到的原始事实，用不用由
        // `LANResolver.effective` 按开关决定。清掉会造成一个隐蔽故障——
        // TUN 运行中关掉再打开，重新生成配置时 DNS 已被接管、探不到东西，
        // 于是快照永久为空，功能看着开着却不起作用。
        guard tunSettings.lanDNSEnabled else { return }
        // TUN 自身地址落在 172.16.0.0/12 里，不排掉会把内核当成"内网 DNS"而自指。
        let probed = await lanResolverProbe(tunResolverExclusions(tunSettings))
        guard probed.isUsable else { return }
        lanResolverSnapshot = probed
    }

    private func tunResolverExclusions(_ settings: TunSettings) -> Set<String> {
        Set(settings.addresses.map { address in
            String(address.split(separator: "/").first ?? "")
        } + [settings.dnsServerAddress])
    }

    private func generateConfiguration(
        runtime: RuntimeParameters,
        ruleSets: PreparedRuleSets,
        routingSettings: RoutingSettings,
        enabledModes: Set<ProxyMode>,
        outboundMode: OutboundMode,
        tunSettings: TunSettings,
        dnsSettings: DNSSettings
    ) async throws -> (Data, [String]) {
        // 只用当前生效配置里的节点与它自带的策略组来生成配置。
        var scoped = routingSettings
        scoped.policyGroups = activeConfigPolicyGroups
        // 物理网络没有全局 IPv6 时，TUN 不配 IPv6 地址——否则应用看到 TUN 的 IPv6
        // 会尝试 IPv6 直连，而 direct 出站到 IPv6 目标会因 en0 无全局 IPv6 报
        // "no route to host"，应用不快速回退 IPv4 → 用户感知"TUN 开了网断"。
        // dnsServerAddress 只看 IPv4，剥掉 IPv6 不影响系统 DNS 指向。
        let effectiveTun = enabledModes.contains(.tun) && !Self.physicalNetworkHasGlobalIPv6()
            ? tunSettings.stripIPv6()
            : tunSettings
        // 内网 DNS 必须在**接管系统 DNS 之前**探测：TUN 一接管，系统 DNS 就只剩内核
        // 自己的地址，再探什么都读不到。start() 里配置生成先于 systemDNSManager.enable，
        // 所以这里读到的还是 DHCP 下发的真实内网 DNS。
        // 重启内核时（崩溃自愈 / 改规则）DNS 已被接管，此时探测拿不到东西——
        // 保留上一次的结果，否则一次重启就把内网分流悄悄弄丢。
        await refreshLANResolverIfPossible(tunSettings: effectiveTun)
        let input = ConfigInput(
            nodes: activeConfigNodes,
            selectedNodeID: selectedNodeID,
            runtime: runtime,
            testURL: testURLString,
            routing: RoutingConfiguration(
                settings: scoped,
                ruleSets: ruleSets,
                subscriptionRules: subscriptionRules
            ),
            enabledModes: enabledModes,
            outboundMode: outboundMode,
            tunSettings: effectiveTun,
            dnsSettings: dnsSettings,
            groupDefaults: resolvedGroupDefaults(),
            lanResolver: lanResolverSnapshot
        )
        // 生成 + JSON 编码大配置（几百出站、上千规则）很吃 CPU，放后台线程，别卡住主线程 UI。
        let result = try await Task.detached { try ConfigGenerator.generateWithWarnings(input) }.value
        return (result.config, result.warnings)
    }

    /// 写一份脱敏的 config.json 供排查用。脱敏要解析+重编码整份配置，也放后台线程，不卡 UI。
    private func writeDiagnosticConfig(_ config: Data) async throws {
        let diagnostic = try await Task.detached { try ConfigGenerator.diagnosticSnapshot(from: config) }.value
        try await storage.writeAtomically(
            diagnostic,
            to: storage.rootDirectory.appending(path: "config.json")
        )
    }

    /// 把持久化的「组名 → 成员名」翻译成配置里的出站 tag；解析不到的丢弃。
    private func resolvedGroupDefaults() -> [String: String] {
        var defaults: [String: String] = [:]
        for (group, name) in groupSelections {
            if let tag = memberTag(name) { defaults[group] = tag }
        }
        return defaults
    }

    private func selectFirstNodeIfNeeded() {
        if !activeConfigNodes.contains(where: { $0.id == selectedNodeID }) {
            // 优先选真实节点，避免选中机场塞进来的套餐信息条目。
            selectedNodeID = (testableNodes.first ?? activeConfigNodes.first)?.id
        }
    }

    /// mixed 端口跨启动保持稳定（缓存了代理地址的客户端不会被换端口甩掉）；
    /// clash_api 端口与 secret 仍然每次随机——它们只在进程内使用，没有外部缓存问题，
    /// 而 secret 随机是真正的安全边界。
    nonisolated private static func makeRuntimeParameters(preferredMixedPort: UInt16?) async throws -> RuntimeParameters {
        let mixedPort = try await RuntimeSecrets.stableHighPort(preferred: preferredMixedPort)
        var clashPort = try RuntimeSecrets.availableHighPort()
        while clashPort == mixedPort {
            clashPort = try RuntimeSecrets.availableHighPort()
        }
        return RuntimeParameters(
            mixedPort: mixedPort,
            clashPort: clashPort,
            secret: try RuntimeSecrets.secret()
        )
    }

    nonisolated private static func waitUntilHealthy(_ client: ClashAPIClient) async throws {
        // 健康即返回，成功时几乎不耗时；上限给足，容忍首次建 TUN、大量出站时内核稍慢就绪，
        // 免得误判失败又回滚。最多 ~6 秒。
        var lastError: Error?
        for attempt in 0..<60 {
            do {
                try await client.health()
                return
            } catch {
                lastError = error
                if attempt < 59 { try await Task.sleep(for: .milliseconds(100)) }
            }
        }
        throw AppStateError.coreHealthFailed(lastError?.localizedDescription ?? "未知错误")
    }

    private func armCoreExitMonitoring(pid: Int32) async {
        await cancelCoreExitMonitoring()
        monitoredCorePID = pid
        do {
            try await processExitMonitor.monitor(pid: pid) { [weak self] exitedPID in
                Task { @MainActor [weak self] in
                    await self?.handleUnexpectedCoreExit(pid: exitedPID)
                }
            }
        } catch {
            if monitoredCorePID == pid { monitoredCorePID = nil }
            appendWarning("无法监控内核退出：\(error.localizedDescription)")
        }
    }

    private func armRunningSystemCoreIfAvailable() async {
        guard let pid = await singBoxProcess.currentPID else {
            appendWarning("无法监控内核退出：运行中的系统代理没有可用 PID")
            return
        }
        await armCoreExitMonitoring(pid: pid)
    }

    private func cancelCoreExitMonitoring() async {
        monitoredCorePID = nil
        await processExitMonitor.cancel()
    }

    private func handleUnexpectedCoreExit(pid: Int32) async {
        guard monitoredCorePID == pid,
              !isHandlingCoreCrash,
              status == .on,
              !activeModes.isEmpty,
              let config = currentConfig,
              let client = clashAPIClient else {
            return
        }

        isHandlingCoreCrash = true
        defer {
            isHandlingCoreCrash = false
            // 清掉中止信号，避免泄漏到下一次崩溃自愈。
            stopRequestedDuringCrashHandling = false
        }
        await cancelCoreExitMonitoring()
        suspendDashboardMonitoring()
        suspendLogMonitoring()

        let modes = activeModes
        guard crashRestartLimiter.allowsRestart(at: now()) else {
            await finishCoreCrash(
                modes: modes,
                message: "内核在 10 秒内连续崩溃，已达到最多 3 次自动重启限制"
            )
            return
        }

        appendWarning("检测到内核意外退出（PID \(pid)），正在自动重启")
        recordRuntimeEvent(level: .warning, title: "检测到内核意外退出", previousPID: pid)
        status = .starting
        errorMessage = nil
        do {
            let restartedPID: Int32
            if modes.contains(.tun) {
                try await recoverTUNIfNeeded()
                // 用户可能在此 await 期间点了 stop。
                if stopRequestedDuringCrashHandling { return }
                let record = try await startTUN(config: config)
                try await healthVerifier(client)
                restartedPID = record.pid
            } else {
                try await singBoxProcess.start(config: config)
                if stopRequestedDuringCrashHandling {
                    // 已起内核但用户要停：把刚起的内核停掉，让 stop() 的清理路径接手。
                    await singBoxProcess.stop()
                    return
                }
                try await healthVerifier(client)
                guard let pid = await singBoxProcess.currentPID else {
                    throw AppStateError.missingRuntimeState
                }
                restartedPID = pid
            }

            // 二次检查：start/healthVerify 期间用户可能点了 stop。
            if stopRequestedDuringCrashHandling {
                if modes.contains(.tun) {
                    try? await stopTUN()
                } else {
                    await singBoxProcess.stop()
                }
                return
            }

            activeModes = modes
            status = .on
            markRuntimeStarted()
            await armCoreExitMonitoring(pid: restartedPID)
            resumeDashboardMonitoringIfNeeded()
            resumeLogMonitoringIfNeeded()
            recordRuntimeEvent(title: "内核已自动恢复", previousPID: pid, currentPID: restartedPID)
        } catch {
            if stopRequestedDuringCrashHandling { return }
            await finishCoreCrash(
                modes: modes,
                message: "内核崩溃后自动重启失败：\(error.localizedDescription)"
            )
        }
    }

    private func finishCoreCrash(modes: Set<ProxyMode>, message: String) async {
        var cleanupMessages: [String] = []
        if modes.contains(.systemProxy) {
            do {
                try await systemProxyManager.restore()
            } catch {
                cleanupMessages.append("系统代理恢复失败：\(error.localizedDescription)")
            }
        }
        if modes.contains(.tun) {
            do {
                try await recoverTUNIfNeeded()
            } catch {
                cleanupMessages.append("TUN 清理失败：\(error.localizedDescription)")
            }
            do {
                try await systemDNSManager.restore()
            } catch {
                cleanupMessages.append("系统 DNS 恢复失败：\(error.localizedDescription)")
            }
        } else {
            if await singBoxProcess.currentPID != nil {
                await singBoxProcess.stop()
            }
        }
        let cleanupMessage = cleanupMessages.isEmpty ? nil : cleanupMessages.joined(separator: "；")

        clearRuntimeState()
        let failureMessage = [message, cleanupMessage].compactMap { $0 }.joined(separator: "；")
        setFailure(failureMessage)
        recordRuntimeEvent(level: .error, title: "内核自动恢复失败")
        do {
            try await notificationSender.send(
                title: "kongshan 内核已停止",
                body: failureMessage
            )
        } catch {
            appendWarning("通知未发送：\(error.localizedDescription)")
        }
    }

    // MARK: - 网络变化与睡眠唤醒

    /// macOS 的代理/DNS 设置按网络服务存储；新出现的服务（新 Wi-Fi、USB 共享、
    /// 雷雳网桥）不会继承设置，流量会静默直连。监听路径变化事件补挂，不轮询。
    private func startNetworkPathMonitoringIfNeeded() {
        guard monitorsSystemEvents, pathMonitor == nil, !activeModes.isEmpty else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleTakeoverReassert()
            }
        }
        monitor.start(queue: DispatchQueue(label: "kongshan.path-monitor"))
        pathMonitor = monitor
    }

    private func stopNetworkPathMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
        pathChangeTask?.cancel()
        pathChangeTask = nil
    }

    /// 路径事件在切网时会连发多条，压到一次、等网络稳定 2 秒再补挂。
    private func scheduleTakeoverReassert() {
        guard status == .on, !activeModes.isEmpty else { return }
        pathChangeTask?.cancel()
        pathChangeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.pathChangeTask = nil
            await self.reassertTakeoversAfterNetworkChange()
        }
    }

    /// 补挂系统代理/DNS。`resetConnections` 为 true 时无条件重置全部连接
    /// （睡眠唤醒场景：连接必然已死，但客户端不知道）。
    func reassertTakeoversAfterNetworkChange(resetConnections: Bool = false, identityChangedForTesting: Bool? = nil) async {
        guard status == .on, !isBusy else { return }
        let identityChanged = identityChangedForTesting ?? networkIdentityChanged()
        if identityChanged {
            recordRuntimeEvent(title: "物理网络已变更", detail: "正在刷新 LAN DNS 与 DoH 连接")
            if activeModes.contains(.tun) {
                lanResolverSnapshot = await lanResolverProbe(tunResolverExclusions(tunSettings))
                await applyTunSettings(tunSettings, operation: "网络变化")
            } else {
                await applyDNSSettings(dnsSettings, operation: "网络变化")
            }
            guard status == .on else { return }
        }
        if activeModes.contains(.systemProxy), let runtime {
            do {
                try await systemProxyManager.reassert(
                    port: Int(runtime.mixedPort),
                    bypassDomains: bypassEntries(for: routingSettings)
                )
            } catch {
                appendWarning("网络变化后补挂系统代理失败：\(error.localizedDescription)")
            }
        }
        if activeModes.contains(.tun) {
            do {
                try await systemDNSManager.reassert(server: tunSettings.dnsServerAddress)
            } catch {
                appendWarning("网络变化后补挂系统 DNS 失败：\(error.localizedDescription)")
            }
        }
        // 换网/唤醒后内核里的旧连接已经作废，但**本地客户端并不知道**：它们的 socket 仍是
        // ESTABLISHED，写进去石沉大海，要等 TCP 重传耗尽（可长达十几分钟）才报错；很多客户端
        // 还用长连接池反复复用这些死连接 → "网络明明恢复了，某个 App 却一直转圈，只能重启它"。
        // 主动关掉，客户端会立刻收到 RST 并重新拨号。
        //
        // **但绝不能见到路径事件就关**：`NWPathMonitor` 对 Wi-Fi 信号变化、IPv6 地址续租、
        // DNS 服务器更新这类无关抖动同样会回调，那样会在用户正常使用中途反复掐断长连接
        // （聊天流式响应、下载、SSH 全部遭殃）。只在**网络身份真的变了**时才重置。
        // 指纹**无条件**更新：写成 `resetConnections || networkIdentityChanged()` 会短路，
        // 唤醒那次就不会刷新指纹，下一次路径事件拿睡前的旧指纹比对，又白白多重置一次。
        if resetConnections || identityChanged, let clashAPIClient {
            try? await clashAPIClient.closeAllConnections()
        }
    }

    /// 物理网络身份是否变化：取 `en*` 接口的 IPv4 集合做指纹。
    /// 换 Wi-Fi、插拔网线、切热点都会变；信号强弱、IPv6 续租不会变。
    private func networkIdentityChanged() -> Bool {
        let signature = Self.physicalNetworkSignature()
        // 取不到（getifaddrs 偶发失败）时既不判定变化、也不覆盖上一次的有效指纹——
        // 否则一次瞬时失败会先误判成"换网"重置一次，恢复后再误判一次。
        guard !signature.isEmpty else { return false }
        defer { lastNetworkSignature = signature }
        guard let previous = lastNetworkSignature else { return false }  // 首次记录不算变化
        return previous != signature
    }

    nonisolated private static func physicalNetworkSignature() -> String {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return "" }
        defer { freeifaddrs(head) }
        var entries: [String] = []
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let name = String(cString: current.pointee.ifa_name)
            // **只认 en*（Wi-Fi / 以太网 / USB 网卡 / 网络共享）**。
            // 用"排除法"不够：`awdl0`、`llw0`（AirDrop、隔空播放）会频繁上下线，
            // `bridge0`（雷雳网桥）、`utun*`（隧道，含我们自己的）也会随代理启停变化，
            // 任何一个进了指纹都会被误判成"换网了"，白白掐断正在进行的长连接。
            guard name.hasPrefix("en") else { continue }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard getnameinfo(
                address, socklen_t(address.pointee.sa_len),
                &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            let end = buffer.firstIndex(of: 0) ?? buffer.count
            let text = String(decoding: buffer[0..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            entries.append("\(name)=\(text)")
        }
        return entries.sorted().joined(separator: ",")
    }

    /// 睡眠唤醒后：网络多半已变、核心可能假死（进程还在但拒绝连接）。
    /// 稳定 3 秒后做一次健康检查并补挂接管；真正的进程退出由退出监控兜底。
    private func handleDidWake() {
        guard status == .on else { return }
        recordRuntimeEvent(title: "系统已唤醒", detail: "正在检查内核与接管")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            await self?.verifyCoreAfterWake()
        }
    }

    private func verifyCoreAfterWake() async {
        guard status == .on, let clashAPIClient else { return }
        do {
            try await clashAPIClient.health()
        } catch {
            let message = "睡眠唤醒后内核控制接口无响应：\(error.localizedDescription)。若持续异常，请关闭再开启接管。"
            if warnings.last != message { appendWarning(message) }
        }
        // 控制接口健康 ≠ 隧道还在。macOS 睡眠会拆掉 utun 设备，内核进程仍活着、
        // Clash API 照常应答，但 TUN 网卡已经消失——用户看到的是"显示已开启却完全没网"。
        // 这里按"TUN 地址是否还挂在某块网卡上"直接判定，没了就当内核已死，走崩溃自愈重建隧道。
        if activeModes.contains(.tun), !Self.tunInterfaceIsUp(address: tunSettings.dnsServerAddress) {
            appendWarning("睡眠唤醒后 TUN 网卡已消失，正在重建隧道")
            await handleTunnelLostAfterWake()
            return
        }
        // 睡眠期间所有连接都已经死了，只是客户端不知道 → 无条件重置。
        await reassertTakeoversAfterNetworkChange(resetConnections: true)
    }

    /// 某块网卡上是否还挂着给定的 IPv4 地址（即 TUN 是否仍然存在）。
    nonisolated private static func tunInterfaceIsUp(address: String) -> Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return false }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let sockaddrPointer = current.pointee.ifa_addr,
                  sockaddrPointer.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard getnameinfo(
                sockaddrPointer,
                socklen_t(sockaddrPointer.pointee.sa_len),
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            let end = buffer.firstIndex(of: 0) ?? buffer.count
            let text = String(decoding: buffer[0..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if text == address { return true }
        }
        return false
    }

    /// 唤醒后隧道没了：内核进程可能还活着但已经不工作。复用崩溃自愈路径重建，
    /// 它会先 recoverTUNIfNeeded 停掉残留内核（信号会升级到 SIGKILL），再用同一份配置重起。
    private func handleTunnelLostAfterWake() async {
        guard let pid = monitoredCorePID else { return }
        await handleUnexpectedCoreExit(pid: pid)
    }

    private func setFailure(_ message: String) {
        status = .failed(message)
        errorMessage = message
    }

    private func clearRuntimeState() {
        stopNetworkPathMonitoring()
        monitoredCorePID = nil
        clearDashboardRuntime()
        suspendLogMonitoring()
        runtime = nil
        clashAPIClient = nil
        currentConfig = nil
        mixedPort = nil
        activeModes = []
    }

    private var subscriptionsURL: URL {
        storage.rootDirectory.appending(path: "subscriptions.json")
    }

    private var manualNodesURL: URL {
        storage.rootDirectory.appending(path: "manual-nodes.json")
    }

    private var settingsURL: URL {
        storage.rootDirectory.appending(path: "settings.json")
    }

    private var rulesURL: URL {
        storage.rootDirectory.appending(path: "rules.json")
    }

    private var runtimeEventsURL: URL {
        storage.rootDirectory.appending(path: "runtime-events.json")
    }

    // MARK: - 特权助手（零弹窗 TUN）

    private func helperIsHealthy() async -> Bool {
        (await helperClient.status())?.ok == true
    }

    /// 轮询等待助手就绪。bootstrap 之后 helper 建 socket 有几十到几百毫秒的空档，
    /// 慢机器上更久；固定 sleep 会误判。返回是否在超时前就绪。
    private func waitForHelperHealthy(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await helperIsHealthy() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private func startTUN(config: Data) async throws -> PrivilegedProcessRecord {
        let backend: TUNBackend
        if let activeTUNBackend {
            backend = activeTUNBackend
        } else {
            backend = await helperIsHealthy() ? .helper : .fallback
        }
        let record: PrivilegedProcessRecord
        switch backend {
        case .helper:
            // 助手可能还握着上一次遗留的内核：App 崩溃后残留、助手重启时认领回来的、
            // 或旧版本留下的僵尸内核。不先清掉的话这次会被助手以 "kernel already running"
            // 顶回来，用户在界面上就是个死胡同——只能去终端 sudo 杀进程。
            // recoverIfNeeded 没有残留时是一次 status 往返的空操作，代价可以忽略。
            try? await helperClient.recoverIfNeeded()
            record = try await helperClient.start(config: config)
        case .fallback:
            record = try await privilegedLauncher.start(config: config)
        }
        activeTUNBackend = backend
        return record
    }

    private func stopTUN() async throws {
        let backend: TUNBackend
        if let activeTUNBackend {
            backend = activeTUNBackend
        } else {
            backend = await helperIsHealthy() ? .helper : .fallback
        }
        switch backend {
        case .helper:
            try await helperClient.stop()
        case .fallback:
            try await privilegedLauncher.stop()
        }
        activeTUNBackend = nil
    }

    private func recoverTUNIfNeeded() async throws {
        if let backend = activeTUNBackend {
            switch backend {
            case .helper:
                try await helperClient.recoverIfNeeded()
            case .fallback:
                try await privilegedLauncher.recoverIfNeeded()
            }
            activeTUNBackend = nil
            return
        }

        var failures: [String] = []
        if let status = await helperClient.status(), status.ok, status.kernelPID != nil {
            do {
                try await helperClient.stop()
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        do {
            try await privilegedLauncher.recoverIfNeeded()
        } catch {
            failures.append(error.localizedDescription)
        }
        guard failures.isEmpty else {
            throw AppStateError.tunCleanupFailed(failures.joined(separator: "；"))
        }
    }

    /// 刷新助手安装状态（启动时、安装/卸载后、进入设置页时调用）。
    func refreshHelperInstallStatus() async {
        helperInstallStatus = PrivilegedHelperInstaller.currentStatus(
            isReachable: await helperIsHealthy()
        )
    }

    /// 安装免密码助手（一条 osascript 提权）。开 TUN 时若助手未装会自动触发（首次弹一次密码，
    /// 后续零弹窗）；也可由用户在设置页手动触发。
    func installHelper() async {
        guard !isHelperOperationInProgress else { return }
        isHelperOperationInProgress = true
        defer { isHelperOperationInProgress = false }
        do {
            try await PrivilegedHelperInstaller.install(authorizer: { script, timeout in
                try await OSAScriptAuthorizer.run(script: script, timeout: timeout)
            })
            // launchctl bootstrap 之后 helper 才开始建 socket，快慢取决于机器负载。
            // 只等固定 500ms 会在慢机器上误判成"装了但没生效"，让用户反复重装。
            // 改成最多轮询 5 秒，healthy 即返回。
            if await waitForHelperHealthy(timeout: 5) {
                helperInstallStatus = .installed
            } else {
                await refreshHelperInstallStatus()
                appendWarning(
                    "助手已安装但自检未通过。请确认 kongshan.app 位于 /应用程序 下；"
                        + "若刚更新过 App，请再点一次「重新安装」（App 签名变化后助手需要重新授权）"
                )
            }
        } catch let error as PrivilegedLauncherError {
            appendWarning("安装助手失败：\(error.localizedDescription)")
        } catch {
            appendWarning("安装助手失败：\(error.localizedDescription)")
        }
    }

    /// 卸载免密码助手（一条 osascript 提权）。
    ///
    /// 卸载会 bootout helper 并删掉 socket 与整个 state 目录——内核不先停就成了 App 再也
    /// 停不掉的残留 root 进程。UI 已在 TUN 运行时禁用本按钮，这里再兜一层：先让 helper
    /// 停掉它起的内核（不可达时由卸载脚本里的 pkill 兜底）。
    func uninstallHelper() async {
        guard !isHelperOperationInProgress else { return }
        isHelperOperationInProgress = true
        defer { isHelperOperationInProgress = false }
        try? await helperClient.recoverIfNeeded()
        do {
            try await PrivilegedHelperInstaller.uninstall(authorizer: { script, timeout in
                try await OSAScriptAuthorizer.run(script: script, timeout: timeout)
            })
            await refreshHelperInstallStatus()
        } catch let error as PrivilegedLauncherError {
            appendWarning("卸载助手失败：\(error.localizedDescription)")
        } catch {
            appendWarning("卸载助手失败：\(error.localizedDescription)")
        }
    }

    private static func singBoxBinaryURL() -> URL {
        if let bundled = Bundle.main.url(forResource: "sing-box", withExtension: nil) {
            return bundled
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "Vendor/sing-box/sing-box")
    }

    /// 物理网络是否有全局（非链路本地）IPv6 地址。
    /// 排除 utun/lo/bridge/gif/stf 等虚拟/隧道接口——只看真实网卡（en/eth/pdp/ipsec）。
    /// 用于决定 TUN 是否配 IPv6 地址：物理网络无 IPv6 时给 TUN 配 IPv6 会让应用
    /// 尝试 IPv6 直连然后失败（"no route to host"），所以这种情况要剥掉 TUN 的 IPv6。
    nonisolated private static func physicalNetworkHasGlobalIPv6() -> Bool {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return false }
        defer { freeifaddrs(ifaddr) }
        var cursor = first
        while true {
            let name = String(cString: cursor.pointee.ifa_name)
            let addr = cursor.pointee.ifa_addr
            // 虚拟/隧道接口不算物理网络——utun 是其它 VPN，lo 是回环，bridge/gif/stf 是隧道。
            let isPhysical = !name.hasPrefix("utun")
                && !name.hasPrefix("lo")
                && !name.hasPrefix("bridge")
                && !name.hasPrefix("gif")
                && !name.hasPrefix("stf")
                && !name.hasPrefix("llw")
                && !name.hasPrefix("awdl")
            if isPhysical, let addr, addr.pointee.sa_family == sa_family_t(AF_INET6) {
                let inet6 = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                // 链路本地 fe80::/10 不算全局 IPv6——没有它物理网络仍不可达 IPv6 目标。
                let bytes = inet6.sin6_addr.__u6_addr.__u6_addr8
                if Self.isGloballyRoutableIPv6(bytes.0, bytes.1) { return true }
            }
            guard let next = cursor.pointee.ifa_next else { break }
            cursor = next
        }
        return false
    }

    /// 这个 IPv6 地址是否**可全球路由**。只看前两个字节就够判定。
    ///
    /// 真机事故（2026-07-30）：用户开 TUN 后微信发不出图片。内核日志里全是
    /// `dial tcp [240e:...]:80: connect: no route to host`——微信的 CDN 有 AAAA 记录，
    /// 应用因此优先走 IPv6，而物理链路根本到不了全局 IPv6。
    ///
    /// 本该由 `stripIPv6()` 兜住（物理网络没 IPv6 就不给 TUN 配 IPv6，应用自然回落 IPv4），
    /// 但判定只排除了链路本地 `fe80::/10`，**把 ULA `fc00::/7` 当成了全局地址**。
    /// ULA 是 IPv6 版的 `192.168.x.x`：路由器普遍下发（用户机器上是 `fd7e:...`），
    /// 但不可全球路由。于是判定为"有 IPv6"→ TUN 配上 IPv6 → 应用尝试 IPv6 → 全数失败。
    ///
    /// `internal` 而非 `private`：这段判定值得被单测钉住，真机复现一次代价太大。
    nonisolated static func isGloballyRoutableIPv6(_ byte0: UInt8, _ byte1: UInt8) -> Bool {
        // fe80::/10 链路本地：只在本网段有意义。
        if byte0 == 0xfe && (byte1 & 0xc0) == 0x80 { return false }
        // fc00::/7 唯一本地地址（ULA）：私有段，不可全球路由。
        if (byte0 & 0xfe) == 0xfc { return false }
        // fec0::/10 站点本地：已废弃，出现了也不该当全局。
        if byte0 == 0xfe && (byte1 & 0xc0) == 0xc0 { return false }
        return true
    }
}

private struct PersistedSettings: Codable {
    let selectedNodeID: UUID?
    let testURL: String
    let preferredMode: ProxyMode?
    let tunSettings: TunSettings?
    let dnsSettings: DNSSettings?
    let subscriptionUpdateSettings: SubscriptionUpdateSettings?
    let ruleSetSettings: RuleSetSettings?
    let outboundMode: OutboundMode?
    /// 各策略组当前选中的成员（组名 → 成员名），旧版设置文件没有该字段。
    let groupSelections: [String: String]?
    /// 当前生效配置 ID 与测速方式，旧版设置文件没有这些字段。
    var activeConfigID: UUID?
    var speedTestMethod: SpeedTestMethod?
    /// 菜单栏图标样式。旧版设置文件没有该字段。
    var menuBarIconStyle: MenuBarIconStyle?
    /// 上次用过的本地 mixed 端口。旧版设置文件没有该字段（nil = 首次分配）。
    /// 属于本机运行时状态，**不进备份**：换台机器该端口未必空闲。
    var mixedPort: UInt16?
}

private struct FileSnapshot {
    let url: URL
    let data: Data?
}

private enum AppStateError: Error, LocalizedError {
    case coreCheckFailed(String)
    case coreHealthFailed(String)
    case invalidTestURL
    case missingRuntimeState
    case tunCleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case let .coreCheckFailed(message):
            "sing-box 配置校验失败：\(message)"
        case let .coreHealthFailed(message):
            "sing-box 控制接口未就绪：\(message)"
        case .invalidTestURL:
            "测速地址必须是 HTTP 或 HTTPS URL"
        case .missingRuntimeState:
            "运行时状态不完整，无法更新分流规则"
        case let .tunCleanupFailed(message):
            "清理旧 TUN 失败：\(message)"
        }
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
