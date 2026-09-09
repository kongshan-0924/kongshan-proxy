import Foundation

/// 出口 IP 的信誉信息。
///
/// **所有字段都是可选的**：数据源自称尚处测试阶段，字段随时可能增删。
/// 全设可选后，某个字段消失只会让那一项不显示，而不是整份解码失败、连 IP 都拿不到。
public struct IPReputationInfo: Codable, Equatable, Sendable {
    public let ip: String?
    public let asn: Int?
    public let asOrganization: String?
    public let fraudScore: Int?
    public let isResidential: Bool?
    public let isBroadcast: Bool?

    public init(
        ip: String? = nil,
        asn: Int? = nil,
        asOrganization: String? = nil,
        fraudScore: Int? = nil,
        isResidential: Bool? = nil,
        isBroadcast: Bool? = nil
    ) {
        self.ip = ip
        self.asn = asn
        self.asOrganization = asOrganization
        self.fraudScore = fraudScore
        self.isResidential = isResidential
        self.isBroadcast = isBroadcast
    }

    /// `AS400618 - Prime Security Corp.`；缺一半时只显示有的那半。
    public var asnText: String? {
        switch (asn, asOrganization) {
        case let (asn?, org?) where !org.isEmpty: "AS\(asn) - \(org)"
        case let (asn?, _): "AS\(asn)"
        case let (_, org?) where !org.isEmpty: org
        default: nil
        }
    }

    /// IP 类型标签。住宅/机房是二选一，广播是附加项。
    public var labels: [String] {
        var result: [String] = []
        if let isResidential { result.append(isResidential ? "住宅 IP" : "机房 IP") }
        if isBroadcast == true { result.append("广播 IP") }
        return result
    }

    public var risk: IPRiskLevel? {
        fraudScore.map(IPRiskLevel.init(fraudScore:))
    }
}

/// 风险等级。分档参照数据源自身的口径：57~60 分它标为「中度风险」。
public enum IPRiskLevel: String, Equatable, Sendable {
    case low
    case medium
    case high

    public init(fraudScore: Int) {
        switch fraudScore {
        case ..<30: self = .low
        case 30..<70: self = .medium
        default: self = .high
        }
    }

    public var title: String {
        switch self {
        case .low: "低风险"
        case .medium: "中度风险"
        case .high: "高风险"
        }
    }
}

/// 拉取出口 IP 的信誉信息。
///
/// **会把当前出口 IP 暴露给这个第三方服务**（用户 2026-09-09 明确表示可以接受）。
/// 拿不到就返回 nil，界面对应区块不显示——绝不能因为这个可选增强让整份出口诊断失败。
public enum IPReputationService {
    /// 数据源。自称测试阶段、可能变动；真要换只改这一行。
    public static let defaultEndpoint = URL(string: "https://my.ippure.com/v1/info")!
    public static let sourceName = "ippure.com"

    public typealias Loader = @Sendable (URLRequest) async throws -> Data

    public static func fetch(
        endpoint: URL = defaultEndpoint,
        timeout: TimeInterval = 10,
        loader: @escaping Loader = defaultLoader
    ) async -> IPReputationInfo? {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let data = try? await loader(request) else { return nil }
        return try? JSONDecoder().decode(IPReputationInfo.self, from: data)
    }

    public static let defaultLoader: Loader = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw IPReputationError.badResponse
        }
        return data
    }
}

public enum IPReputationError: Error {
    case badResponse
}
