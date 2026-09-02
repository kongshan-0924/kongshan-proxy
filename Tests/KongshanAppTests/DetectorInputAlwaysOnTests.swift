import Foundation
import XCTest
@testable import KongshanCore
@testable import kongshan

/// 「检测器在日志页关着时还能不能收到输入」的回归。
///
/// 存在的理由是一次真实的丢证：2026-09-02 22:41 节点连续 276 次建连全部失败（100%），
/// 52 秒后用户手动关掉代理，而消息页**一条记录都没有**。
/// 根因是日志流原本挂在 `LogsView.onAppear/onDisappear` 上，
/// 检测器只在用户盯着日志页时才有输入，其余时间全瞎。
@MainActor
final class DetectorInputAlwaysOnTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-detector-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeState(root: URL) -> AppState {
        AppState(
            storage: Storage(rootDirectory: root),
            singBoxProcess: SingBoxProcess(binaryURL: URL(fileURLWithPath: "/usr/bin/false")),
            automaticallyInitialize: false
        )
    }

    private func failureEntry(_ host: String) -> CoreLogEntry {
        CoreLogEntry(
            level: .error,
            message: "[123456 3.19s] connection: open connection to \(host) using "
                + "outbound/anytls[node-placeholder]: failed to create session: EOF",
            receivedAt: Date()
        )
    }

    /// 日志页**关着**时，失败照样要被统计。
    func testFailuresAreCountedWhileLogsPageIsClosed() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(root: root)
        state.stopLogMonitoring()   // 日志页关闭

        for index in 0..<30 {
            state.receiveLog(failureEntry("api.example.invalid:\(443 + index % 3)"))
        }

        XCTAssertTrue(state.liveLogs.isEmpty, "日志页关着时不该把行攒进界面列表")
        // 统计确实进去了：结算一次就应出报告（30 次尝试全失败，远超 20/5/10% 门槛）。
        let report = state.finishAnomalyWindowsForTesting()
        XCTAssertNotNil(report, "日志页关着时失败也必须被统计到")
        XCTAssertEqual(report?.failures, 30)
    }

    /// 日志页开着时，行照常进界面列表——常开不能把显示搞坏。
    func testLinesStillReachTheListWhenPageIsOpen() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(root: root)
        state.startLogMonitoring()

        state.receiveLog(failureEntry("api.example.invalid:443"))
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(state.liveLogs.isEmpty, "日志页开着时行必须显示出来")
    }

    /// 廉价预筛**不能漏掉任何一种检测器认的形态**。漏一种就是静默丢证——
    /// 不会报错，只会在下次排查时发现又没有记录。
    func testCheapPrefilterCoversEveryShapeTheDetectorsRecognize() {
        let mustPass = [
            // 出站失败（本次事故的形态）
            "connection: open connection to a.invalid:443 using outbound/anytls[n]: failed to create session: EOF",
            "connection: open connection to a.invalid:443 using outbound/anytls[n]: dial tcp 1.2.3.4:443: i/o timeout",
            "connection: open connection to a.invalid:443 using outbound/anytls[n]: connect: connection refused",
            // 成功计数——失败率的分母，漏掉会让比例失真
            "outbound/anytls[n]: outbound connection to a.invalid:443",
            // DNS 解析超时
            "connection: open connection to a.invalid:443 using outbound/direct[direct]: "
                + "lookup a.invalid: (exchange4: context deadline exceeded | exchange6: context deadline exceeded)"
        ]
        for line in mustPass {
            XCTAssertTrue(AppState.mayConcernDetectors(line), "漏掉了：\(line.prefix(70))")
        }

        // 与检测器的真实判据交叉校验：凡是检测器认的，预筛都必须放行。
        for line in mustPass {
            let parsed = CoreLogLine.parse(line)
            let recognized = DNSStallDetector.isResolutionStall(parsed)
                || OutboundFailureDetector.isFailedAttempt(parsed)
                || OutboundFailureDetector.isSuccessfulAttempt(parsed)
            XCTAssertTrue(recognized, "样本本身就没被检测器认出，测试写错了：\(line.prefix(70))")
        }

        // 无关的行挡掉，避免白解析。
        XCTAssertFalse(AppState.mayConcernDetectors("router: found process path: /usr/bin/curl"))
        XCTAssertFalse(AppState.mayConcernDetectors("inbound/tun[tun-in]: started at utun4"))
    }
}
