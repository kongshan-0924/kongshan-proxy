import Foundation
import XCTest
@testable import KongshanCore
@testable import kongshan

/// 命中测试要认内置国内名单：名单内容是二进制规则集，交给内核 `rule-set match` 判定。
///
/// 不认的话，名单里的国内站在命中测试里显示「兜底 → 走代理」，与实际直连相反——
/// v0.2.10 的扩展名单让这类站多了很多，用户一测就像修复没生效。
@MainActor
final class ChinaListRouteTestWiringTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testRouteTestReportsDomainsInTheCachedExtraList() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-cn-list-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let ruleSets = root.appending(path: "rule-sets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: ruleSets, withIntermediateDirectories: true)
        let source = root.appending(path: "extra.json")
        try Data(#"{"version":1,"rules":[{"domain_suffix":["extra-cn.example"]}]}"#.utf8).write(to: source)
        let compiled = try await ProcessRunner.run(
            executable: packageRoot.appending(path: "Vendor/sing-box/sing-box"),
            arguments: ["rule-set", "compile", source.path, "-o", ruleSets.appending(path: "geosite-cn-extra.srs").path],
            timeout: 10
        )
        XCTAssertEqual(compiled.exitCode, 0, compiled.stderr)

        let state = AppState(storage: Storage(rootDirectory: root), automaticallyInitialize: false)
        XCTAssertEqual(state.outboundMode, .rule, "前提：默认规则模式")

        let hit = await state.testRoute(domain: "www.extra-cn.example", ip: nil, processName: nil)
        XCTAssertEqual(hit.source, .chinaList)
        XCTAssertEqual(hit.action, .direct)
        XCTAssertEqual(hit.matchedValue, "国内域名扩展名单")

        let miss = await state.testRoute(domain: "elsewhere.example", ip: nil, processName: nil)
        XCTAssertEqual(miss.source, .final)
    }
}
