import Foundation

public actor Storage {
    public nonisolated let rootDirectory: URL

    public init(rootDirectory: URL = AppIdentity.supportDirectory) {
        self.rootDirectory = rootDirectory
    }

    public nonisolated var subscriptionsDirectory: URL {
        rootDirectory.appending(path: "subscriptions", directoryHint: .isDirectory)
    }

    public nonisolated func cacheURL(for subscription: SubscriptionSource) -> URL {
        subscriptionsDirectory.appending(path: "\(subscription.id.uuidString.lowercased()).yaml")
    }

    public func prepare() throws {
        for directory in [
            rootDirectory,
            subscriptionsDirectory,
            rootDirectory.appending(path: "logs", directoryHint: .isDirectory),
            rootDirectory.appending(path: "rule-sets", directoryHint: .isDirectory)
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    public func writeAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    public func readIfPresent(from url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }
}
