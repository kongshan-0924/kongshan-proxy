import Foundation
import XCTest
@testable import KongshanCore

/// 日志压缩归档（`LogArchiver`）的回归。
///
/// 存在的理由：TUN 模式下日志不到 2 小时就整轮冲掉，真机 2026-10-02 想回查前一晚的告警时原始日志已不在。
final class LogArchiverTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-archive-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 产物必须是标准 gzip：系统自带的 gunzip 能原样还原。
    func testArchiveIsStandardGzipThatGunzipCanRestore() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = (0..<5_000).map { "+0800 2026-10-02 10:00:00 INFO [\($0) 2ms] outbound/direct[direct]: outbound connection to a\($0).example.invalid:443" }
            .joined(separator: "\n") + "\n"
        let previous = directory.appending(path: "sing-box.log.1")
        try Data(original.utf8).write(to: previous)

        let archive = try LogArchiver.archive(previous, baseName: "sing-box.log", in: directory, at: Date())
        let compressed = try Data(contentsOf: archive)
        XCTAssertLessThan(compressed.count, original.utf8.count / 5, "文本日志应明显变小")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", archive.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let restored = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: restored, as: UTF8.self), original)
    }

    func testEmptyFileArchivesToValidGzip() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = directory.appending(path: "x.log.1")
        try Data().write(to: previous)
        let archive = try LogArchiver.archive(previous, baseName: "x.log", in: directory, at: Date())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-t", archive.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "空文件也要是合法 gzip")
    }

    /// 超过 48 小时的删掉；只认本日志的归档，不误删别的日志。
    func testPruneDropsExpiredArchivesOnlyForThatLog() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let old = directory.appending(path: "sing-box.log.20260101-000000.gz")
        let fresh = directory.appending(path: "sing-box.log.20260102-000000.gz")
        let other = directory.appending(path: "sing-box-tun-stream.log.20260101-000000.gz")
        for url in [old, fresh, other] { try Data([1]).write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-49 * 3600)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-49 * 3600)], ofItemAtPath: other.path)

        LogArchiver.prune(baseName: "sing-box.log", in: directory, now: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "别的日志的归档不归这里管")
    }

    /// 日志存储每次滚动都把被覆盖的 `.1` 留档；导出列出归档名。
    func testRotationKeepsCompressedArchivesAndExportListsThem() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ticks = ClockBox(Date(timeIntervalSince1970: 1_790_000_000))
        let store = KernelLogStore(
            directory: directory, maxFileBytes: 200,
            externalTUNLogURL: directory.appending(path: "none.log"),
            now: { ticks.next() }
        )
        for i in 0..<12 {
            try await store.append("line-\(i) " + String(repeating: "x", count: 80) + "\n", source: .system)
        }
        let archives = LogArchiver.list(baseName: "sing-box.log", in: directory)
        XCTAssertGreaterThanOrEqual(archives.count, 2, "被覆盖的旧档要留下来")
        let exported = try await store.exportText()
        XCTAssertTrue(exported.contains("压缩归档"), exported)
        XCTAssertTrue(exported.contains(archives[0].lastPathComponent))
    }
}

/// 每次取时间前进 1 秒，保证归档文件名（精确到秒）不重名。
private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func next() -> Date {
        lock.withLock {
            value = value.addingTimeInterval(1)
            return value
        }
    }
}
