import Darwin
import Foundation
import XCTest
@testable import KongshanCore

/// 测速专用内核：独立于主内核，开没开接管都能测真实延迟。凭据全是占位值。
final class DelayTestKernelTests: XCTestCase {
    private let nodes = [
        ProxyNode(name: "ss", protocolType: .shadowsocks, server: "127.0.0.1", port: 1, password: "pw", method: "aes-128-gcm"),
        ProxyNode(
            name: "reality", protocolType: .vless, server: "vl.example.com", port: 443,
            uuid: "00000000-0000-0000-0000-000000000001", tlsEnabled: true,
            realityPublicKey: "a3hWnD_FlTACs474J0sKv3ZfkQWFJ6aa4eu-bhZqaao", realityShortID: "0123abcd"
        ),
        ProxyNode(name: "hy2", protocolType: .hysteria2, server: "hy.example.com", port: 443, password: "pw"),
        ProxyNode(name: "anytls", protocolType: .anytls, server: "at.example.com", port: 443, password: "pw"),
        // 缺密码：主配置会整份报错，测速配置只跳过它。
        ProxyNode(name: "broken", protocolType: .trojan, server: "tj.example.com", port: 443)
    ]

    /// 只有节点出站 + Clash API：不监听代理端口、不建 TUN；出站绑物理网卡，主内核开着 TUN 也接不走。
    func testConfigHasOnlyNodeOutboundsAndBindsPhysicalInterface() async throws {
        let data = try ConfigGenerator.delayTestConfig(
            nodes: nodes, resolver: "223.5.5.5", interfaceName: "en0", clashPort: 23_456, secret: "s"
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(root["inbounds"])
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        XCTAssertEqual(route["default_interface"] as? String, "en0")
        XCTAssertEqual(route["default_domain_resolver"] as? String, "bootstrap")
        let tags = (root["outbounds"] as? [[String: Any]])?.compactMap { $0["tag"] as? String } ?? []
        XCTAssertEqual(tags, nodes.prefix(4).map(ConfigGenerator.outboundTag) + ["direct"])
        let clash = (root["experimental"] as? [String: Any])?["clash_api"] as? [String: Any]
        XCTAssertEqual(clash?["external_controller"] as? String, "127.0.0.1:23456")

        let check = try await SingBoxProcess(binaryURL: singBoxURL).check(config: data)
        XCTAssertEqual(check.exitCode, 0, check.stderr)
    }

    /// 真内核：起得来、同一批节点不重起、测得出失败原因、关掉后 PID 文件清理。
    func testKernelStartsReusesAndShutsDown() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "delay-kernel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appending(path: "kernel.pid")
        let kernel = DelayTestKernel(binaryURL: singBoxURL, pidFileURL: pidFile)

        // 同时来两次准备（批量测速中又点了单个节点）：排队执行，都不能失败。
        let nodes = nodes
        async let first: Void = kernel.prepare(nodes: nodes, resolver: "223.5.5.5")
        async let second: Void = kernel.prepare(nodes: nodes, resolver: "223.5.5.5")
        _ = try await (first, second)
        let firstPID = try String(contentsOf: pidFile, encoding: .utf8)
        try await kernel.prepare(nodes: nodes, resolver: "223.5.5.5")
        XCTAssertEqual(try String(contentsOf: pidFile, encoding: .utf8), firstPID, "节点没变不该重起")

        // 127.0.0.1:1 上没有 SS 服务：应拿到失败而不是挂住。
        let result = await kernel.delay(
            of: nodes[0], testURL: URL(string: "http://www.gstatic.com/generate_204")!, timeoutMilliseconds: 1_500
        )
        guard case .failure = result else { return XCTFail("不该测成功：\(result)") }

        await kernel.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
        XCTAssertNotEqual(kill(Int32(firstPID)!, 0), 0, "内核进程应已退出")
    }

    /// PID 文件指向的不是测速内核（PID 已被别的程序复用）时不能误杀。
    func testStalePIDOfAnotherProgramIsNotKilled() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "delay-kernel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate() }
        let pidFile = directory.appending(path: "kernel.pid")
        try Data(String(sleeper.processIdentifier).utf8).write(to: pidFile)

        let kernel = DelayTestKernel(binaryURL: singBoxURL, pidFileURL: pidFile)
        try await kernel.prepare(nodes: nodes, resolver: "223.5.5.5")
        await kernel.shutdown()

        XCTAssertTrue(sleeper.isRunning)
    }

    private var singBoxURL: URL {
        TestPaths.vendoredKernel
    }
}
