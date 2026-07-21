import Foundation

public enum ProxyProtocol: String, Codable, CaseIterable, Sendable {
    case shadowsocks
    case trojan
    case vmess
    case hysteria2
    case anytls
}

public struct TransportOptions: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case websocket
        case grpc
    }

    public var kind: Kind
    public var path: String?
    public var headers: [String: String]
    public var serviceName: String?

    public init(
        kind: Kind,
        path: String? = nil,
        headers: [String: String] = [:],
        serviceName: String? = nil
    ) {
        self.kind = kind
        self.path = path
        self.headers = headers
        self.serviceName = serviceName
    }
}

public struct ProxyNode: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var sourceID: UUID?
    public var name: String
    public var protocolType: ProxyProtocol
    public var server: String
    public var port: Int
    public var password: String?
    public var uuid: String?
    public var method: String?
    public var security: String?
    public var alterID: Int?
    public var tlsEnabled: Bool
    public var sni: String?
    public var skipCertificateVerification: Bool
    public var obfsPassword: String?
    public var uploadMbps: Int?
    public var downloadMbps: Int?
    public var transport: TransportOptions?

    public init(
        id: UUID = UUID(),
        sourceID: UUID? = nil,
        name: String,
        protocolType: ProxyProtocol,
        server: String,
        port: Int,
        password: String? = nil,
        uuid: String? = nil,
        method: String? = nil,
        security: String? = nil,
        alterID: Int? = nil,
        tlsEnabled: Bool = false,
        sni: String? = nil,
        skipCertificateVerification: Bool = false,
        obfsPassword: String? = nil,
        uploadMbps: Int? = nil,
        downloadMbps: Int? = nil,
        transport: TransportOptions? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.name = name
        self.protocolType = protocolType
        self.server = server
        self.port = port
        self.password = password
        self.uuid = uuid
        self.method = method
        self.security = security
        self.alterID = alterID
        self.tlsEnabled = tlsEnabled
        self.sni = sni
        self.skipCertificateVerification = skipCertificateVerification
        self.obfsPassword = obfsPassword
        self.uploadMbps = uploadMbps
        self.downloadMbps = downloadMbps
        self.transport = transport
    }
}

/// 机场在订阅响应头 `subscription-userinfo` 里下发的配额：
/// `upload=…; download=…; total=…; expire=…`（字节 / Unix 秒，字段可缺省）。
/// 这是标准来源；节点名里的「套餐信息」条目只是它的兜底展示。
public struct SubscriptionUsage: Codable, Hashable, Sendable {
    public var uploadBytes: Int64?
    public var downloadBytes: Int64?
    public var totalBytes: Int64?
    public var expiresAt: Date?

    public init(
        uploadBytes: Int64? = nil,
        downloadBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        expiresAt: Date? = nil
    ) {
        self.uploadBytes = uploadBytes
        self.downloadBytes = downloadBytes
        self.totalBytes = totalBytes
        self.expiresAt = expiresAt
    }

    /// 上下行合计。两个字段都缺省时视为未知，而不是 0。
    public var usedBytes: Int64? {
        if uploadBytes == nil && downloadBytes == nil { return nil }
        return (uploadBytes ?? 0) + (downloadBytes ?? 0)
    }

    public static func parse(headerValue: String) -> SubscriptionUsage? {
        var fields: [String: Int64] = [:]
        for pair in headerValue.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            // 个别面板会下发小数或科学计数（expire=1.7e9），按 Double 读再取整。
            guard let value = Double(parts[1].trimmingCharacters(in: .whitespaces)),
                  value.isFinite, value >= 0 else { continue }
            fields[key] = Int64(value)
        }
        guard !fields.isEmpty else { return nil }
        return SubscriptionUsage(
            uploadBytes: fields["upload"],
            downloadBytes: fields["download"],
            totalBytes: fields["total"],
            expiresAt: fields["expire"].flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        )
    }
}

public struct SubscriptionSource: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var url: URL
    public var lastUpdatedAt: Date?
    /// 是否参与定时自动更新。手动「刷新订阅」不受此开关限制。
    public var autoUpdate: Bool
    /// 最近一次成功刷新时服务器下发的配额信息；服务器不下发时保留旧值。
    public var usage: SubscriptionUsage?

    public init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        lastUpdatedAt: Date? = nil,
        autoUpdate: Bool = true,
        usage: SubscriptionUsage? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.lastUpdatedAt = lastUpdatedAt
        self.autoUpdate = autoUpdate
        self.usage = usage
    }

    /// 旧版订阅文件没有这些字段，解码时按旧行为补默认值。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(URL.self, forKey: .url)
        lastUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
        autoUpdate = try container.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? true
        usage = try container.decodeIfPresent(SubscriptionUsage.self, forKey: .usage)
    }
}

extension ProxyNode {
    /// 机场常把套餐信息塞进节点名下发（剩余流量、重置日、到期日、官网等）。
    /// 这些条目是合法 outbound，但没有实际代理用途，界面上应作为订阅信息展示而非可选节点。
    public var isSubscriptionInfo: Bool {
        let value = name.trimmingCharacters(in: .whitespaces)
        let keywords = [
            "流量", "剩余", "到期", "过期", "重置", "官网", "套餐", "续费", "购买", "邀请",
            "expire", "traffic", "reset", "remaining", "official", "renew", "plan"
        ]
        let lowercased = value.lowercased()
        if keywords.contains(where: { lowercased.contains($0) }) { return true }
        // 形如 “491.89 G | 500.00 G” 的用量展示
        return value.range(
            of: "^[0-9.]+\\s*[KMGTP]?B?\\s*[|/]\\s*[0-9.]+\\s*[KMGTP]?B?$",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}
