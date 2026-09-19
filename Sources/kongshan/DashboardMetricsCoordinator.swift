import Foundation
import KongshanCore

/// Keeps the one-second core streams accurate while reducing SwiftUI invalidations.
/// Connection cards publish every two samples and the chart every four samples.
struct DashboardMetricsCoordinator: Sendable {
    private var connectionSampleCount = 0
    private var trafficSampleCount = 0

    mutating func shouldPublishTrafficRates() -> Bool {
        trafficSampleCount += 1
        return trafficSampleCount == 1 || trafficSampleCount.isMultiple(of: 2)
    }

    mutating func shouldPublishConnectionSnapshot(_ snapshot: ConnectionSnapshot) -> Bool {
        connectionSampleCount += 1
        return connectionSampleCount == 1 || connectionSampleCount.isMultiple(of: 2)
    }

    mutating func shouldPublishTrafficPoint(isDashboardVisible: Bool) -> Bool {
        guard isDashboardVisible else {
            trafficSampleCount = 0
            return false
        }
        return trafficSampleCount == 1 || trafficSampleCount.isMultiple(of: 4)
    }

    mutating func reset() {
        connectionSampleCount = 0
        trafficSampleCount = 0
    }
}

struct SpeedTestProgress: Equatable, Sendable {
    var completed = 0
    var total = 0

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }

    var label: String {
        total > 0 ? "\(completed) / \(total)" : ""
    }
}
