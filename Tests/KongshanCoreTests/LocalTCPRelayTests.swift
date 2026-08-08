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
