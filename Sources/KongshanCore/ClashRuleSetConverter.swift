import Foundation
import Yams

/// 一份规则集的匹配内容（已按 sing-box 语义归类）。
///
/// 同时服务三方：生成给内核的 sing-box 规则集源码、DNS 用的纯域名版本，
/// 以及规则页「命中测试」在本地判定一条规则集是否命中。
public struct RuleSetContent: Equatable, Sendable {
    public var domain: [String] = []
    public var domainSuffix: [String] = []
    public var domainKeyword: [String] = []
    public var domainRegex: [String] = []
    public var ipCIDR: [String] = []
    public var processName: [String] = []
    public var processPath: [String] = []

    public init() {}

    public var entryCount: Int {
        domain.count + domainSuffix.count + domainKeyword.count + domainRegex.count
            + ipCIDR.count + processName.count + processPath.count
    }

    public var isEmpty: Bool { entryCount == 0 }

    /// 是否含域名类条件。只有这类条件能进 DNS 规则。
    public var hasDomainConditions: Bool {
        !domain.isEmpty || !domainSuffix.isEmpty || !domainKeyword.isEmpty || !domainRegex.isEmpty
    }

    /// sing-box 规则集源码（version 1）。
    ///
    /// **进程条件必须各自单独成一条。** sing-box 的无头规则里，域名 / IP 条件之间是「或」，
    /// 但它们与 `process_name` / `process_path` 之间是「与」——把 `domain_suffix` 和 `process_name`
    /// 写进同一条，得到的是「这个进程**并且**访问这些域名」，而不是「这个进程**或**这些域名」。
    /// 规则集里的多条规则之间才是「或」。（服务端曾因此踩坑：直连名单只对名单里的进程生效。）
    public func singBoxSource() -> [String: Any] {
        var rules: [[String: Any]] = []
        var addressRule: [String: Any] = [:]
        if !domain.isEmpty { addressRule["domain"] = domain }
        if !domainSuffix.isEmpty { addressRule["domain_suffix"] = domainSuffix }
        if !domainKeyword.isEmpty { addressRule["domain_keyword"] = domainKeyword }
        if !domainRegex.isEmpty { addressRule["domain_regex"] = domainRegex }
        if !ipCIDR.isEmpty { addressRule["ip_cidr"] = ipCIDR }
        if !addressRule.isEmpty { rules.append(addressRule) }
        if !processName.isEmpty { rules.append(["process_name": processName]) }
        if !processPath.isEmpty { rules.append(["process_path": processPath]) }
        return ["version": 1, "rules": rules]
    }

    /// DNS 专用的纯域名版本；没有域名条件时为 nil。
    ///
    /// DNS 规则只能按域名匹配：`ip_cidr` 在解析阶段还没有 IP；`process_name` 在 TUN 下
    /// 对应的是发起查询的系统解析进程而不是应用本身——两者放进 DNS 规则要么不生效、要么判错。
    public func singBoxDNSSource() -> [String: Any]? {
        guard hasDomainConditions else { return nil }
        var rule: [String: Any] = [:]
        if !domain.isEmpty { rule["domain"] = domain }
        if !domainSuffix.isEmpty { rule["domain_suffix"] = domainSuffix }
        if !domainKeyword.isEmpty { rule["domain_keyword"] = domainKeyword }
        if !domainRegex.isEmpty { rule["domain_regex"] = domainRegex }
        return ["version": 1, "rules": [rule]]
    }

    /// 从 sing-box 源码读回（合并各条规则的字段）。只用于读回本 App 自己写出的文件——
    /// 我们写出的每条规则只含一类条件，合并后逐项「或」判定与原语义一致。
    public init(singBoxSource root: [String: Any]) {
        for rule in (root["rules"] as? [[String: Any]]) ?? [] {
            domain += rule["domain"] as? [String] ?? []
            domainSuffix += rule["domain_suffix"] as? [String] ?? []
            domainKeyword += rule["domain_keyword"] as? [String] ?? []
            domainRegex += rule["domain_regex"] as? [String] ?? []
            ipCIDR += rule["ip_cidr"] as? [String] ?? []
            processName += rule["process_name"] as? [String] ?? []
            processPath += rule["process_path"] as? [String] ?? []
        }
    }

    /// 去重（保持首次出现的顺序），让输出可复现、体积最小。
    mutating func deduplicate() {
        func unique(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.filter { seen.insert($0).inserted }
        }
        domain = unique(domain)
        domainSuffix = unique(domainSuffix)
        domainKeyword = unique(domainKeyword)
        domainRegex = unique(domainRegex)
        ipCIDR = unique(ipCIDR)
        processName = unique(processName)
        processPath = unique(processPath)
    }
}

public enum ClashRuleSetConversionError: Error, Equatable, LocalizedError {
    case invalidYAML
    case missingPayload
    case tooManyEntries(count: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidYAML: "规则集不是合法的 YAML"
        case .missingPayload: "规则集缺少 payload 列表"
        case let .tooManyEntries(count, limit): "规则集含 \(count) 条，超过 \(limit) 条上限"
        }
    }
}

/// Clash 规则集（`rule-providers` 下载回来的文件）→ `RuleSetContent`。
public enum ClashRuleSetConverter {
    public struct Result: Sendable {
        public let content: RuleSetContent
        /// 跳过的条目：类型 → 条数。不静默丢弃，供告警说明。
        public let skipped: [String: Int]
    }

    public static func convert(
        _ data: Data,
        behavior: SubscriptionRuleProvider.Behavior,
        format: SubscriptionRuleProvider.Format,
        entryLimit: Int = SubscriptionInputLimits.ruleSetEntryLimit
    ) throws -> Result {
        let text = String(decoding: data, as: UTF8.self)
        let lines: [String]
        switch format {
        case .yaml: lines = try payloadLines(yaml: text)
        case .text: lines = textLines(text)
        }
        guard lines.count <= entryLimit else {
            throw ClashRuleSetConversionError.tooManyEntries(count: lines.count, limit: entryLimit)
        }

        var content = RuleSetContent()
        var skipped: [String: Int] = [:]
        for line in lines {
            let accepted = switch behavior {
            case .classical: addClassical(line, to: &content)
            case .domain: addDomainEntry(line, to: &content)
            case .ipcidr: addCIDR(line, to: &content)
            }
            if !accepted {
                let key = behavior == .classical
                    ? (line.split(separator: ",").first.map(String.init)?.uppercased() ?? line)
                    : behavior.rawValue
                skipped[key, default: 0] += 1
            }
        }
        content.deduplicate()
        return Result(content: content, skipped: skipped)
    }

    // MARK: - 读行

    /// YAML 的 `payload:` 列表。先卡体积与别名——规则集文件同样是外部不可信输入，
    /// 别名炸弹对它一样有效（见 `SubscriptionInputLimits`）。
    static func payloadLines(yaml: String) throws -> [String] {
        try SubscriptionInputLimits.validate(yaml: yaml)
        guard let root = try Yams.load(yaml: yaml) as? [String: Any] else {
            throw ClashRuleSetConversionError.invalidYAML
        }
        guard let payload = root["payload"] as? [Any] else {
            throw ClashRuleSetConversionError.missingPayload
        }
        return payload.compactMap { item in
            let line = "\(item)".trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? nil : line
        }
    }

    static func textLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("//") else { return nil }
            return line
        }
    }

    // MARK: - 逐条归类

    /// classical：`类型,值[,选项…]`。
    static func addClassical(_ line: String, to content: inout RuleSetContent) -> Bool {
        let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, !parts[1].isEmpty else { return false }
        let value = parts[1]
        switch parts[0].uppercased() {
        case "DOMAIN": content.domain.append(value.lowercased())
        case "DOMAIN-SUFFIX": content.domainSuffix.append(value.lowercased())
        case "DOMAIN-KEYWORD": content.domainKeyword.append(value.lowercased())
        case "DOMAIN-REGEX": content.domainRegex.append(value)
        case "IP-CIDR", "IP-CIDR6":
            guard let cidr = normalizedCIDR(value) else { return false }
            content.ipCIDR.append(cidr)
        case "PROCESS-NAME": content.processName.append(value)
        case "PROCESS-PATH": content.processPath.append(value)
        default:
            // DST-PORT / SRC-IP-CIDR / GEOSITE / AND / OR / NOT / 嵌套 RULE-SET …：
            // 要么需要额外数据，要么无法在规则集里等价表达。跳过并计数，不猜。
            return false
        }
        return true
    }

    /// domain：mihomo 的写法。
    /// `+.a.com` → 本身与全部子域；`.a.com` → 仅子域；`*.a.com` → 仅一级子域；`a.com` → 精确。
    static func addDomainEntry(_ raw: String, to content: inout RuleSetContent) -> Bool {
        let entry = raw.lowercased()
        if entry.hasPrefix("+.") {
            let suffix = String(entry.dropFirst(2))
            guard isPlainDomain(suffix) else { return false }
            content.domainSuffix.append(suffix)
        } else if entry.hasPrefix("*.") {
            let rest = String(entry.dropFirst(2))
            guard isPlainDomain(rest) else { return false }
            content.domainRegex.append("^[^.]+\\." + NSRegularExpression.escapedPattern(for: rest) + "$")
        } else if entry.hasPrefix(".") {
            let rest = String(entry.dropFirst())
            guard isPlainDomain(rest) else { return false }
            // sing-box 的 domain_suffix 以点开头时只匹配子域，正好对应 mihomo 的 `.a.com`。
            content.domainSuffix.append("." + rest)
        } else {
            guard isPlainDomain(entry) else { return false }
            content.domain.append(entry)
        }
        return true
    }

    /// ipcidr：每行一个网段；裸 IP 按单地址处理。
    static func addCIDR(_ raw: String, to content: inout RuleSetContent) -> Bool {
        guard let cidr = normalizedCIDR(raw) else { return false }
        content.ipCIDR.append(cidr)
        return true
    }

    /// 校验并规整 CIDR；裸地址补成 /32 或 /128。
    static func normalizedCIDR(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        let candidate = value.contains("/") ? value : value + (value.contains(":") ? "/128" : "/32")
        return CustomRouteRule.isValidCIDR(candidate) ? candidate : nil
    }

    /// 没有通配符、空白与非法字符的域名（允许单段，如 `internal`、`local`）。
    static func isPlainDomain(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 253 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "." || scalar == "_"
        } && !value.hasPrefix(".") && !value.hasSuffix(".") && !value.contains("..")
    }
}

extension RuleSetContent {
    /// 在本地判定一条输入是否命中；命中返回命中的那一项（供规则页说明），否则 nil。
    ///
    /// 语义与内核一致：域名、IP、进程三类条件之间是「或」（生成时已拆成独立规则）。
    /// 输入的域名已规整为小写（`RouteTestInput`），规则集里的域名在转换时也已小写。
    public func firstMatch(_ input: RouteTestInput) -> String? {
        if let domain = input.domain, !domain.isEmpty {
            if let hit = self.domain.first(where: { $0 == domain }) { return "完整域名 \(hit)" }
            if let hit = domainSuffix.first(where: { Self.suffix($0, matches: domain) }) { return "域名后缀 \(hit)" }
            if let hit = domainKeyword.first(where: { domain.contains($0) }) { return "域名关键词 \(hit)" }
            if let hit = domainRegex.first(where: { Self.regex($0, matches: domain) }) { return "域名正则 \(hit)" }
        }
        if let ip = input.ip, !ip.isEmpty,
           let hit = ipCIDR.first(where: { CustomRouteRule.cidr($0, contains: ip) }) {
            return "IP \(hit)"
        }
        if let process = input.processName, !process.isEmpty,
           let hit = processName.first(where: { $0.caseInsensitiveCompare(process) == .orderedSame }) {
            return "进程 \(hit)"
        }
        return nil
    }

    /// sing-box 语义：以点开头只匹配子域；否则匹配本身与全部子域（带点边界，`example.com` 不匹配 `badexample.com`）。
    static func suffix(_ suffix: String, matches domain: String) -> Bool {
        if suffix.hasPrefix(".") { return domain.hasSuffix(suffix) }
        return domain == suffix || domain.hasSuffix("." + suffix)
    }

    static func regex(_ pattern: String, matches domain: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: domain, range: NSRange(domain.startIndex..., in: domain)) != nil
    }
}
