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

public actor RuleSetService {
    public typealias Loader = @Sendable (URL) async throws -> HTTPDownload
    public typealias Validator = @Sendable (URL) async throws -> Void

    private struct Resource: Sendable {
        let tag: String
        let remoteURL: URL
    }

    private static let geositeCN = Resource(
        tag: "geosite-cn",
        remoteURL: URL(string: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs")!
    )
    private static let geoipCN = Resource(
        tag: "geoip-cn",
        remoteURL: URL(string: "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs")!
    )
    private static let ads = Resource(
        tag: "geosite-category-ads-all",
        remoteURL: URL(string: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs")!
    )

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

    public init(storage: Storage, binaryURL: URL, session: URLSession = .shared) {
        self.storage = storage
        loader = { url in
            let (data, response) = try await session.data(from: url)
            return HTTPDownload(
                data: data,
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }
        validator = Self.coreValidator(binaryURL: binaryURL)
    }

    public func prepare(includeAds: Bool) async throws -> RuleSetPreparationResult {
        try await storage.prepare()
        var warnings: [String] = []

        let geositeCN = try await prepare(Self.geositeCN, warnings: &warnings)
        let geoipCN = try await prepare(Self.geoipCN, warnings: &warnings)
        let ads = includeAds ? try await prepare(Self.ads, warnings: &warnings) : nil

        return RuleSetPreparationResult(
            ruleSets: PreparedRuleSets(geositeCN: geositeCN, geoipCN: geoipCN, ads: ads),
            warnings: warnings
        )
    }

    private func prepare(_ resource: Resource, warnings: inout [String]) async throws -> URL {
        let cacheURL = storage.rootDirectory.appending(path: "rule-sets/\(resource.tag).srs")
        do {
            let download = try await loader(resource.remoteURL)
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
            return cacheURL
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
            return cacheURL
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
