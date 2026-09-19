import Foundation
import XCTest
@testable import KongshanCore
@testable import kongshan

/// 可推进的测试时钟。`now` provider 要求 `@Sendable`，直接捕获 `var` 过不了 Swift 6 并发检查。
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var current: Date { lock.withLock { value } }

    func advance(_ interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}

/// 自诊断的接线回归。域名一律使用编造的 `.invalid`，不写真实节点或内网域名。
@MainActor
final class SelfDiagnosticsWiringTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-selfdiag-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeState(clock: TestClock) -> AppState {
        AppState(
            storage: Storage(rootDirectory: temporaryDirectory()),
            singBoxProcess: SingBoxProcess(binaryURL: URL(fileURLWithPath: "/usr/bin/false")),
            now: { clock.current },
            automaticallyInitialize: false
        )
    }

    private func stallLine(destination: String, lookup: String) -> CoreLogLine {
        CoreLogLine.parse(
            "[900001 10.0s] connection: open connection to \(destination) using "
            + "outbound/anytls[node-placeholder]: failed to create session: "
            + "lookup \(lookup): (exchange4: context deadline exceeded | exchange6: context deadline exceeded)"
        )
    }

    /// 内核日志里的解析超时要能聚合成一条运行事件。这条链路断掉不会报错，只会安静地不留证据。
    func testResolutionStallsProduceWarningRuntimeEvent() {
        let clock = TestClock(Date(timeIntervalSince1970: 1_760_000_000))
        let state = makeState(clock: clock)

        for _ in 0..<4 {
            state.inspectForDNSStall(
                stallLine(destination: "api.example.invalid:443", lookup: "server.node-placeholder.invalid")
            )
            clock.advance(5)
        }
        XCTAssertFalse(
            state.runtimeEvents.contains { $0.title == "DNS 解析持续超时" },
            "窗口未到期不应该出事件"
        )

        clock.advance(200)
        state.inspectForDNSStall(
            stallLine(destination: "api.example.invalid:443", lookup: "server.node-placeholder.invalid")
        )

        let event = state.runtimeEvents.last { $0.title == "DNS 解析持续超时" }
        XCTAssertNotNil(event, "窗口到期后必须留下一条运行事件")
        XCTAssertEqual(event?.level, .warning)
        XCTAssertEqual(
            event?.detail?.contains("节点域名解析超时 4 次"), true,
            "必须区分节点自身域名与普通域名，前者会让整条代理停摆"
        )
    }

    /// 运行事件是会被导出的。解析目标里可能有用户的节点域名与内网域名，绝不能落进去。
    func testRuntimeEventDetailNeverCarriesResolvedDomain() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_760_000_000))
        let state = makeState(clock: clock)

        for _ in 0..<4 {
            state.inspectForDNSStall(
                stallLine(destination: "api.example.invalid:443", lookup: "server.node-placeholder.invalid")
            )
        }
        clock.advance(200)
        state.inspectForDNSStall(
            stallLine(destination: "api.example.invalid:443", lookup: "server.node-placeholder.invalid")
        )

        let event = try XCTUnwrap(state.runtimeEvents.last { $0.title == "DNS 解析持续超时" })
        let text = (event.title) + " " + (event.detail ?? "")
        XCTAssertFalse(text.contains("placeholder"), "解析目标不得出现在运行事件里：\(text)")
        XCTAssertFalse(text.contains(".invalid"), "解析目标不得出现在运行事件里：\(text)")
    }

    /// 非超时的普通日志行不能触发任何自诊断记录，否则消息页会被正常流量刷满。
    func testOrdinaryLogLinesDoNotRecordAnything() {
        let state = makeState(clock: TestClock(Date(timeIntervalSince1970: 1_760_000_000)))
        state.inspectForDNSStall(
            CoreLogLine.parse("[900002 12ms] outbound/direct[direct]: outbound connection to shop.example.invalid:443")
        )
        XCTAssertTrue(state.runtimeEvents.isEmpty)
    }

    /// 出站失败要能聚合成一条运行事件，并且**用节点名而不是 tag/地址**呈现。
    func testOutboundFailuresSurfaceAsRuntimeEventWithNodeName() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_760_000_000))
        let state = makeState(clock: clock)
        let node = ProxyNode(
            sourceID: UUID(),
            name: "东京 01",
            protocolType: .shadowsocks,
            server: "node.example.invalid",
            port: 443,
            password: "secret",
            method: "aes-128-gcm"
        )
        state.nodes = [node]
        let tag = ConfigGenerator.outboundTag(for: node)

        for i in 0..<30 {
            state.inspectForOutboundFailure(
                CoreLogLine.parse("[1 2ms] outbound/anytls[\(tag)]: outbound connection to s\(i).example.invalid:443")
            )
            clock.advance(1)
        }
        for i in 0..<10 {
            state.inspectForOutboundFailure(CoreLogLine.parse(
                "[2 1.8s] connection: open connection to f\(i).example.invalid:443 using outbound/anytls[\(tag)]: failed to create session: dial tcp 203.0.113.9:8030: connect: connection refused"
            ))
            clock.advance(1)
        }
        XCTAssertFalse(state.runtimeEvents.contains { $0.title == "节点建连失败偏多" },
                       "窗口未到期不该出事件")

        clock.advance(700)
        state.inspectForOutboundFailure(
            CoreLogLine.parse("[3 2ms] outbound/anytls[\(tag)]: outbound connection to tail.example.invalid:443")
        )

        let event = try XCTUnwrap(state.runtimeEvents.last { $0.title == "节点建连失败偏多" })
        XCTAssertEqual(event.level, .warning)
        let detail = try XCTUnwrap(event.detail)
        XCTAssertTrue(detail.contains("东京 01"), "要显示节点名，实际：\(detail)")
        XCTAssertTrue(detail.contains("connection refused"), "要给出主要原因，实际：\(detail)")
        XCTAssertFalse(detail.contains("203.0.113.9"), "不得暴露服务器地址：\(detail)")
        XCTAssertFalse(detail.contains(tag), "不得暴露原始出站 tag：\(detail)")
    }
}
