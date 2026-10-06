import Darwin
import Foundation
import XCTest
@testable import KongshanCore

/// TCP 握手测速绕开系统代理与 TUN：绑物理网卡的 socket + 绑网卡的直连 DNS。
/// 真机 2026-10-06 一次测速 461 条连接全经当前节点转发，测出的是「经节点绕一圈」的延迟。
final class DirectPingTests: XCTestCase {
    func testQueryMessageEncodesLabelsAndRecursionDesired() throws {
        let message = try XCTUnwrap(DirectDNS.message(id: 0x1234, host: "a.example.com"))
        XCTAssertEqual(Array(message[0..<4]), [0x12, 0x34, 0x01, 0x00], "ID + RD")
        XCTAssertEqual(Array(message[4..<6]), [0x00, 0x01], "一个问题")
        XCTAssertEqual(Array(message[12...]), [1] + Array("a".utf8) + [7] + Array("example".utf8) + [3] + Array("com".utf8)
            + [0, 0x00, 0x01, 0x00, 0x01])
        XCTAssertNil(DirectDNS.message(id: 1, host: "bad..name"))
        XCTAssertNil(DirectDNS.message(id: 1, host: String(repeating: "a", count: 64) + ".com"))
    }

    /// 应答里 CNAME 链 + 压缩指针：只取 A 记录。
    func testParseTakesARecordsAcrossCNAMEWithCompression() {
        var response: [UInt8] = [0xBE, 0xEF, 0x81, 0x80, 0x00, 0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00]
        response += [4] + Array("node".utf8) + [7] + Array("example".utf8) + [0, 0x00, 0x01, 0x00, 0x01]
        // CNAME：指回问题里的名字（0xC00C），数据是另一个名字。
        response += [0xC0, 0x0C, 0x00, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x06, 3] + Array("cdn".utf8) + [0xC0, 0x11]
        response += [0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x04, 203, 0, 113, 7]
        response += [0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x04, 203, 0, 113, 8]

        XCTAssertEqual(DirectDNS.parse(response, id: 0xBEEF), .answer([IPLiteral("203.0.113.7")!, IPLiteral("203.0.113.8")!]))
        XCTAssertEqual(DirectDNS.parse(response, id: 0x0001), .mismatched, "ID 对不上的应答丢掉")
    }

    func testParseMapsErrorCodes() {
        let nxdomain: [UInt8] = [0x00, 0x07, 0x81, 0x83, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        XCTAssertEqual(DirectDNS.parse(nxdomain, id: 7), .error("域名不存在"))
        let query: [UInt8] = [0x00, 0x07, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        XCTAssertEqual(DirectDNS.parse(query, id: 7), .mismatched, "不是应答（QR=0）")
    }

    func testVirtualInterfacesAreNotPhysical() {
        XCTAssertTrue(PhysicalInterface.isPhysical("en0"))
        XCTAssertTrue(PhysicalInterface.isPhysical("en7"))
        for name in ["utun4", "ipsec0", "lo0", "awdl0", "llw0", "ppp0", ""] {
            XCTAssertFalse(PhysicalInterface.isPhysical(name), name)
        }
    }

    /// 绑网卡的握手：对本机监听端口成功，对关闭端口很快失败。绑在 lo0 上测，不依赖外网。
    func testBoundConnectMeasuresHandshakeAndFailsFastOnClosedPort() throws {
        let listener = try LoopbackListener()
        defer { listener.close() }
        let loopback = if_nametoindex("lo0")
        XCTAssertNotEqual(loopback, 0)

        let ok = DirectSocket.connectTime(to: IPLiteral("127.0.0.1")!, port: listener.port, interfaceIndex: loopback, timeoutMilliseconds: 1_000)
        guard case let .success(ms) = ok else { return XCTFail("\(ok)") }
        XCTAssertLessThan(ms, 1_000)

        let closed = DirectSocket.connectTime(to: IPLiteral("127.0.0.1")!, port: 9, interfaceIndex: loopback, timeoutMilliseconds: 1_000)
        guard case let .failure(reason) = closed else { return XCTFail("关闭的端口应失败") }
        XCTAssertEqual(reason, "Connection refused")
    }

    /// 绑在一块够不着目标的网卡上必须失败——这正是「绑了网卡就不走 TUN 默认路由」的另一面。
    func testBindingIsEnforced() throws {
        let listener = try LoopbackListener()
        defer { listener.close() }
        guard let physical = PhysicalInterface.primary() else { throw XCTSkip("本机没有物理网卡在线") }
        let result = DirectSocket.connectTime(to: IPLiteral("127.0.0.1")!, port: listener.port, interfaceIndex: physical.index, timeoutMilliseconds: 500)
        guard case .failure = result else { return XCTFail("绑物理网卡后回环地址应不可达：\(result)") }
    }

    func testReadableFailureKeepsDirectResolverReasons() async {
        let result = await TCPPinger.ping(host: "127.0.0.1", port: 0)
        XCTAssertEqual(result, .failure("端口无效"))
    }
}

/// 本机回环上的一次性 TCP 监听。
private final class LoopbackListener {
    let fd: Int32
    let port: Int

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        fd = descriptor
        port = Int(UInt16(bigEndian: actual.sin_port))
    }

    func close() { Darwin.close(fd) }
}
