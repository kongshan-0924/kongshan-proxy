import AppKit
import KongshanCore
import Observation

/// AppKit 状态项：左右键共用自绘菜单面板；速率只替换固定宽度图片。
@MainActor
final class MenuBarController: NSObject {
    private static let statusImagePadding: CGFloat = 6

    let statusItem: NSStatusItem
    let panelController: MenuBarPanelController

    private let state: AppState
    private var throughputCalculator = ThroughputRateCalculator()
    private var throughputTask: Task<Void, Never>?
    private var uploadText = "—"
    private var downloadText = "—"
    private var renderedStatusKey: String?

    init(
        state: AppState,
        statusItem: NSStatusItem? = nil,
        openMainWindow: @escaping (SidebarPage?) -> Void
    ) {
        self.state = state
        self.statusItem = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.panelController = MenuBarPanelController(state: state) { openMainWindow(nil) }
        super.init()

        self.statusItem.menu = nil
        if let button = self.statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        updateStatusButton(uploadText: uploadText, downloadText: downloadText)
    }

    func start() {
        guard throughputTask == nil else { return }
        statusItem.isVisible = true
        observeStatus()
        throughputTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                self.sampleThroughput()
                do {
                    // 允许 1 秒误差：系统可以把这次唤醒与其它定时器合并，长时间运行更省电。
                    try await Task.sleep(for: .seconds(2), tolerance: .seconds(1))
                } catch {
                    break
                }
            }
        }
    }

    /// 状态一变就重画图标与提示，不等两秒一次的速率采样：启停、切换接管方式时图标要立刻跟上。
    private func observeStatus() {
        withObservationTracking {
            _ = state.menuBarIconState
            _ = state.statusText
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.throughputTask != nil else { return }
                self.updateStatusButton(uploadText: self.uploadText, downloadText: self.downloadText)
                self.observeStatus()
            }
        }
    }

    func stop() {
        throughputTask?.cancel()
        throughputTask = nil
        panelController.close()
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// 左右键都进入同一开合逻辑；不再按事件类型维护第二套浮层。
    /// internal 供回归测试直接驱动状态项 action，避免测试依赖真实鼠标事件分发。
    @objc func statusItemClicked() {
        toggleMenuPanel()
    }

    func toggleMenuPanel() {
        guard let button = statusItem.button else { return }
        panelController.toggle(relativeTo: button)
    }

    func updateStatusButton(uploadText: String, downloadText: String) {
        self.uploadText = uploadText
        self.downloadText = downloadText
        let iconStyle = state.menuBarIconStyle
        let iconState = state.menuBarIconState
        let statusText = state.statusText
        let statusKey = "\(iconStyle.rawValue)-\(iconState)-\(uploadText)-\(downloadText)-\(statusText)"
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
            // 提示与读屏文字跟图标一起只在内容变化时写：每 2 秒无条件写一遍是白工。
            statusItem.button?.toolTip = "kongshan · \(statusText)"
            statusItem.button?.setAccessibilityLabel("kongshan，\(statusText)，上传 \(uploadText)，下载 \(downloadText)")
            renderedStatusKey = statusKey
        }
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
