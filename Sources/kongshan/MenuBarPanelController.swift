import AppKit
import KongshanCore
import Observation
import SwiftUI

// MARK: - 非激活窗口与键盘状态
private final class MenuBarNonactivatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor @Observable
final class MenuBarPanelNavigation {
    var highlighted: [Int: String] = [:]
    /// 键盘刚把高亮移到的那一行：长列表据此滚到可视区。只有方向键会写它——鼠标悬停也改 `highlighted`，
    /// 若跟着滚，停在半露的边缘行上时列表会在鼠标下自己挪动（2026-11-10 审计）。
    /// `sequence` 每次递增，同一行被再次选中也算一次新请求。
    var keyboardTarget: KeyboardTarget?

    struct KeyboardTarget: Equatable {
        let level: Int
        let id: String
        let sequence: Int
    }
}

@MainActor
final class MenuBarPanelController: NSObject {
    let state: AppState
    let navigation = MenuBarPanelNavigation()
    private let openMainWindow: () -> Void
    private var panels: [NSPanel] = []
    private var items: [Int: [MenuBarPanelItem]] = [:]
    private var openedRows: [Int: String] = [:]
    private var anchors: [Int: [String: WeakAnchor]] = [:]
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var hoverTask: Task<Void, Never>?
    private var pendingHover: (level: Int, id: String)?
    private var previousMouse = NSEvent.mouseLocation
    private var currentMouse = NSEvent.mouseLocation
    private weak var statusButton: NSStatusBarButton?
    private var keyboardLevel = 0
    /// 每打开一次加一：异步动作完成后只关「发起它的那一次」打开的面板。
    private var openGeneration = 0

    private final class WeakAnchor {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    init(state: AppState, openMainWindow: @escaping () -> Void) {
        self.state = state
        self.openMainWindow = openMainWindow
        super.init()
    }

    var isShown: Bool { !panels.isEmpty }
    var loadedPanelCount: Int { panels.count }
    var mainContentView: NSView? { panels.first?.contentView }
    var contentViews: [NSView] { panels.compactMap(\.contentView) }

    func toggle(relativeTo button: NSStatusBarButton) {
        if isShown { close() } else { show(relativeTo: button) }
    }

    func show(relativeTo button: NSStatusBarButton) {
        close()
        openGeneration &+= 1
        statusButton = button
        previousMouse = NSEvent.mouseLocation
        currentMouse = previousMouse
        // 状态项按钮偶尔还没挂进状态栏窗口（启动瞬间、测试进程），此时退回主屏右上角，
        // 不能直接放弃打开——否则右键毫无反应且没有任何线索。
        let window = button.window
        let anchor = window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
            ?? NSScreen.main.map { CGRect(x: $0.visibleFrame.maxX - 320, y: $0.visibleFrame.maxY, width: 24, height: 0) }
            ?? .zero
        let screen = window?.screen ?? NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        // 无屏幕（ssh 下跑测试、显示器休眠切换瞬间）时用一块假想可见区，面板照常构建，不静默放弃。
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let model = MenuBarPanelModel(state: state)
        items[0] = [.init(id: "power", title: model.title, enabled: !state.isBusy, action: .power)]
            + model.sections.flatMap { $0 }
        let size = CGSize(width: MenuBarPanelMetrics.width, height: min(model.height, visible.height))
        let panel = makePanel(MenuBarPanelView(controller: self).environment(state), size: size, radius: MenuBarPanelMetrics.mainRadius)
        panel.setFrame(Self.mainFrame(size: size, anchor: anchor, visible: visible), display: false)
        panels.append(panel)
        installMonitors()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        hoverTask?.cancel()
        hoverTask = nil
        pendingHover = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        closeChildren(after: -1)
        navigation.highlighted.removeAll()
        navigation.keyboardTarget = nil
        keyboardLevel = 0
        statusButton = nil
    }

    private func makePanel(_ view: some View, size: CGSize, radius: CGFloat = MenuBarPanelMetrics.subRadius) -> NSPanel {
        let panel = MenuBarNonactivatingPanel(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary, .moveToActiveSpace]
        panel.contentView = Self.nativeSurface(NSHostingView(rootView: view), radius: radius)
        return panel
    }

    /// 面板底板交给系统：macOS 26 起是与系统菜单同款的 Liquid Glass，更早是菜单毛玻璃。
    /// 圆角由底板自身裁切，窗口阴影按圆角外形由系统计算——不再在 SwiftUI 里画阴影：
    /// 那层阴影超出圆角的部分会被无边框窗口的直角边界截断，露出直角框线（2026-11-09 用户截图）。
    static func nativeSurface(_ content: NSView, radius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            glass.contentView = content
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = roundedMask(radius: radius)
        content.frame = effect.bounds
        content.autoresizingMask = [.width, .height]
        effect.addSubview(content)
        return effect
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    static func mainFrame(size: CGSize, anchor: CGRect, visible: CGRect) -> CGRect {
        clamped(CGRect(x: anchor.minX, y: anchor.minY - size.height - 4,
                       width: size.width, height: size.height), to: visible)
    }

    static func childFrame(size: CGSize, row: CGRect, parent: CGRect, visible: CGRect) -> CGRect {
        let right = parent.maxX + 6
        let x = right + size.width <= visible.maxX ? right : parent.minX - size.width - 6
        return clamped(CGRect(x: x, y: row.maxY + 4 - size.height,
                              width: size.width, height: size.height), to: visible)
    }

    private static func clamped(_ rect: CGRect, to visible: CGRect) -> CGRect {
        let width = min(rect.width, visible.width)
        let height = min(rect.height, visible.height)
        return CGRect(x: min(max(rect.minX, visible.minX), visible.maxX - width),
                      y: min(max(rect.minY, visible.minY), visible.maxY - height), width: width, height: height)
    }

    private func installMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .mouseMoved]) { [weak self] event in
            // AppKit 保证本地事件 monitor 在主线程；只跨隔离边界返回 Bool，不传递不可 Sendable 的 NSEvent。
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if event.type == .keyDown { return self.handleKey(event) }
                if event.type == .mouseMoved { self.trackMouse(); return false }
                if let window = event.window, self.panels.contains(where: { $0 === window }) { return false }
                // 状态项的 action 负责开合，不能先关闭再被同一次右键重新打开。
                if self.isOverStatusButton() { return false }
                self.close()
                return false
            }
            return consumed ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.close() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDeactivated),
            name: NSApplication.didResignActiveNotification, object: NSApp)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    private func isOverStatusButton() -> Bool {
        guard let button = statusButton, let window = button.window else { return false }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(NSEvent.mouseLocation)
    }

    @objc private func applicationDeactivated() { close() }
    @objc private func workspaceActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        close()
    }

    private func trackMouse() {
        previousMouse = currentMouse
        currentMouse = NSEvent.mouseLocation
    }

    func register(_ view: NSView, id: String, level: Int) {
        anchors[level, default: [:]][id] = WeakAnchor(view)
    }

    private func closeChildren(after level: Int) {
        while panels.count > level + 1 {
            let panel = panels.removeLast()
            // orderOut 不释放 hosting tree；显式断开才能停止 Observation。
            panel.orderOut(nil)
            panel.contentView = nil
        }
        items = items.filter { $0.key <= level }
        anchors = anchors.filter { $0.key <= level }
        openedRows = openedRows.filter { $0.key < level }
        navigation.highlighted = navigation.highlighted.filter { $0.key <= level }
        keyboardLevel = min(keyboardLevel, max(0, level))
    }
}

// MARK: - 子面板与悬停
extension MenuBarPanelController {
    func hover(_ item: MenuBarPanelItem, level: Int, entered: Bool) {
        guard isShown else { return }
        if !entered {
            // 只取消离开的待展开行，不关已展开的窗口，允许鼠标跨越两窗之间的空隙。
            if pendingHover?.level == level, pendingHover?.id == item.id {
                hoverTask?.cancel()
                pendingHover = nil
            }
            return
        }
        hoverTask?.cancel()
        pendingHover = (level, item.id)
        let delay = isMovingTowardChild(at: level) ? 0.35 : 0.15
        hoverTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.isShown, !Task.isCancelled else { return }
            self.pendingHover = nil
            self.navigation.highlighted[level] = item.id
            self.keyboardLevel = level
            if item.action.expands { self.expand(item, level: level) }
            else { self.closeChildren(after: level) }
        }
    }

    private func isMovingTowardChild(at level: Int) -> Bool {
        guard panels.indices.contains(level + 1) else { return false }
        let target = panels[level + 1].frame
        let dx = currentMouse.x - previousMouse.x
        let toward = target.midX > currentMouse.x ? dx > 0 : dx < 0
        return toward && currentMouse.y >= target.minY - 40 && currentMouse.y <= target.maxY + 40
    }

    func activate(_ item: MenuBarPanelItem, level: Int) {
        guard item.enabled else { return }
        hoverTask?.cancel()
        keyboardLevel = level
        navigation.highlighted[level] = item.id
        if item.action.expands { expand(item, level: level) }
        else { perform(item.action) }
    }

    private func expand(_ item: MenuBarPanelItem, level: Int) {
        guard panels.indices.contains(level), openedRows[level] != item.id,
              let anchor = anchors[level]?[item.id]?.view, let window = anchor.window else { return }
        let row = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let parent = panels[level]
        // 与主面板同理：无屏幕时用假想可见区，子面板照常构建。
        let visible = (parent.screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        closeChildren(after: level)
        let next = level + 1
        let panel: NSPanel
        var size: CGSize
        switch item.action {
        case .modes:
            let rows = [OutboundMode.direct, .rule, .global].map { mode in
                MenuBarPanelItem(id: "outbound:" + mode.rawValue, title: mode.displayName,
                    symbol: state.outboundMode == mode ? "checkmark" : "", enabled: !state.isBusy,
                    checked: state.outboundMode == mode, action: .outbound(mode))
            }
            items[next] = rows
            size = CGSize(width: MenuBarPanelMetrics.subWidth, height: MenuBarPanelMetrics.subChrome + CGFloat(rows.count) * MenuBarPanelMetrics.rowStep - MenuBarPanelMetrics.rowGap)
            panel = makePanel(MenuBarPanelListView(title: "模式", items: rows, level: next, controller: self).environment(state), size: size)
        case .moreGroups:
            let model = MenuBarPanelModel(state: state)
            let rows = model.groups.dropFirst(3).map { model.groupItem($0) }
            items[next] = rows
            size = CGSize(width: MenuBarPanelMetrics.subWidth, height: MenuBarPanelMetrics.subChrome + min(MenuBarPanelMetrics.listMaxHeight, CGFloat(rows.count) * MenuBarPanelMetrics.rowStep - MenuBarPanelMetrics.rowGap))
            panel = makePanel(MenuBarPanelListView(title: "更多策略组", items: rows, level: next, controller: self).environment(state), size: size)
        case let .group(group):
            let snapshot = MenuBarPanelNodeSnapshot(state: state, group: group)
            items[next] = keyboardItems(snapshot)
            size = CGSize(width: MenuBarPanelMetrics.subWidth, height: snapshot.height)
            panel = makePanel(MenuBarPanelNodesView(snapshot: snapshot, level: next, controller: self).environment(state), size: size)
        case let .region(group, region):
            let snapshot = MenuBarPanelNodeSnapshot(state: state, group: group, region: region)
            items[next] = keyboardItems(snapshot)
            size = CGSize(width: MenuBarPanelMetrics.subWidth, height: snapshot.height)
            panel = makePanel(MenuBarPanelNodesView(snapshot: snapshot, level: next, controller: self).environment(state), size: size)
        default: return
        }
        size.height = min(size.height, visible.height)
        panel.setFrame(Self.childFrame(size: size, row: row, parent: parent.frame, visible: visible), display: false)
        panels.append(panel)
        openedRows[level] = item.id
        panel.orderFront(nil)
    }

    private func keyboardItems(_ snapshot: MenuBarPanelNodeSnapshot) -> [MenuBarPanelItem] {
        snapshot.entries.compactMap { entry in
            switch entry.content {
            case .heading: nil
            case let .option(option):
                MenuBarPanelItem(id: "option:" + option.id, title: snapshot.title(for: option),
                    enabled: snapshot.canSelect(option, busy: state.isBusy), action: .option(snapshot.group, option))
            case let .region(region):
                MenuBarPanelItem(id: "region:" + region.id, title: region.name, action: .region(snapshot.group, region))
            }
        }
    }
}

// MARK: - 动作与键盘
extension MenuBarPanelController {
    func togglePower() async {
        guard !state.isBusy else { return }
        if state.isOn { await state.stop() }
        else { await state.setMode(state.preferredMode, enabled: true) }
    }

    func select(_ option: GroupOption, in group: PolicyGroup) async {
        guard group.kind == .selector, option.isAvailable, !state.isBusy else { return }
        let generation = openGeneration
        await state.select(optionName: option.name, in: group.name)
        // 等待期间用户可能关掉又重开了面板，不能把新开的那个关掉（2026-11-09 审计）。
        if generation == openGeneration { close() }
    }

    func perform(_ action: MenuBarPanelAction) {
        switch action {
        case .power:
            guard !state.isBusy else { return }
            close()
            Task { @MainActor [self] in await togglePower() }
        case let .takeover(mode):
            guard !state.isBusy else { return }
            let enabled = !state.activeModes.contains(mode)
            close()
            Task { @MainActor [state] in await state.setMode(mode, enabled: enabled) }
        case let .outbound(mode):
            guard !state.isBusy else { return }
            close()
            Task { @MainActor [state] in await state.setOutboundMode(mode) }
        case let .option(group, option):
            Task { @MainActor [self] in await select(option, in: group) }
        case .testDelays:
            if state.isTestingAllDelays { state.cancelDelayTests() }
            else { state.startAllDelayTests() }
        case .dashboard:
            close()
            openMainWindow()
        case .refresh:
            guard !state.isBusy else { return }
            close()
            Task { @MainActor [state] in await state.refreshSubscriptions() }
        case .login:
            guard state.loginItemStatus != .unsupported, state.loginItemStatus != .requiresApproval else { return }
            let enabled = state.loginItemStatus != .enabled
            close()
            Task { @MainActor [state] in await state.setLaunchAtLoginEnabled(enabled) }
        case .quit:
            close()
            NSApplication.shared.terminate(nil)
        case .modes, .moreGroups, .group, .region: break
        }
    }

    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        guard isShown else { return false }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "d": perform(.dashboard); return true
            case "r": perform(.refresh); return true
            case "q": perform(.quit); return true
            default: return false
            }
        }
        switch event.keyCode {
        case 125: moveHighlight(by: 1)
        case 126: moveHighlight(by: -1)
        case 36, 76:
            if let item = highlightedItem { activate(item, level: keyboardLevel) }
        case 124:
            if let item = highlightedItem, item.action.expands {
                expand(item, level: keyboardLevel)
                if panels.count > keyboardLevel + 1 {
                    keyboardLevel += 1
                    moveHighlight(by: 1)
                }
            }
        case 123, 53:
            if panels.count > 1 {
                let parent = panels.count - 2
                closeChildren(after: parent)
                keyboardLevel = parent
            } else { close() }
        default: return false
        }
        return true
    }

    private var highlightedItem: MenuBarPanelItem? {
        // 启停后 enabled 可能改变；主层键盘操作读当前状态，不沿用打开时的快照。
        let rows = keyboardLevel == 0 ? currentMainItems : (items[keyboardLevel] ?? [])
        return rows.first { $0.id == navigation.highlighted[keyboardLevel] }
    }

    private var currentMainItems: [MenuBarPanelItem] {
        let model = MenuBarPanelModel(state: state)
        return [.init(id: "power", title: model.title, enabled: !state.isBusy, action: .power)] + model.sections.flatMap { $0 }
    }

    private func moveHighlight(by delta: Int) {
        let rows = (keyboardLevel == 0 ? currentMainItems : (items[keyboardLevel] ?? [])).filter(\.enabled)
        guard !rows.isEmpty else { return }
        hoverTask?.cancel()
        let index = rows.firstIndex { $0.id == navigation.highlighted[keyboardLevel] }
            ?? (delta > 0 ? -1 : 0)
        let next = rows[(index + delta + rows.count) % rows.count]
        navigation.highlighted[keyboardLevel] = next.id
        navigation.keyboardTarget = .init(level: keyboardLevel, id: next.id,
                                          sequence: (navigation.keyboardTarget?.sequence ?? 0) &+ 1)
        if let anchor = anchors[keyboardLevel]?[next.id]?.view { anchor.scrollToVisible(anchor.bounds) }
    }
}
