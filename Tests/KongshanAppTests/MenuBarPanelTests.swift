import AppKit
import Foundation
import KongshanCore
import SwiftUI
import XCTest
@testable import kongshan

@MainActor
final class MenuBarPanelTests: XCTestCase {
    // MARK: - 主菜单与动作
    func testMainRowsAndOffOpacityRemainOperable() throws {
        let groups = (0..<13).map { PolicyGroup(name: $0 == 0 ? "节点选择" : $0 == 1 ? "自动选择" : $0 == 2 ? "AI 服务" : "组 \($0)") }
        let state = try makeState(names: ["🇺🇸 DMIT-洛杉矶 Reality"], groups: groups)
        for running in [false, true] {
            state.status = .off
            state.setActiveModesForTesting([])
            if running { state.setRunningForTesting(modes: [.systemProxy]) }
            let model = MenuBarPanelModel(state: state)
            XCTAssertEqual(model.title, running ? "已开启" : "已关闭")
            XCTAssertEqual(model.sections.map { $0.map(\.title) }, [
                ["系统代理", "TUN", "模式"],
                ["节点选择", "自动选择", "AI 服务", "更多策略组", "测试全部延迟"],
                ["打开主窗口", "刷新订阅", "登录时启动"], ["退出 kongshan"]
            ])
            XCTAssertEqual(model.controlsOpacity, running ? 1 : 0.4)
            XCTAssertTrue(model.sections[0].allSatisfy(\.enabled), "40% 是视觉状态，不禁用接管动作")
            XCTAssertEqual(model.sections[0][0].toggle, running)
            XCTAssertEqual(model.sections[1][3].value, "10 个")
            XCTAssertEqual(model.height, 454, "原型 504 整体缩到约 0.9（用户 11-09：菜单稍微调小）")
        }
        state.status = .starting
        XCTAssertEqual(MenuBarPanelModel(state: state).title, "正在启动…")
        XCTAssertFalse(MenuBarPanelModel(state: state).sections[0][0].enabled)
        state.status = .stopping
        XCTAssertEqual(MenuBarPanelModel(state: state).title, "正在关闭…")
    }

    func testPowerStartsPreferredModeAndBusyDoesNotStart() async throws {
        let state = try makeState(names: [])
        state.preferredMode = .tun
        let controller = MenuBarPanelController(state: state, openMainWindow: {})
        state.status = .starting
        await controller.togglePower()
        XCTAssertEqual(state.status, .starting)
        state.status = .off
        await controller.togglePower()
        // 走真实 AppState 的空配置启动守卫，避免测试启动内核或改动宿主接管。
        XCTAssertEqual(state.status, .failed("当前配置没有可用节点"))
        XCTAssertEqual(state.preferredMode, .tun)
        state.setRunningForTesting(modes: [])
        await controller.togglePower()
        XCTAssertEqual(state.status, .off, "内核就绪但无接管时，总开关仍必须 stop")
    }

    func testOffSystemProxyRowStartsInsteadOfBeingDisabled() async throws {
        let state = try makeState(names: [])
        let controller = MenuBarPanelController(state: state, openMainWindow: {})
        let system = MenuBarPanelModel(state: state).sections[0][0]
        XCTAssertTrue(system.enabled)
        controller.activate(system, level: 0)
        for _ in 0..<100 where state.status == .off { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(state.status, .failed("当前配置没有可用节点"))
    }

    func testSelectingNodeClosesPanelButURLTestAndMissingCannotSelect() async throws {
        let state = try makeState(names: ["节点 1", "节点 2"])
        let group = PolicyGroup(name: "手动选择")
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let controller = MenuBarPanelController(state: state, openMainWindow: {})
        controller.show(relativeTo: try XCTUnwrap(statusItem.button))
        await controller.select(.node(state.nodes[1]), in: PolicyGroup(name: "自动选择", kind: .urltest))
        XCTAssertTrue(controller.isShown)
        XCTAssertEqual(state.selectedNodeID, state.nodes[0].id)
        await controller.select(.unavailable("旧节点"), in: group)
        XCTAssertTrue(controller.isShown)
        await controller.select(.node(state.nodes[1]), in: group)
        XCTAssertEqual(state.selectedMemberName(in: group.name), "节点 2")
        XCTAssertFalse(controller.isShown)
        XCTAssertNil(controller.mainContentView)
    }

    func testDelayTestActionKeepsPanelAndPublishesCancellationText() async throws {
        let state = try makeState(names: ["节点 1"], ping: { _, _, _ in
            do { try await Task.sleep(for: .seconds(60)) } catch { return .failure("cancelled") }
            return .success(42)
        })
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let controller = MenuBarPanelController(state: state, openMainWindow: {})
        defer { controller.close(); state.cancelDelayTests() }
        controller.show(relativeTo: try XCTUnwrap(statusItem.button))
        controller.perform(.testDelays)
        for _ in 0..<100 where !state.isTestingAllDelays { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(controller.isShown)
        XCTAssertTrue(state.isTestingAllDelays)
        XCTAssertEqual(MenuBarPanelTestRow.title(testing: state.isTestingAllDelays, completed: 0, total: 1), "取消测试（0/1）")
        controller.perform(.testDelays)
        for _ in 0..<100 where state.isTestingAllDelays { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(state.isTestingAllDelays)
        XCTAssertTrue(controller.isShown)
        XCTAssertEqual(MenuBarPanelTestRow.title(testing: false, completed: 0, total: 1), "测试全部延迟")
    }

    // MARK: - 节点目录
    func testTwentyOptionsStayFlatAndTwentyOneCreatesSections() throws {
        let names = (1...19).map { "节点 \($0)" }
        let state = try makeState(names: names)
        for (index, node) in state.nodes.enumerated() { state.delays[node.id] = 100 - index }
        let small = MenuBarPanelNodeSnapshot(state: state, group: PolicyGroup(name: "小组", members: names + ["DIRECT"]))
        XCTAssertEqual(optionNames(small), names + ["DIRECT"])
        XCTAssertEqual(headings(small), [])
        let large = MenuBarPanelNodeSnapshot(state: state, group: PolicyGroup(name: "大组", members: names + ["DIRECT", "旧节点"]))
        XCTAssertEqual(headings(large), ["当前节点", "低延迟", "策略", "按地区"])
        XCTAssertEqual(Array(optionNames(large).prefix(6)), ["节点 1", "节点 19", "节点 18", "节点 17", "节点 16", "节点 15"])
        XCTAssertEqual(Array(optionNames(large).suffix(2)), ["DIRECT", "旧节点"])
        let unavailable = GroupOption.unavailable("旧节点")
        XCTAssertFalse(large.canSelect(unavailable, busy: false))
        XCTAssertFalse(large.canSelect(.node(state.nodes[0]), busy: true))
        let automatic = MenuBarPanelNodeSnapshot(state: state, group: PolicyGroup(name: "自动选择", kind: .urltest))
        XCTAssertEqual(automatic.title, "自动选择 · 自动选路")
        XCTAssertFalse(automatic.canSelect(.node(state.nodes[0]), busy: false))
    }

    func test366NodesAreReachableThroughRegionAndUnknownAlwaysLast() throws {
        let names = (1...102).map { "🇯🇵 节点 \($0)" }
            + (103...190).map { "🇺🇸 节点 \($0)" }
            + (191...254).map { "🇭🇰 节点 \($0)" }
            + (255...302).map { "🇸🇬 节点 \($0)" }
            + (303...366).map { "未知节点 \($0)" }
        let state = try makeState(names: names)
        let group = PolicyGroup(name: "手动选择")
        let root = MenuBarPanelNodeSnapshot(state: state, group: group)
        let regions = root.entries.compactMap { entry -> MenuBarPanelRegion? in
            if case let .region(region) = entry.content { return region }
            return nil
        }
        XCTAssertEqual(regions.map(\.id), ["JP", "US", "HK", "SG", ""])
        let leaves = regions.flatMap { region in
            let snapshot = MenuBarPanelNodeSnapshot(state: state, group: group, region: region)
            XCTAssertEqual(headings(snapshot), [])
            XCTAssertLessThanOrEqual(snapshot.height, 440)
            return optionNames(snapshot)
        }
        XCTAssertEqual(Set(leaves), Set(names))
        XCTAssertEqual(leaves.count, names.count)
        let buckets = ["": Array(state.nodes.prefix(100)), "US": [state.nodes[0]], "HK": [state.nodes[1]]]
        let locale = Locale(identifier: "zh_CN")
        let tied = ["US", "HK"].sorted {
            MenuBarPanelDirectory.regionName($0).compare(MenuBarPanelDirectory.regionName($1), locale: locale) == .orderedAscending
        }
        XCTAssertEqual(MenuBarPanelDirectory.regionCodes(in: buckets), tied + [""])
    }

    private func optionNames(_ snapshot: MenuBarPanelNodeSnapshot) -> [String] {
        snapshot.entries.compactMap { if case let .option(option) = $0.content { return option.name }; return nil }
    }
    private func headings(_ snapshot: MenuBarPanelNodeSnapshot) -> [String] {
        snapshot.entries.compactMap { if case let .heading(title) = $0.content { return title }; return nil }
    }

    // MARK: - 窗口与键盘
    func testPositioningClampsAcrossScreensAndFlipsChildToLeft() {
        let visible = CGRect(x: -1440, y: 40, width: 1440, height: 860)
        let anchor = CGRect(x: -40, y: 900, width: 30, height: 22)
        let main = MenuBarPanelController.mainFrame(size: .init(width: 300, height: 504), anchor: anchor, visible: visible)
        XCTAssertEqual(main.maxX, visible.maxX)
        XCTAssertTrue(visible.contains(main))
        let row = CGRect(x: main.minX + 8, y: main.maxY - 210, width: 284, height: 30)
        let child = MenuBarPanelController.childFrame(size: .init(width: 256, height: 440), row: row, parent: main, visible: visible)
        XCTAssertEqual(child.maxX, main.minX - 6)
        XCTAssertTrue(visible.contains(child))
    }

    /// 面板底板必须是系统材质并自带圆角；SwiftUI 不再画阴影——那层阴影会被无边框窗口的直角边界截断，
    /// 在四角露出直角框线（2026-11-09 用户截图）。
    func testPanelUsesNativeRoundedSurfaceWithoutSwiftUIShadow() throws {
        let state = try makeState(names: ["节点 1"])
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let controller = MenuBarPanelController(state: state, openMainWindow: {})
        defer { controller.close() }
        controller.show(relativeTo: try XCTUnwrap(item.button))
        let surface = try XCTUnwrap(controller.mainContentView)
        if #available(macOS 26.0, *) {
            XCTAssertEqual((surface as? NSGlassEffectView)?.cornerRadius, MenuBarPanelMetrics.mainRadius)
        } else {
            XCTAssertNotNil((surface as? NSVisualEffectView)?.maskImage)
        }
        let window = try XCTUnwrap(surface.window)
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        XCTAssertTrue(window.hasShadow)
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/KongshanAppTests/MenuBarPanelTests.swift", with: "Sources/kongshan/MenuBarPanelView.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains(".shadow("), "面板阴影交给窗口，SwiftUI 里不能再画")
    }

    func testKeyboardOpensModeSubpanelThenEscReleasesAllTrees() throws {
        let state = try makeState(names: ["节点 1"])
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let controller = MenuBarPanelController(state: state, openMainWindow: {})
        defer { controller.close() }
        controller.show(relativeTo: try XCTUnwrap(item.button))
        controller.mainContentView?.layoutSubtreeIfNeeded()
        for _ in 0..<4 { controller.handleKey(try key(125)) }
        XCTAssertEqual(controller.navigation.highlighted[0], "modes")
        weak var childContent: NSView?
        try autoreleasepool {
            controller.handleKey(try key(124))
            XCTAssertEqual(controller.loadedPanelCount, 2)
            childContent = controller.contentViews.last
            XCTAssertNotNil(childContent)
            controller.handleKey(try key(53))
            XCTAssertEqual(controller.loadedPanelCount, 1)
        }
        XCTAssertNil(childContent, "收起子菜单也必须断开 SwiftUI 树")
        controller.handleKey(try key(53))
        XCTAssertEqual(controller.loadedPanelCount, 0)
        XCTAssertNil(controller.mainContentView)
    }

    func testHoverLeavingPendingRowDoesNotOpenAndAppSwitchReleasesPanel() async throws {
        let state = try makeState(names: ["节点 1"])
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let controller = MenuBarPanelController(state: state, openMainWindow: {})
        defer { controller.close() }
        controller.show(relativeTo: try XCTUnwrap(statusItem.button))
        controller.mainContentView?.layoutSubtreeIfNeeded()
        let modeRow = MenuBarPanelModel(state: state).sections[0][2]
        controller.hover(modeRow, level: 0, entered: true)
        controller.hover(modeRow, level: 0, entered: false)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.loadedPanelCount, 1)
        controller.hover(modeRow, level: 0, entered: true)
        for _ in 0..<100 where controller.loadedPanelCount < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.loadedPanelCount, 2)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertFalse(controller.isShown)
        XCTAssertTrue(controller.contentViews.isEmpty)
    }

    private func key(_ code: UInt16) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }

    // MARK: - 原型快照
    func testRenderPrototypeMenuSnapshots() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["KONGSHAN_SNAPSHOT_DIR"] == nil)
        let directory = try XCTUnwrap(ProcessInfo.processInfo.environment["KONGSHAN_SNAPSHOT_DIR"].map(URL.init(fileURLWithPath:)),
                                      "快照只在指定输出目录时运行")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = ["DMIT-洛杉矶 Reality 🇺🇸", "xTom-东京 Reality 🇯🇵", "Singapore 06 🇸🇬", "HKBN 01 🇭🇰", "FRA 02 🇩🇪"]
        let groups = [PolicyGroup(name: "节点选择", members: names), PolicyGroup(name: "自动选择", kind: .urltest, members: names),
                      PolicyGroup(name: "AI 服务", members: names)] + (1...10).map { PolicyGroup(name: "策略组 \($0)", members: names) }
        for dark in [true, false] {
            for on in [true, false] {
                let state = try makeState(names: names, groups: groups)
                await state.select(optionName: names[1], in: "自动选择")
                await state.select(optionName: names[2], in: "AI 服务")
                if on { state.setRunningForTesting(modes: [.systemProxy]) }
                state.setLoginItemStatusForTesting(.enabled)
                for (index, delay) in [187, 203, 96, 42].enumerated() { state.delays[state.nodes[index].id] = delay }
                state.delays[state.nodes[4].id] = .some(nil)
                let controller = MenuBarPanelController(state: state, openMainWindow: {})
                try render(MenuBarPanelView(controller: controller).environment(state),
                    name: "menu-panel-\(dark ? "dark" : "light")-\(on ? "on" : "off")", size: .init(width: MenuBarPanelMetrics.width, height: MenuBarPanelModel(state: state).height),
                    dark: dark, directory: directory)
            }
            let largeNames = (1...102).map { "🇯🇵 节点 \($0)" } + (103...190).map { "🇺🇸 节点 \($0)" }
                + (191...254).map { "🇭🇰 节点 \($0)" } + (255...302).map { "🇸🇬 节点 \($0)" }
                + (303...366).map { "节点 \($0)" }
            let group = PolicyGroup(name: "节点选择", members: largeNames + ["DIRECT", "REJECT", "旧节点"])
            let state = try makeState(names: largeNames, groups: [group])
            for (index, node) in state.nodes.prefix(8).enumerated() { state.delays[node.id] = 42 + index * 21 }
            let controller = MenuBarPanelController(state: state, openMainWindow: {})
            let snapshot = MenuBarPanelNodeSnapshot(state: state, group: group)
            try render(MenuBarPanelNodesView(snapshot: snapshot, level: 1, controller: controller).environment(state),
                name: "menu-panel-nodes-\(dark ? "dark" : "light")", size: .init(width: MenuBarPanelMetrics.subWidth, height: snapshot.height),
                dark: dark, directory: directory)
        }
    }

    // MARK: - 夹具与离屏渲染
    private func makeState(
        names: [String], groups: [PolicyGroup] = [],
        ping: @escaping AppState.TCPPingProvider = { _, _, _ in .success(42) }
    ) throws -> AppState {
        let root = FileManager.default.temporaryDirectory.appending(path: "kongshan-panel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let storage = Storage(rootDirectory: root)
        let state = AppState(storage: storage,
            systemProxyManager: SystemProxyManager(storage: storage) { _, _ in .init(exitCode: 0, stdout: "", stderr: "") },
            systemDNSManager: SystemDNSManager(storage: storage) { _, _ in .init(exitCode: 0, stdout: "", stderr: "") },
            singBoxProcess: SingBoxProcess(binaryURL: URL(fileURLWithPath: "/usr/bin/false")),
            tcpPingProvider: ping, gatewayInterceptionProbe: { _, _, _ in nil }, automaticallyInitialize: false)
        let sourceID = groups.isEmpty ? nil : UUID()
        state.nodes = names.enumerated().map { index, name in
            ProxyNode(sourceID: sourceID, name: name, protocolType: .shadowsocks,
                      server: "n\(index).example.com", port: 443, password: "secret", method: "aes-128-gcm")
        }
        state.activeConfigID = sourceID ?? AppState.localConfigID
        if let sourceID { state.discoveredPolicyGroups[sourceID] = groups }
        state.selectedNodeID = state.nodes.first?.id
        state.speedTestMethod = .tcpPing
        state.isReady = true
        return state
    }

    private func render(_ view: some View, name: String, size: CGSize, dark: Bool, directory: URL) throws {
        let hosting = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)
            .background(Theme.menuPanelBackground)))
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.appearance = hosting.appearance
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appending(path: name + ".png"))
    }
}
