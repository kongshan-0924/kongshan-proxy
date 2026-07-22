import Foundation
import KongshanCore

struct BackupSettings: Codable, Equatable, Sendable {
    var selectedNodeID: UUID?
    var testURL: String
    var preferredMode: ProxyMode
    var tunSettings: TunSettings
    var dnsSettings: DNSSettings
    var subscriptionUpdateSettings: SubscriptionUpdateSettings
    var ruleSetSettings: RuleSetSettings
    var outboundMode: OutboundMode
    var groupSelections: [String: String]
    var activeConfigID: UUID?
    var speedTestMethod: SpeedTestMethod

    static let defaults = BackupSettings(
        selectedNodeID: nil,
        testURL: "http://www.gstatic.com/generate_204",
        preferredMode: .systemProxy,
        tunSettings: .defaults,
        dnsSettings: .defaults,
        subscriptionUpdateSettings: .defaults,
        ruleSetSettings: .defaults,
        outboundMode: .rule,
        groupSelections: [:],
        activeConfigID: nil,
        speedTestMethod: .tcpPing
    )
}

struct KongshanBackup: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let createdAt: Date
    let subscriptions: [SubscriptionSource]
    let manualNodes: [ProxyNode]
    let settings: BackupSettings
    let routingSettings: RoutingSettings
    let subscriptionCaches: [UUID: Data]

    static func decodeValidated(from data: Data) throws -> KongshanBackup {
        let backup = try JSONDecoder().decode(KongshanBackup.self, from: data)
        guard backup.version == currentVersion else {
            throw KongshanBackupError.unsupportedVersion(backup.version)
        }
        _ = try backup.routingSettings.validated()
        let sourceIDs = Set(backup.subscriptions.map(\.id))
        guard backup.subscriptions.allSatisfy({ source in
            ["http", "https"].contains(source.url.scheme?.lowercased() ?? "")
        }), Set(backup.subscriptionCaches.keys).isSubset(of: sourceIDs),
        backup.manualNodes.allSatisfy({ node in
            node.sourceID == nil
                && !node.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !node.server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (1...65_535).contains(node.port)
        }) else {
            throw KongshanBackupError.invalidContents
        }
        guard let testURL = URL(string: backup.settings.testURL),
              ["http", "https"].contains(testURL.scheme?.lowercased() ?? "") else {
            throw KongshanBackupError.invalidContents
        }
        return backup
    }
}

enum KongshanBackupError: Error, Equatable, LocalizedError {
    case unsupportedVersion(Int)
    case invalidContents

    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version): "不支持的 kongshan 备份版本：\(version)"
        case .invalidContents: "备份内容不完整或无效"
        }
    }
}
