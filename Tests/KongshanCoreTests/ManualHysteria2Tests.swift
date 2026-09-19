import XCTest
@testable import KongshanCore

final class ManualHysteria2Tests: XCTestCase {
    func testValidManualNode() throws {
        let form = ManualHysteria2(
            name: " home ",
            server: " vpn.example.com ",
            port: 443,
            password: " secret ",
            sni: " vpn.example.com ",
            skipCertificateVerification: false,
            obfsPassword: " mask ",
            uploadMbps: 20,
            downloadMbps: 100
        )

        let node = try form.makeNode(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

        XCTAssertEqual(node.name, "home")
        XCTAssertEqual(node.server, "vpn.example.com")
        XCTAssertEqual(node.protocolType, .hysteria2)
        XCTAssertEqual(node.password, "secret")
        XCTAssertEqual(node.sni, "vpn.example.com")
        XCTAssertEqual(node.obfsPassword, "mask")
        XCTAssertEqual(node.uploadMbps, 20)
        XCTAssertEqual(node.downloadMbps, 100)
        XCTAssertNil(node.sourceID)
    }

    func testRejectsInvalidPort() {
        let form = makeForm(port: 0)

        XCTAssertThrowsError(try form.makeNode()) { error in
            XCTAssertEqual(error as? ManualHysteria2Error, .invalidPort)
        }
    }

    func testRejectsBlankRequiredFields() {
        XCTAssertThrowsError(try makeForm(name: " ").makeNode())
        XCTAssertThrowsError(try makeForm(server: " ").makeNode())
        XCTAssertThrowsError(try makeForm(password: " ").makeNode())
    }

    func testRejectsNonPositiveBandwidth() {
        XCTAssertThrowsError(try makeForm(uploadMbps: 0).makeNode()) { error in
            XCTAssertEqual(error as? ManualHysteria2Error, .invalidUploadBandwidth)
        }
        XCTAssertThrowsError(try makeForm(downloadMbps: -1).makeNode()) { error in
            XCTAssertEqual(error as? ManualHysteria2Error, .invalidDownloadBandwidth)
        }
    }

    private func makeForm(
        name: String = "home",
        server: String = "vpn.example.com",
        port: Int = 443,
        password: String = "secret",
        uploadMbps: Int? = nil,
        downloadMbps: Int? = nil
    ) -> ManualHysteria2 {
        ManualHysteria2(
            name: name,
            server: server,
            port: port,
            password: password,
            sni: "",
            skipCertificateVerification: false,
            obfsPassword: "",
            uploadMbps: uploadMbps,
            downloadMbps: downloadMbps
        )
    }
}
