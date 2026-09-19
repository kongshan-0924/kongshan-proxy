import Foundation
import XCTest
@testable import KongshanCore

/// CPU 异常持续时自动采调用栈：文件名可排序、参数正确、10 分钟节流、只留最近 5 份。
final class CPUSampleCaptureTests: XCTestCase {
    func testOutputNameCarriesLocalTimestampAndArgumentsTargetTheFile() {
        let directory = URL(fileURLWithPath: "/tmp/kongshan-samples", isDirectory: true)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let url = CPUSampleCapture.outputURL(in: directory, at: date)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        XCTAssertEqual(url.lastPathComponent, "cpu-\(formatter.string(from: date)).txt")
        XCTAssertEqual(url.deletingLastPathComponent().path, directory.path)
        XCTAssertEqual(
            CPUSampleCapture.arguments(pid: 4242, output: url),
            ["4242", "5", "-mayDie", "-file", url.path]
        )
    }

    func testClaimThrottlesToOnePerTenMinutes() {
        var capture = CPUSampleCapture(directory: URL(fileURLWithPath: "/tmp/kongshan-samples", isDirectory: true))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNotNil(capture.claim(now: start))
        XCTAssertNil(capture.claim(now: start.addingTimeInterval(9 * 60)), "同一次爆发的第二份没有新信息，而 sample 自身也要 CPU")
        XCTAssertNotNil(capture.claim(now: start.addingTimeInterval(10 * 60)))
    }

    func testPruneKeepsNewestFiveAndLeavesOtherFilesAlone() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-samples-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 1...7 {
            try Data("x".utf8).write(to: directory.appending(path: String(format: "cpu-20260904-00000%d.txt", index)))
        }
        try Data("y".utf8).write(to: directory.appending(path: "notes.txt"))

        CPUSampleCapture.prune(directory: directory)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(remaining, [
            "cpu-20260904-000003.txt", "cpu-20260904-000004.txt", "cpu-20260904-000005.txt",
            "cpu-20260904-000006.txt", "cpu-20260904-000007.txt", "notes.txt"
        ])
    }
}
