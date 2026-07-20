import Foundation
import ServiceManagement

enum LoginItemStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
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
        guard isApplicationBundle() else { return .notFound }
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
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }
}
