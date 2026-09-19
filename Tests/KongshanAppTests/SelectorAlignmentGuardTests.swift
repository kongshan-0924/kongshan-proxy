import Foundation
import XCTest

/// 节点选择对齐的源码守卫。
///
/// 内核每次（重）启动后都必须把各策略组的选择对齐到 App：TUN 的 `cache_file` 会让内核恢复缓存里的
/// 旧选择、忽略配置 default。只要有一条启动路径直接调 `healthVerifier`，那条路径起来的内核就可能
/// 沿用旧节点——界面选 A、流量走 B（2026-09-19 真机：TUN 下全部代理超时，订阅也更新不了）。
final class SelectorAlignmentGuardTests: XCTestCase {
    private var appStateSource: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return try String(contentsOf: root.appending(path: "Sources/kongshan/AppState.swift"), encoding: .utf8)
        }
    }

    func testEveryKernelStartGoesThroughVerifyKernel() throws {
        let source = try appStateSource
        let codeLines = source.split(separator: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
        let direct = codeLines.filter { $0.contains("healthVerifier(") }
        XCTAssertEqual(direct.count, 1, "healthVerifier 只能在 verifyKernel 里调用：\(direct)")

        let start = try XCTUnwrap(source.range(of: "private func verifyKernel("))
        let body = source[start.lowerBound...].prefix(300)
        XCTAssertTrue(body.contains("try await healthVerifier(client)"))
        XCTAssertTrue(body.contains("await alignSelections(client, config: config)"))

        let sites = source.components(separatedBy: "try await verifyKernel(client, config:").count - 1
        XCTAssertGreaterThanOrEqual(sites, 9, "启动 / 重载 / 回滚 / 崩溃自愈共 9 处都要对齐")
    }
}
