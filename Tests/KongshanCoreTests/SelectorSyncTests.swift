import Foundation
import XCTest
@testable import KongshanCore

/// 节点选择对齐。核心用例用真实内核复现 2026-09-19 的真机问题：开了 `cache_file` 时，
/// selector 启动后恢复缓存里的旧选择、忽略配置 `default`，界面与内核就此分叉。
final class SelectorSyncTests: XCTestCase {
    private var directory: URL!
    private var process: Process?

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "selector-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await stopKernel()
        try? FileManager.default.removeItem(at: directory)
    }

    private var singBoxURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Vendor/sing-box/sing-box")
    }

    /// 两个本地出站 + 两层 selector（H 默认指向组 G），不联网。
    private func config(port: UInt16, cache: Bool, groupDefault: String = "A-direct") throws -> Data {
        var experimental: [String: Any] = [
            "clash_api": ["external_controller": "127.0.0.1:\(port)", "secret": "s"]
        ]
        if cache {
            experimental["cache_file"] = [
                "enabled": true, "path": directory.appending(path: "cache.db").path, "store_fakeip": true
            ]
        }
        let root: [String: Any] = [
            "log": ["level": "error"],
            "outbounds": [
                ["type": "direct", "tag": "A-direct"],
                ["type": "block", "tag": "B-block"],
                ["type": "selector", "tag": "G", "outbounds": ["A-direct", "B-block"], "default": groupDefault],
                ["type": "selector", "tag": "H", "outbounds": ["G", "A-direct"], "default": "G"]
            ],
            "route": ["final": "H"],
            "experimental": experimental
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func startKernel(_ config: Data, port: UInt16) async throws -> ClashAPIClient {
        let file = directory.appending(path: "config.json")
        try config.write(to: file)
        let process = Process()
        process.executableURL = singBoxURL
        process.arguments = ["run", "-c", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        let client = ClashAPIClient(controller: URL(string: "http://127.0.0.1:\(port)")!, secret: "s")
        for _ in 0..<60 {
            if (try? await client.health()) != nil { return client }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("内核 3 秒内没有起来")
        return client
    }

    /// 停掉测试内核并确认它真的退出了。
    ///
    /// **不用 `waitUntilExit()`**：它在异步上下文里同步占住协作线程，内核若迟迟不退
    /// （比如还在等缓存文件锁），整个测试进程就挂死（2026-09-19 全量测试卡住 10 分钟即此）。
    /// 先 SIGTERM，5 秒不退再 SIGKILL。确认退出后缓存文件锁才释放，下一次启动才打得开同一个缓存。
    private func stopKernel() async {
        guard let process else { return }
        self.process = nil
        guard process.isRunning else { return }
        process.terminate()
        if await waitForExit(process, seconds: 5) { return }
        kill(process.processIdentifier, SIGKILL)
        _ = await waitForExit(process, seconds: 2)
    }

    private func waitForExit(_ process: Process, seconds: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !process.isRunning
    }

    func testIntendedSelectionsReadSelectorDefaults() throws {
        let intended = SelectorSync.intendedSelections(inConfig: try config(port: 1, cache: false))
        XCTAssertEqual(intended, ["G": "A-direct", "H": "G"])
        XCTAssertTrue(SelectorSync.intendedSelections(inConfig: Data("not json".utf8)).isEmpty)
    }

    /// **核心回归**：缓存把 G 恢复成旧选择 B-block，App 要的是 A-direct——对齐后内核回到 A，回读一致；
    /// 且下发会写进缓存，再重启时恢复出来的也已是 A。
    func testAlignOverridesSelectionRestoredFromCacheFile() async throws {
        let port = try RuntimeSecrets.availableHighPort()
        let config = try config(port: port, cache: true)

        var client = try await startKernel(config, port: port)
        try await client.select(node: "B-block", in: "G")   // 旧会话里选过 B
        await stopKernel()

        client = try await startKernel(config, port: port)
        let restored = try await client.selectorStates()
        XCTAssertEqual(restored["G"]?.now, "B-block", "前提：缓存覆盖了配置 default（这正是要修的分叉）")

        let outcome = try await SelectorSync.align(client, to: SelectorSync.intendedSelections(inConfig: config))
        XCTAssertEqual(outcome.corrected, ["G": SelectorSync.Correction(from: "B-block", to: "A-direct")])
        XCTAssertTrue(outcome.failed.isEmpty)
        let aligned = try await client.selectorStates()
        XCTAssertEqual(aligned["G"]?.now, "A-direct")
        XCTAssertEqual(aligned["H"]?.now, "G")
        await stopKernel()

        client = try await startKernel(config, port: port)
        let afterRestart = try await client.selectorStates()
        XCTAssertEqual(afterRestart["G"]?.now, "A-direct", "对齐时的下发写进了缓存，下次重启不再分叉")
    }

    func testAlignIsNoOpWhenAlreadyAligned() async throws {
        let port = try RuntimeSecrets.availableHighPort()
        let config = try config(port: port, cache: false)
        let client = try await startKernel(config, port: port)
        let outcome = try await SelectorSync.align(client, to: SelectorSync.intendedSelections(inConfig: config))
        XCTAssertEqual(outcome, SelectorSync.Outcome())
    }

    /// 目标不在可选成员里（比如节点已被订阅删掉）：如实报告，不去乱切。内核里没有的组直接跳过。
    func testUnselectableTargetIsReportedAndMissingGroupIsSkipped() async throws {
        let port = try RuntimeSecrets.availableHighPort()
        let client = try await startKernel(try config(port: port, cache: false), port: port)
        let outcome = try await SelectorSync.align(client, to: ["G": "已删除的节点", "不存在的组": "A-direct"])
        XCTAssertEqual(outcome.failed, ["G"])
        XCTAssertTrue(outcome.corrected.isEmpty)
        let states = try await client.selectorStates()
        XCTAssertEqual(states["G"]?.now, "A-direct")
    }

    func testSelectorStatesOnlyListSelectors() async throws {
        let port = try RuntimeSecrets.availableHighPort()
        let client = try await startKernel(try config(port: port, cache: false), port: port)
        let states = try await client.selectorStates()
        XCTAssertEqual(Set(states.keys), ["G", "H"])
        XCTAssertEqual(states["G"]?.all, ["A-direct", "B-block"])
    }
}
