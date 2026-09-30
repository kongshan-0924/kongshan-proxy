import Foundation
import XCTest
@testable import KongshanCore

final class KernelLogStoreTests: XCTestCase {
    func testAppendKeepsOnlyMostRecentBufferedLines() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KernelLogStore(
            directory: root,
            maxBufferedLines: 3,
            maxFileBytes: 1_024
        )

        try await store.append("one\ntwo\n", source: .system)
        try await store.append("three\nfour\n", source: .system)

        let recentLines = await store.recentLines()
        XCTAssertEqual(recentLines, ["two", "three", "four"])
        XCTAssertEqual(
            try String(contentsOf: root.appending(path: "sing-box.log"), encoding: .utf8),
            "one\ntwo\nthree\nfour\n"
        )
    }

    func testAppendRotatesOnceAndKeepsBothFilesBounded() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KernelLogStore(
            directory: root,
            maxBufferedLines: 10,
            maxFileBytes: 12
        )

        try await store.append("first-line\n", source: .system)
        try await store.append("second\n", source: .system)

        let current = root.appending(path: "sing-box.log")
        let archive = root.appending(path: "sing-box.log.1")
        XCTAssertEqual(try String(contentsOf: archive, encoding: .utf8), "first-line\n")
        XCTAssertEqual(try String(contentsOf: current, encoding: .utf8), "second\n")
        XCTAssertLessThanOrEqual(try fileSize(current), 12)
        XCTAssertLessThanOrEqual(try fileSize(archive), 12)
    }

    func testOversizedChunkKeepsOnlyBoundedSuffix() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KernelLogStore(
            directory: root,
            maxBufferedLines: 10,
            maxFileBytes: 8
        )

        try await store.append("0123456789", source: .system)

        let current = root.appending(path: "sing-box.log")
        // 存储按行落盘，末行不带换行也补上换行（"0123456789\n" 共 11 字节），截到最后 8 字节。
        XCTAssertEqual(try Data(contentsOf: current), Data("3456789\n".utf8))
        XCTAssertEqual(try fileSize(current), 8)
    }

    func testExportReadsOnlyKnownRotatedAndCurrentLogFiles() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("old system\n".utf8).write(to: root.appending(path: "sing-box.log.1"))
        try Data("new system\n".utf8).write(to: root.appending(path: "sing-box.log"))
        try Data("tun output\n".utf8).write(to: root.appending(path: "sing-box-tun.log"))
        try Data("runtime-secret subscription=https://private.example/sub\n".utf8)
            .write(to: root.appending(path: "config.json"))
        try Data("unrelated secret\n".utf8).write(to: root.appending(path: "debug.log"))
        let store = KernelLogStore(directory: root)

        let exported = try await store.exportText()

        XCTAssertTrue(exported.contains("old system"))
        XCTAssertTrue(exported.contains("new system"))
        XCTAssertTrue(exported.contains("tun output"))
        XCTAssertFalse(exported.contains("runtime-secret"))
        XCTAssertFalse(exported.contains("private.example"))
        XCTAssertFalse(exported.contains("unrelated secret"))
    }

    func testPrepareExternalTUNLogRotatesAndPrecreatesUserReadableFile() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let current = root.appending(path: "sing-box-tun.log")
        try Data("0123456789".utf8).write(to: current)
        let store = KernelLogStore(directory: root, maxFileBytes: 8)

        try await store.prepareForExternalAppend(source: .tun)

        let archive = root.appending(path: "sing-box-tun.log.1")
        XCTAssertEqual(try Data(contentsOf: archive), Data("23456789".utf8))
        XCTAssertEqual(try Data(contentsOf: current), Data())
        let permissions = try FileManager.default.attributesOfItem(atPath: current.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testExternalTUNMonitorRotatesActiveAppendWithoutPolling() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KernelLogStore(directory: root, maxFileBytes: 8)
        try await store.prepareForExternalAppend(source: .tun)
        try await store.startExternalRotationMonitoring(source: .tun)
        let current = root.appending(path: "sing-box-tun.log")

        let handle = try FileHandle(forWritingTo: current)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("0123456789".utf8))
        try handle.close()

        let archive = root.appending(path: "sing-box-tun.log.1")
        try await waitUntil {
            FileManager.default.fileExists(atPath: archive.path)
                && (try? Data(contentsOf: current).isEmpty) == true
        }
        XCTAssertEqual(try Data(contentsOf: archive), Data("23456789".utf8))
        await store.stopExternalRotationMonitoring(source: .tun)
    }

    private func fileSize(_ url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return try XCTUnwrap(values.fileSize)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for external log rotation")
    }
}
extension KernelLogStoreTests {
    /// TUN 内核由 helper 以 root 启动，日志写在 **helper 自己的目录**，
    /// 不在 App 的 logs 目录里。导出若不去那边读，TUN 全程的内核日志一条都拿不到——
    /// 真机 2026-09-02 复盘时才发现，30 小时 TUN 会话在导出里完全是空白。
    func testExportIncludesHelperOwnedTUNLog() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let external = root.appending(path: "helper-sing-box-tun.log")
        try Data("TUN-KERNEL-LINE\n".utf8).write(to: external)

        let logs = root.appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let store = KernelLogStore(directory: logs, externalTUNLogURL: external)
        try await store.append("APP-KERNEL-LINE\n", source: .system)

        let text = try await store.exportText()
        XCTAssertTrue(text.contains("APP-KERNEL-LINE"))
        XCTAssertTrue(text.contains("TUN-KERNEL-LINE"), "导出必须包含 helper 那份 TUN 日志")
    }

    /// helper 的日志真机见过 63 MB，整份读进内存既慢又可能顶爆；导出只取尾部。
    func testExportTakesOnlyTailOfAnOversizedExternalLog() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let external = root.appending(path: "helper-sing-box-tun.log")
        let filler = String(repeating: "OLD-LINE\n", count: 2_000)
        try Data((filler + "NEWEST-LINE\n").utf8).write(to: external)

        let logs = root.appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let store = KernelLogStore(directory: logs, maxFileBytes: 200, externalTUNLogURL: external)

        let text = try await store.exportText()
        XCTAssertTrue(text.contains("NEWEST-LINE"), "尾部必须保留")
        XCTAssertLessThan(text.utf8.count, 2_000, "不该把整份大文件读进来")
    }
}

/// 拼行与折叠：`SingBoxProcess` 给的是数据块不是行；TUN 内核的副本来自日志流。
extension KernelLogStoreTests {
    private func makeLogsDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-fold-\(UUID().uuidString)", directoryHint: .isDirectory)
        let logs = root.appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs
    }

    private func read(_ name: String, in directory: URL) throws -> String {
        try String(contentsOf: directory.appending(path: name), encoding: .utf8)
    }

    func testChunkedPipeOutputIsReassembledIntoWholeLines() async throws {
        let logs = try makeLogsDirectory()
        defer { try? FileManager.default.removeItem(at: logs.deletingLastPathComponent()) }
        let store = KernelLogStore(directory: logs, externalTUNLogURL: logs.appending(path: "none.log"))

        try await store.append(SingBoxLogLine(stream: .standardOutput, text: "alpha\nbra"))
        XCTAssertEqual(try read("sing-box.log", in: logs), "alpha\n", "半行要等下一块，不能先写出去")
        try await store.append(SingBoxLogLine(stream: .standardOutput, text: "vo\ncharlie\n"))
        XCTAssertEqual(try read("sing-box.log", in: logs), "alpha\nbravo\ncharlie\n")
    }

    /// stdout 与 stderr 的块会交错到达，半行必须按管道分开拼，否则两路的行会被拼在一起。
    func testStdoutAndStderrPartialLinesStaySeparate() async throws {
        let logs = try makeLogsDirectory()
        defer { try? FileManager.default.removeItem(at: logs.deletingLastPathComponent()) }
        let store = KernelLogStore(directory: logs, externalTUNLogURL: logs.appending(path: "none.log"))

        try await store.append(SingBoxLogLine(stream: .standardOutput, text: "out-"))
        try await store.append(SingBoxLogLine(stream: .standardError, text: "err-"))
        try await store.append(SingBoxLogLine(stream: .standardOutput, text: "line\n"))
        try await store.append(SingBoxLogLine(stream: .standardError, text: "line\n"))
        XCTAssertEqual(try read("sing-box.log", in: logs), "out-line\nerr-line\n")
    }

    func testFinishWritesThePendingTail() async throws {
        let logs = try makeLogsDirectory()
        defer { try? FileManager.default.removeItem(at: logs.deletingLastPathComponent()) }
        let store = KernelLogStore(directory: logs, externalTUNLogURL: logs.appending(path: "none.log"))

        try await store.append(SingBoxLogLine(stream: .standardError, text: "FATAL no newline"))
        try await store.finish(source: .system)
        XCTAssertEqual(try read("sing-box.log", in: logs), "FATAL no newline\n", "内核退出时尾行不能丢")
    }

    /// TUN 副本按内核日志格式落盘；断网刷屏被折叠，恢复后补总结。
    func testTUNStreamMirrorUsesKernelFormatAndFoldsFloods() async throws {
        let logs = try makeLogsDirectory()
        defer { try? FileManager.default.removeItem(at: logs.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_790_000_000)
        let store = KernelLogStore(directory: logs, externalTUNLogURL: logs.appending(path: "none.log"))

        try await store.appendStream([
            CoreLogEntry(level: .info, message: "[1 2ms] outbound/direct[direct]: outbound connection to a.example.invalid:443", receivedAt: origin)
        ])
        var flood: [CoreLogEntry] = []
        for i in 0..<400 {
            let at = origin.addingTimeInterval(1 + Double(i) * 0.1)
            flood.append(CoreLogEntry(
                level: .error,
                message: "[\(100 + i) 3ms] connection: open connection to b\(i).example.invalid:443 using "
                    + "outbound/direct[direct]: dial tcp 203.0.113.7:443: no route to internet",
                receivedAt: at
            ))
        }
        try await store.appendStream(flood)
        try await store.finish(source: .tunStream)

        let text = try read("sing-box-tun-stream.log", in: logs)
        let lines = text.split(separator: "\n")
        XCTAssertTrue(lines.first?.hasSuffix(" INFO [1 2ms] outbound/direct[direct]: outbound connection to a.example.invalid:443") == true,
                      "首行应是内核格式：\(lines.first ?? "")")
        XCTAssertLessThan(lines.count, 60, "400 行失败必须被折叠，实际 \(lines.count) 行")
        XCTAssertTrue(text.contains("建连失败密集"))
        XCTAssertTrue(text.contains("日志折叠结束"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: logs.appending(path: "sing-box.log").path),
                       "TUN 副本不能写进用户态内核的日志")
    }

    func testExportIncludesTUNStreamAndLabelsHelperTail() async throws {
        let logs = try makeLogsDirectory()
        defer { try? FileManager.default.removeItem(at: logs.deletingLastPathComponent()) }
        let helper = logs.deletingLastPathComponent().appending(path: "helper-sing-box-tun.log")
        try Data("HELPER-RAW-LINE\n".utf8).write(to: helper)
        let store = KernelLogStore(directory: logs, externalTUNLogURL: helper)
        try await store.appendStream([
            CoreLogEntry(level: .warning, message: "STREAM-MIRROR-LINE", receivedAt: Date())
        ])

        let text = try await store.exportText()
        XCTAssertTrue(text.contains("===== sing-box-tun-stream.log ====="))
        XCTAssertTrue(text.contains("WARN STREAM-MIRROR-LINE"))
        XCTAssertTrue(text.contains("助手原始输出，仅尾部"))
        XCTAssertTrue(text.contains("HELPER-RAW-LINE"))
    }
}
