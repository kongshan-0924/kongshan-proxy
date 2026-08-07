import AppKit
import KongshanCore

/// 原生状态项与菜单。
///
/// 速度刷新只替换 status button 的固定尺寸图片；`menu` 对象从创建到退出始终不变，
/// 因此菜单跟踪不会再被 SwiftUI Scene 重建打断。
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private static let menuOptionLimit = 40
    private static let statusImagePadding: CGFloat = 6

    let statusItem: NSStatusItem
    let menu = NSMenu()

    private let state: AppState
    private let openMainWindow: () -> Void
    private var throughputCalculator = ThroughputRateCalculator()
    private var throughputTask: Task<Void, Never>?
    private var uploadText = "—"
    private var downloadText = "—"
    private var renderedStatusKey: String?

    init(
        state: AppState,
        statusItem: NSStatusItem? = nil,
        openMainWindow: @escaping () -> Void
    ) {
        self.state = state
        self.statusItem = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.openMainWindow = openMainWindow
        super.init()

        menu.autoenablesItems = false
        menu.delegate = self
        self.statusItem.menu = menu
        updateStatusButton(uploadText: uploadText, downloadText: downloadText)
    }

    func start() {
        guard throughputTask == nil else { return }
        statusItem.isVisible = true
        throughputTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                self.sampleThroughput()
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    break
                }
            }
        }
    }

    func stop() {
        throughputTask?.cancel()
        throughputTask = nil
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        // 菜单只在开始跟踪前同步一次。展开后即使速度继续更新，菜单内容和对象都不变。
        updateStatusButton(uploadText: uploadText, downloadText: downloadText)
        rebuildMenu()
    }

    func rebuildMenu() {
        menu.removeAllItems()

        let status = NSMenuItem(title: state.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(item(title: "打开仪表盘", action: #selector(openDashboard), keyEquivalent: "d"))
        menu.addItem(.separator())

        addOutboundModeMenu()
        menu.addItem(toggleItem(
            title: ProxyMode.systemProxy.displayName,
            checked: state.activeModes.contains(.systemProxy),
            action: #selector(toggleProxyMode),
            representedObject: ProxyMode.systemProxy,
            keyEquivalent: "e",
            enabled: state.isReady && !state.isBusy
        ))
        menu.addItem(toggleItem(
            title: ProxyMode.tun.displayName,
            checked: state.activeModes.contains(.tun),
            action: #selector(toggleProxyMode),
            representedObject: ProxyMode.tun,
            keyEquivalent: "u",
            enabled: state.isReady && !state.isBusy
        ))

        if state.isOn, state.activeModes.isEmpty {
            let stop = item(title: "停止内核", action: #selector(stopCore))
            stop.isEnabled = !state.isBusy
            menu.addItem(stop)
        }

        menu.addItem(.separator())
        addPolicyGroupMenus()
        menu.addItem(.separator())

        let launchEnabled = state.isReady
            && state.loginItemStatus != .requiresApproval
            && state.loginItemStatus != .unsupported
        menu.addItem(toggleItem(
            title: "登录时启动",
            checked: state.loginItemStatus == .enabled,
            action: #selector(toggleLaunchAtLogin),
            enabled: launchEnabled
        ))

        let refresh = item(title: "刷新订阅", action: #selector(refreshSubscriptions), keyEquivalent: "r")
        refresh.isEnabled = !state.subscriptions.isEmpty && !state.isBusy
        menu.addItem(refresh)
        menu.addItem(.separator())
        menu.addItem(item(title: "退出 kongshan", action: #selector(quit), keyEquivalent: "q"))
    }

    func updateStatusButton(uploadText: String, downloadText: String) {
        self.uploadText = uploadText
        self.downloadText = downloadText
        let iconStyle = state.menuBarIconStyle
        let iconState = state.menuBarIconState
        let statusKey = "\(iconStyle.rawValue)-\(iconState)-\(uploadText)-\(downloadText)"
        if renderedStatusKey != statusKey {
            let image = MenuBarIcon.statusImage(
                style: iconStyle,
                state: iconState,
                uploadText: uploadText,
                downloadText: downloadText
            )
            let fixedLength = image.size.width + Self.statusImagePadding
            if statusItem.length != fixedLength { statusItem.length = fixedLength }
            statusItem.button?.image = image
            statusItem.button?.imagePosition = .imageOnly
            statusItem.button?.imageScaling = .scaleNone
            renderedStatusKey = statusKey
        }
        statusItem.button?.toolTip = "kongshan · \(state.statusText)"
        statusItem.button?.setAccessibilityLabel("kongshan，\(state.statusText)，上传 \(uploadText)，下载 \(downloadText)")
    }

    private func sampleThroughput() {
        guard let counters = NetworkThroughput.physicalCounters() else {
            updateStatusButton(uploadText: "—", downloadText: "—")
            return
        }
        let rate = throughputCalculator.rate(from: counters, at: Date())
        updateStatusButton(
            uploadText: MenuRateFormatter.displayText(rate.upload),
            downloadText: MenuRateFormatter.displayText(rate.download)
        )
    }

    private func addOutboundModeMenu() {
        let parent = NSMenuItem(
            title: "出站模式：\(state.outboundMode.displayName)",
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu(title: "出站模式")
        submenu.autoenablesItems = false
        for mode in OutboundMode.allCases {
            let modeItem = item(title: mode.displayName, action: #selector(selectOutboundMode))
            modeItem.representedObject = mode
            modeItem.state = state.outboundMode == mode ? .on : .off
            modeItem.isEnabled = state.isReady && !state.isBusy
            submenu.addItem(modeItem)
        }
        parent.submenu = submenu
        parent.isEnabled = state.isReady && !state.isBusy
        menu.addItem(parent)
    }

    private func addPolicyGroupMenus() {
        for group in state.displayPolicyGroups where group.kind == .selector {
            let selected = state.selectedMemberName(in: group.name) ?? "未选择"
            let parent = NSMenuItem(
                title: "\(Self.clip(group.name, 14))：\(Self.clip(selected, 16))",
                action: nil,
                keyEquivalent: ""
            )
            parent.submenu = policyGroupMenu(group)
            parent.isEnabled = !state.isBusy && !state.testableNodes.isEmpty
            menu.addItem(parent)
        }
    }

    private func policyGroupMenu(_ group: PolicyGroup) -> NSMenu {
        let submenu = NSMenu(title: group.name)
        submenu.autoenablesItems = false
        let options = state.groupOptions(group)
        guard !options.isEmpty else {
            let empty = NSMenuItem(title: "当前配置没有节点", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            return submenu
        }

        let testAll = item(
            title: state.isTestingAllDelays
                ? "取消测速（\(state.speedTestProgress.label)）"
                : "测速全部",
            action: state.isTestingAllDelays ? #selector(cancelAllDelays) : #selector(testAllDelays)
        )
        testAll.isEnabled = !state.testableNodes.isEmpty
        submenu.addItem(testAll)

        let fastest = item(title: "测速并自动选最快", action: #selector(testAndSelectFastest))
        fastest.representedObject = group.name
        fastest.isEnabled = !state.testableNodes.isEmpty && !state.isTestingAllDelays
        submenu.addItem(fastest)
        submenu.addItem(.separator())

        let selectedName = state.selectedMemberName(in: group.name)
        for option in options.prefix(Self.menuOptionLimit) {
            let optionItem = item(title: optionTitle(option), action: #selector(selectOption))
            optionItem.representedObject = MenuSelection(group: group.name, option: option.name)
            optionItem.state = option.name == selectedName ? .on : .off
            submenu.addItem(optionItem)
        }

        if options.count > Self.menuOptionLimit {
            submenu.addItem(.separator())
            submenu.addItem(item(
                title: "在代理页选择全部（\(options.count) 个）…",
                action: #selector(openDashboard)
            ))
        }
        return submenu
    }

    private func optionTitle(_ option: GroupOption) -> String {
        guard case let .node(node) = option else { return option.name }
        let metadata = NodeNameMetadata.parse(node.name)
        let flag = metadata.flag.flatMap { node.name.contains($0) ? nil : $0 + " " } ?? ""
        let multiplier = metadata.multiplierText.map { "  \($0)" } ?? ""
        let delay: String
        switch state.delays[node.id] {
        case let .some(.some(value)): delay = "   \(value) ms"
        case .some(.none): delay = "   超时"
        case .none: delay = ""
        }
        return "\(flag)\(option.name)\(multiplier)\(delay)"
    }

    private func item(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func toggleItem(
        title: String,
        checked: Bool,
        action: Selector,
        representedObject: Any? = nil,
        keyEquivalent: String = "",
        enabled: Bool = true
    ) -> NSMenuItem {
        let item = item(title: title, action: action, keyEquivalent: keyEquivalent)
        item.representedObject = representedObject
        item.state = checked ? .on : .off
        item.isEnabled = enabled
        return item
    }

    private static func clip(_ text: String, _ max: Int) -> String {
        text.count > max ? String(text.prefix(max)) + "…" : text
    }

    @objc private func openDashboard() {
        openMainWindow()
    }

    @objc private func selectOutboundMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? OutboundMode else { return }
        Task { @MainActor [weak self] in await self?.state.setOutboundMode(mode) }
    }

    @objc private func toggleProxyMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? ProxyMode else { return }
        let enabled = !state.activeModes.contains(mode)
        Task { @MainActor [weak self] in await self?.state.setMode(mode, enabled: enabled) }
    }

    @objc private func stopCore() {
        Task { @MainActor [weak self] in await self?.state.stop() }
    }

    @objc private func selectOption(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? MenuSelection else { return }
        Task { @MainActor [weak self] in
            await self?.state.select(optionName: selection.option, in: selection.group)
        }
    }

    @objc private func testAllDelays() {
        state.startAllDelayTests()
    }

    @objc private func cancelAllDelays() {
        state.cancelDelayTests()
    }

    @objc private func testAndSelectFastest(_ sender: NSMenuItem) {
        guard let group = sender.representedObject as? String else { return }
        state.startFastestTest(in: group)
    }

    @objc private func toggleLaunchAtLogin() {
        let enabled = state.loginItemStatus != .enabled
        Task { @MainActor [weak self] in await self?.state.setLaunchAtLoginEnabled(enabled) }
    }

    @objc private func refreshSubscriptions() {
        Task { @MainActor [weak self] in await self?.state.refreshSubscriptions() }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

private final class MenuSelection: NSObject {
    let group: String
    let option: String

    init(group: String, option: String) {
        self.group = group
        self.option = option
    }
}

enum MenuRateFormatter {
    static func compact(_ bytes: Int64) -> String {
        let value = max(0, bytes)
        switch value {
        case 0: return ""
        case 0..<1_024: return "\(value)B"
        case 1_024..<1_048_576: return String(format: "%.1fK", Double(value) / 1_024)
        case 1_048_576..<1_073_741_824: return String(format: "%.1fM", Double(value) / 1_048_576)
        default: return String(format: "%.1fG", Double(value) / 1_073_741_824)
        }
    }

    static func displayText(_ bytes: Int64) -> String {
        let text = compact(bytes)
        return text.isEmpty ? "—" : text
    }
}
