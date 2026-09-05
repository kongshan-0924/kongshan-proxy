import Foundation
import XCTest
@testable import KongshanCore

/// 系统授权弹窗的正文。
///
/// macOS 的 `do shell script … with administrator privileges` **不允许自定义弹窗里的请求者名称**
/// （那一栏由系统按发起进程显示），能改的只有这句正文。所以身份必须写在正文开头，
/// 否则用户看到的就是一个不知道谁在要密码的框。
final class AuthorizationPromptTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: "Sources/KongshanCore/\(name)"), encoding: .utf8)
    }

    func testBothPromptsLeadWithTheProductName() throws {
        for file in ["PrivilegedLauncher.swift", "PrivilegedHelperInstaller.swift"] {
            let text = try source(file)
            let line = try XCTUnwrap(
                text.split(separator: "\n").first { $0.contains("private static let prompt") },
                "\(file) 里找不到授权弹窗正文"
            )
            XCTAssertTrue(
                line.contains("\"空山代理TUN助手"),
                "\(file) 的授权正文必须以产品名开头，实际：\(line)"
            )
        }
    }
}
