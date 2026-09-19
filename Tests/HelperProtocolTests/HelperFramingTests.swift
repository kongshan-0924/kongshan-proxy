import XCTest
@testable import HelperProtocol

final class HelperFramingTests: XCTestCase {
    func testRequestRoundTrips() throws {
        for request in [HelperRequest.status, .startTun, .stopTun] {
            let frame = try HelperFraming.encode(request)
            // 4 字节长度前缀 + body
            let length = frame.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            let body = frame.dropFirst(4)
            XCTAssertEqual(length, body.count)
            XCTAssertEqual(try HelperFraming.decode(HelperRequest.self, from: Data(body)), request)
        }
    }

    func testResponseRoundTrips() throws {
        let response = HelperResponse(ok: true, message: "ok", kernelPID: 4242, helperVersion: "1.2.3")
        let frame = try HelperFraming.encode(response)
        let body = frame.dropFirst(4)
        XCTAssertEqual(try HelperFraming.decode(HelperResponse.self, from: Data(body)), response)
    }

    func testTrustConfigDefaultsToNoCDHashPin() {
        let trust = HelperTrustConfig(clientExecutablePath: "/Applications/kongshan.app/Contents/MacOS/kongshan")
        XCTAssertNil(trust.pinnedCDHashHex)
    }

    func testOversizeFrameRejected() {
        struct Big: Encodable { let blob: String }
        let big = Big(blob: String(repeating: "a", count: HelperFraming.maxFrameBytes + 1))
        XCTAssertThrowsError(try HelperFraming.encode(big)) { error in
            XCTAssertEqual(error as? HelperFramingError, .frameTooLarge)
        }
    }
}
