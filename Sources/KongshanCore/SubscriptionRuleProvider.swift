import Foundation

/// Clash 订阅里 `rule-providers` 的一项：一份远程规则集。
///
/// 订阅的 `rules:` 用 `RULE-SET,<名称>,<目标>` 引用它，匹配内容在 `url` 指向的文件里。
/// 这些文件由 App 下载、转换成 sing-box 规则集后落在自己的数据目录——特权助手只允许内核读
/// 被钉死用户的 App 支持目录里的**本地**规则集，远程规则集一律拒绝（`HelperConfigWhitelist`）。
public struct SubscriptionRuleProvider: Codable, Equatable, Hashable, Sendable {
    /// 规则集内容的写法。
    public enum Behavior: String, Codable, Sendable {
        /// 每行一条带类型的规则：`DOMAIN-SUFFIX,example.com`、`PROCESS-NAME,foo` …
        case classical
        /// 每行一个域名：`example.com` 精确、`+.example.com` 含子域、`.example.com` 仅子域。
        case domain
        /// 每行一个 CIDR。
        case ipcidr
    }

    /// 文件格式。mihomo 的二进制 `mrs` 不支持（没有公开规格），解析时跳过并告警。
    public enum Format: String, Codable, Sendable {
        /// `payload:` 列表。
        case yaml
        /// 纯文本，每行一条。
        case text
    }

    public let name: String
    public let url: URL
    public let behavior: Behavior
    public let format: Format
    /// 订阅建议的刷新周期（秒）；nil 表示未指定。
    public let interval: TimeInterval?

    public init(name: String, url: URL, behavior: Behavior, format: Format, interval: TimeInterval?) {
        self.name = name
        self.url = url
        self.behavior = behavior
        self.format = format
        self.interval = interval
    }

    /// 从 `rule-providers` 的一项解析。不支持的形态返回 nil 并在 `reason` 里说明原因。
    static func parse(name: String, entry: [String: Any]) -> (provider: SubscriptionRuleProvider?, reason: String?) {
        let type = (entry["type"] as? String)?.lowercased() ?? "http"
        guard type == "http" else {
            // `file` 指向机场服务器本机路径，`inline` 是 mihomo 扩展，都拿不到内容。
            return (nil, "\(name)：不支持 type=\(type) 的规则集")
        }
        guard let raw = entry["url"] as? String,
              let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return (nil, "\(name)：规则集地址不是 http(s)")
        }
        let behaviorRaw = (entry["behavior"] as? String)?.lowercased() ?? "classical"
        guard let behavior = Behavior(rawValue: behaviorRaw) else {
            return (nil, "\(name)：不支持 behavior=\(behaviorRaw)")
        }
        let formatRaw = (entry["format"] as? String)?.lowercased() ?? "yaml"
        guard let format = Format(rawValue: formatRaw) else {
            return (nil, "\(name)：不支持 format=\(formatRaw) 的规则集")
        }
        let interval: TimeInterval? = if let seconds = entry["interval"] as? Int, seconds > 0 {
            TimeInterval(seconds)
        } else {
            nil
        }
        return (
            SubscriptionRuleProvider(name: name, url: url, behavior: behavior, format: format, interval: interval),
            nil
        )
    }
}
