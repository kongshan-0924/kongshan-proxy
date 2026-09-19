import Darwin
import Foundation
import XCTest
@testable import KongshanCore

final class LocalTCPRelayTests: XCTestCase {
    func testKeepsPublicPortWhileSwitchingBackendAndSupportsHalfClose() async throws {
        let first = try ReplyServer(reply: Data("first".utf8))
        let second = try ReplyServer(reply: Data("second".utf8))
        defer {
            first.stop()
            second.stop()
        }

        let relay = LocalTCPRelay()
        let publicPort = try await relay.start(preferredPort: nil)
        let repeatedPort = try await relay.start(preferredPort: publicPort)
        XCTAssertEqual(repeatedPort, publicPort)

        relay.setTarget(port: first.port)
        let firstReply = try await request(port: publicPort)
        XCTAssertEqual(firstReply, Data("first".utf8))

        relay.setTarget(port: second.port)
        let secondReply = try await request(port: publicPort)
        XCTAssertEqual(secondReply, Data("second".utf8))

        relay.stop()
    }

    func testTargetClearRejectsNewConnectionsWithoutReleasingPublicPort() async throws {
        let server = try ReplyServer(reply: Data("ok".utf8))
        defer { server.stop() }

        let relay = LocalTCPRelay()
        let publicPort = try await relay.start(preferredPort: nil)
        relay.setTarget(port: server.port)
        let reply = try await request(port: publicPort)
        XCTAssertEqual(reply, Data("ok".utf8))

        relay.setTarget(port: nil)
        await XCTAssertThrowsErrorAsync(try await request(port: publicPort))
        let repeatedPort = try await relay.start(preferredPort: publicPort)
        XCTAssertEqual(repeatedPort, publicPort)
        relay.stop()

        let replacement = LocalTCPRelay()
        let reboundPort = try await replacement.start(preferredPort: publicPort)
        XCTAssertEqual(reboundPort, publicPort)
        replacement.stop()
    }

    /// 后端没人监听时必须**立刻断开**，不能挂着。
    ///
    /// 真机场景：切配置、切模式、内核崩溃都会有一段 sing-box 不在监听的窗口。
    /// 这里守的是一个**不显眼但要命**的实现细节：`RelayPair.handle` 只处理 `.failed`，
    /// 而回环死端口上 NWConnection 停在 `.waiting(ECONNREFUSED)` **永不转 `.failed`**
    /// （实测 8 秒仍是 waiting）。真正救场的是 `pump(from: backend, to: client)`
    /// 那个 `receive` —— 它会立刻带 ECONNREFUSED 回调，走 `cancel()`。
    /// 也就是说这条路径**只有一层保险**：谁要是重排了 pump 的启动顺序、
    /// 或让 backend 的 receive 晚于首个 send 才挂上，客户端就会一直挂着，
    /// 表现为浏览器转圈、Claude/Codex 请求超时。这个测试就是那层保险的看门人。
    /// 给 socket 留 6 秒读超时：断得快才过，挂着的话只能等满 6 秒。
    func testDeadBackendClosesClientImmediatelyInsteadOfHanging() async throws {
        let deadPort = try Self.reservedThenReleasedPort()

        let relay = LocalTCPRelay()
        let publicPort = try await relay.start(preferredPort: nil)
        defer { relay.stop() }
        relay.setTarget(port: deadPort)

        let outcome = try await probeBackendlessTarget(port: publicPort)
        XCTAssertTrue(
            outcome.closedByPeer,
            "中转应主动断开，而不是让读操作超时（errno \(outcome.errnoValue)）"
        )
        XCTAssertLessThan(outcome.elapsed, 3, "断开必须是立刻的，实测 \(outcome.elapsed) 秒")
    }

    private struct BackendlessOutcome {
        let closedByPeer: Bool
        let elapsed: TimeInterval
        let errnoValue: Int32
    }

    private func probeBackendlessTarget(port: UInt16) async throws -> BackendlessOutcome {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.blockingProbe(port: port) })
            }
        }
    }

    private static func blockingProbe(port: UInt16) throws -> BackendlessOutcome {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketTestError("socket") }
        defer { close(descriptor) }

        // 留足读超时：修好了就该秒断，没修好才会等满这 6 秒。
        var timeout = timeval(tv_sec: 6, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = Self.loopback(port: port)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw SocketTestError("connect errno \(errno)") }

        let started = Date()
        let payload = Data("ping".utf8)
        _ = payload.withUnsafeBytes { buffer in
            Darwin.send(descriptor, buffer.baseAddress, buffer.count, 0)
        }

        var buffer = [UInt8](repeating: 0, count: 64)
        let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
        return BackendlessOutcome(
            closedByPeer: count == 0,
            elapsed: Date().timeIntervalSince(started),
            errnoValue: count < 0 ? errno : 0
        )
    }

    // MARK: - 局域网入口

    /// 只绑用户指定的端口——包括 20000 以下的（默认 7890 就在这个区间）。旧实现借用内核端口的
    /// 20000–49151 范围，默认端口从来没被用过，每次开共享都换成随机端口。
    func testLANSharingBindsExactlyTheConfiguredPort() async throws {
        let server = try ReplyServer(reply: Data("lan".utf8))
        let relay = LocalTCPRelay()
        defer {
            relay.stop()
            server.stop()
        }
        _ = try await relay.start(preferredPort: nil)
        relay.setTarget(port: server.port)
        let port = try Self.freeWildcardPort(in: 10_000...19_999)
        let bound = try await relay.startLANSharing(port: port, policy: LANPeerPolicy())
        XCTAssertEqual(bound, port)
        let reply = try await request(port: port)
        XCTAssertEqual(reply, Data("lan".utf8))
    }

    /// 端口被别的程序占着：明确报 `portInUse`，**不另选端口**——别的设备存的就是这个端口。
    func testLANSharingReportsPortInUseInsteadOfSwitching() async throws {
        let port = try Self.freeWildcardPort(in: 10_000...19_999)
        let occupier = try Self.wildcardListener(port: port)
        defer { close(occupier) }
        let relay = LocalTCPRelay()
        defer { relay.stop() }
        do {
            let bound = try await relay.startLANSharing(port: port, policy: LANPeerPolicy())
            XCTFail("端口被占用时不该启动成功，却绑在了 \(bound)")
        } catch LocalTCPRelayError.portInUse(let reported) {
            XCTAssertEqual(reported, port)
        }
    }

    func testLANSharingRejectsPortOutsideAllowedRange() async {
        let relay = LocalTCPRelay()
        do {
            _ = try await relay.startLANSharing(port: 80, policy: LANPeerPolicy())
            XCTFail("低端口要 root 才能绑，应当直接拒绝")
        } catch LocalTCPRelayError.invalidPort(80) {
        } catch {
            XCTFail("\(error)")
        }
    }

    /// 在给定区间里找一个当前能在全部接口上绑的端口。
    private static func freeWildcardPort(in range: ClosedRange<Int>) throws -> UInt16 {
        for _ in 0..<200 {
            let candidate = UInt16(Int.random(in: range))
            if let descriptor = try? wildcardListener(port: candidate) {
                close(descriptor)
                return candidate
            }
        }
        throw POSIXError(.EADDRINUSE)
    }

    /// 在 0.0.0.0 上占住一个端口（不设 SO_REUSEADDR），模拟别的程序在监听。
    private static func wildcardListener(port: UInt16) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EMFILE) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }
        return descriptor
    }

    /// 拿一个「刚刚还在监听、现在已经没人」的端口——正是内核重启窗口里后端的状态。
    private static func reservedThenReleasedPort() throws -> UInt16 {
        let server = try ReplyServer(reply: Data("unused".utf8))
        let port = server.port
        server.stop()
        return port
    }

    private func request(port: UInt16) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.blockingRequest(port: port) })
            }
        }
    }

    private static func blockingRequest(port: UInt16) throws -> Data {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw SocketTestError("socket") }
            defer { close(descriptor) }

            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            var address = Self.loopback(port: port)
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { throw SocketTestError("connect errno \(errno)") }

            let payload = Data("ping".utf8)
            let sent = payload.withUnsafeBytes { buffer in
                Darwin.send(descriptor, buffer.baseAddress, buffer.count, 0)
            }
            guard sent == payload.count else { throw SocketTestError("send errno \(errno)") }
            guard shutdown(descriptor, SHUT_WR) == 0 else { throw SocketTestError("shutdown") }

            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 128)
            while true {
                let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
                if count > 0 {
                    result.append(contentsOf: buffer.prefix(count))
                    continue
                }
                if count == 0 { break }
                throw SocketTestError("recv errno \(errno)")
            }
            guard !result.isEmpty else { throw SocketTestError("empty response") }
            return result
    }

    fileprivate static func loopback(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return address
    }
}

private struct SocketTestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private final class ReplyServer: @unchecked Sendable {
    let port: UInt16
    private let descriptor: Int32
    private let reply: Data
    private let queue = DispatchQueue(label: "com.kaysen.kongshan.relay-test-server")
    private let lock = NSLock()
    private var stopped = false

    init(reply: Data) throws {
        self.reply = reply
        let serverDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard serverDescriptor >= 0 else { throw SocketTestError("server socket") }
        descriptor = serverDescriptor

        var reuse: Int32 = 1
        _ = setsockopt(serverDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = LocalTCPRelayTests.loopback(port: 0)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(serverDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(serverDescriptor, 8) == 0 else {
            close(serverDescriptor)
            throw SocketTestError("server bind/listen errno \(errno)")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(serverDescriptor, $0, &length)
            }
        }
        guard named == 0 else {
            close(serverDescriptor)
            throw SocketTestError("getsockname")
        }
        port = UInt16(bigEndian: address.sin_port)
        queue.async { [weak self] in self?.serve() }
    }

    func stop() {
        let shouldStop = lock.withLock {
            guard !stopped else { return false }
            stopped = true
            return true
        }
        if shouldStop {
            shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
        }
    }

    private func serve() {
        while !lock.withLock({ stopped }) {
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            DispatchQueue.global(qos: .userInitiated).async { [reply] in
                var buffer = [UInt8](repeating: 0, count: 128)
                _ = Darwin.recv(client, &buffer, buffer.count, 0)
                _ = reply.withUnsafeBytes { bytes in
                    Darwin.send(client, bytes.baseAddress, bytes.count, 0)
                }
                shutdown(client, SHUT_WR)
                close(client)
            }
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
