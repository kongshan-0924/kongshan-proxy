import KongshanCore
import XCTest
@testable import kongshan

/// 2026-09-16 事故：换网与停止相隔 3 秒，事后 Thunderbolt Bridge 的 DNS 仍指着已消失的
/// TUN 地址，而它的服务优先级高于 Wi-Fi → 全机解析瘫痪五分钟。
/// 这里钉住两条修复与新增的自检流程。
@MainActor
final class NetworkRepairTests: XCTestCase {

    // MARK: - 修复一：停止必须掐掉在飞的网络变化处理

    /// `stop()` 若不取消 `pathChangeTask`，它末尾的 reassert 会把接管重新盖回去，
    /// 而停止流程已经走完、再无人还原。用源码断言钉死调用顺序——
    /// 这个竞态需要精确时序才能复现，行为测试不稳，源码检查反而是可靠的护栏。
    func testStopCancelsInFlightNetworkChangeTaskBeforeRestoring() throws {
        let source = try String(contentsOf: Self.appStateURL, encoding: .utf8)
        let body = try Self.body(of: "func stop(reason: String", in: source)
        let cancel = try XCTUnwrap(body.range(of: "pathChangeTask?.cancel()"),
                                  "stop() 必须取消在飞的网络变化处理")
        let restore = try XCTUnwrap(body.range(of: "systemProxyManager.restore()"),
                                    "stop() 应当有还原步骤")
        XCTAssertTrue(cancel.lowerBound < restore.lowerBound,
                      "取消必须发生在还原之前，否则竞态窗口仍在")
    }

    /// 修复二：停止后兜底清扫。此前残留清扫只在「启动」「网络变化」跑，
    /// 于是停止后的残留要等到下次启动才被发现——正是这次放大成五分钟断网的原因。
    func testStopSweepsResidueAfterRestoring() throws {
        let source = try String(contentsOf: Self.appStateURL, encoding: .utf8)
        let body = try Self.body(of: "func stop(reason: String", in: source)
        let restore = try XCTUnwrap(body.range(of: "systemProxyManager.restore()"))
        let sweep = try XCTUnwrap(body.range(of: "sweepTakeoverResidue(trigger:"),
                                  "stop() 结束后必须做一次不依赖快照的残留清扫")
        XCTAssertTrue(restore.lowerBound < sweep.lowerBound, "兜底清扫应在还原之后")
    }

    // MARK: - 网络服务顺序解析（事故的要害信息）

    func testServiceOrderParsingKeepsPriority() {
        let output = """
        An asterisk (*) denotes that a network service is disabled.
        (1) Thunderbolt Bridge
        (Hardware Port: Thunderbolt Bridge, Device: bridge0)

        (2) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)
        """
        let parsed = NetworkStateParser.serviceOrder(from: output)
        XCTAssertEqual(parsed.map(\.order), [1, 2])
        XCTAssertEqual(parsed.map(\.name), ["Thunderbolt Bridge", "Wi-Fi"])
    }

    /// 停用的服务（前缀 `*`）也要收进来——停用不代表上面没有残留，
    /// 因为"停用"而跳过清理，正是残留活下来的方式之一。
    func testDisabledServiceIsStillListed() {
        let output = """
        An asterisk (*) denotes that a network service is disabled.
        (1) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)

        (*2) USB 10/100/1000 LAN
        (Hardware Port: USB 10/100/1000 LAN, Device: en5)
        """
        let parsed = NetworkStateParser.serviceOrder(from: output)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed.last?.name, "USB 10/100/1000 LAN")
        XCTAssertEqual(parsed.last?.order, 2)
    }

    /// `(Hardware Port: …)` 这类行不能被当成服务。
    func testHardwarePortLinesAreNotServices() {
        let parsed = NetworkStateParser.serviceOrder(from: "(Hardware Port: Wi-Fi, Device: en0)")
        XCTAssertTrue(parsed.isEmpty)
    }

    /// 未设置 DNS 时 macOS 回的是一句人话，必须识别成"空"而不是一个叫
    /// "There aren't any DNS Servers set on X." 的服务器。
    func testDNSParsingTreatsHumanReadableEmptyAsNone() {
        XCTAssertTrue(NetworkStateParser.dnsServers(
            from: "There aren't any DNS Servers set on Thunderbolt Bridge.").isEmpty)
        XCTAssertEqual(NetworkStateParser.dnsServers(from: "1.1.1.1\n8.8.8.8"), ["1.1.1.1", "8.8.8.8"])
        XCTAssertTrue(NetworkStateParser.dnsServers(from: "   \n  ").isEmpty)
    }

    // MARK: - 报告汇总

    func testReportSummaryPrioritisesProblemsOverFixes() {
        func item(_ s: NetworkCheckSeverity) -> NetworkCheckItem {
            NetworkCheckItem(title: "t\(s.rawValue)", detail: "", severity: s)
        }
        let mixed = NetworkRepairReport(checkedAt: Date(), items: [item(.ok), item(.fixed), item(.problem)], services: [])
        XCTAssertEqual(mixed.problemCount, 1)
        XCTAssertEqual(mixed.fixedCount, 1)
        XCTAssertEqual(mixed.summary, "发现 1 项问题", "有问题时不能只报「已修复」")

        let fixedOnly = NetworkRepairReport(checkedAt: Date(), items: [item(.ok), item(.fixed)], services: [])
        XCTAssertEqual(fixedOnly.summary, "已修复 1 项")

        let clean = NetworkRepairReport(checkedAt: Date(), items: [item(.ok)], services: [])
        XCTAssertEqual(clean.summary, "一切正常")
    }

    /// 自检的顺序不能反：**先清残留、再验连通性**，否则测的是坏状态下的结果。
    func testRepairSweepsBeforeProbingConnectivity() throws {
        let source = try String(contentsOf: Self.appStateURL, encoding: .utf8)
        let body = try Self.body(of: "func runNetworkRepair()", in: source)
        let sweep = try XCTUnwrap(body.range(of: "sweepTakeoverResidue(trigger: \"网络自检\")"))
        let probe = try XCTUnwrap(body.range(of: "SiteReachabilityProbe.run"))
        XCTAssertTrue(sweep.lowerBound < probe.lowerBound, "必须先清残留再验连通性")
    }

    // MARK: - 工具

    private static var appStateURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/kongshan/AppState.swift")
    }

    /// 取出某个函数的函数体（按大括号配平）。
    private static func body(of signature: String, in source: String) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: signature), "找不到 \(signature)")
        var depth = 0
        var began = false
        var index = start.lowerBound
        while index < source.endIndex {
            let ch = source[index]
            if ch == "{" { depth += 1; began = true }
            if ch == "}" {
                depth -= 1
                if began, depth == 0 { return source[start.lowerBound...index] }
            }
            index = source.index(after: index)
        }
        throw XCTSkip("未能取出 \(signature) 的函数体")
    }
}
