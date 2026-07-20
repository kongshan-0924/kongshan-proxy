import Foundation

public struct HTTPDownload: Sendable {
    public let data: Data
    public let statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
}

public struct SubscriptionRefreshResult: Sendable {
    public let nodes: [ProxyNode]
    public let warnings: [String]
    public let usedCache: Bool

    public init(nodes: [ProxyNode], warnings: [String], usedCache: Bool) {
        self.nodes = nodes
        self.warnings = warnings
        self.usedCache = usedCache
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

    public init(storage: Storage, session: URLSession = .shared) {
        self.storage = storage
        loader = { url in
            let (data, response) = try await session.data(from: url)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            return HTTPDownload(data: data, statusCode: statusCode)
        }
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
                usedCache: false
            )
        } catch {
            if let cachedData = try? await storage.readIfPresent(from: storage.cacheURL(for: subscription)),
               let yaml = String(data: cachedData, encoding: .utf8),
               let conversion = try? ClashSubscriptionConverter.convert(yaml: yaml, sourceID: subscription.id) {
                return SubscriptionRefreshResult(
                    nodes: conversion.nodes,
                    warnings: conversion.warnings + ["订阅更新失败，继续使用缓存：\(error.localizedDescription)"],
                    usedCache: true
                )
            }
            throw SubscriptionServiceError.refreshFailedWithoutCache(error.localizedDescription)
        }
    }
}
