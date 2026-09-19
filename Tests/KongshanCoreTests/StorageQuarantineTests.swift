import Foundation
import XCTest
@testable import KongshanCore

/// F2：持久化文件损坏时把原文挪开保留，而不是让它被下一次正常写入覆盖掉。
final class StorageQuarantineTests: XCTestCase {
    private func makeStorage() async throws -> (Storage, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "storage-quarantine-\(UUID().uuidString)", directoryHint: .isDirectory)
        let storage = Storage(rootDirectory: root)
        try await storage.prepare()
        return (storage, root)
    }

    func testCorruptFileIsRenamedAndContentPreserved() async throws {
        let (storage, root) = try await makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appending(path: "settings.json")
        let original = Data("{ 这不是合法 JSON".utf8)
        try await storage.writeAtomically(original, to: url)

        let date = Date(timeIntervalSince1970: 1_758_000_000)
        let moved = try await storage.quarantineCorrupt(url, at: date)
        let target = try XCTUnwrap(moved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "原路径应被腾空，下次写入不会撞上损坏内容")
        XCTAssertEqual(try Data(contentsOf: target), original, "损坏内容必须原样保留——里面可能还有能人工救回的数据")
        XCTAssertTrue(target.lastPathComponent.hasPrefix("settings.corrupt-"))
        XCTAssertEqual(target.pathExtension, "json", "扩展名要留着，用户才认得出这是什么文件")
    }

    /// 同一秒内连续损坏两次不能互相覆盖——第二份同样是证据。
    func testRepeatedQuarantineInSameSecondDoesNotOverwrite() async throws {
        let (storage, root) = try await makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appending(path: "rules.json")
        let date = Date(timeIntervalSince1970: 1_758_000_000)
        try await storage.writeAtomically(Data("first".utf8), to: url)
        // XCTUnwrap 的 autoclosure 不支持并发，await 必须先落到局部变量上。
        let firstMoved = try await storage.quarantineCorrupt(url, at: date)
        let first = try XCTUnwrap(firstMoved)
        try await storage.writeAtomically(Data("second".utf8), to: url)
        let secondMoved = try await storage.quarantineCorrupt(url, at: date)
        let second = try XCTUnwrap(secondMoved)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
    }

    func testMissingFileIsNotAnError() async throws {
        let (storage, root) = try await makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let moved = try await storage.quarantineCorrupt(root.appending(path: "nope.json"))
        XCTAssertNil(moved)
    }
}
