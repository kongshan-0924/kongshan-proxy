import Foundation
import KongshanCore
import XCTest
@testable import kongshan

/// 节点远端卡住的提示接线：连接快照 → 识别 → 按节点名合并告警。
/// 真机 2026-10-07 自建的「中转→家宽出口」节点约 14% 请求挂满 10 秒，空山此前一条提示都没有。
@MainActor
final class StalledConnectionWiringTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_790_000_000)
        func now() -> Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    }

    func testStalledHandshakesRaiseOneAlertNamedAfterTheNode() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "kongshan-stall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        let state = AppState(
            storage: Storage(rootDirectory: root),
            singBoxProcess: SingBoxProcess(binaryURL: URL(fileURLWithPath: "/usr/bin/false")),
            now: { clock.now() },
            automaticallyInitialize: false
        )
        await state.addManual(ManualHysteria2(
            name: "中转→家宽", server: "relay.example.com", port: 443, password: "secret", sni: "relay.example.com",
            skipCertificateVerification: false, obfsPassword: nil, uploadMbps: 20, downloadMbps: 100
        ))
        let node = try XCTUnwrap(state.nodes.first)
        let tag = ConfigGenerator.outboundTag(for: node)
        func stuck(_ id: String) -> StalledConnectionDetector.Sample {
            .init(id: id, outboundTag: tag, network: "tcp", port: 443, upload: 517, download: 0,
                  start: clock.now().addingTimeInterval(-8))
        }
        func alerts() -> [RuntimeEvent] { state.runtimeEvents.filter { $0.title == "节点连接卡住" } }

        state.checkStalledConnections([stuck("a")])
        clock.advance(15)
        state.checkStalledConnections([stuck("b")])
        XCTAssertTrue(alerts().isEmpty, "两条还不够")
        clock.advance(15)
        state.checkStalledConnections([stuck("c")])
        XCTAssertEqual(alerts().count, 1)
        let detail = alerts().first?.detail ?? ""
        XCTAssertTrue(detail.contains("「中转→家宽」") && detail.contains("3 条加密连接"), detail)
        XCTAssertEqual(alerts().first?.level, .warning)

        // 同一节点 30 分钟内再攒够 3 条只合并计数，不再弹。
        for id in ["d", "e", "f"] {
            clock.advance(15)
            state.checkStalledConnections([stuck(id)])
        }
        XCTAssertEqual(alerts().count, 1)
    }
}
