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

/// 规则集下载源。上游都是 sing-box 官方开源仓库 SagerNet/sing-geoip 与 sing-geosite，
/// 这里只切换分发通道：GitHub 原始地址在国内常被阻断，jsDelivr 走 Fastly CDN 更稳。
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
        let repository: String

        func remoteURL(mirror: RuleSetMirror) -> URL {
            mirror.url(repository: repository, file: "\(tag).srs")
        }
    }

    private static let geositeCN = Resource(tag: "geosite-cn", repository: "sing-geosite")
    private static let geoipCN = Resource(tag: "geoip-cn", repository: "sing-geoip")
    private static let ads = Resource(tag: "geosite-category-ads-all", repository: "sing-geosite")

    /// 供设置页展示的当前下载地址。
    public static func sourceURLs(mirror: RuleSetMirror, includeAds: Bool) -> [(tag: String, url: URL)] {
        var resources = [geoipCN, geositeCN]
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
        return RuleSetPreparationResult(
            ruleSets: PreparedRuleSets(geositeCN: geositeCN, geoipCN: geoipCN, ads: adsURL),
            warnings: warnings
        )
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
