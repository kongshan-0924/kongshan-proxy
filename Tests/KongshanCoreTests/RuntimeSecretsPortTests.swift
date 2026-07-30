import Darwin
import HelperProtocol
import XCTest
@testable import KongshanCore

/// mixed 端口跨启动复用的回归测试。
///
/// 背景：端口原本每次启动都随机。系统代理模式下它会写进系统代理设置，而 Chromium 系
/// 客户端（ChatGPT.app 内嵌的 codex 服务、Chrome）会缓存解析到的代理地址——内核一重启
/// 换了端口，它们就一直打死端口，表现为反复「正在重新连接」，重试若干次才恢复。
final class RuntimeSecretsPortTests: XCTestCase {
    private struct SocketFailure: Error { let stage: String }

    func testReusesPreferredPortWhenFree() throws {
        let first = try RuntimeSecrets.availableHighPort()

        // 复用必须是稳定的：连续问都得给同一个，否则"跨启动稳定"无从谈起。
        for _ in 0..<3 {
            XCTAssertEqual(try RuntimeSecrets.availableHighPort(preferred: first), first)
        }
    }

    func testFallsBackWhenPreferredPortHasLiveListener() throws {
        let port = try RuntimeSecrets.availableHighPort()
        let listener = try makeListener(port: port)
        defer { close(listener) }

        // 端口被别的进程真占着时必须让位，不能硬钉着一个起不来的端口。
        let allocated = try RuntimeSecrets.availableHighPort(preferred: port)
        XCTAssertNotEqual(allocated, port)
        XCTAssertTrue(HelperConstants.loopbackHighPorts.contains(Int(allocated)))
    }

    func testIgnoresPreferredPortOutsideHelperWhitelist() throws {
        // helper 只放行 49152~65535 的回环端口。低位端口即使空闲也不能复用，
        // 否则单测全绿、真机上助手直接拒掉这份配置。
        for candidate in [UInt16(80), UInt16(8080), UInt16(1080)] {
            let allocated = try RuntimeSecrets.availableHighPort(preferred: candidate)
            XCTAssertNotEqual(allocated, candidate)
            XCTAssertTrue(HelperConstants.loopbackHighPorts.contains(Int(allocated)))
        }
    }

    /// 真机主场景：内核刚停，旧连接还挂在 TIME_WAIT 上，紧接着重启要能拿回同一个端口。
    ///
    /// sing-box 是 Go 写的，`net.Listen` 默认带 `SO_REUSEADDR`，这种状态下能正常监听。
    /// 探测端若不带同样的选项就会比真实监听端更悲观地报"端口被占"，于是每次重启都被迫
    /// 另选端口——正好把要修的问题原样造回来。这条测试钉死两端行为一致。
    func testReusesPortThatStillHasTimeWaitConnections() throws {
        let port = try RuntimeSecrets.availableHighPort()
        let listener = try makeListener(port: port)

        let client = socket(AF_INET, SOCK_STREAM, 0)
        guard client >= 0 else { throw SocketFailure(stage: "client socket") }
        var target = Self.loopbackAddress(port: port)
        let connected = withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(client)
            close(listener)
            throw SocketFailure(stage: "connect")
        }

        let accepted = Darwin.accept(listener, nil, nil)
        guard accepted >= 0 else {
            close(client)
            close(listener)
            throw SocketFailure(stage: "accept")
        }

        // 服务端先关 = 主动关闭方，本地端口进 TIME_WAIT。内核停掉那一刻就是这个状态。
        close(accepted)
        close(client)
        close(listener)

        XCTAssertEqual(try RuntimeSecrets.availableHighPort(preferred: port), port)
    }

    // MARK: - 首选端口的退避重试（stableHighPort）

    /// 真机事故的回归测试：2026-07-30 一次完整重启后 mixed 端口从 49609 掉到 65408，
    /// 而事后 49609 是空闲的——说明只是**瞬时**占用（旧内核尚未回收的 pcb / 别的进程的
    /// 临时连接，端口池 49152~65535 就是 macOS 临时端口范围本身）。原实现只探一次，
    /// 于是一次瞬时冲突永久改写了落盘端口，系统代理端口跟着变，
    /// Chromium 系客户端又开始反复「正在重新连接」。这里钉死"宁可多等也别换端口"。
    func testStableHighPortWaitsForPreferredPortToBeReleased() async throws {
        let port = try RuntimeSecrets.availableHighPort()
        let listener = try makeListener(port: port)

        // 150ms 后释放，模拟上一个内核的监听 socket 还没回收干净。
        let release = Task {
            try? await Task.sleep(for: .milliseconds(150))
            close(listener)
        }

        let allocated = try await RuntimeSecrets.stableHighPort(
            preferred: port,
            retryDelays: RuntimeSecrets.defaultPreferredPortRetryDelays
        )
        await release.value

        XCTAssertEqual(allocated, port, "首选端口只是被短暂占用，退避重试后必须拿回同一个")
    }

    /// 重试不能变成死等：端口被别的进程长期占着时仍要及时让位。
    func testStableHighPortFallsBackWhenPreferredStaysOccupied() async throws {
        let port = try RuntimeSecrets.availableHighPort()
        let listener = try makeListener(port: port)
        defer { close(listener) }

        let allocated = try await RuntimeSecrets.stableHighPort(
            preferred: port,
            retryDelays: [.milliseconds(1), .milliseconds(1)]
        )
        XCTAssertNotEqual(allocated, port)
        XCTAssertTrue(HelperConstants.loopbackHighPorts.contains(Int(allocated)))
    }

    /// 端口空闲时一次都不该退避，否则每次启动都白等——退避只在真撞上时才付代价。
    func testStableHighPortDoesNotSleepWhenPreferredIsFree() async throws {
        let port = try RuntimeSecrets.availableHighPort()
        let started = ContinuousClock.now
        let allocated = try await RuntimeSecrets.stableHighPort(preferred: port, retryDelays: [.seconds(30)])
        XCTAssertEqual(allocated, port)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
    }

    private static func loopbackAddress(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr(HelperConstants.loopbackAddress))
        return address
    }

    /// 按 sing-box（Go `net.Listen`）的方式建监听：带 `SO_REUSEADDR`。
    private func makeListener(port: UInt16) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketFailure(stage: "socket") }

        var reuse: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = Self.loopbackAddress(port: port)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 8) == 0 else {
            close(descriptor)
            throw SocketFailure(stage: "bind/listen")
        }
        return descriptor
    }
}
