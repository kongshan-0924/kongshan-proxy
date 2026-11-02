import Foundation

public enum ProxyProtocol: String, Codable, CaseIterable, Sendable {
    case shadowsocks
    case trojan
    case vmess
    case vless
    case hysteria2
    case anytls
}

public struct TransportOptions: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case websocket
        case grpc
        /// Xray 的 XHTTP。官方 sing-box 没有，内置内核是官方版本加移植的 XHTTP（Kernel/xhttp）。
        case xhttp
    }

    /// XHTTP 的上下行方式。HTTP/3（alpn h3）没移植，见 `Kernel/xhttp/README.md`。
    public static let supportedXHTTPModes: Set<String> = ["auto", "packet-up", "stream-up", "stream-one"]

    public var kind: Kind
    public var path: String?
    public var headers: [String: String]
    public var serviceName: String?
    /// 以下只给 XHTTP：Host 头、上下行方式、填充长度（如 "100-1000"）、关掉 gRPC 伪装头。
    public var host: String?
    public var mode: String?
    public var xPaddingBytes: String?
    public var noGRPCHeader: Bool?

    public init(
        kind: Kind,
        path: String? = nil,
        headers: [String: String] = [:],
        serviceName: String? = nil,
        host: String? = nil,
        mode: String? = nil,
        xPaddingBytes: String? = nil,
        noGRPCHeader: Bool? = nil
    ) {
        self.kind = kind
        self.path = path
        self.headers = headers
        self.serviceName = serviceName
        self.host = host
        self.mode = mode
        self.xPaddingBytes = xPaddingBytes
        self.noGRPCHeader = noGRPCHeader
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
    public var flow: String?
    public var utlsFingerprint: String?
    public var realityPublicKey: String?
    public var realityShortID: String?
    /// SS 的 SIP003 插件（如 Clash 的 `plugin: obfs`）。直接存 sing-box 用的值：
    /// pluginName="obfs-local"、pluginOptions="obfs=http;obfs-host=…"。缺省＝无插件。
    public var pluginName: String?
    public var pluginOptions: String?
    /// TLS 的 ALPN（订阅的 `alpn`）。给不带传输层的 TLS 节点和 XHTTP 用（XHTTP 按它选 HTTP 版本）；
    /// ws 走 HTTP/1.1 升级，协商成 h2 反而连不上；grpc 由内核自己定。
    public var alpn: [String]?

    /// 内核认得的 uTLS 指纹。订阅写了别的值不能原样交给内核——
    /// 认不出的指纹会让整份配置校验失败，所有节点一起不能用。
    ///
    /// 这一组枚举（指纹、SS 加密、VLESS flow、VMess security）都是 2026-10-25 拿 sing-box 1.14.4
    /// 逐个 `check` 试出来的。**升级内核时用同样的方法重测一遍**：多认的值无害，少认的值会让合法节点被跳过。
    public static let supportedUTLSFingerprints: Set<String> = [
        "chrome", "firefox", "edge", "safari", "360", "qq", "ios", "android", "random", "randomized"
    ]

    static let supportedShadowsocksMethods: Set<String> = [
        "none",
        "aes-128-gcm", "aes-192-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305",
        "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305",
        "aes-128-ctr", "aes-192-ctr", "aes-256-ctr", "aes-128-cfb", "aes-192-cfb", "aes-256-cfb",
        "rc4-md5", "chacha20-ietf", "xchacha20"
    ]

    /// Clash / mihomo 认、内核不认的别名 → 内核写法（同一种算法）。
    static let shadowsocksMethodAliases: [String: String] = [
        "chacha20-poly1305": "chacha20-ietf-poly1305",
        "xchacha20-poly1305": "xchacha20-ietf-poly1305",
        "plain": "none",
        "dummy": "none"
    ]

    static let supportedVMessSecurities: Set<String> = [
        "auto", "none", "zero", "aes-128-gcm", "chacha20-poly1305", "aes-128-cfb"
    ]

    /// 内核能用的 SS 加密写法；内核不认就是 nil（节点该跳过）。
    public static func kernelShadowsocksMethod(_ raw: String) -> String? {
        let method = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mapped = shadowsocksMethodAliases[method] ?? method
        return supportedShadowsocksMethods.contains(mapped) ? mapped : nil
    }

    /// 内核能用的 VLESS flow：空 = 不用 flow。`xtls-rprx-vision-udp443` 是 Xray 的变体（另放行 UDP 443），
    /// 内核只有 vision，换成它握手照样成立。其余值内核不认 → nil。
    public static func kernelVLESSFlow(_ raw: String?) -> String?? {
        let flow = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch flow {
        case "": return .some(nil)
        case "xtls-rprx-vision", "xtls-rprx-vision-udp443": return .some("xtls-rprx-vision")
        default: return nil
        }
    }

    /// 内核能用的 VMess security；内核不认 → nil。
    public static func kernelVMessSecurity(_ raw: String) -> String? {
        let security = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return supportedVMessSecurities.contains(security) ? security : nil
    }

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
        transport: TransportOptions? = nil,
        flow: String? = nil,
        utlsFingerprint: String? = nil,
        realityPublicKey: String? = nil,
        realityShortID: String? = nil,
        pluginName: String? = nil,
        pluginOptions: String? = nil,
        alpn: [String]? = nil
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
        self.flow = flow
        self.utlsFingerprint = utlsFingerprint
        self.realityPublicKey = realityPublicKey
        self.realityShortID = realityShortID
        self.pluginName = pluginName
        self.pluginOptions = pluginOptions
        self.alpn = alpn
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
        let lowercased = value.lowercased()
        if Self.subscriptionInfoKeywords.contains(where: { lowercased.contains($0) }) { return true }
        // 形如 “491.89 G | 500.00 G” 的用量展示。没有分隔符的名字不跑正则——
        // 节点列表每次重绘都可能问到几百个节点（真机 2026-10-08 的卡顿就是它）。
        guard value.contains("|") || value.contains("/") else { return false }
        return value.range(
            of: "^[0-9.]+\\s*[KMGTP]?B?\\s*[|/]\\s*[0-9.]+\\s*[KMGTP]?B?$",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static let subscriptionInfoKeywords = [
        "流量", "剩余", "到期", "过期", "重置", "官网", "套餐", "续费", "购买", "邀请",
        "expire", "traffic", "reset", "remaining", "official", "renew", "plan"
    ]
}
