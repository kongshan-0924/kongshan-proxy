import Foundation

/// CPU 异常**持续**时给自己采一份调用栈（`/usr/bin/sample`）。
///
/// 指标流水与告警最多说到"主线程占 96%、当前页面仪表盘、活跃订阅 仪表盘+菜单栏+日志流"，
/// 说不出主线程在跑**谁**——真机 2026-09-03 22:36 的 36% 爆发就停在这一步，事后只能猜。
/// `sample` 对硬化运行时的自身进程可用（真机 2026-09-04 验证：1 秒 271 KB、完整符号化），
/// 5 秒一份、只在异常持续阶段触发、10 分钟最多一份、只留最近 5 份。
public struct CPUSampleCapture: Sendable {
    public static let tool = URL(fileURLWithPath: "/usr/bin/sample")
    public static let minimumInterval: TimeInterval = 10 * 60
    public static let keepCount = 5
    public static let durationSeconds = 5

    public let directory: URL
    public private(set) var lastCapturedAt: Date?

    public init(directory: URL) {
        self.directory = directory
    }

    /// 这次异常值不值得采：上一份不到 10 分钟就不采——同一次爆发的第二份没有新信息，
    /// 而 sample 自身也要 CPU。返回本次的输出路径。
    public mutating func claim(now: Date) -> URL? {
        if let last = lastCapturedAt, now.timeIntervalSince(last) < Self.minimumInterval {
            return nil
        }
        lastCapturedAt = now
        return Self.outputURL(in: directory, at: now)
    }

    /// 文件名带本地时间戳，字典序即时间序，`prune` 靠它判新旧。
    public static func outputURL(in directory: URL, at date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return directory.appending(path: "cpu-\(formatter.string(from: date)).txt")
    }

    /// `sample <pid> <秒> -mayDie -file <路径>`。`-mayDie` 允许目标在采样期间退出而不报错。
    public static func arguments(pid: Int32, output: URL) -> [String] {
        [String(pid), String(durationSeconds), "-mayDie", "-file", output.path]
    }

    /// 真正跑 sample，同步等它写完（约 duration 秒 + 符号化）。调用方放到后台任务里。
    public static func run(arguments: [String]) throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CPUSampleCaptureError.toolFailed(process.terminationStatus)
        }
    }

    /// 只留最近 `keep` 份；文件名含时间戳，按名字排序即可。
    public static func prune(directory: URL, keep: Int = keepCount) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let samples = names.filter { $0.hasPrefix("cpu-") && $0.hasSuffix(".txt") }.sorted()
        for name in samples.dropLast(keep) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }
}

public enum CPUSampleCaptureError: Error, LocalizedError, Equatable {
    case toolFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case let .toolFailed(status):
            "/usr/bin/sample 退出码 \(status)"
        }
    }
}
