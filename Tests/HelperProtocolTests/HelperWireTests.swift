import Darwin
import Foundation
import XCTest
@testable import HelperProtocol

/// App ↔ helper 的线缆层回环测试：真开一对 socketpair，真传一个 FD 过去。
///
/// 这条链路此前从未被真正执行过（身份校验恒失败挡在前面），线上表现是
/// helper 回 `missing config fd`、TUN 起不来。根因是两端不对称：
/// 发送端一次 sendmsg 发出「长度前缀+body」，接收端却先用普通 `read()` 读长度前缀——
/// SOCK_STREAM 上辅助数据跟随本次发送的首字节投递，普通 read 会让内核**丢弃并关闭** FD。
final class HelperWireTests: XCTestCase {
    private func makeSocketPair() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw XCTSkip("无法创建 socketpair")
        }
        return (fds[0], fds[1])
    }

    /// 核心回归：带 FD 的请求必须完整送达，且收到的 FD 指向**同一个** pipe。
    func testRequestWithFileDescriptorSurvivesRoundTrip() throws {
        let (a, b) = try makeSocketPair()
        defer { close(a); close(b) }

        var pipeFDs: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&pipeFDs), 0)
        let readEnd = pipeFDs[0]
        let writeEnd = pipeFDs[1]
        defer { close(writeEnd) }

        let frame = try HelperFraming.encode(HelperRequest.startTun)
        try HelperWire.send(frame: frame, fd: readEnd, on: a)
        close(readEnd)   // 发送端交出后关掉自己的副本，模拟真实用法

        let (body, receivedFD) = HelperWire.receive(on: b)
        let payload = try XCTUnwrap(body, "帧没收到")
        XCTAssertEqual(try HelperFraming.decode(HelperRequest.self, from: payload), .startTun)
        let fd = try XCTUnwrap(receivedFD, "FD 丢了——这正是线上 missing config fd 的症状")
        defer { close(fd) }

        // 证明收到的确实是同一个 pipe：从写端写，从收到的 FD 读出同样的字节。
        let marker = Array("kongshan-fd-roundtrip".utf8)
        XCTAssertEqual(write(writeEnd, marker, marker.count), marker.count)
        var buffer = [UInt8](repeating: 0, count: marker.count)
        XCTAssertEqual(read(fd, &buffer, marker.count), marker.count)
        XCTAssertEqual(buffer, marker, "收到的 FD 不是发出去的那个 pipe")
    }

    /// 反向证明：**用普通 `read()` 读长度前缀会把 FD 丢掉**（这就是线上那个 bug 的机制）。
    /// 留着这条是为了防止后人"顺手优化"成先 read 再 recvmsg。
    func testPlainReadOnLengthPrefixLosesTheDescriptor() throws {
        let (a, b) = try makeSocketPair()
        defer { close(a); close(b) }
        var pipeFDs: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&pipeFDs), 0)
        defer { close(pipeFDs[1]) }

        try HelperWire.send(frame: try HelperFraming.encode(HelperRequest.startTun), fd: pipeFDs[0], on: a)
        close(pipeFDs[0])

        // 旧接收写法：普通 read 吃掉 4 字节长度前缀……
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        XCTAssertEqual(read(b, &lengthBytes, 4), 4)
        // ……再 recvmsg 读 body，此时控制数据已被内核丢弃。
        var iov = iovec(iov_base: UnsafeMutableRawPointer(mutating: [UInt8](repeating: 0, count: 64)), iov_len: 64)
        let space = (MemoryLayout<cmsghdr>.size + MemoryLayout<Int32>.size + 3) & ~3
        let control = UnsafeMutableRawBufferPointer.allocate(byteCount: space, alignment: MemoryLayout<Int>.alignment)
        memset(control.baseAddress, 0, space)
        defer { control.deallocate() }
        var msg = msghdr()
        msg.msg_iov = withUnsafeMutablePointer(to: &iov) { $0 }
        msg.msg_iovlen = 1
        msg.msg_control = control.baseAddress
        msg.msg_controllen = socklen_t(space)
        XCTAssertGreaterThan(recvmsg(b, &msg, 0), 0)

        let dataOffset = (MemoryLayout<cmsghdr>.size + 3) & ~3
        var gotFD = false
        if msg.msg_controllen >= socklen_t(dataOffset + MemoryLayout<Int32>.size), let ctl = msg.msg_control {
            let cmsg = ctl.assumingMemoryBound(to: cmsghdr.self)
            gotFD = cmsg.pointee.cmsg_level == SOL_SOCKET && cmsg.pointee.cmsg_type == SCM_RIGHTS
        }
        XCTAssertFalse(gotFD, "普通 read 之后居然还能拿到 FD？那说明这条结论过时了，需重新评估线缆层设计")
    }

    /// 不带 FD 的请求（status/stopTun）：正常送达，且不能凭空多出一个 FD。
    func testRequestWithoutFileDescriptor() throws {
        let (a, b) = try makeSocketPair()
        defer { close(a); close(b) }

        try HelperWire.send(frame: try HelperFraming.encode(HelperRequest.status), fd: nil, on: a)
        let (body, fd) = HelperWire.receive(on: b)
        XCTAssertNil(fd)
        XCTAssertEqual(try HelperFraming.decode(HelperRequest.self, from: try XCTUnwrap(body)), .status)
    }

    /// 响应方向（helper → App）同样走这套线缆层。
    func testResponseRoundTrip() throws {
        let (a, b) = try makeSocketPair()
        defer { close(a); close(b) }

        let response = HelperResponse(ok: true, message: "started", kernelPID: 4_242, helperVersion: "0.1.0")
        try HelperWire.send(frame: try HelperFraming.encode(response), fd: nil, on: a)
        let (body, _) = HelperWire.receive(on: b)
        XCTAssertEqual(try HelperFraming.decode(HelperResponse.self, from: try XCTUnwrap(body)), response)
    }

    /// 大 body（超过单次 write 常见分片）也要完整送达，且 FD 仍在。
    func testLargeFrameWithFileDescriptor() throws {
        let (a, b) = try makeSocketPair()
        defer { close(a); close(b) }
        // socketpair 默认缓冲有限，先撑大接收端缓冲避免测试自身死锁。
        var size = 1 << 20
        _ = setsockopt(b, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int>.size))
        _ = setsockopt(a, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int>.size))

        var pipeFDs: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&pipeFDs), 0)
        defer { close(pipeFDs[1]) }

        // 造一个几十 KB 的响应体，逼出多次 write。
        let long = String(repeating: "配置", count: 20_000)
        let frame = try HelperFraming.encode(HelperResponse(ok: true, message: long))
        XCTAssertGreaterThan(frame.count, 64_000)
        try HelperWire.send(frame: frame, fd: pipeFDs[0], on: a)
        close(pipeFDs[0])

        let (body, fd) = HelperWire.receive(on: b)
        if let fd { close(fd) }
        let decoded = try HelperFraming.decode(HelperResponse.self, from: try XCTUnwrap(body))
        XCTAssertEqual(decoded.message, long, "大帧被截断")
    }

    /// 对端直接关闭（没发任何东西）→ 收不到帧，且不能返回野 FD。
    func testClosedPeerYieldsNothing() throws {
        let (a, b) = try makeSocketPair()
        defer { close(b) }
        close(a)
        let (body, fd) = HelperWire.receive(on: b)
        XCTAssertNil(body)
        XCTAssertNil(fd)
    }
}
