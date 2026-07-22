import Foundation
import XCTest
@testable import KongshanCore
@testable import kongshan

final class ExitDiagnosticsServiceTests: XCTestCase {
    func testRunLoadsExitAndThreeUniqueDNSResolverSamples() async throws {
        let recorder = URLRecorder()
        let service = ExitDiagnosticsService { request in
            let url = try XCTUnwrap(request.url)
            await recorder.append(url)
            if url.path == "/config" {
                return Data(#"{"dns_leak_domain":"dnsleak.example.test","ipv4_url":"https://ipv4.example.test"}"#.utf8)
            }
            if url.host == "ipv4.example.test" {
                return Data(#"{"ip":"203.0.113.8","country":"Japan","city":"Tokyo","organization":"Example ISP"}"#.utf8)
            }
            return Data(#"[{"ip":"1.1.1.1","country":"Netherlands","city":"Amsterdam","organization":"Cloudflare, Inc.","mullvad_dns":false}]"#.utf8)
        }

        let report = try await service.run(remoteDoH: "https://cloudflare-dns.com/dns-query")

        XCTAssertEqual(report.exit.ip, "203.0.113.8")
        XCTAssertEqual(report.resolvers.map(\.ip), ["1.1.1.1"])
        XCTAssertEqual(report.dns.status, .clear)
        let urls = await recorder.values()
        let dnsHosts = urls.compactMap(\.host).filter { $0.hasSuffix(".dnsleak.example.test") }
        XCTAssertEqual(dnsHosts.count, 3)
        XCTAssertEqual(Set(dnsHosts).count, 3)
        XCTAssertTrue(dnsHosts.allSatisfy { host in
            host.split(separator: ".").first?.allSatisfy { $0.isLowercase || $0.isNumber } == true
        })
    }

    func testRunPropagatesConfigFailure() async {
        let service = ExitDiagnosticsService { _ in throw URLError(.cannotConnectToHost) }

        do {
            _ = try await service.run(remoteDoH: "https://dns.google/dns-query")
            XCTFail("Expected diagnostic request to fail")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
    }
}

private actor URLRecorder {
    private var urls: [URL] = []

    func append(_ url: URL) { urls.append(url) }
    func values() -> [URL] { urls }
}
