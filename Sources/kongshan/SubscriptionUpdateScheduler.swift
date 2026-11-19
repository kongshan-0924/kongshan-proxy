import Foundation
import KongshanCore

struct SubscriptionUpdateSettings: Codable, Equatable, Sendable {
    var enabled: Bool
    var intervalHours: Int

    static let defaults = SubscriptionUpdateSettings(enabled: true, intervalHours: 24)

    func validated() throws -> SubscriptionUpdateSettings {
        guard (1...168).contains(intervalHours) else {
            throw SubscriptionUpdateSettingsError.invalidInterval
        }
        return self
    }
}

private enum SubscriptionUpdateSettingsError: Error, LocalizedError {
    case invalidInterval

    var errorDescription: String? {
        "订阅更新间隔必须在 1 到 168 小时之间"
    }
}

actor SubscriptionUpdateScheduler {
    typealias NowProvider = @Sendable () -> Date
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void
    typealias Action = @Sendable () async -> Void

    private let now: NowProvider
    private let sleeper: Sleeper
    private var scheduledTask: Task<Void, Never>?

    init(
        now: @escaping NowProvider = Date.init,
        sleeper: @escaping Sleeper = { delay in
            try await Task.sleep(for: .seconds(delay))
        }
    ) {
        self.now = now
        self.sleeper = sleeper
    }

    deinit {
        scheduledTask?.cancel()
    }

    nonisolated static func nextUpdateDate(
        sources: [SubscriptionSource],
        settings: SubscriptionUpdateSettings,
        now: Date
    ) -> Date? {
        guard settings.enabled, !sources.isEmpty else { return nil }
        let interval = TimeInterval(settings.intervalHours * 3_600)
        let earliest = sources.map { source in
            source.lastUpdatedAt?.addingTimeInterval(interval) ?? now
        }.min() ?? now
        return max(earliest, now)
    }

    @discardableResult
    func schedule(
        sources: [SubscriptionSource],
        settings: SubscriptionUpdateSettings,
        notBefore: Date? = nil,
        action: @escaping Action
    ) -> Date? {
        scheduledTask?.cancel()
        scheduledTask = nil

        let currentDate = now()
        guard let calculatedDate = Self.nextUpdateDate(
            sources: sources,
            settings: settings,
            now: currentDate
        ) else {
            return nil
        }
        let scheduledDate = max(calculatedDate, notBefore ?? calculatedDate)
        let delay = max(0, scheduledDate.timeIntervalSince(currentDate))
        let sleeper = self.sleeper
        generation &+= 1
        let token = generation
        scheduledTask = Task { [weak self] in
            do {
                if delay > 0 { try await sleeper(delay) }
                guard !Task.isCancelled else { return }
            } catch {
                return
            }
            // 开始执行就从「待取消」名单里摘掉：之后的 schedule / cancel 只取消还在等待的那次，
            // 不打断正在跑的更新。原先执行途中（比如用户点了「更新全部」、切了「参与定时更新」）一重排
            // 就把正在重载内核的这次取消掉——健康检查与回滚都抛 CancellationError，代理被整个撤掉
            // （2026-11-19 11:38 真机：「当前配置应用与回滚均失败」，35 秒后才重新起来）。
            await self?.detachRunningTask(token)
            await action()
        }
        return scheduledDate
    }

    /// 每次 schedule 递增，用来认出「正在执行的是不是最近排的那次」。
    private var generation = 0

    private func detachRunningTask(_ token: Int) {
        guard token == generation else { return }
        scheduledTask = nil
    }

    func cancel() {
        scheduledTask?.cancel()
        scheduledTask = nil
    }
}
