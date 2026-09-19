import Foundation

public struct HTTPDownload: Sendable {
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]

    public init(data: Data, statusCode: Int, headers: [String: String] = [:]) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }

    /// HTTP 头名不区分大小写；各家面板下发的大小写并不统一。
    public func headerValue(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct SubscriptionRefreshResult: Sendable {
    public let nodes: [ProxyNode]
    public let warnings: [String]
    public let usedCache: Bool
    /// 订阅自带的策略组，供「策略组」页一键导入。
    public var policyGroups: [PolicyGroup] = []
    public var subscriptionRules: [SubscriptionRule] = []
    /// 订阅的 rule-providers（被 RULE-SET 引用、且形态受支持的）。
    public var ruleProviders: [SubscriptionRuleProvider] = []
    /// 订阅 MATCH 的目标。
    public var matchTarget: String?
    /// 来自 `subscription-userinfo` 响应头；走缓存兜底时为 nil（沿用旧值）。
    public var usage: SubscriptionUsage?
    /// 服务器建议的订阅名（`profile-title` / `Content-Disposition` 文件名）。
    public var suggestedName: String?

    public init(
        nodes: [ProxyNode],
        warnings: [String],
        usedCache: Bool,
        policyGroups: [PolicyGroup] = [],
        subscriptionRules: [SubscriptionRule] = [],
        ruleProviders: [SubscriptionRuleProvider] = [],
        matchTarget: String? = nil,
        usage: SubscriptionUsage? = nil,
        suggestedName: String? = nil
    ) {
        self.nodes = nodes
        self.warnings = warnings
        self.usedCache = usedCache
        self.policyGroups = policyGroups
        self.subscriptionRules = subscriptionRules
        self.ruleProviders = ruleProviders
        self.matchTarget = matchTarget
        self.usage = usage
        self.suggestedName = suggestedName
    }
}

public enum SubscriptionServiceError: Error, Equatable, LocalizedError {
    case invalidURL
    case invalidStatus(Int)
    case emptyResponse
    case invalidEncoding
    case refreshFailedWithoutCache(String)
    /// 响应体超过 `SubscriptionInputLimits.documentByteLimit`。
    case responseTooLarge(limit: Int)
    /// https 订阅被重定向到明文 http。
    case insecureRedirect(to: String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "订阅地址必须使用 HTTP 或 HTTPS"
        case let .invalidStatus(code): "订阅服务器返回 HTTP \(code)"
        case .emptyResponse: "订阅响应为空"
        case .invalidEncoding: "订阅内容不是 UTF-8 文本"
        case let .refreshFailedWithoutCache(message): "订阅更新失败且没有可用缓存：\(message)"
        case let .responseTooLarge(limit):
            "订阅响应超过 \(limit / 1_048_576) MB 上限，已中止下载"
        case let .insecureRedirect(target):
            "订阅地址被重定向到明文 HTTP（\(target)），已中止——订阅链接通常带鉴权令牌，"
                + "明文跳转会把它暴露在链路上"
        }
    }
}

public actor SubscriptionService {
    public typealias Loader = @Sendable (URL) async throws -> HTTPDownload

    private let storage: Storage
    private let loader: Loader

    public init(storage: Storage, loader: @escaping Loader) {
        self.storage = storage
        self.loader = loader
    }

    /// 订阅请求的 User-Agent。绝大多数机场面板按 UA 决定返回格式：
    /// 含 "clash"（不区分大小写）→ Clash YAML；含 "sing-box" → sing-box JSON。
    /// 我们的转换器只认 Clash YAML，所以 UA 必须带 "clash" 且不能带 "sing-box"，
    /// 否则同一条链接可能拿到 base64 节点串或 JSON，整个导入直接失败。
    public static let userAgent = "clash.meta kongshan/1.0"

    public static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// 订阅下载专用会话。网络未就绪（刚唤醒、Wi-Fi 还在重连）时**等网络**，而不是立刻报
    /// 「The Internet connection appears to be offline」；等待封顶 90 秒，不会无限挂着。
    public static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 90
        return URLSession(configuration: config)
    }()

    public init(storage: Storage, session: URLSession = SubscriptionService.defaultSession) {
        self.storage = storage
        loader = { url in
            // 订阅是外部不可信输入，两道门都要在**数据落地之前**生效：
            //
            // 1) 体积：`URLSession.data(for:)` 会把整个响应读进内存后才返回，
            //    机场面板（或劫持者）回一个几 GB 的响应就能把 App 撑爆。改用
            //    `bytes(for:)` 边收边累计，越界立刻中止，不会读完再判。
            // 2) 降级重定向：订阅链接通常在 URL 里带鉴权令牌，https→http 的跳转
            //    会把它明文发出去。用 delegate 在跳转发生**前**拦下。
            let guardDelegate = InsecureRedirectGuard(originIsSecure: url.scheme?.lowercased() == "https")
            let (stream, response) = try await session.bytes(
                for: Self.request(for: url),
                delegate: guardDelegate
            )
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (key, value) in http?.allHeaderFields ?? [:] {
                guard let key = key as? String, let value = value as? String else { continue }
                headers[key] = value
            }

            let limit = SubscriptionInputLimits.documentByteLimit
            var data = Data()
            data.reserveCapacity(min(limit, 512 * 1024))
            for try await byte in stream {
                data.append(byte)
                if data.count > limit {
                    throw SubscriptionServiceError.responseTooLarge(limit: limit)
                }
            }
            if let blocked = await guardDelegate.blockedTarget {
                throw SubscriptionServiceError.insecureRedirect(to: blocked)
            }
            return HTTPDownload(data: data, statusCode: http?.statusCode ?? 0, headers: headers)
        }
    }

    /// 服务器建议的订阅名：`profile-title`（可带 `base64:` 前缀）优先，
    /// 其次 `Content-Disposition` 的文件名（RFC 5987 的 filename* 变体优先，去扩展名）。
    static func suggestedName(from download: HTTPDownload) -> String? {
        if let raw = download.headerValue("profile-title") {
            var value = raw
            if raw.lowercased().hasPrefix("base64:"),
               let data = Data(base64Encoded: String(raw.dropFirst("base64:".count))),
               let decoded = String(data: data, encoding: .utf8) {
                value = decoded
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        guard let disposition = download.headerValue("Content-Disposition") else { return nil }
        let pieces = disposition.split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        for piece in pieces where piece.lowercased().hasPrefix("filename*=") {
            var value = String(piece.dropFirst("filename*=".count))
            if let range = value.range(of: "''") { value = String(value[range.upperBound...]) }
            if let decoded = value.removingPercentEncoding {
                let name = (decoded as NSString).deletingPathExtension
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { return name }
            }
        }
        for piece in pieces where piece.lowercased().hasPrefix("filename=") {
            let value = String(piece.dropFirst("filename=".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            let name = (value as NSString).deletingPathExtension
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return nil
    }

    public func refresh(_ subscription: SubscriptionSource) async throws -> SubscriptionRefreshResult {
        do {
            guard ["http", "https"].contains(subscription.url.scheme?.lowercased() ?? "") else {
                throw SubscriptionServiceError.invalidURL
            }
            let download = try await loader(subscription.url)
            guard (200...299).contains(download.statusCode) else {
                throw SubscriptionServiceError.invalidStatus(download.statusCode)
            }
            guard !download.data.isEmpty else { throw SubscriptionServiceError.emptyResponse }
            guard let yaml = String(data: download.data, encoding: .utf8) else {
                throw SubscriptionServiceError.invalidEncoding
            }
            let conversion = try ClashSubscriptionConverter.convert(yaml: yaml, sourceID: subscription.id)
            try await storage.prepare()
            try await storage.writeAtomically(download.data, to: storage.cacheURL(for: subscription))
            return SubscriptionRefreshResult(
                nodes: conversion.nodes,
                warnings: conversion.warnings,
                usedCache: false,
                policyGroups: conversion.policyGroups,
                subscriptionRules: conversion.subscriptionRules,
                ruleProviders: conversion.ruleProviders,
                matchTarget: conversion.matchTarget,
                usage: download.headerValue("subscription-userinfo")
                    .flatMap(SubscriptionUsage.parse(headerValue:)),
                suggestedName: Self.suggestedName(from: download)
            )
        } catch {
            let refreshError = error
            // 缓存兜底：网络失败或新 YAML 解析失败时，若缓存可读且能解析，沿用缓存。
            // 这里区分「缓存也解析失败」——旧实现用 try? 把缓存解析错误吞掉，
            // 抛出的 refreshFailedWithoutCache 只带 refreshError，用户看不到缓存也坏了。
            // 改成显式 try，缓存解析失败时把两路错误都报给用户。
            if let cachedData = try? await storage.readIfPresent(from: storage.cacheURL(for: subscription)),
               let yaml = String(data: cachedData, encoding: .utf8) {
                do {
                    let conversion = try ClashSubscriptionConverter.convert(yaml: yaml, sourceID: subscription.id)
                    return SubscriptionRefreshResult(
                        nodes: conversion.nodes,
                        warnings: conversion.warnings + [
                            "订阅「\(subscription.name)」更新失败，继续使用缓存：\(refreshError.localizedDescription)"
                        ],
                        usedCache: true,
                        policyGroups: conversion.policyGroups,
                        subscriptionRules: conversion.subscriptionRules,
                        ruleProviders: conversion.ruleProviders,
                        matchTarget: conversion.matchTarget
                    )
                } catch let cacheError {
                    throw SubscriptionServiceError.refreshFailedWithoutCache(
                        "\(refreshError.localizedDescription)（缓存解析也失败：\(cacheError.localizedDescription)）"
                    )
                }
            }
            throw SubscriptionServiceError.refreshFailedWithoutCache(refreshError.localizedDescription)
        }
    }
}


/// 拦截 https → http 的降级重定向。
///
/// 订阅链接几乎都把鉴权令牌放在 URL 里（`?token=…` 或路径段）。`URLSession` 默认会
/// 跟随重定向，于是一个被劫持（或只是配错）的 301 就能让令牌以明文发出去。
/// 返回 nil 即拒绝跟随；同时记下目标供上层报错说明。
actor InsecureRedirectGuard: NSObject, URLSessionTaskDelegate {
    private let originIsSecure: Bool
    private(set) var blockedTarget: String?

    init(originIsSecure: Bool) {
        self.originIsSecure = originIsSecure
        super.init()
    }

    nonisolated func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard originIsSecure else { return request }
        guard let url = request.url, url.scheme?.lowercased() != "https" else { return request }
        await record(url.absoluteString)
        return nil
    }

    private func record(_ target: String) {
        if blockedTarget == nil { blockedTarget = target }
    }
}
