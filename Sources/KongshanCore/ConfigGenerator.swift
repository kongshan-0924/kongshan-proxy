import Foundation

public struct ConfigInput: Sendable {
    public let nodes: [ProxyNode]
    public let selectedNodeID: UUID?
    public let runtime: RuntimeParameters
    public let testURL: String

    public init(
        nodes: [ProxyNode],
        selectedNodeID: UUID?,
        runtime: RuntimeParameters,
        testURL: String = "http://www.gstatic.com/generate_204"
    ) {
        self.nodes = nodes
        self.selectedNodeID = selectedNodeID
        self.runtime = runtime
        self.testURL = testURL
    }
}

public enum ConfigGenerationError: Error, Equatable, LocalizedError {
    case noNodes
    case selectedNodeMissing
    case missingField(node: String, field: String)
    case invalidJSON

    public var errorDescription: String? {
        switch self {
        case .noNodes: "至少需要一个代理节点"
        case .selectedNodeMissing: "当前选中的节点已不存在"
        case let .missingField(node, field): "节点 \(node) 缺少 \(field)"
        case .invalidJSON: "生成的 sing-box 配置不是有效 JSON"
        }
    }
}

public enum ConfigGenerator {
    public static func outboundTag(for node: ProxyNode) -> String {
        "node-\(node.id.uuidString.lowercased())"
    }

    public static func generate(_ input: ConfigInput) throws -> Data {
        guard !input.nodes.isEmpty else { throw ConfigGenerationError.noNodes }

        let nodeTags = input.nodes.map(outboundTag)
        let selectedTag: String
        if let selectedNodeID = input.selectedNodeID {
            guard let selected = input.nodes.first(where: { $0.id == selectedNodeID }) else {
                throw ConfigGenerationError.selectedNodeMissing
            }
            selectedTag = outboundTag(for: selected)
        } else {
            selectedTag = nodeTags[0]
        }

        var outbounds = try input.nodes.map(outbound)
        outbounds.append([
            "type": "selector",
            "tag": "手动选择",
            "outbounds": nodeTags,
            "default": selectedTag
        ])
        outbounds.append([
            "type": "urltest",
            "tag": "自动选择",
            "outbounds": nodeTags,
            "url": input.testURL,
            "interval": "5m"
        ])

        let manualTags = input.nodes.filter { $0.sourceID == nil }.map(outboundTag)
        if !manualTags.isEmpty {
            outbounds.append([
                "type": "selector",
                "tag": "自建",
                "outbounds": manualTags,
                "default": manualTags[0]
            ])
        }
        outbounds.append(["type": "direct", "tag": "direct"])
        outbounds.append(["type": "block", "tag": "reject"])

        let root: [String: Any] = [
            "log": ["level": "info", "timestamp": true],
            "inbounds": [[
                "type": "mixed",
                "tag": "mixed-in",
                "listen": "127.0.0.1",
                "listen_port": Int(input.runtime.mixedPort)
            ]],
            "outbounds": outbounds,
            "route": ["rules": [], "final": "自动选择"],
            "experimental": [
                "clash_api": [
                    "external_controller": "127.0.0.1:\(input.runtime.clashPort)",
                    "secret": input.runtime.secret
                ]
            ]
        ]
        return try encode(root)
    }

    public static func diagnosticSnapshot(from fullConfig: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: fullConfig) as? [String: Any] else {
            throw ConfigGenerationError.invalidJSON
        }
        if var experimental = root["experimental"] as? [String: Any] {
            experimental.removeValue(forKey: "clash_api")
            if experimental.isEmpty {
                root.removeValue(forKey: "experimental")
            } else {
                root["experimental"] = experimental
            }
        }
        return try encode(root)
    }

    private static func outbound(_ node: ProxyNode) throws -> [String: Any] {
        var value: [String: Any] = [
            "type": node.protocolType.rawValue,
            "tag": outboundTag(for: node),
            "server": node.server,
            "server_port": node.port
        ]

        switch node.protocolType {
        case .shadowsocks:
            value["method"] = try required(node.method, node: node, field: "method")
            value["password"] = try required(node.password, node: node, field: "password")
        case .trojan:
            value["password"] = try required(node.password, node: node, field: "password")
            value["tls"] = tls(for: node)
            if let transport = transport(node.transport) { value["transport"] = transport }
        case .vmess:
            value["uuid"] = try required(node.uuid, node: node, field: "uuid")
            value["security"] = node.security ?? "auto"
            value["alter_id"] = node.alterID ?? 0
            if node.tlsEnabled { value["tls"] = tls(for: node) }
            if let transport = transport(node.transport) { value["transport"] = transport }
        case .hysteria2:
            value["password"] = try required(node.password, node: node, field: "password")
            value["tls"] = tls(for: node)
            if let uploadMbps = node.uploadMbps { value["up_mbps"] = uploadMbps }
            if let downloadMbps = node.downloadMbps { value["down_mbps"] = downloadMbps }
            if let obfsPassword = node.obfsPassword {
                value["obfs"] = ["type": "salamander", "password": obfsPassword]
            }
        case .anytls:
            value["password"] = try required(node.password, node: node, field: "password")
            value["tls"] = tls(for: node)
        }
        return value
    }

    private static func required(_ value: String?, node: ProxyNode, field: String) throws -> String {
        guard let value, !value.isEmpty else {
            throw ConfigGenerationError.missingField(node: node.name, field: field)
        }
        return value
    }

    private static func tls(for node: ProxyNode) -> [String: Any] {
        [
            "enabled": true,
            "server_name": node.sni ?? node.server,
            "insecure": node.skipCertificateVerification
        ]
    }

    private static func transport(_ options: TransportOptions?) -> [String: Any]? {
        guard let options else { return nil }
        switch options.kind {
        case .websocket:
            var value: [String: Any] = ["type": "ws"]
            if let path = options.path { value["path"] = path }
            if !options.headers.isEmpty { value["headers"] = options.headers }
            return value
        case .grpc:
            var value: [String: Any] = ["type": "grpc"]
            if let serviceName = options.serviceName { value["service_name"] = serviceName }
            return value
        }
    }

    private static func encode(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw ConfigGenerationError.invalidJSON }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}
