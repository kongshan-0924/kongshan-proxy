import Foundation
import XCTest
@testable import KongshanCore

/// 连续指标流水的回归。
///
/// 存在的理由：「只记异常」救不了归因——2026-08-28 起 4 天累计 21 小时 CPU 只有 623 秒
/// 有记录；2026-09-03 主窗口开着时稳定 5~7%，因低于 12% 异常阈值而一条记录都没有。
final class MetricsJournalTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-metrics-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sample(_ offset: Double, cpu: Double = 5.5, page: String? = "连接") -> MetricsJournal.Sample {
        MetricsJournal.Sample(
            t: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            win: 60, cpu: cpu, peak: cpu * 2, usr: 0.97, main: 0.96,
            rss: 105, th: 8, page: page, subs: "连接流+仪表盘", mode: "系统代理+TUN",
            conns: 412, logs: 120, net: 3.4,
            pubConn: 58, pubTraffic: 60, pubLogs: 12
        )
    }

    func testAppendsAndReadsBackEveryField() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = MetricsJournal(directory: root)

        journal.append(sample(0))
        journal.append(sample(60, cpu: 7.8))

        let samples = journal.samples()
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples.last?.cpu, 7.8)
        // 归因要靠的几项必须原样往返，缺一项就少一条线索。
        XCTAssertEqual(samples.first?.page, "连接")
        XCTAssertEqual(samples.first?.subs, "连接流+仪表盘")
        XCTAssertEqual(samples.first?.mode, "系统代理+TUN")
        XCTAssertEqual(samples.first?.main, 0.96)
        XCTAssertEqual(samples.first?.pubConn, 58)
        XCTAssertEqual(samples.first?.conns, 412)
    }

    /// 无窗口时 page 为 nil，不能因为可选值就整条丢掉。
    func testSampleWithoutVisiblePageSurvivesRoundTrip() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = MetricsJournal(directory: root)
        journal.append(sample(0, page: nil))
        XCTAssertEqual(journal.samples().count, 1)
        XCTAssertNil(journal.samples().first?.page)
    }

    /// 高频写入必须有界，且**轮转后仍读得到上一代**——
    /// 否则刚跨过轮转点就查不到刚发生的事，正是排查最需要的那一段。
    func testRotatesAndKeepsPreviousGeneration() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = MetricsJournal(directory: root, maxBytes: 1_200)

        for index in 0..<40 { journal.append(sample(Double(index) * 60)) }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appending(path: "metrics.ndjson.1").path),
            "超过上限必须轮转"
        )
        let samples = journal.samples()
        XCTAssertGreaterThan(samples.count, 1, "轮转后仍要读得到上一代")
        XCTAssertEqual(samples.last?.t, Date(timeIntervalSince1970: 1_700_000_000 + 39 * 60))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appending(path: "metrics.ndjson.2").path),
            "只留两代"
        )
    }

    /// 与告警**分文件**：告警稀疏而珍贵，指标高频而廉价，混在一起告警会被淹掉。
    func testMetricsAndDiagnosticsUseSeparateFiles() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let metrics = MetricsJournal(directory: root)
        let diagnostics = DiagnosticsJournal(directory: root)
        XCTAssertNotEqual(metrics.fileURL, diagnostics.fileURL)

        metrics.append(sample(0))
        diagnostics.append(DiagnosticsJournal.Record(
            t: Date(timeIntervalSince1970: 1_700_000_000), level: "warning", title: "t", detail: nil
        ))
        XCTAssertEqual(metrics.samples().count, 1)
        XCTAssertEqual(diagnostics.records().count, 1)
    }
}
