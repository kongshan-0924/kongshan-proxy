import Foundation
import XCTest
@testable import KongshanCore

final class StorageTests: XCTestCase {
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

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }
}
