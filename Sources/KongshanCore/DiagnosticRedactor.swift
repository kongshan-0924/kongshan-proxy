import Foundation

/// 「可公开分享」的诊断包：在凭据脱敏（`ConfigGenerator.diagnosticSnapshot`）之上，
/// 再隐去能指认人或网络的值。
///
/// 存在的理由：原有导出只去掉凭据，节点服务器地址与端口、SNI、自定义规则 / 绕过列表、内网 DNS、
/// 告警原文里的地址，以及内核日志里逐条的访问目标都原样带出；贴到公开场合就全漏了。
/// 保留的是排查真正要看的东西：结构、类型、标签、规则顺序与出站去向——「哪条规则把流量送去了哪」。
public enum DiagnosticRedactor {
    /// 规则里承载具体值的字段（route 与 dns 规则通用）。
    static let ruleValueKeys: Set<String> = [
        "domain", "domain_suffix", "domain_keyword", "domain_regex",
        "ip_cidr", "source_ip_cidr", "process_name", "process_path", "port", "source_port"
    ]

    /// 内置、人人相同、不指认任何人的值，留着方便看懂规则。
    static let publicRuleValues: Set<String> = Set(ConfigGenerator.nonexistentSuffixes)
        .union(["local", "home.arpa", "in-addr.arpa", "ip6.arpa", "_dns-sd._udp", ConfigGenerator.tunFakeIPv4Range])

    /// 出站里指认服务器的字段：地址、SNI、伪装域名（`host` / `Host` 头）。
    static let addressKeys: Set<String> = ["server", "server_name", "host", "Host"]

    public static func shareableConfig(from fullConfig: Data) throws -> Data {
        let snapshot = try ConfigGenerator.diagnosticSnapshot(from: fullConfig)
        guard var root = try JSONSerialization.jsonObject(with: snapshot) as? [String: Any] else {
            throw ConfigGenerationError.invalidJSON
        }
        var aliases: [String: String] = [:]
        if let outbounds = root["outbounds"] as? [[String: Any]] {
            root["outbounds"] = outbounds.map { hideAddresses(in: $0, aliases: &aliases) as? [String: Any] ?? $0 }
        }
        if var dns = root["dns"] as? [String: Any] {
            if let servers = dns["servers"] as? [[String: Any]] {
                dns["servers"] = servers.map { server in
                    var server = server
                    if let address = server["server"] as? String { server["server"] = alias(address, &aliases) }
                    return server
                }
            }
            if let rules = dns["rules"] as? [[String: Any]] { dns["rules"] = rules.map(hideRuleValues) }
            root["dns"] = dns
        }
        if var route = root["route"] as? [String: Any] {
            if let rules = route["rules"] as? [[String: Any]] { route["rules"] = rules.map(hideRuleValues) }
            root["route"] = route
        }
        if let inbounds = root["inbounds"] as? [[String: Any]] {
            root["inbounds"] = inbounds.map { inbound in
                var inbound = inbound
                if let excluded = inbound["route_exclude_address"] as? [String] {
                    inbound["route_exclude_address"] = hidden(excluded)
                }
                return inbound
            }
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// 自由文本（运行事件、告警存档、警告）：名字换成编号，地址与链接隐去。
    /// `names` 是 (原名, 代号)；只换 3 个字以上的名字——太短的（如「全部」）会误伤标题里的同形字。
    public static func redactText(_ text: String, replacing names: [(String, String)]) -> String {
        var result = text
        for (name, label) in names.filter({ $0.0.count >= 3 }).sorted(by: { $0.0.count > $1.0.count }) {
            result = result.replacingOccurrences(of: name, with: label)
        }
        result = replace(urlPattern, in: result, with: "<链接>")
        result = replace(ipv4Pattern, in: result, with: "<IP>")
        // IPv6 的候选与时间（12:31:55）同形：必须含 `::` 或十六进制字母才算地址。
        result = replace(ipv6Pattern, in: result) { candidate in
            candidate.contains("::") || candidate.contains(where: { "abcdefABCDEF".contains($0) }) ? "<IP>" : nil
        }
        return result
    }

    // MARK: - 实现

    private static func hideAddresses(in value: Any, aliases: inout [String: String]) -> Any {
        if var dictionary = value as? [String: Any] {
            // 按键名排序遍历：代号按出现顺序编号，字典的遍历顺序每次运行都不同，不排序同一份配置会得到不同代号。
            for key in dictionary.keys.sorted() {
                let nested = dictionary[key]!
                if addressKeys.contains(key), let string = nested as? String {
                    dictionary[key] = alias(string, &aliases)
                } else if addressKeys.contains(key), let strings = nested as? [String] {
                    dictionary[key] = strings.map { alias($0, &aliases) }
                } else if key == "path", nested is String {
                    // ws / http 传输的路径常带鉴权片段。
                    dictionary[key] = "<已隐藏>"
                } else {
                    dictionary[key] = hideAddresses(in: nested, aliases: &aliases)
                }
            }
            return dictionary
        }
        if let array = value as? [Any] {
            return array.map { hideAddresses(in: $0, aliases: &aliases) }
        }
        return value
    }

    /// 同一个值始终换成同一个代号：哪些节点共用一台服务器、DNS 是不是同一台，这些关系还看得出来。
    private static func alias(_ value: String, _ aliases: inout [String: String]) -> String {
        if let existing = aliases[value] { return existing }
        let label = "server-\(aliases.count + 1).example"
        aliases[value] = label
        return label
    }

    private static func hideRuleValues(_ rule: [String: Any]) -> [String: Any] {
        var rule = rule
        for key in ruleValueKeys {
            if let values = rule[key] as? [String] {
                rule[key] = hidden(values)
            } else if let values = rule[key] as? [Int] {
                rule[key] = ["已隐藏 \(values.count) 项"]
            }
        }
        return rule
    }

    private static func hidden(_ values: [String]) -> [String] {
        let kept = values.filter(publicRuleValues.contains)
        let count = values.count - kept.count
        return count == 0 ? kept : kept + ["已隐藏 \(count) 项"]
    }

    private static let urlPattern = try! NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s"'<>）」】]+"#)
    private static let ipv4Pattern = try! NSRegularExpression(
        pattern: #"(?<![\d.])(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}(?:/\d{1,2})?(?![\d.])"#
    )
    private static let ipv6Pattern = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?:/\d{1,3})?(?![0-9A-Fa-f:])"#
    )

    private static func replace(_ pattern: NSRegularExpression, in text: String, with replacement: String) -> String {
        replace(pattern, in: text) { _ in replacement }
    }

    private static func replace(_ pattern: NSRegularExpression, in text: String, _ transform: (String) -> String?) -> String {
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let candidate = source.substring(with: match.range)
            guard let replacement = transform(candidate) else { continue }
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += replacement
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        return result
    }
}
