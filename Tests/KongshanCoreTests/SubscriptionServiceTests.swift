import Foundation
import XCTest
@testable import KongshanCore

final class SubscriptionServiceTests: XCTestCase {
    func testSuccessfulRefreshReplacesCache() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = SubscriptionService(storage: fixture.storage) { _ in
            HTTPDownload(data: Data(Self.newYAML.utf8), statusCode: 200)
        }

        let result = try await service.refresh(fixture.subscription)

        XCTAssertFalse(result.usedCache)
        XCTAssertEqual(result.nodes.map(\.name), ["new"])
        XCTAssertEqual(try Data(contentsOf: fixture.storage.cacheURL(for: fixture.subscription)), Data(Self.newYAML.utf8))
    }

    func testDownloadFailureUsesOldCache() async throws {
        let fixture = try makeFixture(oldCache: Self.oldYAML)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = SubscriptionService(storage: fixture.storage) { _ in
            throw URLError(.notConnectedToInternet)
        }

        let result = try await service.refresh(fixture.subscription)

        XCTAssertTrue(result.usedCache)
        XCTAssertEqual(result.nodes.map(\.name), ["old"])
        XCTAssertTrue(result.warnings.contains { $0.contains("缓存") })
    }

    func testMalformedRefreshDoesNotOverwriteOldCache() async throws {
        let fixture = try makeFixture(oldCache: Self.oldYAML)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = SubscriptionService(storage: fixture.storage) { _ in
            HTTPDownload(data: Data("proxies: [broken".utf8), statusCode: 200)
        }

        let result = try await service.refresh(fixture.subscription)

        XCTAssertTrue(result.usedCache)
        XCTAssertEqual(try String(contentsOf: fixture.storage.cacheURL(for: fixture.subscription), encoding: .utf8), Self.oldYAML)
    }

    func testFailureWithoutCacheIsReported() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = SubscriptionService(storage: fixture.storage) { _ in
            throw URLError(.timedOut)
        }

        do {
            _ = try await service.refresh(fixture.subscription)
            XCTFail("Expected refresh failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("缓存"))
        }
    }

    func testDefaultRequestSendsClashUserAgentWithoutSingBoxMarker() {
        let request = SubscriptionService.request(for: URL(string: "https://example.com/sub")!)
        let userAgent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
        // 面板按 UA 分发格式：必须命中 "clash" 分支拿 YAML；
        // 带 "sing-box" 会拿到 JSON，我们的转换器直接失败。
        XCTAssertTrue(userAgent.lowercased().contains("clash"), userAgent)
        XCTAssertFalse(userAgent.lowercased().contains("sing-box"), userAgent)
    }

    func testSubscriptionUserInfoHeaderParsing() {
        let usage = SubscriptionUsage.parse(
            headerValue: "upload=1073741824; download=5368709120; total=107374182400; expire=1770000000"
        )
        XCTAssertEqual(usage?.uploadBytes, 1_073_741_824)
        XCTAssertEqual(usage?.downloadBytes, 5_368_709_120)
        XCTAssertEqual(usage?.totalBytes, 107_374_182_400)
        XCTAssertEqual(usage?.usedBytes, 6_442_450_944)
        XCTAssertEqual(usage?.expiresAt, Date(timeIntervalSince1970: 1_770_000_000))

        // 字段可缺省、可乱序、可带空格；expire=0 表示不限期。
        let partial = SubscriptionUsage.parse(headerValue: " download=100 ;upload=50; expire=0 ")
        XCTAssertEqual(partial?.usedBytes, 150)
        XCTAssertNil(partial?.totalBytes)
        XCTAssertNil(partial?.expiresAt)

        XCTAssertNil(SubscriptionUsage.parse(headerValue: "nonsense"))
        XCTAssertNil(SubscriptionUsage.parse(headerValue: ""))
    }

    func testRefreshCapturesUsageAndSuggestedNameFromHeaders() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = SubscriptionService(storage: fixture.storage) { _ in
            HTTPDownload(
                data: Data(Self.newYAML.utf8),
                statusCode: 200,
                headers: [
                    "Subscription-Userinfo": "upload=10; download=20; total=100; expire=1770000000",
                    "Content-Disposition": "attachment; filename=\"MyAirport.yaml\""
                ]
            )
        }

        let result = try await service.refresh(fixture.subscription)

        XCTAssertEqual(result.usage?.usedBytes, 30)
        XCTAssertEqual(result.usage?.totalBytes, 100)
        XCTAssertEqual(result.suggestedName, "MyAirport")
    }

    func testSuggestedNamePrefersProfileTitleAndDecodesVariants() {
        XCTAssertEqual(
            SubscriptionService.suggestedName(from: HTTPDownload(
                data: Data(), statusCode: 200,
                headers: ["profile-title": "我的机场", "Content-Disposition": "attachment; filename=\"x.yaml\""]
            )),
            "我的机场"
        )
        let encoded = Data("Base64机场".utf8).base64EncodedString()
        XCTAssertEqual(
            SubscriptionService.suggestedName(from: HTTPDownload(
                data: Data(), statusCode: 200,
                headers: ["Profile-Title": "base64:\(encoded)"]
            )),
            "Base64机场"
        )
        XCTAssertEqual(
            SubscriptionService.suggestedName(from: HTTPDownload(
                data: Data(), statusCode: 200,
                headers: ["Content-Disposition": "attachment; filename*=UTF-8''%E6%9C%BA%E5%9C%BA.yaml"]
            )),
            "机场"
        )
        XCTAssertNil(SubscriptionService.suggestedName(from: HTTPDownload(data: Data(), statusCode: 200)))
    }

    func testSubscriptionSourceDecodesLegacyJSONWithoutUsage() throws {
        let legacy = """
        {"id":"20000000-0000-0000-0000-000000000009","name":"old","url":"https://a.example/c.yaml"}
        """
        let source = try JSONDecoder().decode(SubscriptionSource.self, from: Data(legacy.utf8))
        XCTAssertNil(source.usage)
        XCTAssertTrue(source.autoUpdate)

        var updated = source
        updated.usage = SubscriptionUsage(uploadBytes: 1, downloadBytes: 2, totalBytes: 3, expiresAt: nil)
        let data = try JSONEncoder().encode(updated)
        let decoded = try JSONDecoder().decode(SubscriptionSource.self, from: data)
        XCTAssertEqual(decoded.usage?.usedBytes, 3)
    }

    private func makeFixture(oldCache: String? = nil) throws -> (
        root: URL,
        storage: Storage,
        subscription: SubscriptionSource
    ) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let storage = Storage(rootDirectory: root)
        let subscription = SubscriptionSource(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            name: "airport",
            url: URL(string: "https://example.com/clash.yaml")!
        )
        try FileManager.default.createDirectory(at: root.appending(path: "subscriptions"), withIntermediateDirectories: true)
        if let oldCache {
            try Data(oldCache.utf8).write(to: storage.cacheURL(for: subscription))
        }
        return (root, storage, subscription)
    }

    private static let oldYAML = """
    proxies:
      - {name: old, type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: old}
    """

    private static let newYAML = """
    proxies:
      - {name: new, type: ss, server: 2.2.2.2, port: 443, cipher: aes-128-gcm, password: new}
    """
}

final class SpeedTestTests: XCTestCase {
    func testTCPPingRejectsInvalidPort() async {
        let result = await TCPPinger.ping(host: "127.0.0.1", port: 0, timeoutMilliseconds: 200)
        guard case .failure = result else { return XCTFail("端口 0 应失败") }
    }

    func testTCPPingClosedPortFailsWithinTimeout() async {
        // 本机一个几乎不可能被占用的高位端口，握手应很快失败（拒绝/超时），不挂死。
        let result = await TCPPinger.ping(host: "127.0.0.1", port: 59_237, timeoutMilliseconds: 800)
        guard case .failure = result else { return XCTFail("关闭的端口应失败") }
    }

    func testSpeedTestMethodDefaultsAndRoundTrips() throws {
        XCTAssertEqual(SpeedTestMethod.allCases, [.tcpPing, .urlTest])
        let data = try JSONEncoder().encode(SpeedTestMethod.urlTest)
        XCTAssertEqual(try JSONDecoder().decode(SpeedTestMethod.self, from: data), .urlTest)
    }
}
