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

public struct SubscriptionSource: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var url: URL
    public var lastUpdatedAt: Date?

    public init(id: UUID = UUID(), name: String, url: URL, lastUpdatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.lastUpdatedAt = lastUpdatedAt
    }
}
