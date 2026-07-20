import Foundation
import KongshanCore
import Observation

@MainActor
@Observable
final class AppState {
    typealias RuntimeFactory = @Sendable () throws -> RuntimeParameters
    typealias HealthVerifier = @Sendable (ClashAPIClient) async throws -> Void

    enum Status: Equatable {
        case off
        case starting
        case on
        case stopping
        case failed(String)
    }

    var status: Status = .off
    var nodes: [ProxyNode] = []
    var subscriptions: [SubscriptionSource] = []
    var selectedNodeID: UUID?
    var delays: [UUID: Int?] = [:]
    var mixedPort: UInt16?
    var testURLString = "http://www.gstatic.com/generate_204"
    var errorMessage: String?
    var warnings: [String] = []
    var isReady = false
    var routingSettings = RoutingSettings.defaults
    var preferredMode: ProxyMode = .systemProxy
    private(set) var activeMode: ProxyMode?
    var tunSettings: TunSettings = .defaults
    private(set) var isApplyingRouting = false

    @ObservationIgnored private let storage: Storage
    @ObservationIgnored private let subscriptionService: SubscriptionService
    @ObservationIgnored private let ruleSetService: RuleSetService
    @ObservationIgnored private let systemProxyManager: SystemProxyManager
    @ObservationIgnored private let singBoxProcess: SingBoxProcess
    @ObservationIgnored private let privilegedLauncher: any PrivilegedLaunching
    @ObservationIgnored private let runtimeFactory: RuntimeFactory
    @ObservationIgnored private let healthVerifier: HealthVerifier
    @ObservationIgnored private var clashAPIClient: ClashAPIClient?
    @ObservationIgnored private var runtime: RuntimeParameters?
    @ObservationIgnored private var currentConfig: Data?

    init(
        storage: Storage = Storage(),
        subscriptionService: SubscriptionService? = nil,
        ruleSetService: RuleSetService? = nil,
        systemProxyManager: SystemProxyManager? = nil,
        singBoxProcess: SingBoxProcess? = nil,
        privilegedLauncher: (any PrivilegedLaunching)? = nil,
        runtimeFactory: RuntimeFactory? = nil,
        healthVerifier: HealthVerifier? = nil,
        automaticallyInitialize: Bool = true
    ) {
        let binaryURL = Self.singBoxBinaryURL()
        self.storage = storage
        self.subscriptionService = subscriptionService ?? SubscriptionService(storage: storage)
        self.ruleSetService = ruleSetService ?? RuleSetService(storage: storage, binaryURL: binaryURL)
        self.systemProxyManager = systemProxyManager ?? SystemProxyManager(storage: storage)
        self.singBoxProcess = singBoxProcess ?? SingBoxProcess(binaryURL: binaryURL)
        self.privilegedLauncher = privilegedLauncher ?? PrivilegedLauncher(
            storage: storage,
            binaryURL: binaryURL
        )
        self.runtimeFactory = runtimeFactory ?? Self.makeRuntimeParameters
        self.healthVerifier = healthVerifier ?? Self.waitUntilHealthy

        if automaticallyInitialize {
            Task { await initialize() }
        }
    }

    var isBusy: Bool {
        status == .starting || status == .stopping || isApplyingRouting
    }

    var isOn: Bool {
        status == .on
    }

    var selectedNode: ProxyNode? {
        nodes.first { $0.id == selectedNodeID }
    }

    var menuBarSymbol: String {
        switch status {
        case .off, .failed:
            "shield.slash"
        case .starting, .stopping:
            "shield.lefthalf.filled"
        case .on:
            "shield.fill"
        }
    }

    var statusText: String {
        switch status {
        case .off: "已关闭"
        case .starting: "正在启动系统代理…"
        case .on: "系统代理已开启"
        case .stopping: "正在关闭…"
        case let .failed(message): "失败：\(message)"
        }
    }

    func initialize() async {
        guard !isReady else { return }
        do {
            try await privilegedLauncher.recoverIfNeeded()
            try await systemProxyManager.recoverIfNeeded()
            try await storage.prepare()
            try await loadPersistedState()
            isReady = true
        } catch {
            setFailure("启动恢复失败：\(error.localizedDescription)")
        }
    }

    func startSystemProxy() async {
        await startPreferredProxy()
    }

    func startPreferredProxy() async {
        guard !isBusy, status != .on, activeMode == nil else { return }
        guard !nodes.isEmpty else {
            setFailure("至少需要一个代理节点")
            return
        }

        status = .starting
        errorMessage = nil
        let requestedMode = preferredMode
        var tunStarted = false
        do {
            let prepared = try await ruleSetService.prepare(includeAds: routingSettings.blockAds)
            warnings.append(contentsOf: prepared.warnings)
            let runtime = try runtimeFactory()
            let config = try ConfigGenerator.generate(ConfigInput(
                nodes: nodes,
                selectedNodeID: selectedNodeID,
                runtime: runtime,
                testURL: testURLString,
                routing: RoutingConfiguration(settings: routingSettings, ruleSets: prepared.ruleSets),
                proxyMode: requestedMode,
                tunSettings: tunSettings
            ))
            let diagnostic = try ConfigGenerator.diagnosticSnapshot(from: config)
            try await storage.writeAtomically(
                diagnostic,
                to: storage.rootDirectory.appending(path: "config.json")
            )

            let check = try await singBoxProcess.check(config: config)
            guard check.exitCode == 0 else {
                throw AppStateError.coreCheckFailed(check.stderr)
            }
            let client = ClashAPIClient(
                controller: URL(string: "http://127.0.0.1:\(runtime.clashPort)")!,
                secret: runtime.secret
            )
            switch requestedMode {
            case .systemProxy:
                try await singBoxProcess.start(config: config)
                try await healthVerifier(client)
                try await systemProxyManager.enable(
                    port: Int(runtime.mixedPort),
                    bypassDomains: routingSettings.systemProxyBypassEntries
                )
            case .tun:
                _ = try await privilegedLauncher.start(config: config)
                tunStarted = true
                try await healthVerifier(client)
            }

            self.runtime = runtime
            clashAPIClient = client
            currentConfig = config
            mixedPort = requestedMode == .systemProxy ? runtime.mixedPort : nil
            activeMode = requestedMode
            status = .on
        } catch {
            switch requestedMode {
            case .systemProxy:
                try? await systemProxyManager.restore()
                await singBoxProcess.stop()
            case .tun:
                if tunStarted {
                    do {
                        try await privilegedLauncher.stop()
                    } catch let stopError {
                        activeMode = .tun
                        currentConfig = nil
                        mixedPort = nil
                        setFailure(
                            "TUN 启动失败且无法停止：\(error.localizedDescription)；\(stopError.localizedDescription)"
                        )
                        return
                    }
                }
            }
            clearRuntimeState()
            setFailure(error.localizedDescription)
        }
    }

    func stop() async {
        guard !isBusy, status != .off else { return }
        guard let activeMode else {
            clearRuntimeState()
            status = .off
            return
        }
        status = .stopping
        errorMessage = nil
        switch activeMode {
        case .systemProxy:
            do {
                try await systemProxyManager.restore()
            } catch {
                setFailure("恢复系统代理失败：\(error.localizedDescription)")
                return
            }
            await singBoxProcess.stop()
        case .tun:
            do {
                try await privilegedLauncher.stop()
            } catch {
                setFailure("停止 TUN 失败：\(error.localizedDescription)")
                return
            }
        }
        clearRuntimeState()
        status = .off
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

        let shouldRestart = status == .on && activeMode != nil
        if activeMode != nil {
            await stop()
            guard status == .off, activeMode == nil else { return }
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
        if activeMode != nil {
            await stop()
            return status == .off
        } else {
            do {
                try await privilegedLauncher.recoverIfNeeded()
                try await systemProxyManager.recoverIfNeeded()
                clearRuntimeState()
                status = .off
                return true
            } catch {
                setFailure("退出前恢复系统代理失败：\(error.localizedDescription)")
                return false
            }
        }
    }

    func importSubscription(url: URL) async {
        guard !isBusy else { return }
        let source = SubscriptionSource(
            name: url.host ?? "订阅 \(subscriptions.count + 1)",
            url: url
        )
        do {
            let result = try await subscriptionService.refresh(source)
            var savedSource = source
            savedSource.lastUpdatedAt = Date()
            subscriptions.append(savedSource)
            replaceNodes(result.nodes, for: source.id)
            warnings = result.warnings
            selectFirstNodeIfNeeded()
            try await persistSubscriptions()
            try await persistSettings()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshSubscriptions() async {
        guard !isBusy else { return }
        var collectedWarnings: [String] = []
        for index in subscriptions.indices {
            let source = subscriptions[index]
            do {
                let result = try await subscriptionService.refresh(source)
                subscriptions[index].lastUpdatedAt = Date()
                replaceNodes(result.nodes, for: source.id)
                collectedWarnings.append(contentsOf: result.warnings)
            } catch {
                collectedWarnings.append("订阅 \(source.name) 更新失败：\(error.localizedDescription)")
            }
        }
        warnings = collectedWarnings
        selectFirstNodeIfNeeded()
        try? await persistSubscriptions()
        try? await persistSettings()
    }

    func addManual(_ form: ManualHysteria2) async {
        do {
            nodes.append(try form.makeNode())
            selectFirstNodeIfNeeded()
            try await persistManualNodes()
            try await persistSettings()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func select(_ node: ProxyNode) async {
        guard nodes.contains(where: { $0.id == node.id }) else { return }
        if let clashAPIClient, status == .on {
            do {
                try await clashAPIClient.select(node: ConfigGenerator.outboundTag(for: node))
            } catch {
                errorMessage = "切换节点失败：\(error.localizedDescription)"
                return
            }
        }
        selectedNodeID = node.id
        try? await persistSettings()
    }

    func testDelay(_ node: ProxyNode) async {
        guard let clashAPIClient, let testURL = URL(string: testURLString), status == .on else {
            errorMessage = "请先开启系统代理"
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

    func testAllDelays() async {
        guard let clashAPIClient, let testURL = URL(string: testURLString), status == .on else {
            errorMessage = "请先开启系统代理"
            return
        }
        let tags = nodes.map(ConfigGenerator.outboundTag)
        let results = await clashAPIClient.delays(nodes: tags, testURL: testURL)
        for node in nodes {
            switch results[ConfigGenerator.outboundTag(for: node)] {
            case let .success(value):
                delays[node.id] = value
            case .failure:
                delays.updateValue(nil, forKey: node.id)
            case nil:
                break
            }
        }
    }

    func saveSettings() async {
        do {
            guard let url = URL(string: testURLString), ["http", "https"].contains(url.scheme) else {
                throw AppStateError.invalidTestURL
            }
            try await persistSettings()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyRoutingSettings(_ requestedSettings: RoutingSettings) async {
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
            guard let runtime, let oldConfig = currentConfig, let client = clashAPIClient else {
                throw AppStateError.missingRuntimeState
            }

            let oldSettings = routingSettings
            let prepared = try await ruleSetService.prepare(includeAds: settings.blockAds)
            warnings.append(contentsOf: prepared.warnings)
            let newConfig = try ConfigGenerator.generate(ConfigInput(
                nodes: nodes,
                selectedNodeID: selectedNodeID,
                runtime: runtime,
                testURL: testURLString,
                routing: RoutingConfiguration(settings: settings, ruleSets: prepared.ruleSets)
            ))
            let check = try await singBoxProcess.check(config: newConfig)
            guard check.exitCode == 0 else {
                throw AppStateError.coreCheckFailed(check.stderr)
            }

            do {
                try await singBoxProcess.restart(config: newConfig)
                try await healthVerifier(client)
            } catch {
                await restoreOldRouting(
                    config: oldConfig,
                    settings: oldSettings,
                    client: client,
                    updateError: error
                )
                return
            }

            do {
                try await systemProxyManager.updateBypassDomains(
                    to: settings.systemProxyBypassEntries,
                    rollbackTo: oldSettings.systemProxyBypassEntries
                )
            } catch {
                await restoreOldRouting(
                    config: oldConfig,
                    settings: oldSettings,
                    client: client,
                    updateError: error
                )
                return
            }

            routingSettings = settings
            currentConfig = newConfig
            try await persistRoutingSettings()
            try await storage.writeAtomically(
                ConfigGenerator.diagnosticSnapshot(from: newConfig),
                to: storage.rootDirectory.appending(path: "config.json")
            )
            errorMessage = nil
        } catch {
            errorMessage = "应用分流规则失败：\(error.localizedDescription)"
        }
    }

    func dismissError() {
        errorMessage = nil
        if case .failed = status, activeMode == nil { status = .off }
    }

    func nodes(for source: SubscriptionSource) -> [ProxyNode] {
        nodes.filter { $0.sourceID == source.id }
    }

    var manualNodes: [ProxyNode] {
        nodes.filter { $0.sourceID == nil }
    }

    private func loadPersistedState() async throws {
        if let data = try await storage.readIfPresent(from: subscriptionsURL) {
            subscriptions = try JSONDecoder().decode([SubscriptionSource].self, from: data)
        }
        if let data = try await storage.readIfPresent(from: manualNodesURL) {
            nodes = try JSONDecoder().decode([ProxyNode].self, from: data)
        }
        for source in subscriptions {
            guard let data = try await storage.readIfPresent(from: storage.cacheURL(for: source)),
                  let yaml = String(data: data, encoding: .utf8),
                  let result = try? ClashSubscriptionConverter.convert(yaml: yaml, sourceID: source.id) else {
                continue
            }
            nodes.append(contentsOf: result.nodes)
            warnings.append(contentsOf: result.warnings)
        }
        if let data = try await storage.readIfPresent(from: settingsURL) {
            let settings = try JSONDecoder().decode(PersistedSettings.self, from: data)
            selectedNodeID = settings.selectedNodeID
            testURLString = settings.testURL
            preferredMode = settings.preferredMode ?? .systemProxy
            tunSettings = settings.tunSettings ?? .defaults
        }
        if let data = try await storage.readIfPresent(from: rulesURL) {
            routingSettings = try JSONDecoder().decode(RoutingSettings.self, from: data).validated()
        }
        selectFirstNodeIfNeeded()
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
                tunSettings: tunSettings
            )),
            to: settingsURL
        )
    }

    private func persistRoutingSettings() async throws {
        try await storage.writeAtomically(
            try JSONEncoder.sorted.encode(routingSettings),
            to: rulesURL
        )
    }

    private func restoreOldRouting(
        config: Data,
        settings: RoutingSettings,
        client: ClashAPIClient,
        updateError: Error
    ) async {
        do {
            try await singBoxProcess.restart(config: config)
            try await healthVerifier(client)
            currentConfig = config
            routingSettings = settings
            status = .on
            errorMessage = "应用分流规则失败，已恢复旧配置：\(updateError.localizedDescription)"
        } catch {
            await singBoxProcess.stop()
            let restoreMessage: String
            do {
                try await systemProxyManager.restore()
                restoreMessage = "系统代理已恢复"
            } catch let proxyError {
                restoreMessage = "系统代理恢复失败：\(proxyError.localizedDescription)"
            }
            clearRuntimeState()
            setFailure(
                "分流更新失败且旧配置无法恢复：\(updateError.localizedDescription)；\(error.localizedDescription)；\(restoreMessage)"
            )
        }
    }

    private func replaceNodes(_ newNodes: [ProxyNode], for sourceID: UUID) {
        nodes.removeAll { $0.sourceID == sourceID }
        nodes.append(contentsOf: newNodes)
    }

    private func selectFirstNodeIfNeeded() {
        if !nodes.contains(where: { $0.id == selectedNodeID }) {
            selectedNodeID = nodes.first?.id
        }
    }

    nonisolated private static func makeRuntimeParameters() throws -> RuntimeParameters {
        let mixedPort = try RuntimeSecrets.availableHighPort()
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
        var lastError: Error?
        for attempt in 0..<30 {
            do {
                try await client.health()
                return
            } catch {
                lastError = error
                if attempt < 29 { try await Task.sleep(for: .milliseconds(100)) }
            }
        }
        throw AppStateError.coreHealthFailed(lastError?.localizedDescription ?? "未知错误")
    }

    private func setFailure(_ message: String) {
        status = .failed(message)
        errorMessage = message
    }

    private func clearRuntimeState() {
        runtime = nil
        clashAPIClient = nil
        currentConfig = nil
        mixedPort = nil
        activeMode = nil
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

    private static func singBoxBinaryURL() -> URL {
        if let bundled = Bundle.main.url(forResource: "sing-box", withExtension: nil) {
            return bundled
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "Vendor/sing-box/sing-box")
    }
}

private struct PersistedSettings: Codable {
    let selectedNodeID: UUID?
    let testURL: String
    let preferredMode: ProxyMode?
    let tunSettings: TunSettings?
}

private enum AppStateError: Error, LocalizedError {
    case coreCheckFailed(String)
    case coreHealthFailed(String)
    case invalidTestURL
    case missingRuntimeState

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
