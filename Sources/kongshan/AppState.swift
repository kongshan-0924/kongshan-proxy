import Foundation
import KongshanCore
import Observation

@MainActor
@Observable
final class AppState {
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

    @ObservationIgnored private let storage: Storage
    @ObservationIgnored private let subscriptionService: SubscriptionService
    @ObservationIgnored private let systemProxyManager: SystemProxyManager
    @ObservationIgnored private let singBoxProcess: SingBoxProcess
    @ObservationIgnored private var clashAPIClient: ClashAPIClient?
    @ObservationIgnored private var runtime: RuntimeParameters?

    init(
        storage: Storage = Storage(),
        subscriptionService: SubscriptionService? = nil,
        systemProxyManager: SystemProxyManager? = nil,
        singBoxProcess: SingBoxProcess? = nil,
        automaticallyInitialize: Bool = true
    ) {
        self.storage = storage
        self.subscriptionService = subscriptionService ?? SubscriptionService(storage: storage)
        self.systemProxyManager = systemProxyManager ?? SystemProxyManager(storage: storage)
        self.singBoxProcess = singBoxProcess ?? SingBoxProcess(binaryURL: Self.singBoxBinaryURL())

        if automaticallyInitialize {
            Task { await initialize() }
        }
    }

    var isBusy: Bool {
        status == .starting || status == .stopping
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
            try await systemProxyManager.recoverIfNeeded()
            try await storage.prepare()
            try await loadPersistedState()
            isReady = true
        } catch {
            setFailure("启动恢复失败：\(error.localizedDescription)")
        }
    }

    func startSystemProxy() async {
        guard !isBusy, status != .on else { return }
        guard !nodes.isEmpty else {
            setFailure("至少需要一个代理节点")
            return
        }

        status = .starting
        errorMessage = nil
        do {
            let runtime = try makeRuntimeParameters()
            let config = try ConfigGenerator.generate(ConfigInput(
                nodes: nodes,
                selectedNodeID: selectedNodeID,
                runtime: runtime,
                testURL: testURLString
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
            try await singBoxProcess.start(config: config)

            let client = ClashAPIClient(
                controller: URL(string: "http://127.0.0.1:\(runtime.clashPort)")!,
                secret: runtime.secret
            )
            try await waitUntilHealthy(client)
            try await systemProxyManager.enable(port: Int(runtime.mixedPort))

            self.runtime = runtime
            clashAPIClient = client
            mixedPort = runtime.mixedPort
            status = .on
        } catch {
            try? await systemProxyManager.restore()
            await singBoxProcess.stop()
            runtime = nil
            clashAPIClient = nil
            mixedPort = nil
            setFailure(error.localizedDescription)
        }
    }

    func stop() async {
        guard !isBusy, status != .off else { return }
        status = .stopping
        errorMessage = nil
        do {
            try await systemProxyManager.restore()
        } catch {
            setFailure("恢复系统代理失败：\(error.localizedDescription)")
            return
        }

        await singBoxProcess.stop()
        runtime = nil
        clashAPIClient = nil
        mixedPort = nil
        status = .off
    }

    func prepareForTermination() async -> Bool {
        if status != .off {
            await stop()
            return status == .off
        } else {
            do {
                try await systemProxyManager.recoverIfNeeded()
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

    func dismissError() {
        errorMessage = nil
        if case .failed = status { status = .off }
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
                testURL: testURLString
            )),
            to: settingsURL
        )
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

    private func makeRuntimeParameters() throws -> RuntimeParameters {
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

    private func waitUntilHealthy(_ client: ClashAPIClient) async throws {
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

    private var subscriptionsURL: URL {
        storage.rootDirectory.appending(path: "subscriptions.json")
    }

    private var manualNodesURL: URL {
        storage.rootDirectory.appending(path: "manual-nodes.json")
    }

    private var settingsURL: URL {
        storage.rootDirectory.appending(path: "settings.json")
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
}

private enum AppStateError: Error, LocalizedError {
    case coreCheckFailed(String)
    case coreHealthFailed(String)
    case invalidTestURL

    var errorDescription: String? {
        switch self {
        case let .coreCheckFailed(message):
            "sing-box 配置校验失败：\(message)"
        case let .coreHealthFailed(message):
            "sing-box 控制接口未就绪：\(message)"
        case .invalidTestURL:
            "测速地址必须是 HTTP 或 HTTPS URL"
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
