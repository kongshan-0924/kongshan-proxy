import XCTest
@testable import KongshanCore
@testable import kongshan

@MainActor
final class DashboardRouteTests: XCTestCase {
    func testOffRouteKeepsIdentityButHidesExit() {
        let state = makeState()
        state.applyExitAnalysisSnapshotFixture()

        let route = DashboardRoute(state: state)

        XCTAssertEqual(route.statusTitle, "已关闭")
        XCTAssertEqual(route.config.value, "sub.example.com")
        XCTAssertEqual(route.policy.value, "节点选择")
        XCTAssertEqual(route.node.value, "香港 IEPL 01")
        XCTAssertFalse(route.hasTakeover)
        XCTAssertNil(route.exit)
    }

    func testRunningRouteShowsExitOnlyDuringTakeover() {
        let state = makeState()
        state.applyExitAnalysisSnapshotFixture()
        state.setRunningForTesting(modes: [.systemProxy])

        let route = DashboardRoute(state: state)

        XCTAssertTrue(route.hasTakeover)
        XCTAssertEqual(route.exit?.value, "Tokyo, Japan")
        XCTAssertEqual(route.exit?.detail, "203.0.113.23")
    }

    func testCoreOnlyDoesNotPresentStaleExitAsActiveRoute() {
        let state = makeState()
        state.applyExitAnalysisSnapshotFixture()
        state.setRunningForTesting(modes: [])

        let route = DashboardRoute(state: state)

        XCTAssertEqual(route.statusTitle, "内核就绪 · 未接管")
        XCTAssertFalse(route.hasTakeover)
        XCTAssertNil(route.exit)
    }

    private func makeState() -> AppState {
        let state = AppState(
            storage: Storage(rootDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "kongshan-route-tests-\(UUID().uuidString)")),
            automaticallyInitialize: false
        )
        let source = SubscriptionSource(
            name: "sub.example.com",
            url: URL(string: "https://sub.example.com/sub")!
        )
        let node = ProxyNode(
            sourceID: source.id,
            name: "香港 IEPL 01",
            protocolType: .shadowsocks,
            server: "example.com",
            port: 443
        )
        state.subscriptions = [source]
        state.nodes = [node]
        state.activeConfigID = source.id
        state.selectedNodeID = node.id
        state.discoveredPolicyGroups[source.id] = [
            PolicyGroup(name: "节点选择", kind: .selector, members: [node.name]),
            PolicyGroup(name: "流媒体", kind: .selector, members: ["节点选择"]),
            PolicyGroup(name: "自动选择", kind: .urltest, members: ["节点选择"])
        ]
        return state
    }
}
