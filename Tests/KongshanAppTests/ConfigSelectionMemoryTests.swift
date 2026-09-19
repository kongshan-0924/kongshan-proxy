import KongshanCore
import XCTest
@testable import kongshan

/// 切配置时记住「这个配置上次用的节点与策略组选择」。
///
/// 旧行为：`setActiveConfig` 把 `selectedNodeID` 与 `groupSelections` 一起清空、再选第一个节点，
/// 于是 A→B→A 回来后选择全丢，用户得重新找一遍刚才在用的节点。
@MainActor
final class ConfigSelectionMemoryTests: XCTestCase {
    private struct Fixture {
        let state: AppState
        let root: URL
        let configA: UUID
        let configB: UUID
        let nodesA: [ProxyNode]
        let nodesB: [ProxyNode]
    }

    private func makeFixture() -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-selmem-\(UUID().uuidString)", directoryHint: .isDirectory)
        let state = AppState(storage: Storage(rootDirectory: root), automaticallyInitialize: false)

        let a = SubscriptionSource(name: "机场 A", url: URL(string: "https://example.com/a.yaml")!)
        let b = SubscriptionSource(name: "机场 B", url: URL(string: "https://example.com/b.yaml")!)
        func node(_ source: UUID, _ name: String) -> ProxyNode {
            ProxyNode(
                sourceID: source, name: name, protocolType: .shadowsocks,
                server: "127.0.0.1", port: 9, password: "secret", method: "aes-128-gcm"
            )
        }
        let nodesA = [node(a.id, "A-东京"), node(a.id, "A-香港"), node(a.id, "A-新加坡")]
        let nodesB = [node(b.id, "B-洛杉矶"), node(b.id, "B-法兰克福")]
        state.subscriptions = [a, b]
        state.nodes = nodesA + nodesB
        state.activeConfigID = a.id
        return Fixture(state: state, root: root, configA: a.id, configB: b.id,
                       nodesA: nodesA, nodesB: nodesB)
    }

    /// 本功能的核心：换过去再换回来，节点还是原来那个。
    func testSwitchingBackRestoresTheNodeThatConfigLastUsed() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        // 在 A 里挑第三个节点（刻意不选第一个——否则跟"回退到首个"的旧行为分不开）。
        f.state.selectedNodeID = f.nodesA[2].id

        await f.state.setActiveConfig(f.configB)
        XCTAssertEqual(f.state.activeConfigID, f.configB)
        XCTAssertTrue(
            f.nodesB.map(\.id).contains(try XCTUnwrap(f.state.selectedNodeID)),
            "切到 B 之后当前节点必须是 B 的节点"
        )

        // 在 B 里也挑一个非首位的。
        f.state.selectedNodeID = f.nodesB[1].id

        await f.state.setActiveConfig(f.configA)
        XCTAssertEqual(f.state.selectedNodeID, f.nodesA[2].id, "切回 A 应复原 A 上次用的节点")

        await f.state.setActiveConfig(f.configB)
        XCTAssertEqual(f.state.selectedNodeID, f.nodesB[1].id, "切回 B 应复原 B 上次用的节点")
    }

    /// 记住的节点被订阅更新删掉了：回退到第一个，而不是留着一个不存在的 ID。
    func testRememberedNodeThatDisappearedFallsBackToFirstNode() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        f.state.selectedNodeID = f.nodesA[2].id
        await f.state.setActiveConfig(f.configB)

        // 模拟订阅更新：A 只剩下头两个节点。
        f.state.nodes = Array(f.nodesA.prefix(2)) + f.nodesB

        await f.state.setActiveConfig(f.configA)
        let restored = try XCTUnwrap(f.state.selectedNodeID)
        XCTAssertNotEqual(restored, f.nodesA[2].id, "已消失的节点不能被选中")
        XCTAssertEqual(restored, f.nodesA[0].id, "应回退到该配置的第一个节点")
    }

    /// 规则模式下真正决定走哪个节点的是策略组选择，只记主节点等于只修一半。
    func testGroupSelectionsAreRestoredWithTheConfig() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        f.state.selectedNodeID = f.nodesA[1].id
        await f.state.select(optionName: "A-新加坡", in: "流媒体")
        XCTAssertEqual(f.state.groupSelections["流媒体"], "A-新加坡")

        await f.state.setActiveConfig(f.configB)
        XCTAssertNil(f.state.groupSelections["流媒体"], "切到 B 后不该带着 A 的组选择")

        await f.state.setActiveConfig(f.configA)
        XCTAssertEqual(f.state.groupSelections["流媒体"], "A-新加坡", "切回 A 应连组选择一起复原")
        XCTAssertEqual(f.state.selectedNodeID, f.nodesA[1].id)
    }

    /// 记忆要跨重启，所以必须落进 settings.json。
    func testSelectionMemoryIsWrittenToTheSettingsFile() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        f.state.selectedNodeID = f.nodesA[2].id
        await f.state.setActiveConfig(f.configB)

        let data = try Data(contentsOf: f.root.appending(path: "settings.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let selections = try XCTUnwrap(
            root["configSelections"] as? [String: Any],
            "settings.json 里必须有 configSelections，且是键值对而不是数组"
        )
        let entry = try XCTUnwrap(selections[f.configA.uuidString] as? [String: Any])
        XCTAssertEqual(entry["nodeID"] as? String, f.nodesA[2].id.uuidString)
    }

    /// 删掉配置时记忆要一起删：留着既是垃圾，同一 UUID 被复用时还会复原到失效节点。
    func testRemovingASubscriptionDropsItsSelectionMemory() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        f.state.selectedNodeID = f.nodesA[2].id
        await f.state.setActiveConfig(f.configB)
        XCTAssertNotNil(f.state.configSelectionMemory[f.configA])

        await f.state.removeSubscription(id: f.configA)
        XCTAssertNil(f.state.configSelectionMemory[f.configA], "配置删了，它的记忆也该没了")
    }

    /// 持久化用字符串键（`[UUID: T]` 会被编成 [k,v,k,v] 数组，设置文件就没法读了）。
    func testStringKeyRoundTripAndBadKeysAreDropped() {
        let config = UUID()
        let node = UUID()
        let memory = [config: ConfigSelectionMemory(nodeID: node, groupSelections: ["组": "成员"])]

        let encoded = AppState.encodeSelectionMemory(memory)
        XCTAssertEqual(encoded.keys.first, config.uuidString)

        XCTAssertEqual(AppState.decodeSelectionMemory(encoded), memory)
        XCTAssertEqual(AppState.decodeSelectionMemory(nil), [:], "旧设置文件没有该字段时应为空")

        var dirty = encoded
        dirty["这不是 UUID"] = ConfigSelectionMemory(nodeID: nil, groupSelections: [:])
        XCTAssertEqual(
            AppState.decodeSelectionMemory(dirty), memory,
            "一处脏键不该毁掉整份记忆，只丢它自己"
        )
    }
}
