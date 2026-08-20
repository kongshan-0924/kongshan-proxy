import Foundation
import XCTest
@testable import KongshanCore

final class StorageTests: XCTestCase {
    /// 孤儿清理只动「UUID.yaml」形态的文件：在册缓存、非 UUID 文件名、其他扩展名一概不碰。
    func testOrphanSweepRemovesOnlyUnregisteredUUIDCaches() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "storage-orphan-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = Storage(rootDirectory: root)
        try await storage.prepare()

        let kept = SubscriptionSource(
            id: UUID(), name: "kept", url: URL(string: "https://example.invalid/sub")!
        )
        let orphanID = UUID()
        let dir = storage.subscriptionsDirectory
        try "kept".data(using: .utf8)!.write(to: storage.cacheURL(for: kept))
        try "orphan".data(using: .utf8)!.write(
            to: dir.appending(path: "\(orphanID.uuidString.lowercased()).yaml"))
        try "not-uuid".data(using: .utf8)!.write(to: dir.appending(path: "notes.yaml"))
        try "wrong-ext".data(using: .utf8)!.write(
            to: dir.appending(path: "\(UUID().uuidString.lowercased()).json"))

        let removed = await storage.removeOrphanSubscriptionCaches(keeping: [kept])

        XCTAssertEqual(removed, ["\(orphanID.uuidString.lowercased()).yaml"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.cacheURL(for: kept).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appending(path: "notes.yaml").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appending(path: "\(orphanID.uuidString.lowercased()).yaml").path))
    }

    /// 大写 UUID 在册时也不能误删（cacheURL 落盘用小写，在册比对必须不区分大小写）。
    func testOrphanSweepMatchesRegisteredIDsCaseInsensitively() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "storage-orphan-case-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = Storage(rootDirectory: root)
        try await storage.prepare()
        let sub = SubscriptionSource(
            id: UUID(), name: "s", url: URL(string: "https://example.invalid/sub")!
        )
        try "data".data(using: .utf8)!.write(to: storage.cacheURL(for: sub))
        let removed = await storage.removeOrphanSubscriptionCaches(keeping: [sub])
        XCTAssertTrue(removed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.cacheURL(for: sub).path))
    }

    /// removeSubscriptionCache 幂等：文件不存在不抛错。
    func testRemoveSubscriptionCacheIsIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "storage-remove-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = Storage(rootDirectory: root)
        try await storage.prepare()
        let sub = SubscriptionSource(
            id: UUID(), name: "s", url: URL(string: "https://example.invalid/sub")!
        )
        try "data".data(using: .utf8)!.write(to: storage.cacheURL(for: sub))
        try await storage.removeSubscriptionCache(for: sub)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.cacheURL(for: sub).path))
        try await storage.removeSubscriptionCache(for: sub)
    }

    func testPreparesDirectoriesAndReplacesFileAtomically() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = Storage(rootDirectory: root)
        try await storage.prepare()
        let file = root.appending(path: "settings.json")

        try await storage.writeAtomically(Data("old".utf8), to: file)
        try await storage.writeAtomically(Data("new".utf8), to: file)

        XCTAssertEqual(try Data(contentsOf: file), Data("new".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "subscriptions").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "logs").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "rule-sets").path))
    }

    /// 内容没变就不该真写盘。不少调用方是定时触发的（订阅自动更新每轮顺手落一次设置），
    /// 内容通常与上次完全一致；`.atomic` 写要建临时文件 + rename，白写就是白写。
    /// 用 mtime 判定"有没有真写"：内容相同的两次写之间 mtime 必须一动不动。
    func testSkipsWriteWhenContentIsUnchanged() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = Storage(rootDirectory: root)
        try await storage.prepare()
        let file = root.appending(path: "settings.json")

        try await storage.writeAtomically(Data("same".utf8), to: file)
        let firstWrite = try modificationDate(of: file)

        // HFS+/APFS 的 mtime 分辨率足够，但两次调用可能落在同一纳秒刻度上——
        // 睡一下让"真写了"的情况一定能被观测到，否则这条断言会假阳性通过。
        try await Task.sleep(for: .milliseconds(20))
        try await storage.writeAtomically(Data("same".utf8), to: file)
        XCTAssertEqual(try modificationDate(of: file), firstWrite, "内容相同不该重写文件")

        try await Task.sleep(for: .milliseconds(20))
        try await storage.writeAtomically(Data("different".utf8), to: file)
        XCTAssertNotEqual(try modificationDate(of: file), firstWrite, "内容变了必须真写")
        XCTAssertEqual(try Data(contentsOf: file), Data("different".utf8))
    }

    /// 跳过写入不能顺带把"收紧权限"也跳过去：旧版本可能以 0644 建过这些文件，
    /// 而里面是订阅凭据和 Clash API secret。
    func testUnchangedWriteStillTightensLoosePermissions() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = Storage(rootDirectory: root)
        try await storage.prepare()
        let file = root.appending(path: "settings.json")

        try await storage.writeAtomically(Data("secret".utf8), to: file)
        // 模拟旧版本留下的宽松权限。
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: file.path
        )

        try await storage.writeAtomically(Data("secret".utf8), to: file)

        let permissions = try FileManager.default
            .attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o600)
    }

    private func modificationDate(of url: URL) throws -> Date {
        try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }
}
