import Foundation

/// 单个网络服务此刻的接管相关状态。
public struct NetworkServiceState: Sendable, Equatable, Identifiable {
    /// 服务优先级（1 最高）。macOS **按这个顺序决定用谁的 DNS**——
    /// 这正是 2026-09-16 事故的要害：Thunderbolt Bridge 排在 Wi-Fi 之前，
    /// 它的 DNS 残留指向已消失的 TUN 地址，于是全机解析瘫痪，而用户只会去看 Wi-Fi。
    public let order: Int
    public let name: String
    public let dnsServers: [String]
    public let proxyPort: Int?

    public var id: String { name }

    public init(order: Int, name: String, dnsServers: [String], proxyPort: Int?) {
        self.order = order
        self.name = name
        self.dnsServers = dnsServers
        self.proxyPort = proxyPort
    }
}

public enum NetworkCheckSeverity: String, Sendable, Equatable {
    /// 查过，没问题。
    case ok
    /// 发现了问题并且**已经修好**。
    case fixed
    /// 发现了问题但修不了，需要用户处理。
    case problem
}

public struct NetworkCheckItem: Sendable, Equatable, Identifiable {
    public let title: String
    public let detail: String
    public let severity: NetworkCheckSeverity

    public var id: String { title }

    public init(title: String, detail: String, severity: NetworkCheckSeverity) {
        self.title = title
        self.detail = detail
        self.severity = severity
    }
}

public struct NetworkRepairReport: Sendable, Equatable {
    public let checkedAt: Date
    public let items: [NetworkCheckItem]
    public let services: [NetworkServiceState]

    public init(checkedAt: Date, items: [NetworkCheckItem], services: [NetworkServiceState]) {
        self.checkedAt = checkedAt
        self.items = items
        self.services = services
    }

    public var fixedCount: Int { items.filter { $0.severity == .fixed }.count }
    public var problemCount: Int { items.filter { $0.severity == .problem }.count }

    public var summary: String {
        if problemCount > 0 { return "发现 \(problemCount) 项问题" }
        if fixedCount > 0 { return "已修复 \(fixedCount) 项" }
        return "一切正常"
    }
}

/// `networksetup` 输出的解析。纯函数，便于单测。
public enum NetworkStateParser {
    /// 解析 `networksetup -listnetworkserviceorder`。
    ///
    /// 输出形如：
    /// ```
    /// An asterisk (*) denotes that a network service is disabled.
    /// (1) Thunderbolt Bridge
    /// (Hardware Port: Thunderbolt Bridge, Device: bridge0)
    ///
    /// (2) Wi-Fi
    /// (Hardware Port: Wi-Fi, Device: en0)
    /// ```
    /// `(*)` 前缀表示该服务已停用，一并返回——停用的服务不参与解析，
    /// 但它上面的残留仍然该被清掉，不能因为"停用"就跳过。
    public static func serviceOrder(from output: String) -> [(order: Int, name: String)] {
        var result: [(Int, String)] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            // 只认 "(数字) 名字"；"(Hardware Port: …)" 这类要排除。
            guard text.hasPrefix("("), let close = text.firstIndex(of: ")") else { continue }
            var token = String(text[text.index(after: text.startIndex)..<close])
            if token.hasPrefix("*") { token.removeFirst() }
            guard let order = Int(token) else { continue }
            let name = text[text.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            result.append((order, name))
        }
        return result
    }

    /// 解析 `networksetup -getdnsservers <服务>`。
    /// 未设置时 macOS 返回一句人话而不是空，必须识别出来当成"未设置"。
    public static func dnsServers(from output: String) -> [String] {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.lowercased().contains("aren't any") else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
