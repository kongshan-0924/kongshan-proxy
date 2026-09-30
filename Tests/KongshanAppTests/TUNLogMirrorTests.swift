import Foundation
import XCTest
@testable import KongshanCore
@testable import kongshan

/// TUN 内核日志副本（`sing-box-tun-stream.log`）的接线回归。
///
/// 存在的理由：TUN 内核由助手启动、日志直写进助手目录，App 无法逐行过滤；真机 2026-09-26 断网时
/// 那份文件几分钟就被截断一轮，断网前后的记录全部丢失。副本来自本来就常开的日志流，
/// 接线一断不会报错，只会安静地不再留日志。
@MainActor
final class TUNLogMirrorTests: XCTestCase {
    private func makeState() throws -> (AppState, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-mirror-\(UUID().uuidString)", directoryHint: .isDirectory)
        let logs = root.appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let store = KernelLogStore(directory: logs, externalTUNLogURL: root.appending(path: "helper.log"))
        let state = AppState(
            storage: Storage(rootDirectory: root),
            singBoxProcess: SingBoxProcess(binaryURL: URL(fileURLWithPath: "/usr/bin/false")),
            kernelLogStore: store,
            automaticallyInitialize: false
        )
        return (state, root)
    }

    private func mirrorURL(_ root: URL) -> URL {
        root.appending(path: "logs/sing-box-tun-stream.log")
    }

    func testTUNModeMirrorsTheLogStream() async throws {
        let (state, root) = try makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        state.setActiveModesForTesting([.tun, .systemProxy])

        state.receiveLog(CoreLogEntry(
            level: .info,
            message: "[7 2ms] outbound/direct[direct]: outbound connection to a.example.invalid:443",
            receivedAt: Date()
        ))
        await state.finishTUNLogMirror()

        let text = try String(contentsOf: mirrorURL(root), encoding: .utf8)
        XCTAssertTrue(text.contains(" INFO [7 2ms] outbound/direct[direct]: outbound connection to a.example.invalid:443"))
    }

    /// 只开系统代理时内核由 App 自己起，输出本来就经 App 落盘，不再抄一份。
    func testSystemProxyOnlyDoesNotMirror() async throws {
        let (state, root) = try makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        state.setActiveModesForTesting([.systemProxy])

        state.receiveLog(CoreLogEntry(level: .info, message: "[8 2ms] something", receivedAt: Date()))
        await state.finishTUNLogMirror()

        XCTAssertFalse(FileManager.default.fileExists(atPath: mirrorURL(root).path))
    }

    /// 断网刷屏在副本里被折叠，内核停止时补上总结。
    func testOutageFloodIsFoldedInTheMirror() async throws {
        let (state, root) = try makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        state.setActiveModesForTesting([.tun])
        let origin = Date()

        for i in 0..<300 {
            state.receiveLog(CoreLogEntry(
                level: .error,
                message: "[\(1_000 + i) 3ms] connection: open connection to c\(i).example.invalid:443 using "
                    + "outbound/direct[direct]: dial tcp 203.0.113.7:443: no route to internet",
                receivedAt: origin.addingTimeInterval(Double(i) * 0.1)
            ))
        }
        await state.finishTUNLogMirror()

        let text = try String(contentsOf: mirrorURL(root), encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertLessThan(lines.count, 40, "300 行失败必须被折叠，实际 \(lines.count) 行")
        XCTAssertTrue(text.contains("建连失败密集"))
        XCTAssertTrue(text.contains("日志折叠结束"), "内核停止时要补上总结")
    }
}
