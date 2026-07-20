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
        scheduledTask = Task {
            do {
                if delay > 0 { try await sleeper(delay) }
                guard !Task.isCancelled else { return }
                await action()
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
        return scheduledDate
    }

    func cancel() {
        scheduledTask?.cancel()
        scheduledTask = nil
    }
}
