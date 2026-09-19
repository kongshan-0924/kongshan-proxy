import XCTest

/// 草稿归属守卫。
///
/// 一个 `Codable` 设置结构体若在两个视图里各有一份 `@State` 草稿、且都无条件
/// `onChange` 同步，两处同时编辑会互相覆盖：A 页改了没应用 → B 页拨动任意开关触发
/// `state.routingSettings` 变化 → A 页的草稿被冲掉，用户的输入无声消失。
///
/// 2026-09-17 信息架构重构把绕过列表从设置页搬到规则页时，正是先删掉设置页那份草稿
/// 才算搬完。这条守着它不被搬回来。
final class DraftOwnershipGuardTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: "Sources/kongshan/\(name)"), encoding: .utf8)
    }

    private let viewFiles = [
        "MainWindowView.swift", "NodesView.swift", "SettingsView.swift", "DashboardView.swift",
        "PolicyGroupsView.swift", "RoutingView.swift", "ConnectionsView.swift", "LogsView.swift",
        "MessagesView.swift", "SharingView.swift", "DiagnosticsView.swift", "ExitAnalysisView.swift",
        "SubscriptionScheduleSheet.swift", "RuleSetDatabaseSheet.swift", "SpeedTestURLSheet.swift",
    ]

    /// 每个设置结构体的 `@State` 草稿在全应用只能有一处。
    func testEachSettingsStructHasExactlyOneDraftHolder() throws {
        let structs = ["RoutingSettings", "TunSettings", "DNSSettings", "SubscriptionUpdateSettings"]
        for name in structs {
            var holders: [String] = []
            for file in viewFiles {
                let text = (try? source(file)) ?? ""
                if text.contains("@State private var") && text.contains("\(name).defaults") {
                    // 只认「@State … = <结构体>.defaults」这种草稿声明
                    for line in text.split(separator: "\n") where
                        line.contains("@State private var") && line.contains("\(name).defaults") {
                        holders.append(file)
                    }
                }
            }
            XCTAssertLessThanOrEqual(
                holders.count, 1,
                "\(name) 有 \(holders.count) 处草稿：\(holders)。两处同时编辑会互相覆盖——只保留产生这个设置的那一页。"
            )
        }
    }

    /// 草稿跟随外部变化时必须先判断自己脏不脏。
    /// 无条件 `onChange(of: state.X) { _, new in draft = new }` 会在用户编辑途中冲掉输入。
    func testDraftSyncChecksDirtinessFirst() throws {
        for file in viewFiles {
            let text = (try? source(file)) ?? ""
            for settings in ["routingSettings", "tunSettings", "dnsSettings"] {
                XCTAssertFalse(
                    text.contains(".onChange(of: state.\(settings)) { _, new in"),
                    "\(file) 无条件同步 \(settings) 草稿；应改成「草稿未脏才同步」"
                )
            }
        }
    }
}
