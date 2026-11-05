import Foundation
import XCTest
@testable import KongshanCore

/// 输出超过管道缓冲（约 64 KB）的命令：以前等进程退出才读输出，子进程写不进管道、永远不退出，只能等到超时。
final class ProcessRunnerOutputTests: XCTestCase {
    func testLargeOutputDoesNotDeadlock() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "head -c 300000 /dev/zero | tr '\\0' a; head -c 100000 /dev/zero | tr '\\0' b >&2"],
            timeout: 10
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.count, 300_000)
        XCTAssertEqual(result.stderr.count, 100_000)
    }
}
