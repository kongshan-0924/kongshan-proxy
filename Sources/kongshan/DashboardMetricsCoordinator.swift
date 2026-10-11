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

/// 一分钟的流量：均值与峰值（字节/秒）。
struct TrafficMinute: Identifiable, Equatable, Sendable {
    let start: Date
    let uploadAverage: Int64
    let downloadAverage: Int64
    let uploadPeak: Int64
    let downloadPeak: Int64

    var id: Date { start }
}

/// 按分钟累计速率样本，保留最近一小时。
///
/// 仪表盘的流量图原先只在仪表盘开着时才攒点（四秒一个、最多 60 个），每次打开都从空白开始，
/// 能看的最多四分钟——用户 2026-10-10 反馈「看起来一点用都没有」。分钟桶在后台一直累计，
/// 只做几次加法、不进 Observation，打开仪表盘时一次交给图表。
struct TrafficMinuteAccumulator: Sendable {
    static let capacity = 60

    private(set) var minutes: [TrafficMinute] = []
    private var currentStart: Date?
    private var uploadSum: Int64 = 0
    private var downloadSum: Int64 = 0
    private var sampleCount: Int64 = 0
    private var uploadPeak: Int64 = 0
    private var downloadPeak: Int64 = 0

    init(minutes: [TrafficMinute] = []) {
        self.minutes = Array(minutes.suffix(Self.capacity))
    }

    /// 记一个样本；跨进新的一分钟时把上一分钟封存，返回 true。
    @discardableResult
    mutating func record(upload: Int64, download: Int64, at date: Date) -> Bool {
        let start = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
        var closed = false
        if let currentStart, currentStart != start {
            closeCurrent()
            closed = true
        }
        if currentStart == nil { currentStart = start }
        uploadSum += upload
        downloadSum += download
        sampleCount += 1
        uploadPeak = max(uploadPeak, upload)
        downloadPeak = max(downloadPeak, download)
        return closed
    }

    private mutating func closeCurrent() {
        guard let currentStart, sampleCount > 0 else { return }
        minutes.append(TrafficMinute(
            start: currentStart,
            uploadAverage: uploadSum / sampleCount,
            downloadAverage: downloadSum / sampleCount,
            uploadPeak: uploadPeak,
            downloadPeak: downloadPeak
        ))
        if minutes.count > Self.capacity { minutes.removeFirst(minutes.count - Self.capacity) }
        self.currentStart = nil
        uploadSum = 0
        downloadSum = 0
        sampleCount = 0
        uploadPeak = 0
        downloadPeak = 0
    }
}
