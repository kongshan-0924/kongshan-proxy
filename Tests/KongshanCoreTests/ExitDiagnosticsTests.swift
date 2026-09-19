import Foundation
import XCTest
@testable import KongshanCore

final class ExitDiagnosticsTests: XCTestCase {
    func testMullvadExitPayloadDecodesLocationAndOrganization() throws {
        let data = Data(#"{"ip":"203.0.113.8","country":"Japan","city":"Tokyo","organization":"Example ISP"}"#.utf8)

        let info = try JSONDecoder().decode(ExitIPInfo.self, from: data)

        XCTAssertEqual(info.ip, "203.0.113.8")
        XCTAssertEqual(info.city, "Tokyo")
        XCTAssertEqual(info.country, "Japan")
        XCTAssertEqual(info.organization, "Example ISP")
    }

    func testResolverPayloadDecodesMullvadFieldAndDeduplicatesByIP() throws {
        let data = Data(#"[{"ip":"1.1.1.1","country":"Japan","organization":"Cloudflare, Inc.","mullvad_dns":false},{"ip":"1.1.1.1","country":"Japan","organization":"Cloudflare, Inc.","mullvad_dns":false}]"#.utf8)
        let decoded = try JSONDecoder().decode([DNSResolverInfo].self, from: data)

        let unique = DNSLeakAnalyzer.deduplicated(decoded)

        XCTAssertEqual(unique.count, 1)
        XCTAssertEqual(unique.first?.organization, "Cloudflare, Inc.")
        XCTAssertEqual(unique.first?.isMullvadDNS, false)
    }

    func testExpectedRemoteDoHProviderIsNotReportedAsLeak() {
        let exit = ExitIPInfo(ip: "203.0.113.8", country: "Japan", city: "Tokyo", organization: "Example ISP")
        let resolvers = [DNSResolverInfo(ip: "1.1.1.1", country: "Netherlands", city: "Amsterdam", organization: "Cloudflare, Inc.", isMullvadDNS: false)]

        let result = DNSLeakAnalyzer.assess(
            exit: exit,
            resolvers: resolvers,
            remoteDoH: "https://cloudflare-dns.com/dns-query"
        )

        XCTAssertEqual(result.status, .clear)
    }

    func testResolverInSameExitCountryIsNotReportedAsLeak() {
        let exit = ExitIPInfo(ip: "203.0.113.8", country: "Japan", city: "Tokyo", organization: "Example ISP")
        let resolvers = [DNSResolverInfo(ip: "192.0.2.53", country: "Japan", city: nil, organization: "Local Resolver", isMullvadDNS: false)]

        let result = DNSLeakAnalyzer.assess(exit: exit, resolvers: resolvers, remoteDoH: "https://unknown.example/dns-query")

        XCTAssertEqual(result.status, .clear)
    }

    func testUnexpectedResolverCountryIsPossibleLeak() {
        let exit = ExitIPInfo(ip: "203.0.113.8", country: "Japan", city: "Tokyo", organization: "Example ISP")
        let resolvers = [DNSResolverInfo(ip: "198.51.100.53", country: "China", city: nil, organization: "Local Broadband", isMullvadDNS: false)]

        let result = DNSLeakAnalyzer.assess(
            exit: exit,
            resolvers: resolvers,
            remoteDoH: "https://cloudflare-dns.com/dns-query"
        )

        XCTAssertEqual(result.status, .possible)
        XCTAssertTrue(result.detail.contains("Local Broadband"))
    }

    func testNoResolverResultIsIndeterminate() {
        let exit = ExitIPInfo(ip: "203.0.113.8", country: "Japan", city: "Tokyo", organization: "Example ISP")

        let result = DNSLeakAnalyzer.assess(exit: exit, resolvers: [], remoteDoH: "https://dns.google/dns-query")

        XCTAssertEqual(result.status, .indeterminate)
    }
}
