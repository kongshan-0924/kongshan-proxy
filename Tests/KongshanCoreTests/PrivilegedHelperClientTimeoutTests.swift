import Darwin
import Foundation
import HelperProtocol
import XCTest
@testable import KongshanCore

/// 启动等待要比通用读写超时长：helper 启动前要完整校验内核签名，Intel iMac 上 90 MB 的内核
/// 单这一步就 2 秒多、整体 5.1 秒，压过了原先统一的 5 秒——App 判失败，内核却在之后起来
/// （2026-10-26 实测）。这里用一个故意晚回应的假 helper 钉住两种超时各管各的。
final class PrivilegedHelperClientTimeoutTests: XCTestCase {
    /// 假 helper：收一个请求帧，等 `delay` 秒再回 started。
    private final class SlowHelper: @unchecked Sendable {
        let path: String
        private let listener: Int32

        init(delay: TimeInterval) throws {
            // sun_path 上限 104 字节，测试临时目录太长，放 /tmp 下短名。
            path = "/tmp/ks-\(UUID().uuidString.prefix(8)).sock"
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, Darwin.listen(listener, 2) == 0 else { throw POSIXError(.EADDRINUSE) }
            let fd = listener
            Thread.detachNewThread {
                let conn = Darwin.accept(fd, nil, nil)
                guard conn >= 0 else { return }
                let (_, passed) = HelperWire.receive(on: conn)
                if let passed { close(passed) }
                Thread.sleep(forTimeInterval: delay)
                if let frame = try? HelperFraming.encode(HelperResponse(ok: true, message: "started", kernelPID: 4242)) {
                    try? HelperWire.send(frame: frame, fd: nil, on: conn)
                }
                close(conn)
            }
        }

        deinit {
            close(listener)
            unlink(path)
        }
    }

    private let binary = URL(fileURLWithPath: "/usr/bin/true")

    func testStartWaitsLongerThanGeneralIOTimeout() async throws {
        let helper = try SlowHelper(delay: 1.5)
        let client = PrivilegedHelperClient(binaryURL: binary, socketPath: helper.path, ioTimeout: 0.5, startTimeout: 4)
        let record = try await client.start(config: Data("{}".utf8))
        XCTAssertEqual(record.pid, 4242, "启动应等到 helper 回应，而不是按 0.5 秒的通用超时放弃")
    }

    func testStartStillGivesUpAfterStartTimeout() async throws {
        let helper = try SlowHelper(delay: 2)
        let client = PrivilegedHelperClient(binaryURL: binary, socketPath: helper.path, ioTimeout: 0.5, startTimeout: 0.5)
        do {
            _ = try await client.start(config: Data("{}".utf8))
            XCTFail("超过启动等待上限应报未收到响应")
        } catch PrivilegedHelperClientError.receiveFailed {
        }
    }

    /// 默认值要留够余量：签名校验 + 配置读写在慢机器上已实测 5.1 秒。
    func testDefaultStartTimeoutLeavesHeadroom() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appending(path: "Sources/KongshanCore/PrivilegedHelperClient.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("startTimeout: TimeInterval = 30"))
        XCTAssertTrue(source.contains("connectSocket(timeout: startTimeout)"))
        XCTAssertTrue(source.contains("connectSocket(timeout: stopTimeout)"))
    }
}
