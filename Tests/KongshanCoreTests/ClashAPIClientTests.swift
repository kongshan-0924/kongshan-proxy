import Foundation
import XCTest
@testable import KongshanCore

final class ClashAPIClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.state.reset()
    }

    func testSelectUsesBearerTokenEncodedPathAndPUTBody() async throws {
        StubURLProtocol.state.setHandler { _ in StubResponse(data: Data("{}".utf8)) }
        let client = makeClient()

        try await client.select(node: "香港 01", in: "手动选择")

        let request = try XCTUnwrap(StubURLProtocol.state.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer runtime-secret")
        XCTAssertTrue(request.url?.absoluteString.contains("%E6%89%8B%E5%8A%A8%E9%80%89%E6%8B%A9") == true)
        let body = try XCTUnwrap(bodyData(for: request))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: body) as? [String: String])?["name"], "香港 01")
    }

    func testDelayParsesMillisecondsAndEncodesQuery() async throws {
        StubURLProtocol.state.setHandler { _ in StubResponse(data: Data(#"{"delay":123}"#.utf8)) }
        let client = makeClient()
        let testURL = URL(string: "http://www.gstatic.com/generate_204")!

        let delay = try await client.delay(node: "香港 01", testURL: testURL, timeoutMilliseconds: 5_000)

        XCTAssertEqual(delay, 123)
        let request = try XCTUnwrap(StubURLProtocol.state.requests.first)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "url" })?.value, testURL.absoluteString)
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "timeout" })?.value, "5000")
    }

    func testHealthUsesVersionEndpoint() async throws {
        StubURLProtocol.state.setHandler { _ in StubResponse(data: Data(#"{"version":"1.13.14"}"#.utf8)) }
        let client = makeClient()

        try await client.health()
        let version = try await client.version()

        XCTAssertEqual(version, "1.13.14")
        XCTAssertTrue(StubURLProtocol.state.requests.allSatisfy { $0.url?.path == "/version" })
    }

    func testDelayRejectsHTTPError() async {
        StubURLProtocol.state.setHandler { _ in StubResponse(statusCode: 503, data: Data()) }
        let client = makeClient()

        do {
            _ = try await client.delay(
                node: "node",
                testURL: URL(string: "http://www.gstatic.com/generate_204")!
            )
            XCTFail("Expected HTTP error")
        } catch {
            XCTAssertEqual(error as? ClashAPIError, .httpStatus(503))
        }
    }

    func testBatchDelayLimitsConcurrencyToEight() async {
        StubURLProtocol.state.setHandler { _ in
            StubResponse(data: Data(#"{"delay":42}"#.utf8), delay: 0.03)
        }
        let client = makeClient()
        let nodes = (0..<16).map { "node-\($0)" }

        let results = await client.delays(
            nodes: nodes,
            testURL: URL(string: "http://www.gstatic.com/generate_204")!,
            limit: 8
        )

        XCTAssertEqual(results.count, 16)
        XCTAssertLessThanOrEqual(StubURLProtocol.state.peakActiveRequests, 8)
        XCTAssertTrue(results.values.allSatisfy { $0 == .success(42) })
    }

    private func makeClient() -> ClashAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpMaximumConnectionsPerHost = 64
        return ClashAPIClient(
            controller: URL(string: "http://127.0.0.1:9090")!,
            secret: "runtime-secret",
            session: URLSession(configuration: configuration)
        )
    }

    private func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private struct StubResponse: Sendable {
    var statusCode: Int = 200
    var data: Data
    var delay: TimeInterval = 0
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = StubState()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = Self.state.begin(request)
        DispatchQueue.global().asyncAfter(deadline: .now() + response.delay) { [weak self] in
            guard let self, let url = self.request.url else { return }
            let http = HTTPURLResponse(
                url: url,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            self.client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: response.data)
            self.client?.urlProtocolDidFinishLoading(self)
            Self.state.end()
        }
    }

    override func stopLoading() {}
}

private final class StubState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: @Sendable (URLRequest) -> StubResponse = { _ in StubResponse(data: Data()) }
    private var activeRequests = 0
    private(set) var peakActiveRequests = 0
    private(set) var requests: [URLRequest] = []

    func reset() {
        lock.withLock {
            handler = { _ in StubResponse(data: Data()) }
            activeRequests = 0
            peakActiveRequests = 0
            requests = []
        }
    }

    func setHandler(_ handler: @escaping @Sendable (URLRequest) -> StubResponse) {
        lock.withLock { self.handler = handler }
    }

    func begin(_ request: URLRequest) -> StubResponse {
        lock.withLock {
            requests.append(request)
            activeRequests += 1
            peakActiveRequests = max(peakActiveRequests, activeRequests)
            return handler(request)
        }
    }

    func end() {
        lock.withLock { activeRequests -= 1 }
    }
}

/// 连接元数据的真实形状（sing-box 1.13.21 实测）：只有 `processPath` 与 `type`，没有 `process`。
extension ClashAPIClientTests {
    private func detail(_ meta: [String: Any]) -> ConnectionDetail {
        ConnectionDetail(payload: ["id": "c", "metadata": meta, "rule": "final", "chains": ["direct"]])
    }

    func testProcessNameComesFromProcessPath() {
        let app = detail(["type": "tun/tun-in", "processPath": "/Applications/Foo Bar.app/Contents/MacOS/Foo Bar (user)"])
        XCTAssertEqual(app.process, "Foo Bar")
        XCTAssertEqual(app.inboundType, "tun")
        XCTAssertFalse(app.viaLocalProxyEntry)

        let tool = detail(["type": "mixed/mixed-in", "processPath": "/usr/bin/curl (user)"])
        XCTAssertEqual(tool.process, "curl")
        XCTAssertFalse(tool.viaLocalProxyEntry, "直连内核入口、认得出来源的不算经系统代理")
    }

    /// 经空山本地入口进来的：来源是空山自己或查不到，标为经系统代理，不能据此建分应用规则。
    func testConnectionsThroughTheLocalEntryAreMarked() {
        let relayed = detail(["type": "mixed/mixed-in", "processPath": "/Applications/kongshan.app/Contents/MacOS/kongshan (user)"])
        XCTAssertEqual(relayed.process, "kongshan")
        XCTAssertTrue(relayed.viaLocalProxyEntry)
        XCTAssertTrue(detail(["type": "mixed/mixed-in", "processPath": ""]).viaLocalProxyEntry)
    }

    func testLegacyProcessKeyStillWorks() {
        XCTAssertEqual(detail(["process": "Safari"]).process, "Safari")
        XCTAssertNil(detail([:]).process)
        XCTAssertNil(detail([:]).inboundType)
    }
}

