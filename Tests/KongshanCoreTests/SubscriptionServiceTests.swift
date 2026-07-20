import Foundation
import XCTest
@testable import KongshanCore

final class SubscriptionServiceTests: XCTestCase {
    func testSuccessfulRefreshReplacesCache() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = SubscriptionService(storage: fixture.storage) { _ in
            HTTPDownload(data: Data(Self.newYAML.utf8), statusCode: 200)
        }

        let result = try await service.refresh(fixture.subscription)

        XCTAssertFalse(result.usedCache)
        XCTAssertEqual(result.nodes.map(\.name), ["new"])
        XCTAssertEqual(try Data(contentsOf: fixture.storage.cacheURL(for: fixture.subscription)), Data(Self.newYAML.utf8))
    }

    func testDownloadFailureUsesOldCache() async throws {
        let fixture = try makeFixture(oldCache: Self.oldYAML)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = SubscriptionService(storage: fixture.storage) { _ in
            throw URLError(.notConnectedToInternet)
        }

        let result = try await service.refresh(fixture.subscription)

        XCTAssertTrue(result.usedCache)
        XCTAssertEqual(result.nodes.map(\.name), ["old"])
        XCTAssertTrue(result.warnings.contains { $0.contains("缓存") })
    }

    func testMalformedRefreshDoesNotOverwriteOldCache() async throws {
        let fixture = try makeFixture(oldCache: Self.oldYAML)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = SubscriptionService(storage: fixture.storage) { _ in
            HTTPDownload(data: Data("proxies: [broken".utf8), statusCode: 200)
        }

        let result = try await service.refresh(fixture.subscription)

        XCTAssertTrue(result.usedCache)
        XCTAssertEqual(try String(contentsOf: fixture.storage.cacheURL(for: fixture.subscription), encoding: .utf8), Self.oldYAML)
    }

    func testFailureWithoutCacheIsReported() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = SubscriptionService(storage: fixture.storage) { _ in
            throw URLError(.timedOut)
        }

        do {
            _ = try await service.refresh(fixture.subscription)
            XCTFail("Expected refresh failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("缓存"))
        }
    }

    private func makeFixture(oldCache: String? = nil) throws -> (
        root: URL,
        storage: Storage,
        subscription: SubscriptionSource
    ) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let storage = Storage(rootDirectory: root)
        let subscription = SubscriptionSource(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            name: "airport",
            url: URL(string: "https://example.com/clash.yaml")!
        )
        try FileManager.default.createDirectory(at: root.appending(path: "subscriptions"), withIntermediateDirectories: true)
        if let oldCache {
            try Data(oldCache.utf8).write(to: storage.cacheURL(for: subscription))
        }
        return (root, storage, subscription)
    }

    private static let oldYAML = """
    proxies:
      - {name: old, type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: old}
    """

    private static let newYAML = """
    proxies:
      - {name: new, type: ss, server: 2.2.2.2, port: 443, cipher: aes-128-gcm, password: new}
    """
}
