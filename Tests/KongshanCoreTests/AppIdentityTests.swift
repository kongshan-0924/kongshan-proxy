import XCTest
@testable import KongshanCore

final class AppIdentityTests: XCTestCase {
    func testIdentityAndSupportDirectory() {
        XCTAssertEqual(AppIdentity.name, "kongshan")
        XCTAssertEqual(AppIdentity.bundleIdentifier, "com.kaysen.kongshan")
        XCTAssertTrue(AppIdentity.supportDirectory.path.hasSuffix("Application Support/kongshan"))
    }

    func testReleaseVerifierCanUseOnlyScopedTemporarySupportOverride() {
        XCTAssertEqual(
            AppIdentity.resolvedSupportDirectory(environment: [
                "KONGSHAN_TEST_SUPPORT_DIRECTORY": "/tmp/kongshan-verify-example/support"
            ]).path,
            "/tmp/kongshan-verify-example/support"
        )
        XCTAssertTrue(
            AppIdentity.resolvedSupportDirectory(environment: [
                "KONGSHAN_TEST_SUPPORT_DIRECTORY": "/Users/example/unsafe"
            ]).path.hasSuffix("Library/Application Support/kongshan")
        )
        XCTAssertNil(AppIdentity.releaseVerificationSupportDirectory(environment: [
            "KONGSHAN_TEST_SUPPORT_DIRECTORY": "/Users/example/unsafe"
        ]))
        XCTAssertNil(AppIdentity.releaseVerificationSupportDirectory(environment: [
            "KONGSHAN_TEST_SUPPORT_DIRECTORY": "/tmp/kongshan-verify-example/../../Users/example/unsafe"
        ]))
        XCTAssertNil(AppIdentity.releaseVerificationSupportDirectory(environment: [
            "KONGSHAN_TEST_SUPPORT_DIRECTORY": "/tmp/kongshan-verify-example/not-support"
        ]))
    }
}
