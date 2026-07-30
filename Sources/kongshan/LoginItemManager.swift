import Foundation
import ServiceManagement

enum LoginItemStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    /// 系统还不认识这个 App（`SMAppService.Status.notFound`）。
    ///
    /// **这是可注册的正常状态，不是错误**：ad-hoc 签名的 App 在第一次
    /// `register()` 之前系统本来就查不到它。此前和「不是应用包」共用一个 `.notFound`，
    /// 界面于是把开关禁掉并显示"应用包不可用"——用户被永久挡在功能之外，
    /// 而其实打开开关就能注册。
    case notRegisteredYet
    /// 真的不是 `.app` 包（例如直接跑 `swift run` 的可执行文件）。此时功能确实用不了。
    case unsupported
}

protocol LoginItemManaging: Sendable {
    func currentStatus() async -> LoginItemStatus
    func setEnabled(_ enabled: Bool) async throws -> LoginItemStatus
    func openSystemSettings() async
}

enum LoginItemManagerError: Error, LocalizedError {
    case notApplicationBundle

    var errorDescription: String? {
        "开机自启只能从已打包的 kongshan.app 中设置"
    }
}

final class LoginItemManager: LoginItemManaging, @unchecked Sendable {
    typealias ApplicationBundleCheck = @Sendable () -> Bool

    private let isApplicationBundle: ApplicationBundleCheck

    init(
        isApplicationBundle: @escaping ApplicationBundleCheck = {
            Bundle.main.bundleURL.pathExtension == "app"
        }
    ) {
        self.isApplicationBundle = isApplicationBundle
    }

    func currentStatus() async -> LoginItemStatus {
        guard isApplicationBundle() else { return .unsupported }
        return Self.map(SMAppService.mainApp.status)
    }

    func setEnabled(_ enabled: Bool) async throws -> LoginItemStatus {
        guard isApplicationBundle() else {
            throw LoginItemManagerError.notApplicationBundle
        }
        let service = SMAppService.mainApp
        if enabled {
            switch service.status {
            case .enabled, .requiresApproval:
                break
            case .notRegistered, .notFound:
                try service.register()
            @unknown default:
                try service.register()
            }
        } else if service.status != .notRegistered {
            try await service.unregister()
        }
        return Self.map(service.status)
    }

    func openSystemSettings() async {
        guard isApplicationBundle() else { return }
        await MainActor.run {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    nonisolated static func map(_ status: SMAppService.Status) -> LoginItemStatus {
        switch status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notRegisteredYet
        @unknown default: .notRegisteredYet
        }
    }
}
