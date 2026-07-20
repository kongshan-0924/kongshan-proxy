import XCTest
@testable import KongshanCore

final class AppIdentityTests: XCTestCase {
    func testIdentityAndSupportDirectory() {
        XCTAssertEqual(AppIdentity.name, "kongshan")
        XCTAssertEqual(AppIdentity.bundleIdentifier, "com.kaysen.kongshan")
        XCTAssertTrue(AppIdentity.supportDirectory.path.hasSuffix("Application Support/kongshan"))
    }
}
