import Foundation

/// 运行指标的连续流水账。
///
/// **存在的理由是"只记异常"救不了归因。** 现有的自诊断只在越过阈值时留一条事件，
/// 于是：2026-08-28 起 4 天累计 21 小时 CPU，只有 623 秒有记录，其余 99.8% 无从追溯；
/// 2026-09-03 主窗口开着时稳定 5~7%，因为低于 12% 的异常阈值，一条记录都不会有。
/// 阈值调低会把正常状态一起报成告警，调高则继续看不见——**问题出在"只记异常"本身**。
///
/// 这里改成每分钟无条件记一行：CPU/内存/线程、主线程占比、当时在哪个页面、
/// 哪些推送订阅在跑、活跃连接数、以及**几个刷新源各发布了多少次**。
/// 事后把这条时间线拉出来，就能回答"从什么时候开始涨的、涨的时候在做什么"，
/// 而不必等下一次复现。
///
/// 与 `DiagnosticsJournal` 分文件：告警稀疏而珍贵，指标高频而廉价，
/// 混在一起会让告警被淹掉。
public final class MetricsJournal: @unchecked Sendable {
    /// 一分钟的汇总。字段名刻意取短——这个文件每天要追加约 1,440 行。
    public struct Sample: Codable, Equatable, Sendable {
        /// 本段结束时刻。
        public let t: Date
        /// 本段实际跨度（秒）。睡眠唤醒后会明显大于名义值，本身就是线索。
        public let win: Double
        /// 本段平均 / 峰值 CPU 百分比。
        public let cpu: Double
        public let peak: Double
        /// user 占比（接近 1 为纯计算，偏低为 I/O 密集）。
        public let usr: Double
        /// 主线程占本段 CPU 的比例（高=界面渲染，低=后台并发线程）。
        public let main: Double
        public let rss: Int
        public let th: Int
        /// 主窗口当时停在哪个页面；无窗口为 nil。
        public let page: String?
        /// 正在跑的推送订阅（连接流/仪表盘/菜单栏/日志流）。
        public let subs: String
        /// 接管方式与代理状态。
        public let mode: String
        public let conns: Int
        /// 本段流入的内核日志行数。
        public let logs: Int
        /// 本段物理网卡收发增量（MB）。用来区分"机器没网"与"某一环出问题"。
        public let net: Double
        /// **各刷新源本段的发布次数**。SwiftUI 的重绘由它们直接驱动，
        /// 只知道"主线程在渲染"定位不到具体是谁——这三项才是。
        public let pubConn: Int
        public let pubTraffic: Int
        public let pubLogs: Int

        public init(
            t: Date, win: Double, cpu: Double, peak: Double, usr: Double, main: Double,
            rss: Int, th: Int, page: String?, subs: String, mode: String,
            conns: Int, logs: Int, net: Double,
            pubConn: Int, pubTraffic: Int, pubLogs: Int
        ) {
            self.t = t; self.win = win; self.cpu = cpu; self.peak = peak
            self.usr = usr; self.main = main; self.rss = rss; self.th = th
            self.page = page; self.subs = subs; self.mode = mode
            self.conns = conns; self.logs = logs; self.net = net
            self.pubConn = pubConn; self.pubTraffic = pubTraffic; self.pubLogs = pubLogs
        }
    }

    private let file: JournalFile

    /// 默认 4 MB：一行约 200 字节、每分钟一行 ⇒ 约 1,440 行/天 ≈ 290 KB/天，
    /// 两代合计能留住**近两周**的连续运行情况，足够覆盖"上周开始变卡"这类回溯。
    public init(
        directory: URL = AppIdentity.supportDirectory,
        fileName: String = "metrics.ndjson",
        maxBytes: Int = 4 * 1_048_576
    ) {
        self.file = JournalFile(url: directory.appending(path: fileName), maxBytes: maxBytes)
    }

    public var fileURL: URL { file.fileURL }

    public func append(_ sample: Sample) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(sample) else { return }
        data.append(0x0A)
        file.append(data)
    }

    public func samples() -> [Sample] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return file.readLines().compactMap { try? decoder.decode(Sample.self, from: $0) }
    }
}
