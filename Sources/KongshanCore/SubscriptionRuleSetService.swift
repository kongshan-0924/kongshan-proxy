import CryptoKit
import Foundation

/// 可写进内核配置的一份订阅规则集。
public struct PreparedSubscriptionRuleSet: Equatable, Sendable {
    /// `rule-providers` 里的名字，也就是订阅规则 `RULE-SET,<名字>,…` 引用的那个。
    public let name: String
    /// 路由规则引用的 tag 与二进制文件（含域名、IP、进程条件）。
    public let routeTag: String
    public let routeFile: URL
    /// DNS 规则引用的纯域名版本（没有域名条件时是空规则集）。只读缓存里的旧文件可能没有，为 nil。
    public let dnsTag: String?
    public let dnsFile: URL?
    /// sing-box 源码（JSON），供规则页命中测试在本地判定。
    public let sourceFile: URL
    public let entryCount: Int
    public let fetchedAt: Date
    /// 超过这个时间就该后台重下（`fetchedAt` + 刷新周期）。
    public let expiresAt: Date
    /// 还没下载到，暂用空规则集占位。占位与正式文件**同路径**：下载完成、原子替换后内核自动重载，
    /// 配置不用改、内核不用重启。
    public var isPlaceholder = false
}

public enum SubscriptionRuleSetError: Error, Equatable, LocalizedError {
    case invalidStatus(Int)
    case tooLarge(limit: Int)
    case insecureRedirect(String)
    case empty
    case compileFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidStatus(code): "服务器返回 HTTP \(code)"
        case let .tooLarge(limit): "超过 \(limit / 1_048_576) MB 上限"
        case let .insecureRedirect(target): "被重定向到明文 HTTP（\(target)）"
        case .empty: "没有可用条目"
        case let .compileFailed(reason): "内核编译失败：\(reason)"
        }
    }
}

/// 订阅规则集的下载、转换、编译与缓存。
///
/// **为什么要由 App 下载**：特权助手只允许 root 内核读被钉死用户的 App 支持目录里的**本地**
/// 规则集，远程规则集一律拒（`HelperConfigWhitelist`）。所以订阅 `rule-providers` 指向的远程文件
/// 必须先落到本地、按本地文件引用。
///
/// **生成配置永不联网、永不等待**：`prepareForConfiguration` 有缓存用缓存（哪怕已过期），
/// 没有就在正式路径放一份空规则集占位。缺的、过期的由 `refresh` 在后台下载，原子替换正式文件——
/// sing-box 会自动重载被原子替换的本地规则集文件（2026-09-18 实测 1.13.21：同一个 PID、
/// 不重启，占位→正式、正式→新版连续两次替换都在 3 秒内生效）。所以配置只取决于订阅本身，
/// 与下载进度无关：启动不卡网络，下载完成也不用重启内核、不掐断任何连接。
public actor SubscriptionRuleSetService {
    public typealias Downloader = @Sendable (URL, Int) async throws -> Data
    public typealias Compiler = @Sendable (URL, URL) async throws -> Void

    public struct Result: Sendable {
        public var prepared: [String: PreparedSubscriptionRuleSet] = [:]
        public var warnings: [String] = []
        /// 有缓存、但已超过刷新周期的规则集名。
        public var stale: [String] = []
        /// 本次实际重新下载并替换了文件的规则集名。
        public var updated: [String] = []
        /// 没有可用缓存的规则集名（生成配置时它们是占位，需要后台下载）。
        public var missing: [String] = []
    }

    /// 每份规则集旁边的元数据。
    struct Metadata: Codable, Equatable {
        let url: URL
        let fetchedAt: Date
        let entryCount: Int
        let hasDNS: Bool
        let skipped: [String: Int]
    }

    /// 刷新周期的下限与缺省值。订阅没写 interval 时按一天；写得过短也不低于一小时，免得反复打服务器。
    static let minimumRefreshInterval: TimeInterval = 3_600
    static let defaultRefreshInterval: TimeInterval = 86_400
    static let concurrentDownloads = 6

    private let storage: Storage
    private let downloader: Downloader
    private let compiler: Compiler

    public init(storage: Storage, downloader: @escaping Downloader, compiler: @escaping Compiler) {
        self.storage = storage
        self.downloader = downloader
        self.compiler = compiler
    }

    /// 生产用：URLSession 流式下载（带体积上限与降级重定向拦截）+ 内置内核编译。
    public init(storage: Storage, binaryURL: URL) {
        let config = URLSessionConfiguration.default
        // 与内置规则集一致：代理没开时直连机场服务器可能很慢，不能让生成配置卡在默认的 60 秒上。
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        // 刚唤醒、网络未就绪时等网络（受上面 60 秒封顶），不要立刻报「离线」。
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config)
        self.init(
            storage: storage,
            downloader: { url, limit in try await Self.download(url, byteLimit: limit, session: session) },
            compiler: Self.coreCompiler(binaryURL: binaryURL)
        )
    }

    // MARK: - 对外接口

    /// 只读缓存：给规则页显示条数、给命中测试读内容。不建目录、不写文件、不联网。
    public func cached(
        providers: [SubscriptionRuleProvider],
        sourceID: UUID,
        now: Date = Date()
    ) -> Result {
        scan(providers: providers, sourceID: sourceID, now: now).result
    }

    /// 生成配置用：每份规则集都给出可引用的本地文件——有缓存用缓存（哪怕已过期），
    /// 没有就在正式路径放空规则集占位。**不联网、不排队**，可与后台下载并行。
    public func prepareForConfiguration(
        providers: [SubscriptionRuleProvider],
        sourceID: UUID,
        now: Date = Date()
    ) async -> Result {
        var (result, accepted) = scan(providers: providers, sourceID: sourceID, now: now)
        let needsDNS = result.prepared.values.contains { $0.dnsFile == nil }
        guard !result.missing.isEmpty || needsDNS else { return result }
        guard let empty = await emptyRuleSet() else {
            result.warnings.append("无法生成占位规则集，未下载的 \(result.missing.count) 份规则集本次跳过")
            return result
        }
        let directory = directory(for: sourceID)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let missing = Set(result.missing)
        for provider in accepted {
            let files = Files(directory: directory, stem: Self.fileStem(for: provider.name))
            if missing.contains(provider.name) {
                Self.placeIfAbsent(empty, at: files.route)
                Self.placeIfAbsent(empty, at: files.dns)
                guard Self.exists(files.route), Self.exists(files.dns) else { continue }
                result.prepared[provider.name] = PreparedSubscriptionRuleSet(
                    name: provider.name,
                    routeTag: Self.routeTag(for: provider.name), routeFile: files.route,
                    dnsTag: Self.dnsTag(for: provider.name), dnsFile: files.dns,
                    sourceFile: files.source, entryCount: 0,
                    fetchedAt: .distantPast, expiresAt: .distantPast, isPlaceholder: true
                )
            } else if let prepared = result.prepared[provider.name], prepared.dnsFile == nil {
                // 旧缓存没有 DNS 版本：补一份空的，让配置里每份规则集的形态一致、与内容无关。
                Self.placeIfAbsent(empty, at: files.dns)
                guard Self.exists(files.dns) else { continue }
                result.prepared[provider.name] = PreparedSubscriptionRuleSet(
                    name: prepared.name, routeTag: prepared.routeTag, routeFile: prepared.routeFile,
                    dnsTag: Self.dnsTag(for: provider.name), dnsFile: files.dns,
                    sourceFile: prepared.sourceFile, entryCount: prepared.entryCount,
                    fetchedAt: prepared.fetchedAt, expiresAt: prepared.expiresAt
                )
            }
        }
        return result
    }

    /// 后台刷新。`force` 为真时全部重下，否则只重下过期或缺失的。
    /// 下载失败时保留旧缓存继续用——规则集只是分流依据，旧的也比没有强。
    public func refresh(
        providers: [SubscriptionRuleProvider],
        sourceID: UUID,
        force: Bool,
        now: Date = Date()
    ) async -> Result {
        await exclusively {
            await self.run(providers: providers, sourceID: sourceID, now: now) { cached, provider in
                guard let cached else { return .download }
                return force || Self.isStale(cached, provider: provider, now: now) ? .download : .useCache
            }
        }
    }

    /// 订阅被删除时清掉它的全部规则集。排在进行中的下载之后，免得删完又被写回来。
    public func removeCache(sourceID: UUID) async {
        await exclusively { await self.deleteDirectory(for: sourceID) }
    }

    /// 启动时兜底：删掉不再对应任何在册订阅的规则集目录，返回删掉的个数。
    /// 只认「小写 UUID」形态的目录名，别的东西一概不碰。
    @discardableResult
    public func removeOrphanCaches(keeping sourceIDs: Set<UUID>) async -> Int {
        await exclusively { await self.deleteOrphanDirectories(keeping: sourceIDs) }
    }

    // MARK: - 串行化

    /// 会改文件的操作排队执行。actor 可重入：一次刷新在下载处挂起时，另一次刷新若插进来，
    /// 它的孤儿清理会删掉前一次正在用的临时目录，`removeCache` 也会和正在写的文件打架。
    private var tail: Task<Void, Never>?

    private func exclusively<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
        let previous = tail
        let task = Task<T, Never> {
            await previous?.value
            return await operation()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    /// 空规则集（编译一次，之后复用）：占位、以及没有域名条件时的 DNS 版本都用它。
    private var emptyRuleSetData: Data?

    private func emptyRuleSet() async -> Data? {
        if let emptyRuleSetData { return emptyRuleSetData }
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-empty-rule-set-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let source = temporary.appending(path: "empty.json")
            let output = temporary.appending(path: "empty.srs")
            try Data(#"{"version":1,"rules":[]}"#.utf8).write(to: source)
            try await compiler(source, output)
            let data = try Data(contentsOf: output)
            emptyRuleSetData = data
            return data
        } catch {
            return nil
        }
    }

    /// 只在目标不存在时放一份占位。用 O_EXCL 创建：与进行中的下载（原子替换正式文件）并发时，
    /// 不论谁先谁后，都不会拿空文件盖掉刚下载好的正式文件。
    static func placeIfAbsent(_ data: Data, at url: URL) {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var failed = false
        data.withUnsafeBytes { buffer in
            failed = write(descriptor, buffer.baseAddress, buffer.count) != buffer.count
        }
        if failed { unlink(url.path) }
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func deleteDirectory(for sourceID: UUID) {
        try? FileManager.default.removeItem(at: directory(for: sourceID))
    }

    private func deleteOrphanDirectories(keeping sourceIDs: Set<UUID>) -> Int {
        let root = storage.rootDirectory.appending(path: "rule-sets/subscription")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return 0 }
        let registered = Set(sourceIDs.map { $0.uuidString.lowercased() })
        var removed = 0
        for entry in entries {
            guard let id = UUID(uuidString: entry), id.uuidString.lowercased() == entry,
                  !registered.contains(entry) else { continue }
            if (try? FileManager.default.removeItem(at: root.appending(path: entry))) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: - 流程

    private enum Decision {
        case useCache
        case download
    }

    /// 只读扫描缓存，不改任何文件。
    private func scan(
        providers: [SubscriptionRuleProvider], sourceID: UUID, now: Date
    ) -> (result: Result, accepted: [SubscriptionRuleProvider]) {
        var result = Result()
        let accepted = Self.limitCount(providers, warnings: &result.warnings)
        let directory = directory(for: sourceID)
        for provider in accepted {
            guard let cached = Self.cachedMetadata(for: provider, in: directory),
                  let prepared = Self.prepared(provider, metadata: cached, in: directory) else {
                result.missing.append(provider.name)
                continue
            }
            result.prepared[provider.name] = prepared
            if Self.isStale(cached, provider: provider, now: now) { result.stale.append(provider.name) }
        }
        Self.limitTotalEntries(&result, order: accepted)
        return (result, accepted)
    }

    /// 按原因汇总失败：一份就点名，多份报份数并列出前几个名字。
    static func summarize(_ failures: [String: [String]], outcome: String) -> [String] {
        failures.sorted { $0.key < $1.key }.map { reason, names in
            guard names.count > 1 else { return "规则集「\(names[0])」\(outcome)：\(reason)" }
            let listed = names.prefix(5).joined(separator: "、") + (names.count > 5 ? " 等" : "")
            return "\(names.count) 份规则集\(outcome)：\(reason)（\(listed)）"
        }
    }

    private static func limitCount(
        _ providers: [SubscriptionRuleProvider], warnings: inout [String]
    ) -> [SubscriptionRuleProvider] {
        guard providers.count > SubscriptionInputLimits.ruleSetCountLimit else { return providers }
        warnings.append(
            "订阅引用了 \(providers.count) 份规则集，超过 \(SubscriptionInputLimits.ruleSetCountLimit) 份上限，多出的已忽略"
        )
        return Array(providers.prefix(SubscriptionInputLimits.ruleSetCountLimit))
    }

    /// 总条目上限：超出时按订阅里的顺序保留前面的，丢掉后面的并告警（不静默截断）。
    private static func limitTotalEntries(_ result: inout Result, order: [SubscriptionRuleProvider]) {
        var total = 0
        for provider in order {
            guard let prepared = result.prepared[provider.name] else { continue }
            if total + prepared.entryCount > SubscriptionInputLimits.ruleSetTotalEntryLimit {
                // 不算「缺」：它有缓存，只是这次不写进配置。更不能放占位——占位与正式文件同路径，
                // 写进配置就等于把超限的内容照样加载了。
                result.prepared[provider.name] = nil
                result.warnings.append(
                    "规则集「\(provider.name)」使合计条目超过 \(SubscriptionInputLimits.ruleSetTotalEntryLimit) 条上限，已忽略"
                )
                continue
            }
            total += prepared.entryCount
        }
        let kept = Set(result.prepared.keys)
        result.stale.removeAll { !kept.contains($0) }
        result.stale.sort()
        result.updated.sort()
        result.missing.sort()
    }

    private func run(
        providers: [SubscriptionRuleProvider],
        sourceID: UUID,
        now: Date,
        decide: (Metadata?, SubscriptionRuleProvider) -> Decision
    ) async -> Result {
        var result = Result()
        let accepted = Self.limitCount(providers, warnings: &result.warnings)
        let directory = directory(for: sourceID)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        removeOrphans(in: directory, keeping: Set(accepted.map { Self.fileStem(for: $0.name) }))

        // 先按缓存与决策分流；需要下载的并发进行（封顶），其余立即就绪。
        var toDownload: [(SubscriptionRuleProvider, Metadata?)] = []
        for provider in accepted {
            let cached = Self.cachedMetadata(for: provider, in: directory)
            switch decide(cached, provider) {
            case .useCache:
                if let cached, let prepared = Self.prepared(provider, metadata: cached, in: directory) {
                    result.prepared[provider.name] = prepared
                    if Self.isStale(cached, provider: provider, now: now) { result.stale.append(provider.name) }
                } else {
                    toDownload.append((provider, cached))
                }
            case .download:
                toDownload.append((provider, cached))
            }
        }

        let empty = toDownload.isEmpty ? nil : await emptyRuleSet()
        let outcomes = await Self.downloadAll(
            toDownload.map(\.0), into: directory, now: now, emptyRuleSet: empty,
            storage: storage, downloader: downloader, compiler: compiler
        )
        // 同一原因的失败合并成一条：断一次网，十几份规则集各报一行只会淹没真正的信息。
        var keptCache: [String: [String]] = [:]
        var unavailable: [String: [String]] = [:]
        for (provider, cached) in toDownload {
            switch outcomes[provider.name] {
            case let .success(prepared):
                result.prepared[provider.name] = prepared
                result.updated.append(provider.name)
            case let .failure(error):
                // 下载失败：有旧缓存就继续用旧的，并说清楚。
                if let cached, let prepared = Self.prepared(provider, metadata: cached, in: directory) {
                    result.prepared[provider.name] = prepared
                    keptCache[error.localizedDescription, default: []].append(provider.name)
                } else {
                    result.missing.append(provider.name)
                    unavailable[error.localizedDescription, default: []].append(provider.name)
                }
            case nil:
                result.missing.append(provider.name)
            }
        }
        result.warnings += Self.summarize(keptCache, outcome: "更新失败，继续使用缓存")
        result.warnings += Self.summarize(unavailable, outcome: "不可用")
        Self.limitTotalEntries(&result, order: accepted)
        return result
    }

    /// 并发下载、转换、编译、落盘，封顶 `concurrentDownloads` 路。
    private static func downloadAll(
        _ providers: [SubscriptionRuleProvider],
        into directory: URL,
        now: Date,
        emptyRuleSet: Data?,
        storage: Storage,
        downloader: @escaping Downloader,
        compiler: @escaping Compiler
    ) async -> [String: Swift.Result<PreparedSubscriptionRuleSet, Error>] {
        var outcomes: [String: Swift.Result<PreparedSubscriptionRuleSet, Error>] = [:]
        await withTaskGroup(of: (String, Swift.Result<PreparedSubscriptionRuleSet, Error>).self) { group in
            var iterator = providers.makeIterator()
            func enqueue() {
                guard let provider = iterator.next() else { return }
                group.addTask {
                    do {
                        let prepared = try await install(
                            provider, into: directory, now: now, emptyRuleSet: emptyRuleSet,
                            storage: storage, downloader: downloader, compiler: compiler
                        )
                        return (provider.name, .success(prepared))
                    } catch {
                        return (provider.name, .failure(error))
                    }
                }
            }
            for _ in 0..<concurrentDownloads { enqueue() }
            while let (name, outcome) = await group.next() {
                outcomes[name] = outcome
                enqueue()
            }
        }
        return outcomes
    }

    /// 下载 → 转换 → 编译校验 → 原子替换。任何一步失败都不碰已有缓存。
    private static func install(
        _ provider: SubscriptionRuleProvider,
        into directory: URL,
        now: Date,
        emptyRuleSet: Data?,
        storage: Storage,
        downloader: @escaping Downloader,
        compiler: @escaping Compiler
    ) async throws -> PreparedSubscriptionRuleSet {
        let data = try await downloader(provider.url, SubscriptionInputLimits.ruleSetByteLimit)
        let converted = try ClashRuleSetConverter.convert(data, behavior: provider.behavior, format: provider.format)
        guard !converted.content.isEmpty else { throw SubscriptionRuleSetError.empty }

        let stem = fileStem(for: provider.name)
        let files = Files(directory: directory, stem: stem)
        let token = UUID().uuidString
        let temporary = directory.appending(path: ".\(stem)-\(token)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        // 先在临时目录里写源码、编译出二进制——编译本身就是格式校验；全部成功后才替换正式文件。
        let sourceData = try JSONSerialization.data(withJSONObject: converted.content.singBoxSource(), options: [.sortedKeys])
        let stagedSource = temporary.appending(path: "route.json")
        let stagedRoute = temporary.appending(path: "route.srs")
        try await storage.writeAtomically(sourceData, to: stagedSource)
        try await compiler(stagedSource, stagedRoute)

        // DNS 版本总是写一份：没有域名条件就写空规则集。配置里每份规则集因此都有 DNS 版本，
        // 与内容无关——内容变了（域名条件从无到有、从有到无）也只是替换文件，不用改配置。
        let dnsSource = converted.content.singBoxDNSSource()
        var stagedDNS: URL?
        if let dnsSource {
            let source = temporary.appending(path: "dns.json")
            let output = temporary.appending(path: "dns.srs")
            try await storage.writeAtomically(
                try JSONSerialization.data(withJSONObject: dnsSource, options: [.sortedKeys]), to: source
            )
            try await compiler(source, output)
            stagedDNS = output
        } else if let emptyRuleSet {
            let output = temporary.appending(path: "dns.srs")
            try emptyRuleSet.write(to: output)
            stagedDNS = output
        }

        // 原子替换正式文件。内核监视的是正式路径，替换后自动重载，无需重启。
        try replace(files.route, with: stagedRoute)
        if let stagedDNS {
            try replace(files.dns, with: stagedDNS)
        } else {
            try? FileManager.default.removeItem(at: files.dns)
        }
        try replace(files.source, with: stagedSource)
        let metadata = Metadata(
            url: provider.url, fetchedAt: now, entryCount: converted.content.entryCount,
            hasDNS: dnsSource != nil, skipped: converted.skipped
        )
        try await storage.writeAtomically(try JSONEncoder().encode(metadata), to: files.metadata)
        guard let prepared = prepared(provider, metadata: metadata, in: directory) else {
            throw SubscriptionRuleSetError.empty
        }
        return prepared
    }

    // MARK: - 缓存与文件

    struct Files {
        let route: URL
        let dns: URL
        let source: URL
        let metadata: URL

        init(directory: URL, stem: String) {
            route = directory.appending(path: "\(stem).srs")
            dns = directory.appending(path: "\(stem).dns.srs")
            source = directory.appending(path: "\(stem).json")
            metadata = directory.appending(path: "\(stem).meta.json")
        }
    }

    private func directory(for sourceID: UUID) -> URL {
        storage.rootDirectory.appending(path: "rule-sets/subscription/\(sourceID.uuidString.lowercased())")
    }

    /// 规则集名来自订阅，是**不可信输入**，不能直接拼进文件路径（`../../x` 就能逃出目录）。
    /// 安全字符集内原样使用，否则取名字的 SHA-256 前缀——两者都不含路径分隔符与 `..`。
    static func fileStem(for name: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        if !name.isEmpty, name.count <= 64,
           name.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return name
        }
        let digest = SHA256.hash(data: Data(name.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "p-\(digest)"
    }

    /// 内核配置里的 tag。加前缀避免与内置规则集（geosite-cn / geoip-cn / …）撞名。
    static func routeTag(for name: String) -> String { "sub-\(fileStem(for: name))" }
    static func dnsTag(for name: String) -> String { "sub-\(fileStem(for: name))-dns" }

    private static func cachedMetadata(for provider: SubscriptionRuleProvider, in directory: URL) -> Metadata? {
        let files = Files(directory: directory, stem: fileStem(for: provider.name))
        guard let data = try? Data(contentsOf: files.metadata),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              // 订阅把同名规则集指向了别的地址：旧缓存作废，按没有缓存处理。
              metadata.url == provider.url else { return nil }
        return metadata
    }

    private static func prepared(
        _ provider: SubscriptionRuleProvider, metadata: Metadata, in directory: URL
    ) -> PreparedSubscriptionRuleSet? {
        let files = Files(directory: directory, stem: fileStem(for: provider.name))
        let manager = FileManager.default
        guard manager.fileExists(atPath: files.route.path),
              manager.fileExists(atPath: files.source.path) else { return nil }
        // DNS 版本看文件在不在（没有域名条件时是空规则集），不看 metadata.hasDNS。
        let hasDNS = manager.fileExists(atPath: files.dns.path)
        return PreparedSubscriptionRuleSet(
            name: provider.name,
            routeTag: routeTag(for: provider.name),
            routeFile: files.route,
            dnsTag: hasDNS ? dnsTag(for: provider.name) : nil,
            dnsFile: hasDNS ? files.dns : nil,
            sourceFile: files.source,
            entryCount: metadata.entryCount,
            fetchedAt: metadata.fetchedAt,
            expiresAt: metadata.fetchedAt.addingTimeInterval(refreshInterval(for: provider))
        )
    }

    static func refreshInterval(for provider: SubscriptionRuleProvider) -> TimeInterval {
        max(provider.interval ?? defaultRefreshInterval, minimumRefreshInterval)
    }

    private static func isStale(_ metadata: Metadata, provider: SubscriptionRuleProvider, now: Date) -> Bool {
        now.timeIntervalSince(metadata.fetchedAt) >= refreshInterval(for: provider)
    }

    /// 清掉订阅不再引用的规则集文件（订阅刷新后删了某个 provider），以及中断留下的临时目录。
    private func removeOrphans(in directory: URL, keeping stems: Set<String>) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for entry in entries {
            let stem = entry.hasPrefix(".") ? "" : String(entry.split(separator: ".").first ?? "")
            if !stems.contains(stem) {
                try? FileManager.default.removeItem(at: directory.appending(path: entry))
            }
        }
    }

    private static func replace(_ target: URL, with staged: URL) throws {
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: target)
        }
    }

    // MARK: - 生产实现

    /// 流式下载，边收边累计，越界立即中止；https 被重定向到 http 直接拦断。
    static func download(_ url: URL, byteLimit: Int, session: URLSession) async throws -> Data {
        let guardDelegate = InsecureRedirectGuard(originIsSecure: url.scheme?.lowercased() == "https")
        let (stream, response) = try await session.bytes(from: url, delegate: guardDelegate)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else { throw SubscriptionRuleSetError.invalidStatus(status) }
        var data = Data()
        for try await byte in stream {
            data.append(byte)
            if data.count > byteLimit { throw SubscriptionRuleSetError.tooLarge(limit: byteLimit) }
        }
        if let blocked = await guardDelegate.blockedTarget { throw SubscriptionRuleSetError.insecureRedirect(blocked) }
        return data
    }

    static func coreCompiler(binaryURL: URL) -> Compiler {
        { source, output in
            let result = try await ProcessRunner.run(
                executable: binaryURL,
                arguments: ["rule-set", "compile", source.path, "-o", output.path],
                timeout: 30
            )
            guard result.exitCode == 0 else {
                throw SubscriptionRuleSetError.compileFailed(
                    result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }
    }
}
