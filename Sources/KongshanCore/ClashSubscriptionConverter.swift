import Foundation
@preconcurrency import Yams

public struct SubscriptionConversionResult: Sendable {
    public let nodes: [ProxyNode]
    public let warnings: [String]

    public init(nodes: [ProxyNode], warnings: [String]) {
        self.nodes = nodes
        self.warnings = warnings
    }
}

public enum SubscriptionConversionError: Error, Equatable, LocalizedError {
    case missingProxies
    case noSupportedNodes

    public var errorDescription: String? {
        switch self {
        case .missingProxies: "订阅中缺少 proxies 列表"
        case .noSupportedNodes: "订阅中没有可用的受支持节点"
        }
    }
}

public enum ClashSubscriptionConverter {
    public static func convert(yaml: String, sourceID: UUID) throws -> SubscriptionConversionResult {
        guard let root = try Yams.load(yaml: yaml) as? [String: Any],
              let proxies = root["proxies"] as? [[String: Any]] else {
            throw SubscriptionConversionError.missingProxies
        }

        var nodes: [ProxyNode] = []
        var warnings: [String] = []
        for raw in proxies {
            do {
                nodes.append(try map(raw, sourceID: sourceID))
            } catch {
                let name = optionalString(raw, "name") ?? "未命名"
                warnings.append("\(name): \(error.localizedDescription)")
            }
        }

        guard !nodes.isEmpty else { throw SubscriptionConversionError.noSupportedNodes }
        return SubscriptionConversionResult(nodes: nodes, warnings: warnings)
    }

    private static func map(_ raw: [String: Any], sourceID: UUID) throws -> ProxyNode {
        let name = try requiredString(raw, "name")
        let type = try requiredString(raw, "type").lowercased()
        let server = try requiredString(raw, "server")
        let port = try requiredPort(raw)
        let sni = optionalString(raw, "sni") ?? optionalString(raw, "servername")
        let skipCertificateVerification = bool(raw, "skip-cert-verify")
        let transport = try transport(raw)

        switch type {
        case "ss", "shadowsocks":
            return ProxyNode(
                sourceID: sourceID,
                name: name,
                protocolType: .shadowsocks,
                server: server,
                port: port,
                password: try requiredString(raw, "password"),
                method: try requiredString(raw, "cipher"),
                transport: transport
            )

        case "trojan":
            return ProxyNode(
                sourceID: sourceID,
                name: name,
                protocolType: .trojan,
                server: server,
                port: port,
                password: try requiredString(raw, "password"),
                tlsEnabled: true,
                sni: sni,
                skipCertificateVerification: skipCertificateVerification,
                transport: transport
            )

        case "vmess":
            return ProxyNode(
                sourceID: sourceID,
                name: name,
                protocolType: .vmess,
                server: server,
                port: port,
                uuid: try requiredString(raw, "uuid"),
                security: optionalString(raw, "cipher") ?? optionalString(raw, "security") ?? "auto",
                alterID: int(raw, "alterId") ?? int(raw, "alter-id"),
                tlsEnabled: bool(raw, "tls"),
                sni: sni,
                skipCertificateVerification: skipCertificateVerification,
                transport: transport
            )

        case "hysteria2", "hy2":
            if let obfs = optionalString(raw, "obfs"), obfs.lowercased() != "salamander" {
                throw NodeMappingError.unsupportedObfs(obfs)
            }
            return ProxyNode(
                sourceID: sourceID,
                name: name,
                protocolType: .hysteria2,
                server: server,
                port: port,
                password: try requiredString(raw, "password"),
                tlsEnabled: true,
                sni: sni,
                skipCertificateVerification: skipCertificateVerification,
                obfsPassword: optionalString(raw, "obfs-password"),
                uploadMbps: bandwidth(raw, "up"),
                downloadMbps: bandwidth(raw, "down")
            )

        case "anytls":
            return ProxyNode(
                sourceID: sourceID,
                name: name,
                protocolType: .anytls,
                server: server,
                port: port,
                password: try requiredString(raw, "password"),
                tlsEnabled: true,
                sni: sni,
                skipCertificateVerification: skipCertificateVerification
            )

        default:
            throw NodeMappingError.unsupportedProtocol(type)
        }
    }

    private static func transport(_ raw: [String: Any]) throws -> TransportOptions? {
        guard let network = optionalString(raw, "network")?.lowercased() else { return nil }
        switch network {
        case "ws":
            let options = raw["ws-opts"] as? [String: Any]
            let rawHeaders = options?["headers"] as? [String: Any] ?? [:]
            let headers = rawHeaders.reduce(into: [String: String]()) { result, item in
                result[item.key] = String(describing: item.value)
            }
            return TransportOptions(
                kind: .websocket,
                path: optionalString(options ?? [:], "path"),
                headers: headers
            )
        case "grpc":
            let options = raw["grpc-opts"] as? [String: Any]
            return TransportOptions(
                kind: .grpc,
                serviceName: optionalString(options ?? [:], "grpc-service-name")
                    ?? optionalString(options ?? [:], "service-name")
            )
        default:
            throw NodeMappingError.unsupportedTransport(network)
        }
    }

    private static func requiredPort(_ raw: [String: Any]) throws -> Int {
        guard let port = int(raw, "port"), (1...65_535).contains(port) else {
            throw NodeMappingError.invalidPort
        }
        return port
    }

    private static func requiredString(_ raw: [String: Any], _ key: String) throws -> String {
        guard let value = optionalString(raw, key) else { throw NodeMappingError.missingField(key) }
        return value
    }

    private static func optionalString(_ raw: [String: Any], _ key: String) -> String? {
        guard let value = raw[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func int(_ raw: [String: Any], _ key: String) -> Int? {
        if let value = raw[key] as? Int { return value }
        if let value = raw[key] as? String { return Int(value) }
        return nil
    }

    private static func bool(_ raw: [String: Any], _ key: String) -> Bool {
        if let value = raw[key] as? Bool { return value }
        if let value = raw[key] as? String { return ["true", "yes", "1"].contains(value.lowercased()) }
        return false
    }

    private static func bandwidth(_ raw: [String: Any], _ key: String) -> Int? {
        if let value = int(raw, key) { return value > 0 ? value : nil }
        guard let text = optionalString(raw, key),
              let digits = text.split(whereSeparator: { !$0.isNumber }).first,
              let value = Int(digits), value > 0 else { return nil }
        return value
    }
}

private enum NodeMappingError: Error, LocalizedError {
    case missingField(String)
    case invalidPort
    case unsupportedProtocol(String)
    case unsupportedTransport(String)
    case unsupportedObfs(String)

    var errorDescription: String? {
        switch self {
        case let .missingField(field): "缺少 \(field)"
        case .invalidPort: "port 必须在 1 到 65535 之间"
        case let .unsupportedProtocol(value): "不支持的协议 \(value)"
        case let .unsupportedTransport(value): "不支持的传输方式 \(value)"
        case let .unsupportedObfs(value): "不支持的 Hysteria2 obfs \(value)"
        }
    }
}
