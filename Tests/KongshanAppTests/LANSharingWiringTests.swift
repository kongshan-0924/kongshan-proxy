import Foundation
import XCTest
@testable import KongshanCore
@testable import kongshan

/// 局域网共享模块的接线回归。
@MainActor
final class LANSharingWiringTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-lan-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeState(root: URL) -> AppState {
        AppState(
            storage: Storage(rootDirectory: root),
            singBoxProcess: SingBoxProcess(binaryURL: URL(fileURLWithPath: "/usr/bin/false")),
            automaticallyInitialize: false
        )
    }

    /// 默认关闭。打开等于让同网段任何设备都能用你的出口，升级绝不能凭空把它打开。
    func testDefaultsOff() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(root: root)
        XCTAssertFalse(state.lanSharing.enabled)
        XCTAssertTrue(state.lanSharing.allowedCIDRs.isEmpty)
        XCTAssertNil(state.lanSharingBoundPort)
    }

    /// 开关要留运行事件：这是个影响安全边界的状态，事后必须能回答"什么时候开的"。
    func testTogglingRecordsRuntimeEvent() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(root: root)

        var settings = LANSharingSettings.defaults
        settings.enabled = true
        await state.applyLANSharing(settings)
        XCTAssertTrue(state.lanSharing.enabled)

        settings.enabled = false
        await state.applyLANSharing(settings)
        XCTAssertFalse(state.lanSharing.enabled)
        XCTAssertEqual(state.runtimeEvents.last?.title, "已关闭局域网共享")
    }

    /// 非法配置要就地拒绝并给出原因，不能静默存下一个起不来的设置。
    func testRejectsInvalidPortAndCIDR() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(root: root)

        await state.applyLANSharing(LANSharingSettings(enabled: true, port: 80, allowedCIDRs: []))
        XCTAssertFalse(state.lanSharing.enabled, "低端口要 root 才能绑，不该被接受")
        XCTAssertNotNil(state.errorMessage)

        state.dismissError()
        await state.applyLANSharing(LANSharingSettings(enabled: true, port: 7890, allowedCIDRs: ["不是网段"]))
        XCTAssertFalse(state.lanSharing.enabled)
        XCTAssertNotNil(state.errorMessage)
    }

    /// 代理没开时只存意图，不去起监听——那时起了也没有后端可转发。
    func testDoesNotStartListenerWhileProxyIsOff() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(root: root)
        await state.applyLANSharing(LANSharingSettings(enabled: true, port: 7890, allowedCIDRs: []))
        XCTAssertTrue(state.lanSharing.enabled)
        XCTAssertNil(state.lanSharingBoundPort, "没有后端时不该有绑定端口")
    }
}

/// 共享页的源码守卫：这一页的数值每秒刷新，动画修饰符会按刷新率持续重绘。
final class SharingViewGuardTests: XCTestCase {
    func testSharingViewCarriesNoPerFrameRedrawDrivers() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Sources/kongshan/SharingView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains(".animation("))
        XCTAssertFalse(source.contains(".contentTransition("))
        XCTAssertFalse(source.contains("style: .timer"))
        // 页面不可见时必须停掉每秒轮询，否则切走了还在烧 CPU。
        XCTAssertTrue(source.contains("stopLANClientsMonitoring"))
    }
}
