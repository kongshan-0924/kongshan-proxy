import Foundation

/// 内核日志刷屏折叠。纯逻辑：调用方逐行喂入，拿回应当落盘的 0~n 行。
///
/// **为什么要有它**：真机 2026-09-26 10:00–11:53 整机断网近两小时。TUN 的默认路由还在，
/// 系统以为有网，各应用平均每秒重试约 15 次；每次尝试内核写约 5 行（入站两行、查进程、出站、失败），
/// 合计每分钟约 4,500 行。日志文件 5 MB 封顶、只留一份旧档（助手那份更是截到只剩约 1 MB），
/// 几分钟就写满一轮——断网前后真正有用的记录十几分钟内就被冲掉，事后复盘时整段都不在了。
///
/// **做法**：10 秒内建连失败达到阈值即进入折叠态。此后带 `[连接ID 耗时]` 前缀的逐条连接日志
/// 不再落盘，改为每分钟一条汇总（省略了多少行、失败多少次，按直连 / 节点 / DNS 与原因分类）；
/// 失败回落并安静一段时间后退出，补一条总结。**不带连接 ID 的行照常落盘**——内核启停、
/// 网卡切换、配置告警这类全局事件正是复盘要看的。
///
/// **只作用于落盘文件**：检测器读的是 Clash API 日志流，不经过这里，折叠不会让告警少看一行。
public struct KernelLogFolder: Sendable {
    public struct Policy: Sendable, Equatable {
        /// 统计失败的滑动窗口（秒）。
        public var window: TimeInterval
        /// 窗口内失败达到这么多次即进入折叠。默认 10 秒 30 次，即持续每秒 3 次——
        /// 真机单个节点故障（2026-09-26 04:23，10 分钟 832 次，约每秒 1.4 次）不会被折叠，细节照常留；
        /// 断网（约每秒 8 次）才会。
        public var enterFailures: Int
        /// 窗口内失败低于这么多次、并持续 `exitQuietPeriod` 秒，才退出折叠；
        /// 完全没有失败满 `exitQuietPeriod` 秒则立即退出。
        public var exitFailures: Int
        public var exitQuietPeriod: TimeInterval
        /// 折叠期间每隔多久写一条汇总（秒）。
        public var summaryInterval: TimeInterval

        public init(
            window: TimeInterval,
            enterFailures: Int,
            exitFailures: Int,
            exitQuietPeriod: TimeInterval,
            summaryInterval: TimeInterval
        ) {
            self.window = window
            self.enterFailures = enterFailures
            self.exitFailures = exitFailures
            self.exitQuietPeriod = exitQuietPeriod
            self.summaryInterval = summaryInterval
        }

        public static let standard = Policy(
            window: 10, enterFailures: 30, exitFailures: 5, exitQuietPeriod: 30, summaryInterval: 60
        )
    }

    /// 一段时间内被省略的行的计数。
    struct Tally: Equatable, Sendable {
        var lines = 0
        var failures = 0
        var byKind: [String: Int] = [:]
        var byReason: [String: Int] = [:]

        mutating func count(_ plain: String, failure: Bool) {
            lines += 1
            guard failure else { return }
            failures += 1
            byKind[KernelLogFolder.failureKind(plain), default: 0] += 1
            byReason[KernelLogFolder.failureReason(plain), default: 0] += 1
        }
    }

    private struct Fold: Sendable {
        var startedAt: Date
        var lastSummaryAt: Date
        /// 窗口内失败首次回落到退出阈值以下的时刻；再次升高时清空。
        var belowSince: Date?
        var sinceSummary = Tally()
        var total = Tally()
    }

    private let policy: Policy
    private let timeZone: TimeZone
    private var recentFailures: [Date] = []
    private var lastFailureAt: Date?
    private var fold: Fold?

    public init(policy: Policy = .standard, timeZone: TimeZone = .current) {
        self.policy = policy
        self.timeZone = timeZone
    }

    public var isFolding: Bool { fold != nil }

    /// 喂入一行（不含换行符），返回应当落盘的行。
    public mutating func process(_ line: String, at date: Date) -> [String] {
        let plain = Self.stripANSI(line)
        let perConnection = Self.isPerConnection(plain)
        let failure = perConnection && Self.isFailure(plain)
        if failure {
            recentFailures.append(date)
            lastFailureAt = date
        }
        let cutoff = date.addingTimeInterval(-policy.window)
        if let firstKept = recentFailures.firstIndex(where: { $0 > cutoff }) {
            if firstKept > 0 { recentFailures.removeFirst(firstKept) }
        } else {
            recentFailures.removeAll(keepingCapacity: true)
        }

        var output: [String] = []
        if var current = fold {
            if shouldExit(&current, at: date) {
                output.append(finalSummary(current, at: date))
                fold = nil
                output.append(line)
                return output
            }
            if date.timeIntervalSince(current.lastSummaryAt) >= policy.summaryInterval,
               current.sinceSummary.lines > 0 {
                output.append(periodicSummary(current, at: date))
                current.sinceSummary = Tally()
                current.lastSummaryAt = date
            }
            fold = current
        } else {
            guard recentFailures.count >= policy.enterFailures else { return [line] }
            fold = Fold(startedAt: date, lastSummaryAt: date)
            output.append(
                stamp(date, level: "WARN")
                    + " kongshan: 建连失败密集（\(Self.formatSeconds(policy.window)) 内 \(recentFailures.count) 次），"
                    + "逐条连接日志暂停落盘，改为每分钟汇总一次"
            )
        }

        if perConnection {
            fold?.sinceSummary.count(plain, failure: failure)
            fold?.total.count(plain, failure: failure)
        } else {
            output.append(line)
        }
        return output
    }

    /// 内核停止或文件收尾时调用：仍在折叠就补一条总结。
    public mutating func finish(at date: Date) -> [String] {
        defer {
            fold = nil
            recentFailures.removeAll()
            lastFailureAt = nil
        }
        guard let current = fold else { return [] }
        return [finalSummary(current, at: date)]
    }

    // MARK: - 状态机

    private func shouldExit(_ current: inout Fold, at date: Date) -> Bool {
        if let lastFailureAt, date.timeIntervalSince(lastFailureAt) >= policy.exitQuietPeriod {
            return true
        }
        guard recentFailures.count < policy.exitFailures else {
            current.belowSince = nil
            return false
        }
        let since = current.belowSince ?? date
        current.belowSince = since
        return date.timeIntervalSince(since) >= policy.exitQuietPeriod
    }

    private func periodicSummary(_ current: Fold, at date: Date) -> String {
        let span = date.timeIntervalSince(current.lastSummaryAt)
        return stamp(date, level: "WARN")
            + " kongshan: 日志折叠中（近 \(Self.formatDuration(span))）：\(Self.describe(current.sinceSummary))"
    }

    private func finalSummary(_ current: Fold, at date: Date) -> String {
        stamp(date, level: "INFO")
            + " kongshan: 日志折叠结束，持续 \(Self.formatDuration(date.timeIntervalSince(current.startedAt)))："
            + Self.describe(current.total)
    }

    private func stamp(_ date: Date, level: String) -> String {
        Self.timestamp(date, timeZone: timeZone) + " " + level
    }

    // MARK: - 行分类（internal：单测直接覆盖）

    /// 去掉 ANSI 颜色码。内核输出到管道时带颜色，连接 ID 本身也会被着色
    /// （`[\e[38;5;217m101789385\e[0m 513ms]`），不先去掉就认不出连接行。
    static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        var result = String.UnicodeScalarView()
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            guard scalar == "\u{1B}" else {
                result.append(scalar)
                continue
            }
            guard let next = iterator.next() else { break }
            guard next == "[" else { continue }
            // CSI 序列：参数与中间字节之后，以 0x40–0x7E 结束。
            while let body = iterator.next() {
                if (0x40...0x7E).contains(body.value) { break }
            }
        }
        return String(result)
    }

    /// 是否为逐条连接日志：正文里有 `[<数字 ID> <耗时>]`。
    /// `[node-xxx]`、`[mixed-in]` 这类方括号不算。
    static func isPerConnection(_ plain: String) -> Bool {
        var remaining = plain[...]
        while let open = remaining.firstIndex(of: "[") {
            let afterOpen = remaining[remaining.index(after: open)...]
            if let close = afterOpen.firstIndex(of: "]") {
                let inside = afterOpen[..<close]
                let fields = inside.split(separator: " ", omittingEmptySubsequences: false)
                if fields.count == 2,
                   !fields[0].isEmpty, fields[0].allSatisfy(\.isASCIIDigitCharacter),
                   let duration = fields[1].first, duration.isASCIIDigitCharacter {
                    return true
                }
                remaining = afterOpen[close...]
            } else {
                return false
            }
        }
        return false
    }

    /// 是否为建连 / 解析失败：逐条连接日志中的 ERROR 行，排除规则主动拒绝与重载时的主动取消。
    /// 广告拦截每命中一次就是一条 `operation not permitted`，算进来会让正常浏览也触发折叠。
    static func isFailure(_ plain: String) -> Bool {
        plain.contains(" ERROR ")
            && !plain.contains("operation not permitted")
            && !plain.contains("context canceled")
    }

    static func failureKind(_ plain: String) -> String {
        if plain.contains("outbound/direct[") { return "直连" }
        if plain.contains(" dns: ") || plain.contains("] dns:") { return "DNS" }
        if plain.contains("using outbound/") { return "节点" }
        return "其他"
    }

    /// 失败原因：去掉地址与端口后的尾段，与出站失败检测的归因口径一致。
    static func failureReason(_ plain: String) -> String {
        let message: Substring
        if let range = plain.range(of: "] ") {
            message = plain[range.upperBound...]
        } else {
            message = plain[...]
        }
        let reason = OutboundFailureDetector.normalizedReason(from: String(message))
        return reason.count > 48 ? String(reason.prefix(48)) + "…" : reason
    }

    // MARK: - 格式

    static func describe(_ tally: Tally) -> String {
        var text = "省略连接日志 \(grouped(tally.lines)) 行"
        guard tally.failures > 0 else { return text }
        let kinds = tally.byKind
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "\($0.key) \(grouped($0.value))" }
            .joined(separator: "、")
        let reasons = tally.byReason
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(3)
            .map { "\($0.key) \(grouped($0.value))" }
            .joined(separator: "、")
        text += "，其中建连失败 \(grouped(tally.failures)) 次（\(kinds)；\(reasons)）"
        return text
    }

    /// 与内核日志一致的时间前缀：`+0800 2026-09-26 10:27:00`。
    public static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = timeZone.secondsFromGMT(for: date)
        let sign = offset >= 0 ? "+" : "-"
        let hours = abs(offset) / 3600
        let minutes = abs(offset) % 3600 / 60
        return String(
            format: "%@%02d%02d %04d-%02d-%02d %02d:%02d:%02d",
            sign, hours, minutes,
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }

    static func grouped(_ value: Int) -> String {
        let digits = String(abs(value))
        var result = ""
        for (index, character) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return value < 0 ? "-" + result : result
    }

    static func formatSeconds(_ seconds: TimeInterval) -> String {
        "\(Int(seconds.rounded())) 秒"
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let secs = total % 60
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        if minutes > 0 { return secs > 0 ? "\(minutes) 分 \(secs) 秒" : "\(minutes) 分" }
        return "\(secs) 秒"
    }
}

private extension Character {
    var isASCIIDigitCharacter: Bool {
        guard let ascii = asciiValue else { return false }
        return (48...57).contains(ascii)
    }
}
