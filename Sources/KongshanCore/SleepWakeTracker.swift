import Foundation

/// 察觉「刚从睡眠醒来」（含暗唤醒），醒来后的一小段时间里不把失败算进检测器。
///
/// 存在的理由：Mac 合盖睡眠时大约每 15 分钟暗唤醒一次（pmset 日志里的 `DarkWake`），每次只醒 2～7 秒，
/// 网络还没恢复，后台程序的请求就集中失败。真机 2026-10-03 最近 200 条运行事件里，
/// 「DNS 解析持续超时」「本机网络不通」「节点建连失败偏多」共 70 条，时间与暗唤醒逐一吻合；
/// 20:32 那条还把唤醒瞬间本机没网造成的失败算到了节点头上。这些都是误报。
///
/// 判据不靠通知：暗唤醒不发 `NSWorkspace.didWakeNotification`。改为比较两只时钟——
/// `CLOCK_MONOTONIC_RAW` 睡眠时照走，`CLOCK_UPTIME_RAW` 睡眠时停；两次观测之间前者比后者多走的，
/// 就是这期间睡掉的时间。与观测间隔无关，任何时候观测都算得准。
public struct SleepWakeTracker: Sendable {
    public struct Reading: Sendable, Equatable {
        /// 睡眠时照走的单调时钟（秒）。
        public var monotonic: TimeInterval
        /// 睡眠时停走的单调时钟（秒）。
        public var uptime: TimeInterval

        public init(monotonic: TimeInterval, uptime: TimeInterval) {
            self.monotonic = monotonic
            self.uptime = uptime
        }

        public static func current() -> Reading {
            Reading(
                monotonic: TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000,
                uptime: TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
            )
        }
    }

    /// 睡掉这么久才算一次睡眠；更短的差值是两只时钟各自的抖动。
    public static let minimumSleep: TimeInterval = 5
    /// 醒来后多久内不算失败。暗唤醒只醒几秒；合盖后重新打开，Wi-Fi 重连加内核重载通常在一分钟内。
    /// 醒来后网络真坏了，过了这段照样会报。
    public static let quietAfterWake: TimeInterval = 90

    private var last: Reading?
    public private(set) var quietUntil: Date?

    public init() {}

    /// 记一次观测；发现期间睡过，就把安静期延到 `date + quietAfterWake`。返回这次是否发现了睡眠。
    @discardableResult
    public mutating func observe(_ reading: Reading, at date: Date) -> Bool {
        defer { last = reading }
        guard let last else { return false }
        let slept = (reading.monotonic - last.monotonic) - (reading.uptime - last.uptime)
        guard slept >= Self.minimumSleep else { return false }
        let until = date.addingTimeInterval(Self.quietAfterWake)
        quietUntil = max(quietUntil ?? until, until)
        return true
    }

    public func isQuiet(at date: Date) -> Bool {
        guard let quietUntil else { return false }
        return date <= quietUntil
    }
}
