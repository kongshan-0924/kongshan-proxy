import Foundation
import XCTest
@testable import KongshanCore

final class ClashStreamingTests: XCTestCase {
    func testConnectionEndpointParsesDomainsIPv4AndIPv6() {
        XCTAssertEqual(ConnectionEndpoint(hostAndPort: "example.com:443"), ConnectionEndpoint(
            address: "example.com", port: 443, isIPAddress: false
        ))
        XCTAssertEqual(ConnectionEndpoint(hostAndPort: "203.0.113.8:8443"), ConnectionEndpoint(
            address: "203.0.113.8", port: 8443, isIPAddress: true
        ))
        XCTAssertEqual(ConnectionEndpoint(hostAndPort: "[2001:db8::1]:443"), ConnectionEndpoint(
            address: "2001:db8::1", port: 443, isIPAddress: true
        ))
        XCTAssertEqual(ConnectionEndpoint(hostAndPort: "2001:db8::1:443"), ConnectionEndpoint(
            address: "2001:db8::1", port: 443, isIPAddress: true
        ))
    }
    func testTrafficStreamUsesAuthenticatedWebSocketAndDecodesSamples() async throws {
        let fixture = StreamFixture(payloads: [Data(#"{"up":123,"down":456}"#.utf8)])
        let client = makeClient(fixture: fixture)

        let sample = try await first(await client.trafficStream())

        XCTAssertEqual(sample, TrafficSample(up: 123, down: 456))
        let request = try XCTUnwrap(fixture.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "ws://127.0.0.1:9090/traffic")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer runtime-secret")
    }

    func testConnectionsStreamUsesOneSecondPushAndCountsConnections() async throws {
        let fixture = StreamFixture(payloads: [
            Data(#"{"downloadTotal":1000,"uploadTotal":2000,"connections":[{"id":"a"},{"id":"b"}],"memory":3145728}"#.utf8)
        ])
        let client = makeClient(fixture: fixture)

        let snapshot = try await first(await client.connectionStream())

        // 累计量必须一并带上来：这是唯一权威的累计流量来源，之前被整个丢掉，
        // 于是「本次会话用了多少」根本无从计算（见 `SessionTrafficAccumulator`）。
        XCTAssertEqual(
            snapshot,
            ConnectionSnapshot(
                connectionCount: 2,
                memory: 3_145_728,
                uploadTotal: 2_000,
                downloadTotal: 1_000
            )
        )
        let request = try XCTUnwrap(fixture.requests.first)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "ws")
        XCTAssertEqual(components.path, "/connections")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "interval", value: "1000")])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer runtime-secret")
    }

    func testLogStreamUsesLevelAndMapsWarnPayload() async throws {
        let fixture = StreamFixture(payloads: [Data(#"{"type":"warn","payload":"route fallback"}"#.utf8)])
        let receivedAt = Date(timeIntervalSince1970: 1_234)
        let client = makeClient(fixture: fixture, now: { receivedAt })

        let entry = try await first(await client.logStream(level: .warning))

        XCTAssertEqual(entry, CoreLogEntry(level: .warning, message: "route fallback", receivedAt: receivedAt))
        let request = try XCTUnwrap(fixture.requests.first)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "ws")
        XCTAssertEqual(components.path, "/logs")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "level", value: "warn")])
    }

    func testInvalidPayloadEndsTypedStreamWithReadableError() async {
        let fixture = StreamFixture(payloads: [Data(#"{"unexpected":true}"#.utf8)])
        let client = makeClient(fixture: fixture)

        do {
            _ = try await first(await client.trafficStream())
            XCTFail("Expected invalid payload")
        } catch {
            XCTAssertEqual(error as? ClashAPIError, .invalidPayload)
        }
    }

    func testConsumerCancellationClosesUnderlyingDataStream() async throws {
        let fixture = StreamFixture(payloads: [], finishesAutomatically: false)
        let client = makeClient(fixture: fixture)
        let stream = await client.trafficStream()
        let consumer = Task {
            for try await _ in stream {}
        }
        try await waitUntil { fixture.requests.count == 1 }

        consumer.cancel()

        try await waitUntil { fixture.terminationCount == 1 }
    }

    private func makeClient(
        fixture: StreamFixture,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> ClashAPIClient {
        ClashAPIClient(
            controller: URL(string: "http://127.0.0.1:9090")!,
            secret: "runtime-secret",
            streamFactory: fixture.stream(for:),
            now: now
        )
    }

    private func first<Element>(
        _ stream: AsyncThrowingStream<Element, Error>
    ) async throws -> Element {
        for try await value in stream { return value }
        throw EmptyStreamError()
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

private struct EmptyStreamError: Error {}

private final class StreamFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let payloads: [Data]
    private let finishesAutomatically: Bool
    private var storedRequests: [URLRequest] = []
    private var storedTerminationCount = 0

    init(payloads: [Data], finishesAutomatically: Bool = true) {
        self.payloads = payloads
        self.finishesAutomatically = finishesAutomatically
    }

    var requests: [URLRequest] {
        lock.withLock { storedRequests }
    }

    var terminationCount: Int {
        lock.withLock { storedTerminationCount }
    }

    func stream(for request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        lock.withLock { storedRequests.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.withLock { storedTerminationCount += 1 }
            }
            for payload in payloads { continuation.yield(payload) }
            if finishesAutomatically { continuation.finish() }
        }
    }
}
