import Foundation
import XCTest

final class MenuBarViewStabilityTests: XCTestCase {
    func testOpenMenuDoesNotObserveLiveProxyRates() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appending(path: "Sources/kongshan/MenuBarView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("state.uploadRate"))
        XCTAssertFalse(source.contains("state.downloadRate"))
    }
}
