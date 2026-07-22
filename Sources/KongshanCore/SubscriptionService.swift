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
        usage: SubscriptionUsage? = nil,
        suggestedName: String? = nil
    ) {
        self.nodes = nodes
        self.warnings = warnings
        self.usedCache = usedCache
        self.policyGroups = policyGroups
        self.subscriptionRules = subscriptionRules
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

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "订阅地址必须使用 HTTP 或 HTTPS"
        case let .invalidStatus(code): "订阅服务器返回 HTTP \(code)"
        case .emptyResponse: "订阅响应为空"
        case .invalidEncoding: "订阅内容不是 UTF-8 文本"
        case let .refreshFailedWithoutCache(message): "订阅更新失败且没有可用缓存：\(message)"
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

    public init(storage: Storage, session: URLSession = .shared) {
        self.storage = storage
        loader = { url in
            let (data, response) = try await session.data(for: Self.request(for: url))
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (key, value) in http?.allHeaderFields ?? [:] {
                guard let key = key as? String, let value = value as? String else { continue }
                headers[key] = value
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
                        warnings: conversion.warnings + ["订阅更新失败，继续使用缓存：\(refreshError.localizedDescription)"],
                        usedCache: true,
                        policyGroups: conversion.policyGroups,
                        subscriptionRules: conversion.subscriptionRules
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
