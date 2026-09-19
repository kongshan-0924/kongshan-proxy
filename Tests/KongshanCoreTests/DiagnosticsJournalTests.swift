import Foundation
import XCTest
@testable import KongshanCore

final class DiagnosticsJournalTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func record(_ title: String, at offset: TimeInterval = 0) -> DiagnosticsJournal.Record {
        DiagnosticsJournal.Record(
            t: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            level: "warning",
            title: title,
            detail: "detail for \(title)"
        )
    }

    func testAppendsAndReadsBackInOrder() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DiagnosticsJournal(directory: root)

        for index in 0..<5 {
            journal.append(record("event-\(index)", at: Double(index)))
        }

        let records = journal.records()
        XCTAssertEqual(records.map(\.title), (0..<5).map { "event-\($0)" })
        XCTAssertEqual(records.first?.detail, "detail for event-0")
        XCTAssertEqual(records.first?.level, "warning")
    }

    /// 每条独占一行是刻意的：崩溃或断电最多毁掉最后一行，
    /// 不会像整体重写 JSON 数组那样把整个存档写成半截。
    func testOneRecordPerLineAndPartialTailDoesNotLoseEarlierRecords() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DiagnosticsJournal(directory: root)
        for index in 0..<3 { journal.append(record("event-\(index)", at: Double(index))) }

        let url = journal.fileURL
        let text = try XCTUnwrap(String(data: try Data(contentsOf: url), encoding: .utf8))
        XCTAssertEqual(text.split(separator: "\n").count, 3)

        // 模拟写到一半断电：追加一段残缺 JSON。
        var data = try Data(contentsOf: url)
        data.append(Data(#"{"t":"2023-11-14T22:13:2"#.utf8))
        try data.write(to: url)

        let records = journal.records()
        XCTAssertEqual(records.map(\.title), ["event-0", "event-1", "event-2"], "残缺的尾行不该带走前面的记录")
    }

    /// 存档要有界，但轮转后**上一代仍要能读到**——否则刚跨过轮转点就查不到刚发生的事。
    func testRotatesWhenOversizedAndStillReadsPreviousGeneration() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DiagnosticsJournal(directory: root, maxBytes: 400)

        for index in 0..<12 { journal.append(record("event-\(index)", at: Double(index))) }

        let rotated = root.appending(path: "diagnostics.ndjson.1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path), "超过上限必须轮转")

        let records = journal.records()
        XCTAssertEqual(records.last?.title, "event-11")
        XCTAssertGreaterThan(records.count, 1, "轮转后仍要读得到上一代")
        // 只留两代，不无限增长。
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "diagnostics.ndjson.2").path))
    }

    /// 取证记录写不进去，绝不能反过来打断正在处理的那件事——
    /// 记录 CPU 异常时抛错、把异常处理流程带崩，是最坏的结果。
    func testAppendStaysSilentWhenDirectoryIsMissing() async {
        let journal = DiagnosticsJournal(
            directory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/nested")
        )
        journal.append(record("event"))
        let records = journal.records()
        XCTAssertTrue(records.isEmpty)
    }
}
