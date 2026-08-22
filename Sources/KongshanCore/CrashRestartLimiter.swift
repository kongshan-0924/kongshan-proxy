import Foundation

public struct CrashRestartLimiter: Sendable {
    public let maxRestarts: Int
    public let window: TimeInterval
    private var restartDates: [Date] = []

    public init(maxRestarts: Int = 3, window: TimeInterval = 10) {
        precondition(maxRestarts > 0)
        precondition(window > 0)
        self.maxRestarts = maxRestarts
        self.window = window
    }

    /// 当前滑动窗口内已计入的重启次数。`allowsRestart` 放行后读它即为"这是第几次"，
    /// 供运行事件说明自愈进度——只说"检测到意外退出"而不说第几次，用户看不出是偶发还是在打转。
    public var recentRestartCount: Int { restartDates.count }

    public mutating func allowsRestart(at date: Date) -> Bool {
        restartDates.removeAll { date.timeIntervalSince($0) >= window }
        guard restartDates.count < maxRestarts else { return false }
        restartDates.append(date)
        return true
    }

    public mutating func reset() {
        restartDates.removeAll(keepingCapacity: true)
    }
}
