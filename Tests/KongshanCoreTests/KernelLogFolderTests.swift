import Foundation
import XCTest
@testable import KongshanCore

/// 断网刷屏折叠（`KernelLogFolder`）的回归。
///
/// 存在的理由：真机 2026-09-26 整机断网近两小时，内核每分钟约 4,500 行，日志文件几分钟就写满一轮，
/// 断网前后的记录十几分钟内被冲掉，事后复盘时整段都不在了。
final class KernelLogFolderTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_790_000_000)
    private let utc8 = TimeZone(secondsFromGMT: 8 * 3600)!

    private func stamp(_ seconds: Double) -> String {
        KernelLogFolder.timestamp(origin.addingTimeInterval(seconds), timeZone: utc8)
    }

    /// 与真机输出一致：级别与连接 ID 都带 ANSI 颜色码。
    private func failureLine(id: Int, at seconds: Double, outbound: String = "direct[direct]") -> String {
        "\(stamp(seconds)) \u{1B}[31mERROR\u{1B}[0m [\u{1B}[38;5;217m\(id)\u{1B}[0m 3ms] connection: "
            + "open connection to x\(id).example.invalid:443 using outbound/\(outbound): "
            + "dial tcp 203.0.113.7:443: no route to internet"
    }

    private func attemptLine(id: Int, at seconds: Double) -> String {
        "\(stamp(seconds)) \u{1B}[36mINFO\u{1B}[0m [\u{1B}[38;5;217m\(id)\u{1B}[0m 1ms] outbound/direct[direct]: "
            + "outbound connection to x\(id).example.invalid:443"
    }

    private func globalLine(at seconds: Double, _ text: String) -> String {
        "\(stamp(seconds)) \u{1B}[36mINFO\u{1B}[0m \(text)"
    }

    // MARK: - 行分类

    func testRecognizesColoredConnectionLinesAndIgnoresOtherBrackets() {
        let colored = KernelLogFolder.stripANSI(failureLine(id: 101789385, at: 0))
        XCTAssertTrue(KernelLogFolder.isPerConnection(colored))
        XCTAssertTrue(KernelLogFolder.isFailure(colored))
        XCTAssertFalse(colored.contains("\u{1B}"), "颜色码必须去干净")

        let global = KernelLogFolder.stripANSI(globalLine(at: 0, "outbound/vless[node-abc]: started"))
        XCTAssertFalse(KernelLogFolder.isPerConnection(global), "[node-xxx] 不是连接 ID")
        let inbound = KernelLogFolder.stripANSI(globalLine(at: 0, "inbound/mixed[mixed-in]: tcp server started at 127.0.0.1:41665"))
        XCTAssertFalse(KernelLogFolder.isPerConnection(inbound), "[mixed-in] 不是连接 ID")
    }

    /// 广告拦截每命中一次就是一条 `operation not permitted`；算成失败会让正常浏览也触发折叠。
    func testRuleRejectionsAndCancellationsAreNotFailures() {
        let reject = "\(stamp(0)) ERROR [12 8ms] connection: open connection to ads.example.invalid:443 "
            + "using outbound/block[reject]: operation not permitted"
        let canceled = "\(stamp(0)) ERROR [13 1ms] connection: open connection to a.example.invalid:443 "
            + "using outbound/vless[node-x]: failed to create session: context canceled"
        XCTAssertFalse(KernelLogFolder.isFailure(reject))
        XCTAssertFalse(KernelLogFolder.isFailure(canceled))
    }

    func testTimestampMatchesKernelFormat() {
        XCTAssertEqual(
            KernelLogFolder.timestamp(Date(timeIntervalSince1970: 1_790_000_000), timeZone: utc8),
            "+0800 2026-09-21 22:13:20"
        )
    }

    // MARK: - 状态机

    func testOrdinaryTrafficPassesThroughUntouched() {
        var folder = KernelLogFolder(timeZone: utc8)
        var written: [String] = []
        for i in 0..<200 {
            written += folder.process(attemptLine(id: i, at: Double(i) * 0.1), at: origin.addingTimeInterval(Double(i) * 0.1))
        }
        // 零星失败（10 秒内远不到 30 次）照常落盘，细节是排查节点问题要看的。
        for i in 0..<10 {
            written += folder.process(failureLine(id: 1_000 + i, at: 20 + Double(i)), at: origin.addingTimeInterval(20 + Double(i)))
        }
        XCTAssertEqual(written.count, 210)
        XCTAssertFalse(folder.isFolding)
    }

    /// 断网：每秒约 8 次失败、每次尝试 2 行。进入折叠后逐条连接日志不再落盘，
    /// 全局事件照常写，每分钟一条汇总，恢复后补总结并恢复逐条落盘。
    func testOutageFloodIsFoldedIntoPeriodicSummariesAndAClosingSummary() throws {
        var folder = KernelLogFolder(timeZone: utc8)
        var written: [String] = []
        var id = 0
        var input = 0
        // 2 分钟断网：每 0.125 秒一次尝试（尝试行 + 失败行）。
        var t = 0.0
        while t < 120 {
            let date = origin.addingTimeInterval(t)
            written += folder.process(attemptLine(id: id, at: t), at: date)
            written += folder.process(failureLine(id: id, at: t, outbound: id % 3 == 0 ? "vless[node-x]" : "direct[direct]"), at: date)
            input += 2
            id += 1
            if Int(t * 8) % 240 == 0 {
                written += folder.process(globalLine(at: t, "network: updated default interface"), at: date)
                input += 1
            }
            t += 0.125
        }
        XCTAssertTrue(folder.isFolding)
        // 网络恢复：35 秒后来了正常连接。
        let recovered = origin.addingTimeInterval(155)
        written += folder.process(attemptLine(id: 99_999, at: 155), at: recovered)
        XCTAssertFalse(folder.isFolding, "安静超过 30 秒必须退出折叠")

        let plain = written.map(KernelLogFolder.stripANSI)
        XCTAssertLessThan(written.count, input / 10, "刷屏必须被压到原来的一成以下，实际 \(written.count)/\(input)")
        XCTAssertEqual(plain.filter { $0.contains("建连失败密集") }.count, 1)
        let periodic = plain.filter { $0.contains("日志折叠中") }
        XCTAssertGreaterThanOrEqual(periodic.count, 1, "折叠期间每分钟要有汇总")
        let closing = try XCTUnwrap(plain.first { $0.contains("日志折叠结束") })
        XCTAssertTrue(closing.contains("no route to internet"), "总结要给出主要原因：\(closing)")
        XCTAssertTrue(closing.contains("直连") && closing.contains("节点"), "总结要区分直连与节点：\(closing)")
        XCTAssertFalse(
            plain.filter { $0.contains("kongshan:") }.joined().contains("203.0.113"),
            "汇总里不得出现地址"
        )
        XCTAssertTrue(plain.contains { $0.contains("network: updated default interface") }, "全局事件照常落盘")
        XCTAssertTrue(written.last?.contains("x99999.example.invalid") == true, "恢复后逐条日志照常落盘")
    }

    /// 广告拦截再密集也不能触发折叠。
    func testDenseRuleRejectionsDoNotTriggerFolding() {
        var folder = KernelLogFolder(timeZone: utc8)
        var written = 0
        for i in 0..<300 {
            let line = "\(stamp(Double(i) * 0.02)) ERROR [\(i) 8ms] connection: open connection to ads\(i).example.invalid:443 "
                + "using outbound/block[reject]: operation not permitted"
            written += folder.process(line, at: origin.addingTimeInterval(Double(i) * 0.02)).count
        }
        XCTAssertEqual(written, 300)
        XCTAssertFalse(folder.isFolding)
    }

    /// 内核停止时仍在折叠：`finish` 必须补上总结，不然最后一段只剩省略、没有交代。
    func testFinishWritesClosingSummaryOnlyWhileFolding() {
        var folder = KernelLogFolder(timeZone: utc8)
        XCTAssertTrue(folder.finish(at: origin).isEmpty)
        for i in 0..<40 {
            _ = folder.process(failureLine(id: i, at: Double(i) * 0.1), at: origin.addingTimeInterval(Double(i) * 0.1))
        }
        XCTAssertTrue(folder.isFolding)
        let closing = folder.finish(at: origin.addingTimeInterval(10))
        XCTAssertEqual(closing.count, 1)
        XCTAssertTrue(closing[0].contains("日志折叠结束"))
        XCTAssertFalse(folder.isFolding)
    }

    func testGroupedNumbersAndDurations() {
        XCTAssertEqual(KernelLogFolder.grouped(0), "0")
        XCTAssertEqual(KernelLogFolder.grouped(4_512), "4,512")
        XCTAssertEqual(KernelLogFolder.grouped(1_234_567), "1,234,567")
        XCTAssertEqual(KernelLogFolder.formatDuration(45), "45 秒")
        XCTAssertEqual(KernelLogFolder.formatDuration(90), "1 分 30 秒")
        XCTAssertEqual(KernelLogFolder.formatDuration(6_780), "1 小时 53 分")
    }
}
