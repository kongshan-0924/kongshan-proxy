import Foundation

struct RuntimeEvent: Codable, Equatable, Identifiable, Sendable {
    enum Level: String, Codable, Sendable {
        case info
        case warning
        case error
    }

    let id: UUID
    let timestamp: Date
    let level: Level
    let title: String
    let detail: String?
    let previousPID: Int32?
    let currentPID: Int32?

    init(
        id: UUID = UUID(),
        timestamp: Date,
        level: Level = .info,
        title: String,
        detail: String? = nil,
        previousPID: Int32? = nil,
        currentPID: Int32? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.title = title
        self.detail = detail
        self.previousPID = previousPID
        self.currentPID = currentPID
    }
}
