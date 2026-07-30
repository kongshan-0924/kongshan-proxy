import Foundation

/// 从 sing-box 的一行日志里抽出结构。
///
/// 内核的行长这样：
/// ```
/// [3235370629 284ms] outbound/vless[node-xxx]: outbound connection to chatgpt.com:443
/// [1524482931 10.0s] connection: open connection to claude.ai:443 using outbound/trojan[...]: lookup ...
/// ```
/// 前缀里的第一个数字是**连接 ID**——同一条连接的所有行共用它。之前界面把整行当纯文本，
/// 于是"某个域名为什么连不上"只能靠肉眼在几千行里找同号的行，这是日志页最不好用的根源。
///
/// 解析全部是宽容的：抽不出来就留 nil，绝不因为格式变化让日志行显示不出来。
public struct CoreLogLine: Equatable, Sendable {
    /// 连接 ID。同一条连接的多行日志共用，是聚合的依据。
    public let connectionID: String?
    /// 目标主机（含端口）。从 `to <host>:<port>` 里抽。
    public let host: String?
    /// 出站/入站标签，如 `outbound/vless`、`inbound/mixed`。
    public let category: String?
    /// 去掉前缀后的正文。前缀里的 ID 和耗时已单独成字段，正文里重复显示只是噪音。
    public let message: String

    public init(connectionID: String?, host: String?, category: String?, message: String) {
        self.connectionID = connectionID
        self.host = host
        self.category = category
        self.message = message
    }

    public static func parse(_ raw: String) -> CoreLogLine {
        var rest = Substring(raw)
        var connectionID: String?

        // 前缀 `[<id> <elapsed>] `。id 必须是纯数字——`[node-xxx]` 之类的方括号不能误吃。
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            let inside = rest[rest.index(after: rest.startIndex)..<close]
            let fields = inside.split(separator: " ")
            if let first = fields.first, first.allSatisfy(\.isNumber), !first.isEmpty {
                connectionID = String(first)
                rest = rest[rest.index(after: close)...].drop(while: { $0 == " " })
            }
        }

        let message = String(rest)
        return CoreLogLine(
            connectionID: connectionID,
            host: extractHost(from: message),
            category: extractCategory(from: message),
            message: message
        )
    }

    /// 抽 ` to <host>:<port>`。内核所有连接行都用这个措辞
    /// （`inbound connection to`、`outbound connection to`、`open connection to`）。
    private static func extractHost(from message: String) -> String? {
        guard let range = message.range(of: " to ") else { return nil }
        let tail = message[range.upperBound...]
        let token = tail.prefix { !$0.isWhitespace }
        guard !token.isEmpty else { return nil }
        // 结尾可能带冒号或逗号（`... to a.com:443 using ...` / `... to a.com:443:`）。
        var host = String(token)
        while let last = host.last, last == ":" || last == "," { host.removeLast() }
        // 必须含 `:` 或 `.` 才认，避免把 `to reject` 之类的词当主机名。
        guard host.contains(":") || host.contains(".") else { return nil }
        return host
    }

    /// 抽 `outbound/vless[...]` 里的 `outbound/vless`。取到第一个 `[` 或 `:` 为止。
    private static func extractCategory(from message: String) -> String? {
        for keyword in ["inbound/", "outbound/", "router", "connection:", "dns"] {
            guard let range = message.range(of: keyword) else { continue }
            let tail = message[range.lowerBound...]
            let token = tail.prefix { $0 != "[" && $0 != ":" && !$0.isWhitespace }
            guard !token.isEmpty else { continue }
            return String(token)
        }
        return nil
    }
}
