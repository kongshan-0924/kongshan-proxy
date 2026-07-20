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
