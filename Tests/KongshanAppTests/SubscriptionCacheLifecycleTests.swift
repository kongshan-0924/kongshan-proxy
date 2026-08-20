import Foundation
import XCTest
@testable import KongshanCore
@testable import kongshan

/// 订阅缓存的生命周期：删除订阅必须连带删除缓存 YAML（内含节点凭据，属敏感数据）。
@MainActor
final class SubscriptionCacheLifecycleTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-subcache-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testRemoveSubscriptionDeletesItsCacheFile() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = Storage(rootDirectory: root)
        try await storage.prepare()

        let source = SubscriptionSource(
            name: "cache-test",
            url: URL(string: "https://example.invalid/sub.yaml")!
        )
        try "proxies: []".data(using: .utf8)!.write(to: storage.cacheURL(for: source))

        let state = AppState(
            storage: storage,
            singBoxProcess: SingBoxProcess(binaryURL: URL(fileURLWithPath: "/usr/bin/false")),
            automaticallyInitialize: false
        )
        state.subscriptions = [source]

        await state.removeSubscription(id: source.id)

        XCTAssertTrue(state.subscriptions.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: storage.cacheURL(for: source).path),
            "删除订阅后缓存 YAML 必须一并删除——里面有节点凭据"
        )
    }
}
