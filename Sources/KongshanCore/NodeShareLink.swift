import Foundation

public enum NodeShareLinkError: Error, Equatable, LocalizedError {
    case empty
    case unsupportedScheme(String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .empty: "剪贴板里没有内容"
        case let .unsupportedScheme(scheme): "不支持的链接类型：\(scheme)"
        case let .malformed(reason): "链接解析失败：\(reason)"
        }
    }
}

/// 节点分享链接解析。把 `ss://` / `trojan://` / `vmess://` / `vless://` / `hysteria2://` /
/// `anytls://` 粘贴进来直接变成 `ProxyNode`，省掉手填十几个字段。
///
/// 设计取舍：
/// - **只解析，不校验连通性**。字段缺失走各协议的常规默认值，让用户在表单里看到结果再改，
///   而不是直接报错拒掉——半对的表单比一句"链接无效"有用得多。
/// - **宽容对待 base64**：分享链接普遍用 URL-safe 变体且经常省掉 `=` 补位，
///   两种字母表都试、补位自己算。这是实际链接最常见的坏法，不容错等于大半链接都解析不了。
public enum NodeShareLink {
    public static func parse(_ raw: String) throws -> ProxyNode {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NodeShareLinkError.empty }

        guard let separator = text.range(of: "://") else {
            throw NodeShareLinkError.malformed("看起来不是分享链接（缺少 ://）")
        }
        let scheme = text[text.startIndex..<separator.lowerBound].lowercased()
        let body = String(text[separator.upperBound...])

        switch scheme {
        case "ss": return try parseShadowsocks(body)
        case "trojan": return try parseTrojan(body)
        case "vmess": return try parseVMess(body)
        case "vless": return try parseVLESS(body)
        case "hysteria2", "hy2": return try parseHysteria2(body)
        case "anytls": return try parseAnyTLS(body)
        default: throw NodeShareLinkError.unsupportedScheme(scheme)
        }
    }

    /// 从一段文本里挑出所有能解析的分享链接（剪贴板常常是一整批）。
    /// 逐行尝试，解析不了的行安静跳过——批量粘贴时不该被一行坏数据整体拒掉。
    public static func parseAll(_ raw: String) -> [ProxyNode] {
        raw.split(whereSeparator: \.isNewline)
            .compactMap { try? parse(String($0)) }
    }

    // MARK: - 各协议

    private static func parseShadowsocks(_ body: String) throws -> ProxyNode {
        let (main, name) = splitFragment(body)

        // 两种历史格式都要认：
        //   新：base64(method:password)@host:port
        //   旧：base64(method:password@host:port)   —— 整段都被编码
        let userInfo: String
        let hostPart: String
        if let at = main.lastIndex(of: "@") {
            userInfo = String(main[main.startIndex..<at])
            hostPart = String(main[main.index(after: at)...])
        } else {
            guard let decoded = decodeBase64(percentDecoded(main)),
                  let at = decoded.lastIndex(of: "@") else {
                throw NodeShareLinkError.malformed("ss 链接缺少 @host:port")
            }
            userInfo = String(decoded[decoded.startIndex..<at])
            hostPart = String(decoded[decoded.index(after: at)...])
        }

        // userInfo 可能是 base64，也可能已是明文 `method:password`（部分客户端这么发）。
        let credentials = decodeBase64(percentDecoded(userInfo)) ?? percentDecoded(userInfo)
        guard let colon = credentials.firstIndex(of: ":") else {
            throw NodeShareLinkError.malformed("ss 链接缺少 method:password")
        }
        let method = String(credentials[credentials.startIndex..<colon])
        let password = String(credentials[credentials.index(after: colon)...])

        let (host, port, query) = try splitHostPort(hostPart)
        let plugin = try pluginFields(from: query)
        return ProxyNode(
            name: name ?? host,
            protocolType: .shadowsocks,
            server: host,
            port: port,
            password: password,
            method: try kernelShadowsocksMethod(method),
            pluginName: plugin?.name,
            pluginOptions: plugin?.options
        )
    }

    private static func parseTrojan(_ body: String) throws -> ProxyNode {
        let (main, name) = splitFragment(body)
        let (password, hostPart) = try splitUserInfo(main, field: "trojan 密码")
        let (host, port, query) = try splitHostPort(hostPart)

        return ProxyNode(
            name: name ?? host,
            protocolType: .trojan,
            server: host,
            port: port,
            password: percentDecoded(password),
            // Trojan 的全部安全性建立在"看起来是 HTTPS"上，TLS 恒开，链接里不带也一样。
            tlsEnabled: true,
            sni: query["sni"] ?? query["peer"] ?? query["host"],
            skipCertificateVerification: isTruthy(query["allowInsecure"]) || isTruthy(query["insecure"]),
            transport: try transport(from: query)
        )
    }

    private static func parseVMess(_ body: String) throws -> ProxyNode {
        // VMess 的通行格式是整个 JSON 做 base64，不是 URL 结构。
        guard let decoded = decodeBase64(body),
              let data = decoded.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NodeShareLinkError.malformed("vmess 链接不是 base64 编码的 JSON")
        }

        guard let host = string(json["add"]), !host.isEmpty else {
            throw NodeShareLinkError.malformed("vmess 缺少服务器地址")
        }
        guard let port = int(json["port"]) else {
            throw NodeShareLinkError.malformed("vmess 缺少端口")
        }
        let network = (string(json["net"]) ?? "tcp").lowercased()
        let wsHost = string(json["host"])
        let path = string(json["path"])
        var options: TransportOptions?
        switch network {
        case "ws":
            options = TransportOptions(
                kind: .websocket,
                path: path,
                headers: wsHost.map { ["Host": $0] } ?? [:]
            )
        case "grpc":
            options = TransportOptions(kind: .grpc, serviceName: path)
        case "tcp", "":
            options = nil
        default:
            // h2 / kcp / quic / httpupgrade 等内核这里没接：当成裸 TCP 导入会握手后不通，还看不出原因。
            throw NodeShareLinkError.malformed("vmess 传输方式 \(network) 暂不支持")
        }

        let tls = (string(json["tls"]) ?? "").lowercased()
        return ProxyNode(
            name: string(json["ps"]) ?? host,
            protocolType: .vmess,
            server: host,
            port: port,
            uuid: string(json["id"]),
            security: try kernelVMessSecurity(string(json["scy"]) ?? "auto"),
            // alterID 现在恒为 0（AEAD）。老链接里的非 0 值照收，但不去猜。
            alterID: int(json["aid"]) ?? 0,
            tlsEnabled: tls == "tls" || tls == "reality",
            sni: string(json["sni"]) ?? wsHost,
            skipCertificateVerification: isTruthy(string(json["allowInsecure"])),
            transport: options
        )
    }

    private static func parseVLESS(_ body: String) throws -> ProxyNode {
        let (main, name) = splitFragment(body)
        let (uuid, hostPart) = try splitUserInfo(main, field: "vless UUID")
        let (host, port, query) = try splitHostPort(hostPart)

        let security = (query["security"] ?? "none").lowercased()
        let transport = try transport(from: query)
        return ProxyNode(
            name: name ?? host,
            protocolType: .vless,
            server: host,
            port: port,
            uuid: percentDecoded(uuid),
            tlsEnabled: security == "tls" || security == "reality" || security == "xtls",
            sni: query["sni"] ?? query["peer"] ?? query["host"],
            skipCertificateVerification: isTruthy(query["allowInsecure"]) || isTruthy(query["insecure"]),
            transport: transport,
            flow: try kernelVLESSFlow(query["flow"]),
            // 内核认不得的指纹（大小写不对、自造名字）会让整份配置校验失败、所有节点一起不能用：
            // 只收认得的，其余当没写（Reality 节点由配置生成补默认 chrome）。
            utlsFingerprint: query["fp"].map { $0.lowercased() }.flatMap {
                ProxyNode.supportedUTLSFingerprints.contains($0) ? $0 : nil
            },
            // Reality 的公钥/短 ID 在链接里是 pbk/sid。
            realityPublicKey: security == "reality" ? query["pbk"] : nil,
            realityShortID: security == "reality" ? try realityShortID(query["sid"]) : nil,
            // XHTTP 按 ALPN 选 HTTP 版本（h2 / http/1.1）；其余传输不带，理由见 `ProxyNode.alpn`。
            alpn: transport?.kind == .xhttp ? query["alpn"].map { $0.split(separator: ",").map(String.init) } : nil
        )
    }

    private static func parseHysteria2(_ body: String) throws -> ProxyNode {
        let (main, name) = splitFragment(body)
        let (password, hostPart) = try splitUserInfo(main, field: "hysteria2 密码")
        let (host, port, query) = try splitHostPort(hostPart)

        // obfs 目前只有 salamander 一种；密码字段名两种写法都见过。
        let obfs = (query["obfs"] ?? "").lowercased()
        let obfsPassword = obfs.isEmpty ? nil : (query["obfs-password"] ?? query["obfsParam"])
        // 写了 obfs 却没给密码：空密码内核直接拒（整份配置失败），不带 obfs 又连不上。
        if !obfs.isEmpty, obfsPassword?.isEmpty ?? true {
            throw NodeShareLinkError.malformed("hysteria2 开了 obfs 却没有 obfs 密码")
        }

        return ProxyNode(
            name: name ?? host,
            protocolType: .hysteria2,
            server: host,
            port: port,
            password: percentDecoded(password),
            tlsEnabled: true,
            sni: query["sni"] ?? query["peer"],
            skipCertificateVerification: isTruthy(query["insecure"]) || isTruthy(query["allowInsecure"]),
            obfsPassword: obfsPassword,
            uploadMbps: query["upmbps"].flatMap { Int($0) },
            downloadMbps: query["downmbps"].flatMap { Int($0) }
        )
    }

    private static func parseAnyTLS(_ body: String) throws -> ProxyNode {
        let (main, name) = splitFragment(body)
        let (password, hostPart) = try splitUserInfo(main, field: "anytls 密码")
        let (host, port, query) = try splitHostPort(hostPart)

        return ProxyNode(
            name: name ?? host,
            protocolType: .anytls,
            server: host,
            port: port,
            password: percentDecoded(password),
            tlsEnabled: true,
            sni: query["sni"] ?? query["peer"],
            skipCertificateVerification: isTruthy(query["insecure"]) || isTruthy(query["allowInsecure"])
        )
    }

    // MARK: - 通用拆解

    /// 切掉 `#备注`。备注是百分号编码的，且可能含 `#` 之后再无内容。
    private static func splitFragment(_ body: String) -> (main: String, name: String?) {
        guard let hash = body.firstIndex(of: "#") else { return (body, nil) }
        let name = percentDecoded(String(body[body.index(after: hash)...]))
            .trimmingCharacters(in: .whitespaces)
        return (String(body[body.startIndex..<hash]), name.isEmpty ? nil : name)
    }

    /// `userinfo@host:port?query` → (userinfo, `host:port?query`)。
    /// 用 `lastIndex` 而不是 `firstIndex`：密码里可能含 `@`。
    private static func splitUserInfo(_ main: String, field: String) throws -> (String, String) {
        guard let at = main.lastIndex(of: "@") else {
            throw NodeShareLinkError.malformed("缺少 \(field)")
        }
        let userInfo = String(main[main.startIndex..<at])
        guard !userInfo.isEmpty else { throw NodeShareLinkError.malformed("缺少 \(field)") }
        return (userInfo, String(main[main.index(after: at)...]))
    }

    /// `host:port?a=b&c=d` → (host, port, query)。IPv6 字面量写作 `[::1]:443`。
    private static func splitHostPort(_ raw: String) throws -> (String, Int, [String: String]) {
        var rest = raw
        var query: [String: String] = [:]
        if let mark = rest.firstIndex(of: "?") {
            query = parseQuery(String(rest[rest.index(after: mark)...]))
            rest = String(rest[rest.startIndex..<mark])
        }
        // 去掉可能存在的路径部分（`host:port/path`）。
        if let slash = rest.firstIndex(of: "/") {
            rest = String(rest[rest.startIndex..<slash])
        }

        let host: String
        let portText: String
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            portText = after.hasPrefix(":") ? String(after.dropFirst()) : ""
        } else if let colon = rest.lastIndex(of: ":") {
            host = String(rest[rest.startIndex..<colon])
            portText = String(rest[rest.index(after: colon)...])
        } else {
            host = rest
            portText = ""
        }

        guard !host.isEmpty else { throw NodeShareLinkError.malformed("缺少服务器地址") }
        guard let port = Int(portText), (1...65_535).contains(port) else {
            throw NodeShareLinkError.malformed("端口无效：\(portText.isEmpty ? "（空）" : portText)")
        }
        return (host, port, query)
    }

    private static func parseQuery(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            guard let equals = pair.firstIndex(of: "=") else {
                result[String(pair)] = ""
                continue
            }
            let key = String(pair[pair.startIndex..<equals])
            let value = percentDecoded(String(pair[pair.index(after: equals)...]))
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    private static func transport(from query: [String: String]) throws -> TransportOptions? {
        let type = (query["type"] ?? "tcp").lowercased()
        switch type {
        case "ws", "websocket":
            let host = query["host"]
            return TransportOptions(
                kind: .websocket,
                path: query["path"] ?? "/",
                headers: host.map { ["Host": $0] } ?? [:]
            )
        case "grpc":
            return TransportOptions(kind: .grpc, serviceName: query["serviceName"] ?? query["path"])
        case "xhttp", "splithttp":
            let mode = (query["mode"] ?? "auto").lowercased()
            guard TransportOptions.supportedXHTTPModes.contains(mode) else {
                throw NodeShareLinkError.malformed("XHTTP 上下行方式 \(mode) 暂不支持")
            }
            // extra 是 Xray 的进阶 JSON；单独的下行地址（downloadSettings）没接，导入成单通道会连不上。
            let extra = query["extra"].flatMap { Data($0.utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            if extra["downloadSettings"] != nil {
                throw NodeShareLinkError.malformed("XHTTP 单独下行地址（downloadSettings）暂不支持")
            }
            if (query["alpn"] ?? "").lowercased().split(separator: ",").contains("h3") {
                throw NodeShareLinkError.malformed("HTTP/3 的 XHTTP 暂不支持")
            }
            return TransportOptions(
                kind: .xhttp,
                path: query["path"] ?? "/",
                host: query["host"],
                mode: mode,
                xPaddingBytes: extra["xPaddingBytes"] as? String,
                noGRPCHeader: extra["noGRPCHeader"] as? Bool
            )
        case "tcp", "":
            // tcp + headerType=http 是 HTTP 伪装，不是裸 TCP。
            if (query["headerType"] ?? "none").lowercased() != "none" {
                throw NodeShareLinkError.malformed("TCP 伪装 headerType=\(query["headerType"] ?? "") 暂不支持")
            }
            return nil
        default:
            // httpupgrade / h2 / kcp 等这里没接：当成裸 TCP 导入会握手后不通，还看不出原因。
            throw NodeShareLinkError.malformed("传输方式 \(type) 暂不支持")
        }
    }

    /// 枚举字段换成内核写法，内核不认的导入即拒：写进配置会让整份配置校验失败（见 `ProxyNode.supportedShadowsocksMethods`）。
    private static func kernelShadowsocksMethod(_ value: String) throws -> String {
        guard let method = ProxyNode.kernelShadowsocksMethod(value) else {
            throw NodeShareLinkError.malformed("内核不支持的 SS 加密方式 \(value)")
        }
        return method
    }

    private static func kernelVMessSecurity(_ value: String) throws -> String {
        guard let security = ProxyNode.kernelVMessSecurity(value) else {
            throw NodeShareLinkError.malformed("内核不支持的 vmess 加密方式 \(value)")
        }
        return security
    }

    private static func kernelVLESSFlow(_ value: String?) throws -> String? {
        guard let flow = ProxyNode.kernelVLESSFlow(value) else {
            throw NodeShareLinkError.malformed("内核不支持的 flow \(value ?? "")")
        }
        return flow
    }

    /// Reality 短 ID：最多 16 位十六进制、偶数长度。写坏了内核会 hex 解码失败、整份配置不能用。
    private static func realityShortID(_ value: String?) throws -> String? {
        guard let value, !value.isEmpty else { return nil }
        let hex = Set("0123456789abcdefABCDEF")
        guard value.count <= 16, value.count.isMultiple(of: 2), value.allSatisfy(hex.contains) else {
            throw NodeShareLinkError.malformed("Reality 短 ID 无效：\(value)")
        }
        return value
    }

    /// SS 的 SIP003 插件。链接里写成 `plugin=obfs-local;obfs=http;obfs-host=x`。
    ///
    /// 插件名要换成内核认得的：SIP002 示例里的 `simple-obfs` 内核不认，原样写进去整份配置都会被拒。
    /// 与 Clash 订阅路径一致，只接 obfs（与 v2ray-plugin）；其余插件报错，不静默生成坏节点。
    private static func pluginFields(from query: [String: String]) throws -> (name: String, options: String)? {
        guard let raw = query["plugin"], !raw.isEmpty else { return nil }
        var parts = raw.split(separator: ";").map(String.init)
        guard let name = parts.first, !name.isEmpty else { return nil }
        parts.removeFirst()
        let options = parts.joined(separator: ";")
        switch name.lowercased() {
        case "obfs-local", "simple-obfs", "obfs":
            return ("obfs-local", options)
        case "v2ray-plugin":
            return ("v2ray-plugin", options)
        default:
            throw NodeShareLinkError.malformed("SS 插件 \(name) 暂不支持")
        }
    }

    private static func isTruthy(_ value: String?) -> Bool {
        guard let value = value?.lowercased() else { return false }
        return value == "1" || value == "true" || value == "yes"
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func percentDecoded(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    /// 宽容的 base64：URL-safe 字母表 + 自动补位。分享链接里两者都极常见，
    /// 不容错的话大半链接直接解析不了。
    private static func decodeBase64(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        text.removeAll { $0 == "\n" || $0 == "\r" || $0 == "=" }
        guard !text.isEmpty else { return nil }
        let padding = (4 - text.count % 4) % 4
        text += String(repeating: "=", count: padding)
        guard let data = Data(base64Encoded: text), let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        return decoded
    }
}
