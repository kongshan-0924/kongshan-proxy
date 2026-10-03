import Foundation

public struct RuleSetPreparationResult: Equatable, Sendable {
    public let ruleSets: PreparedRuleSets
    public let warnings: [String]

    public init(ruleSets: PreparedRuleSets, warnings: [String]) {
        self.ruleSets = ruleSets
        self.warnings = warnings
    }
}

public enum RuleSetServiceError: Error, Equatable, LocalizedError {
    case invalidStatus(tag: String, code: Int)
    case emptyResponse(String)
    case unavailable(tag: String, reason: String)
    case validationFailed(tag: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidStatus(tag, code): "规则集 \(tag) 服务器返回 HTTP \(code)"
        case let .emptyResponse(tag): "规则集 \(tag) 下载内容为空"
        case let .unavailable(tag, reason): "规则集 \(tag) 更新失败且没有可用缓存：\(reason)"
        case let .validationFailed(tag, reason): "规则集 \(tag) 解析验证失败：\(reason)"
        }
    }
}

/// 规则集下载源。上游是 sing-box 官方开源仓库 SagerNet/sing-geoip 与 sing-geosite，
/// 国内域名扩展名单来自 MetaCubeX/meta-rules-dat。这里只切换分发通道：
/// GitHub 原始地址在国内常被阻断，jsDelivr 走 Fastly CDN 更稳。
public enum RuleSetMirror: String, Codable, CaseIterable, Sendable {
    case githubRaw
    case jsdelivr

    public var displayName: String {
        switch self {
        case .githubRaw: "GitHub 原始地址"
        case .jsdelivr: "jsDelivr CDN（Fastly）"
        }
    }

    public func url(repository: String, file: String) -> URL {
        switch self {
        case .githubRaw:
            URL(string: "https://raw.githubusercontent.com/SagerNet/\(repository)/rule-set/\(file)")!
        case .jsdelivr:
            URL(string: "https://fastly.jsdelivr.net/gh/SagerNet/\(repository)@rule-set/\(file)")!
        }
    }

    /// MetaCubeX/meta-rules-dat 的 sing 分支（mihomo 社区维护的 sing-box 格式规则集）。
    public func metaCubeXURL(path: String) -> URL {
        switch self {
        case .githubRaw:
            URL(string: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/\(path)")!
        case .jsdelivr:
            URL(string: "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/\(path)")!
        }
    }
}

public struct RuleSetSettings: Codable, Equatable, Sendable {
    public var mirror: RuleSetMirror
    /// 关闭后只使用本地缓存，不发起下载。
    public var autoUpdate: Bool
    public var lastUpdatedAt: Date?

    public init(mirror: RuleSetMirror, autoUpdate: Bool, lastUpdatedAt: Date? = nil) {
        self.mirror = mirror
        self.autoUpdate = autoUpdate
        self.lastUpdatedAt = lastUpdatedAt
    }

    public static let defaults = RuleSetSettings(mirror: .jsdelivr, autoUpdate: true)
}

public actor RuleSetService {
    public typealias Loader = @Sendable (URL) async throws -> HTTPDownload
    public typealias Validator = @Sendable (URL) async throws -> Void

    private struct Resource: Sendable {
        let tag: String
        let remote: @Sendable (RuleSetMirror) -> URL

        func remoteURL(mirror: RuleSetMirror) -> URL {
            remote(mirror)
        }

        static func sagerNet(tag: String, repository: String) -> Resource {
            Resource(tag: tag) { $0.url(repository: repository, file: "\(tag).srs") }
        }
    }

    private static let geositeCN = Resource.sagerNet(tag: "geosite-cn", repository: "sing-geosite")
    private static let geoipCN = Resource.sagerNet(tag: "geoip-cn", repository: "sing-geoip")
    private static let ads = Resource.sagerNet(tag: "geosite-category-ads-all", repository: "sing-geosite")
    /// 国内域名扩展名单：v2fly 的 cn 并上 dnsmasq-china-list（权威 DNS 在国内的域名），约 11 万条。
    /// SagerNet 的 geosite-cn 只有前者，没进订阅名单的国内中小站（真机：两个游戏交易站）都不在里面。
    private static let geositeCNExtra = Resource(tag: ConfigGenerator.geositeCNExtraTag) {
        $0.metaCubeXURL(path: "geo/geosite/cn.srs")
    }

    /// 供设置页展示的当前下载地址。
    public static func sourceURLs(mirror: RuleSetMirror, includeAds: Bool) -> [(tag: String, url: URL)] {
        var resources = [geoipCN, geositeCN, geositeCNExtra]
        if includeAds { resources.append(ads) }
        return resources.map { ($0.tag, $0.remoteURL(mirror: mirror)) }
    }

    private let storage: Storage
    private let loader: Loader
    private let validator: Validator

    public init(storage: Storage, loader: @escaping Loader, validator: @escaping Validator) {
        self.storage = storage
        self.loader = loader
        self.validator = validator
    }

    public init(storage: Storage, binaryURL: URL, loader: @escaping Loader) {
        self.storage = storage
        self.loader = loader
        validator = Self.coreValidator(binaryURL: binaryURL)
    }

    public init(storage: Storage, binaryURL: URL, session: URLSession? = nil) {
        self.storage = storage
        // 规则集下载给合理超时：代理还没开时，国内直连 jsDelivr/GitHub 可能很慢甚至被阻断，
        // 不能让启动卡在 URLSession 默认的 60 秒上。
        let session = session ?? {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 20
            return URLSession(configuration: config)
        }()
        loader = { url in
            let (data, response) = try await session.data(from: url)
            return HTTPDownload(
                data: data,
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }
        validator = Self.coreValidator(binaryURL: binaryURL)
    }

    public func prepare(
        includeAds: Bool,
        mirror: RuleSetMirror = .githubRaw,
        allowsNetwork: Bool = true,
        forceRefresh: Bool = false
    ) async throws -> RuleSetPreparationResult {
        try await storage.prepare()

        // 三个规则集并发下载 + 校验：旧实现串行 await，首次启动无缓存时累积延迟。
        // 并发后总时间≈最慢的那个，而不是三个之和。缓存命中路径不变（直接 return）。
        // 之所以能并发：prepare 是 nonisolated static，loader/validator/storage 都是 Sendable，
        // 不会被 RuleSetService actor mailbox 串行化。
        var resources = [Self.geositeCN, Self.geoipCN]
        if includeAds { resources.append(Self.ads) }

        // 扩展名单与核心规则集并发准备（首次下载不拖慢启动）；它自己失败不影响核心规则集，见 `prepareOptional`。
        async let extra = Self.prepareOptional(
            Self.geositeCNExtra,
            mirror: mirror,
            allowsNetwork: allowsNetwork,
            forceRefresh: forceRefresh,
            storage: storage,
            loader: loader,
            validator: validator
        )

        var collected: [(tag: String, url: URL, warnings: [String])] = []
        try await withThrowingTaskGroup(of: (String, URL, [String]).self) { [storage, loader, validator] group in
            for resource in resources {
                group.addTask {
                    let (url, warnings) = try await Self.prepare(
                        resource,
                        mirror: mirror,
                        allowsNetwork: allowsNetwork,
                        forceRefresh: forceRefresh,
                        storage: storage,
                        loader: loader,
                        validator: validator
                    )
                    return (resource.tag, url, warnings)
                }
            }
            // withThrowingTaskGroup：任一子任务抛错就整体抛，行为与旧串行 try 一致。
            for try await item in group { collected.append(item) }
        }

        var warnings: [String] = []
        var geositeURL: URL?
        var geoipURL: URL?
        var adsURL: URL?
        for item in collected {
            if !item.warnings.isEmpty {
                warnings.append(contentsOf: item.warnings)
            }
            switch item.tag {
            case Self.geositeCN.tag: geositeURL = item.url
            case Self.geoipCN.tag: geoipURL = item.url
            case Self.ads.tag: adsURL = item.url
            default: break
            }
        }

        guard let geositeCN = geositeURL, let geoipCN = geoipURL else {
            throw RuleSetServiceError.unavailable(tag: "core", reason: "核心规则集缺失")
        }

        let (extraURL, extraWarnings) = await extra
        warnings.append(contentsOf: extraWarnings)
        return RuleSetPreparationResult(
            ruleSets: PreparedRuleSets(geositeCN: geositeCN, geoipCN: geoipCN, ads: adsURL, geositeCNExtra: extraURL),
            warnings: warnings
        )
    }

    /// 可有可无的规则集：拿不到就返回 nil，配置照常生成、退回原有名单——绝不能因为它让内核起不来。
    /// 自动更新关着又没有缓存时不算失败（那是用户的选择），不出警告，免得每次启动都提示一遍。
    private static func prepareOptional(
        _ resource: Resource,
        mirror: RuleSetMirror,
        allowsNetwork: Bool,
        forceRefresh: Bool,
        storage: Storage,
        loader: @escaping Loader,
        validator: @escaping Validator
    ) async -> (URL?, [String]) {
        let cacheURL = storage.rootDirectory.appending(path: "rule-sets/\(resource.tag).srs")
        if !allowsNetwork, !FileManager.default.fileExists(atPath: cacheURL.path) {
            return (nil, [])
        }
        do {
            return try await prepare(
                resource, mirror: mirror, allowsNetwork: allowsNetwork, forceRefresh: forceRefresh,
                storage: storage, loader: loader, validator: validator
            )
        } catch {
            return (nil, ["国内域名扩展名单暂不可用，国内站分流先用内置名单：\(error.localizedDescription)"])
        }
    }

    /// 单个规则集的下载 + 校验 + 缓存。nonisolated 以便外层并发调用。
    /// 缓存优先：非强制刷新时，只要本地已有该规则集就直接用，绝不在启动路径上等网络。
    /// 缓存是写入时校验过的（且 sing-box check 启动前还会再校验一次整份配置），这里不重复校验以省时间。
    private static func prepare(
        _ resource: Resource,
        mirror: RuleSetMirror,
        allowsNetwork: Bool,
        forceRefresh: Bool,
        storage: Storage,
        loader: @escaping Loader,
        validator: @escaping Validator
    ) async throws -> (URL, [String]) {
        let cacheURL = storage.rootDirectory.appending(path: "rule-sets/\(resource.tag).srs")
        if !forceRefresh, FileManager.default.fileExists(atPath: cacheURL.path) {
            return (cacheURL, [])
        }
        var warnings: [String] = []
        do {
            guard allowsNetwork else {
                throw RuleSetServiceError.unavailable(tag: resource.tag, reason: "无缓存且自动更新已关闭")
            }
            let download = try await loader(resource.remoteURL(mirror: mirror))
            guard (200...299).contains(download.statusCode) else {
                throw RuleSetServiceError.invalidStatus(tag: resource.tag, code: download.statusCode)
            }
            guard !download.data.isEmpty else {
                throw RuleSetServiceError.emptyResponse(resource.tag)
            }

            let temporaryURL = cacheURL.deletingLastPathComponent().appending(
                path: ".\(resource.tag)-\(UUID().uuidString).download.srs"
            )
            try await storage.writeAtomically(download.data, to: temporaryURL)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            do {
                try await validator(temporaryURL)
            } catch {
                throw RuleSetServiceError.validationFailed(
                    tag: resource.tag,
                    reason: error.localizedDescription
                )
            }
            try await storage.writeAtomically(download.data, to: cacheURL)
            return (cacheURL, warnings)
        } catch {
            guard (try? await storage.readIfPresent(from: cacheURL)) != nil else {
                throw RuleSetServiceError.unavailable(tag: resource.tag, reason: error.localizedDescription)
            }
            do {
                try await validator(cacheURL)
            } catch {
                throw RuleSetServiceError.unavailable(
                    tag: resource.tag,
                    reason: "缓存解析验证失败：\(error.localizedDescription)"
                )
            }
            warnings.append("规则集 \(resource.tag) 更新失败，继续使用最后成功缓存：\(error.localizedDescription)")
            return (cacheURL, warnings)
        }
    }

    private static func coreValidator(binaryURL: URL) -> Validator {
        { ruleSetURL in
            let result = try await ProcessRunner.run(
                executable: binaryURL,
                arguments: ["rule-set", "decompile", ruleSetURL.path, "-o", "/dev/null"],
                timeout: 10
            )
            guard result.exitCode == 0 else {
                throw RuleSetServiceError.validationFailed(
                    tag: ruleSetURL.lastPathComponent,
                    reason: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }
    }
}
